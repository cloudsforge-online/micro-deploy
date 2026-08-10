/**
 * The two refusals that stop this system taking the host down with it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * A backup process is, mechanically, a program whose job is to fill a disk. On this host that disk
 * is `/dev/sdb1`, and `/dev/sdb1` also holds `/data/chains` — 553 GB of Bitcoin, Litecoin and
 * Dogecoin block data that the miner is actively writing to. Filling it does not degrade the
 * backup system, it stops the chain.
 *
 * So there are two independent bounds, and `backup_settings` states both as CHECK-constrained
 * columns rather than as configuration:
 *
 *   `ceiling_bytes`   what THIS system may occupy in total. Enforced before a run starts and again
 *                     by `backup.prune` afterwards.
 *   `min_free_bytes`  what must remain free on the filesystem WHATEVER the ceiling says. The
 *                     ceiling protects the disk from this system; this protects it from everything
 *                     else sharing the disk — including the chain growing while backups sat still.
 *
 * Both are checked BEFORE the first byte is written. A run that discovers it cannot fit halfway
 * through has already done the damage: `ENOSPC` reaches the miner and the backup system at the
 * same instant, and only one of them is supposed to be a problem.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { randomUUID } from 'node:crypto'
import { readFile, readlink, rm, stat, statfs, writeFile } from 'node:fs/promises'

export class SpaceError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SpaceError'
  }
}

export class DestinationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'DestinationError'
  }
}

/**
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **PROVE THE DESTINATION IS REAL BEFORE CLAIMING ANY WORK.**
 *
 * This is not paranoia about disks. It is a specific, measured, SILENT failure on this host, and it
 * is the worst failure mode a backup system can have.
 *
 * Docker here is the **Canonical snap** (`docker 29.3.1 rev 3505, publisher canonical`). Snap
 * confinement grants the `docker:home` interface but not `removable-media`, so the daemon cannot
 * see `/data` at all. A bind of `/data/cloudsforge-backups:/backups` therefore does not fail — the
 * container gets an **empty directory in its own ephemeral layer**, every write "succeeds", and the
 * bytes are destroyed when the container stops. Verified on the host 2026-08-05: a canary written
 * through a `/data` bind was not present on the host afterwards; the same write through
 * `/home/malf/cloudsforge-backups` was.
 *
 * Nothing else in this system would notice. `pg_dump` exits 0, the checksum is computed from the
 * stream and is correct, `statfs` reports the container filesystem's space, the manifest is written,
 * and `backup_runs` says `succeeded` with a perfectly good `manifest_sha256`. Every green light in
 * this repository stays green while the estate has no backups whatsoever.
 *
 * The permanent fix is on the host: `/data/cloudsforge-backups` is bind-mounted at
 * `/home/malf/cloudsforge-backups` (in `/etc/fstab`, `nofail`), which snap docker CAN see, and the
 * bytes still land on `/dev/sdb1`. The compose overlay binds that path. This check is what makes
 * the fix's absence loud rather than invisible — if somebody later edits the overlay back to
 * `/data`, the runner refuses to start instead of silently backing up nothing.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Write, read back, stat, remove. The read-back is the part that matters: a write into an ephemeral
 * layer is readable by the same container, so this cannot prove the host sees it — but it does
 * prove the path is writable and durable within this process's own view, and it is paired with
 * `expectedFilesystemBytes` below, which catches the ephemeral layer by its size.
 */
export async function assertDestinationIsReal(root: string, options: { minimumBytes?: bigint } = {}): Promise<void> {
  const canary = `${root}/.cf-backup-canary-${randomUUID()}`
  const contents = `cloudsforge-backup canary ${new Date().toISOString()}\n`

  try {
    await writeFile(canary, contents, { mode: 0o600 })
    const readBack = await readFile(canary, 'utf8')
    if (readBack !== contents) {
      throw new DestinationError(`${root} did not read back what was written to it`)
    }
    const info = await stat(canary)
    if (info.size !== Buffer.byteLength(contents)) {
      throw new DestinationError(`${root} reports a different size than was written`)
    }
  } catch (err) {
    if (err instanceof DestinationError) throw err
    throw new DestinationError(
      `the backup destination ${root} is not writable: ${err instanceof Error ? err.message : String(err)}`,
    )
  } finally {
    await rm(canary, { force: true }).catch(() => {})
  }

  // The size check that catches the snap failure specifically. The real destination is a 2.0 TB
  // ext4 filesystem with 1.4 TB free; a container's ephemeral overlay is the root filesystem's,
  // which on this host is a different and much smaller device. A destination that reports less than
  // a floor no real backup disk would be under is a destination that is not the backup disk.
  const minimum = options.minimumBytes ?? 100n * 1_073_741_824n
  const stats = await statfs(root, { bigint: true })
  const total = stats.bsize * stats.blocks
  if (total < minimum) {
    throw new DestinationError(
      `the backup destination ${root} is on a filesystem of only ${total} bytes, below the ${minimum}-byte floor. ` +
        `On this host that means the bind mount is not what it should be — snap-packaged Docker cannot see /data, ` +
        `and a bind of a path it cannot see silently becomes an empty ephemeral directory. Bind ` +
        `/home/malf/cloudsforge-backups instead.`,
    )
  }
}

/** Bytes available to an unprivileged writer — `bavail`, not `bfree`, which counts root's reserve. */
export async function freeBytesAt(path: string): Promise<bigint> {
  const stats = await statfs(path, { bigint: true })
  return stats.bsize * stats.bavail
}

// ══════════════════════════════════════════════════════════════════════════════════════════════
// THE ONLY HEALTH SIGNAL THE BACKUP DISK HAS, BECAUSE IT HAS NO SMART (micro-org#207).
//
// `/dev/sdb` is a MARVELL 88SE9230 virtual disk. `smartctl -H /dev/sdb` answers "device lacks SMART
// capability", and on 2026-08-10 the "we used the wrong `-d` type" hypothesis was closed for good:
// the controller is bound to `ahci`, not to a RAID driver (`/sys/class/scsi_host/host2/proc_name`
// is `ahci`, `lsmod` shows no `mv*`/`megaraid_sas`), so the card does its array in FIRMWARE and
// hands the kernel one ordinary SATA device. The member disks are not devices Linux has ever seen.
// There is no `-d` value that can work and none should be tried. `mvcli` is in no Ubuntu archive.
//
// So reallocated sectors, pending sectors and power-on hours are all permanently unknown for the
// disk that holds every backup this estate has. What is NOT unknown is whether ext4 has hit an
// error on it: ext4 keeps a counter in the SUPERBLOCK and exposes it read-only under `/sys`, so it
// survives a reboot and a remount, needs no root, no smartmontools and no privileged container —
// which is why this lives in the process that already has the destination mounted rather than in a
// node_exporter nobody has deployed. Confirmed readable from inside the runner's own container on
// 2026-08-10: `/sys` is an ordinary sysfs mount there, `/sys/fs/ext4/sdb1/errors_count` -> `0`.
//
// **READ THE LIMIT BEFORE TRUSTING THE NUMBER.** This counts errors EXT4 ITSELF detects — I/O and
// metadata errors it handles. A read error on file data returned straight to a caller is not one,
// and it predicts NOTHING: a disk days from failure reads zero here until the first failure. It is
// a smoke alarm, not a thermometer. That is still strictly more than the estate had, which was
// nothing at all.
// ══════════════════════════════════════════════════════════════════════════════════════════════

export interface FilesystemErrors {
  /** The kernel's name for the block device, e.g. `sdb1` — the key `/sys/fs/ext4` is indexed by. */
  readonly device: string
  readonly count: bigint
}

/**
 * `st_dev` as the `major:minor` string `/sys/dev/block` is indexed by.
 *
 * Linux's `dev_t` is not `major << 8 | minor`; it is the split encoding glibc's `major()`/`minor()`
 * macros decode, with the high bits of each field living above bit 32. Reproducing it here rather
 * than shelling out to `stat -c %t:%T` keeps this a pure function with no process to fail — and the
 * wide fields are not hypothetical: the estate's own device is 8:17, but a `dm-` or NVMe minor on a
 * larger host runs past 8 bits and a naive `& 0xff` would silently name the wrong device.
 *
 * Exported for the test, which is the only way to exercise the wide-field halves on a host whose
 * every device number is small.
 */
export function majorMinorOf(dev: bigint): string {
  // The second term of each field is masked to 32 BITS and not merely to "everything above the low
  // byte". glibc's macros cast that half to `unsigned int` before masking, and the cast is load
  // bearing: without it a major above 0xfff bleeds its high bits down into the minor — the test
  // caught exactly that, `makedev(4096, 1)` decoding as minor 4294967297 instead of 1.
  const major = ((dev >> 8n) & 0xfffn) | ((dev >> 32n) & 0xfffff000n)
  const minor = (dev & 0xffn) | ((dev >> 12n) & 0xffffff00n)
  return `${major}:${minor}`
}

/**
 * The ext4 error count for the filesystem `path` is on, or `null` when there is not one to read.
 *
 * `null` — and NOT zero — for a destination that is not ext4, or a kernel that does not export the
 * counter. Zero is a claim: "ext4 has seen no error on this filesystem". A destination whose health
 * is unreadable has not made that claim, and publishing a zero for it would put this metric in the
 * same class as the disk it is trying to make up for: a green light that means nothing was asked.
 * The caller leaves the gauge unset, and `Metrics.render` then emits no sample at all.
 *
 * The device is resolved from `st_dev` rather than configured. A `BACKUP_DESTINATION_DEVICE`
 * variable would be one more thing to set correctly on a host where the destination already moves
 * through a bind mount (`/home/malf/cloudsforge-backups` -> `/data/cloudsforge-backups` on
 * `/dev/sdb1`) — and a stale value would report a different disk's health under this disk's name,
 * which is worse than reporting none. `stat` follows the bind to the real filesystem for free.
 */
export async function fsErrorsAt(path: string): Promise<FilesystemErrors | null> {
  const info = await stat(path, { bigint: true }).catch(() => null)
  if (!info) return null

  // `/sys/dev/block/8:17` -> `../../devices/…/block/sdb/sdb1`. The last segment is the name
  // `/sys/fs/ext4` uses. `readlink` and not `realpath`, because the target of the link is all that
  // is wanted and resolving it would touch every directory on the way.
  const link = await readlink(`/sys/dev/block/${majorMinorOf(info.dev)}`).catch(() => null)
  const device = link?.split('/').pop()
  if (!device) return null

  const raw = await readFile(`/sys/fs/ext4/${device}/errors_count`, 'utf8').catch(() => null)
  if (raw === null) return null

  // A file under `/sys` that exists and does not hold a number is a kernel this code does not
  // understand, which is a reason to publish nothing rather than to publish a guess.
  const trimmed = raw.trim()
  if (!/^\d+$/.test(trimmed)) return null

  return { device, count: BigInt(trimmed) }
}

export interface SpaceDecision {
  readonly freeBytes: bigint
  readonly projectedBytes: bigint
  readonly existingBytes: bigint
  readonly minFreeBytes: bigint
  readonly ceilingBytes: bigint
}

/**
 * Refuse, with a sentence an operator can act on, or return.
 *
 * The projection is **uncompressed source size**, deliberately. `pg_dump -Fc` compresses and a
 * gzipped tarball of PNGs does not, so the real figure lands somewhere below this — which makes
 * this a conservative bound rather than an estimate that can be wrong in the dangerous direction.
 * A run that is refused when it would in fact have fitted costs an operator a settings change; a
 * run that is allowed when it does not fit costs the chain.
 *
 * Pure, so the arithmetic is testable without a filesystem: every input is a number.
 */
export function assertSpaceAvailable(decision: SpaceDecision): void {
  if (decision.freeBytes - decision.projectedBytes < decision.minFreeBytes) {
    throw new SpaceError(
      `refusing to start: ${decision.freeBytes} bytes free, this run projects ${decision.projectedBytes}, ` +
        `and min_free_bytes requires ${decision.minFreeBytes} to remain. Prune older sets or lower the ` +
        `projection — this disk also holds the chain.`,
    )
  }
  if (decision.existingBytes + decision.projectedBytes > decision.ceilingBytes) {
    throw new SpaceError(
      `refusing to start: backups already occupy ${decision.existingBytes} bytes and this run projects ` +
        `${decision.projectedBytes}, which breaches the ceiling_bytes of ${decision.ceilingBytes}. ` +
        `Run backup.prune or raise the ceiling deliberately.`,
    )
  }
}
