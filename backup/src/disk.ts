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
import { readFile, rm, stat, statfs, writeFile } from 'node:fs/promises'

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
