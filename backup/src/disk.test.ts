/**
 * Tests for `disk.ts` — the two refusals that stop this system filling the chain's disk, and the
 * one health signal the backup disk has (micro-org#207).
 *
 * These lived in `prune.test.ts`, which tests `prune.ts` and nothing else. They are here now because
 * the section below needed to grow and a reader looking for the coverage of a metric an alert pages
 * on should not have to guess that it is filed under retention.
 */

import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { Metrics } from '@cloudsforge/telemetry'
import { assertDestinationIsReal, assertSpaceAvailable, DestinationError, fsErrorsAt, majorMinorOf, SpaceError } from './disk.ts'

const GiB = 1_073_741_824n

// ── THE SPACE REFUSALS ───────────────────────────────────────────────────────────────────────

test('a run refuses when it would eat into min_free_bytes — the disk also holds the chain', () => {
  assert.throws(
    () =>
      assertSpaceAvailable({
        freeBytes: 110n * GiB,
        projectedBytes: 20n * GiB,
        existingBytes: 0n,
        minFreeBytes: 100n * GiB,
        ceilingBytes: 200n * GiB,
      }),
    SpaceError,
  )
})

test('a run refuses when the projected total would breach ceiling_bytes', () => {
  assert.throws(
    () =>
      assertSpaceAvailable({
        freeBytes: 1_000n * GiB,
        projectedBytes: 20n * GiB,
        existingBytes: 190n * GiB,
        minFreeBytes: 100n * GiB,
        ceilingBytes: 200n * GiB,
      }),
    SpaceError,
  )
})

test('a run that fits under both bounds proceeds', () => {
  assert.doesNotThrow(() =>
    assertSpaceAvailable({
      freeBytes: 1_400n * GiB,
      projectedBytes: 1n * GiB,
      existingBytes: 10n * GiB,
      minFreeBytes: 100n * GiB,
      ceilingBytes: 200n * GiB,
    }),
  )
})

// ── THE DESTINATION CANARY ───────────────────────────────────────────────────────────────────

test('a writable destination of a plausible size passes, and leaves no canary behind', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-dest-'))
  try {
    // A 1-byte floor, because the test filesystem is whatever the runner has. The floor that
    // matters in production is the 100 GiB default, which is what catches a container's ephemeral
    // overlay standing in for a 2 TB disk.
    await assertDestinationIsReal(dir, { minimumBytes: 1n })
    assert.deepEqual(await readdir(dir), [], 'the canary was not cleaned up')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a destination that does not exist refuses the boot rather than being created', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-dest-'))
  try {
    await assert.rejects(
      () => assertDestinationIsReal(join(dir, 'not-mounted'), { minimumBytes: 1n }),
      DestinationError,
    )
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a destination on an implausibly small filesystem is refused — that is the snap failure', async () => {
  // Snap-packaged Docker cannot see /data, so a bind of a path it cannot see silently becomes an
  // empty directory in the container's own ephemeral layer. Every write then "succeeds" and nothing
  // survives the container. Verified on the host 2026-08-05. The size floor is what makes that
  // loud: the real destination is a 2.0 TB ext4 filesystem, an overlay is not.
  const dir = await mkdtemp(join(tmpdir(), 'cf-dest-'))
  try {
    await assert.rejects(
      () => assertDestinationIsReal(dir, { minimumBytes: 2n ** 70n }),
      (err: unknown) => {
        assert.ok(err instanceof DestinationError)
        assert.match(err.message, /snap-packaged Docker cannot see \/data/)
        return true
      },
    )
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

// ── THE BACKUP DISK'S ONLY HEALTH SIGNAL (micro-org#207) ──────────────────────────────────────
//
// `/dev/sdb` is a Marvell 88SE9230 firmware array bound to `ahci`, so it exposes no SMART and no
// `-d` type can reach its members. ext4's superblock error counter is what is left. These tests
// cover the ways it can be wrong without anything noticing: naming the wrong device, turning
// "unreadable" into a zero, and — the one that matters most — never rising at all.

test('a device number decodes to the major:minor /sys/dev/block is indexed by', () => {
  // 2065 is the estate's own `/backups` on 2026-08-10 — `stat -c %d` inside the running
  // backup-runner container, and `/sys/dev/block/8:17` -> `…/block/sdb/sdb1`.
  assert.equal(majorMinorOf(2065n), '8:17')
  assert.equal(majorMinorOf(2050n), '8:2')
})

test('a minor past eight bits is not truncated — the high halves of both fields are decoded', () => {
  // The trap this guards is silent: a naive `dev & 0xff` names a REAL but DIFFERENT device, so the
  // metric would report some other disk's health under this disk's name. Worse than reporting none.
  // Built with the same split encoding glibc's makedev() uses, so these are the kernel's numbers
  // and not this function's own restated.
  const makedev = (major: bigint, minor: bigint) =>
    (minor & 0xffn) | ((major & 0xfffn) << 8n) | ((minor & 0xffffff00n) << 12n) | ((major & 0xfffff000n) << 32n)

  assert.equal(majorMinorOf(makedev(253n, 300n)), '253:300')
  assert.equal(majorMinorOf(makedev(4096n, 1n)), '4096:1')
  assert.equal(majorMinorOf(makedev(259n, 1048576n)), '259:1048576')
})

// ── A SYSFS THIS TEST BUILT, BECAUSE THE ONE ON THIS HOST CANNOT ANSWER THE QUESTION ──────────
//
// The whole point of `backup_destination_fs_errors` is that it goes ABOVE ZERO, and the alert on it
// is `> 0`. Nothing that reads the real `/sys` can demonstrate that: measured 2026-08-10,
// `/sys/fs/ext4/sdb1/errors_count` on the estate host is 0 and has always been 0, and the machines
// this suite runs on (macOS, and the CI runner's container) have no `/sys/fs/ext4` at all — every
// one of them can only produce the `null` branch. A suite built only from those would stay green if
// the entire read were replaced by `return null`, which is the same unearned green light this issue
// exists to complain about.
//
// So the sysfs is built here: an ordinary temporary directory shaped the way Linux shapes `/sys`.
// The one thing it does NOT fake is the device number — the tests stat a real directory on a real
// filesystem and key the fake `dev/block` entry off `majorMinorOf` of the `st_dev` the kernel gave
// it, so the decode is still exercised against a number this test did not invent.

/** The link target Linux writes for a partition on the estate's own controller, shape for shape. */
const SDB1 = '../../devices/pci0000:00/0000:00:02.2/0000:01:00.0/ata2/host2/target2:0:0/2:0:0:0/block/sdb/sdb1'

interface FakeSysfs {
  /** A real directory on a real filesystem. Its `st_dev` is what `fsErrorsAt` decodes. */
  readonly destination: string
  readonly sysfsRoot: string
}

async function withFakeSysfs(
  shape: { blockLink?: string; ext4?: Record<string, string> },
  body: (fs: FakeSysfs) => Promise<void>,
): Promise<void> {
  const base = await mkdtemp(join(tmpdir(), 'cf-sysfs-'))
  try {
    const destination = join(base, 'backups')
    const sysfsRoot = join(base, 'sys')
    await mkdir(destination)
    await mkdir(join(sysfsRoot, 'dev', 'block'), { recursive: true })

    if (shape.blockLink !== undefined) {
      const { dev } = await stat(destination, { bigint: true })
      // A dangling symlink on purpose: `fsErrorsAt` uses `readlink` and not `realpath`, so the
      // target is read and never walked. Building the whole `devices/…` tree would test nothing
      // extra and would misrepresent what the production code touches.
      await symlink(shape.blockLink, join(sysfsRoot, 'dev', 'block', majorMinorOf(dev)))
    }
    for (const [device, count] of Object.entries(shape.ext4 ?? {})) {
      await mkdir(join(sysfsRoot, 'fs', 'ext4', device), { recursive: true })
      await writeFile(join(sysfsRoot, 'fs', 'ext4', device, 'errors_count'), count)
    }

    await body({ destination, sysfsRoot })
  } finally {
    await rm(base, { recursive: true, force: true })
  }
}

test('THE GAUGE CAN GO UP: a non-zero errors_count is read, and carries the device it came from', async () => {
  // The one assertion the alert `backup_destination_fs_errors > 0` depends on. Without it nothing
  // in this repository distinguishes a working detector from a stub.
  await withFakeSysfs({ blockLink: SDB1, ext4: { sdb1: '3\n' } }, async ({ destination, sysfsRoot }) => {
    assert.deepEqual(await fsErrorsAt(destination, sysfsRoot), { device: 'sdb1', count: 3n })
  })
})

test('a clean filesystem publishes a ZERO, which is a claim, and not silence', async () => {
  // Zero and null are different facts and the alert treats them differently: a zero is ext4 saying
  // it has seen no error, and null is nobody having said anything. This is the half of that pair
  // that must not collapse into the other.
  await withFakeSysfs({ blockLink: SDB1, ext4: { sdb1: '0\n' } }, async ({ destination, sysfsRoot }) => {
    const errors = await fsErrorsAt(destination, sysfsRoot)
    assert.notEqual(errors, null, 'a readable zero must be published, not dropped')
    assert.deepEqual(errors, { device: 'sdb1', count: 0n })
  })
})

test('the whole width of the superblock field survives — the count is bigint, not a parseInt', async () => {
  // ext4's `s_error_count` is a __u32, so 4294967295 is the largest value this can ever legitimately
  // read. It is below 2^53 and would survive a Number today; asserting it as a bigint is what keeps
  // that true if the parse is ever rewritten.
  await withFakeSysfs({ blockLink: SDB1, ext4: { sdb1: '4294967295' } }, async ({ destination, sysfsRoot }) => {
    assert.deepEqual(await fsErrorsAt(destination, sysfsRoot), { device: 'sdb1', count: 4294967295n })
  })
})

test('the PARTITION is named, not the whole disk it sits on', async () => {
  // `/sys/fs/ext4` has an entry per mounted ext4 filesystem, and on this host that is `sdb1` — the
  // partition. A link resolved one segment short would read `sdb`, and if some other filesystem is
  // on that disk the alert would page naming the wrong one. Both entries exist here and only the
  // partition's count may be returned.
  await withFakeSysfs(
    { blockLink: SDB1, ext4: { sdb: '99', sdb1: '7' } },
    async ({ destination, sysfsRoot }) => {
      assert.deepEqual(await fsErrorsAt(destination, sysfsRoot), { device: 'sdb1', count: 7n })
    },
  )
})

test('a destination that is not ext4 publishes NOTHING, not a zero', async () => {
  // The device resolves, but there is no `/sys/fs/ext4` entry for it — xfs, btrfs, tmpfs, an
  // overlay. Zero here would be the unearned green light: "ext4 has seen no error on a filesystem
  // that is not ext4" is not a statement anything made.
  await withFakeSysfs({ blockLink: SDB1 }, async ({ destination, sysfsRoot }) => {
    assert.equal(await fsErrorsAt(destination, sysfsRoot), null)
  })
})

test('a device sysfs has no entry for publishes NOTHING', async () => {
  // No `dev/block/<major:minor>` at all. Reached on any kernel without sysfs, and inside a
  // container that was given one without `/sys` mounted.
  await withFakeSysfs({ ext4: { sdb1: '3' } }, async ({ destination, sysfsRoot }) => {
    assert.equal(await fsErrorsAt(destination, sysfsRoot), null)
  })
})

test('a counter that is not a number publishes NOTHING rather than a guess', async () => {
  // A file under `/sys` that exists and does not hold a decimal integer is a kernel this code does
  // not understand. Every one of these would become 0 or NaN under `parseInt`, and a NaN reaches
  // Prometheus as a sample the alert silently never fires on.
  for (const contents of ['', '\n', 'N/A\n', '-1\n', '0x11\n', '3 5\n', 'unknown']) {
    await withFakeSysfs({ blockLink: SDB1, ext4: { sdb1: contents } }, async ({ destination, sysfsRoot }) => {
      assert.equal(await fsErrorsAt(destination, sysfsRoot), null, `${JSON.stringify(contents)} was read as a count`)
    })
  }
})

test('a link that resolves to nothing publishes NOTHING', async () => {
  // A `dev/block` entry whose target ends in a separator leaves no device name. Defensive rather
  // than observed, and the branch exists so that a malformed sysfs cannot produce a gauge labelled
  // with the empty string.
  await withFakeSysfs({ blockLink: '../../devices/block/sdb/', ext4: { sdb1: '3' } }, async ({ destination, sysfsRoot }) => {
    assert.equal(await fsErrorsAt(destination, sysfsRoot), null)
  })
})

test('a path that does not exist is unreadable rather than an exception', async () => {
  // This runs inside the /metrics handler. A throw there would be an unhandled rejection on a
  // scrape, which is a way to lose the whole exposition over a question about one gauge.
  assert.equal(await fsErrorsAt('/nonexistent-cf-backup-destination'), null)
})

test('against the REAL /sys, this host answers without throwing and without inventing a device', async () => {
  // The default argument, exercised against whatever sysfs is actually here. On macOS and in the CI
  // container this is the `null` branch; on the estate host it is `sdb1` reading 0. Neither is
  // asserted, because the point of this one is only that the production call path — no injection —
  // stays total.
  const dir = await mkdtemp(join(tmpdir(), 'cf-fserr-'))
  try {
    const errors = await fsErrorsAt(dir)
    assert.ok(errors === null || typeof errors.count === 'bigint')
    if (errors) assert.match(errors.device, /^[a-zA-Z0-9_.-]+$/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

// ── THE EXPOSITION CONTRACT THE `null` DESIGN RESTS ON ────────────────────────────────────────

test('an unset gauge renders no sample, and a set one renders its device label', () => {
  // `fsErrorsAt` returning null is only honest if the caller's "leave it unset" really does mean no
  // sample. That is a property of `Metrics.render` in @cloudsforge/telemetry rather than of this
  // deployable — which is exactly why it is asserted here: this is the consumer that would be
  // wrong, silently and in the reassuring direction, if the behaviour ever changed to emit a 0.
  //
  // Registered with the same name and label as `index.ts` because the alert reads that name.
  const metrics = new Metrics().register({
    name: 'backup_destination_fs_errors',
    help: 'ext4 errors_count for the filesystem holding the backups, from its superblock',
    kind: 'gauge',
    labels: ['device'],
  })

  const silent = metrics.render()
  assert.match(silent, /# TYPE backup_destination_fs_errors gauge/, 'the metric should still be declared')
  assert.equal(
    silent.split('\n').filter((line) => line.startsWith('backup_destination_fs_errors')).length,
    0,
    'an unreadable filesystem must publish no sample at all, not a zero',
  )

  metrics.set('backup_destination_fs_errors', 3, { device: 'sdb1' })
  assert.match(metrics.render(), /^backup_destination_fs_errors\{device="sdb1"\} 3$/m)
})
