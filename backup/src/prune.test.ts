import assert from 'node:assert/strict'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { selectForPrune, type PrunableRun } from './prune.ts'
import { assertDestinationIsReal, assertSpaceAvailable, DestinationError, fsErrorsAt, majorMinorOf, SpaceError } from './disk.ts'

const GiB = 1_073_741_824n

function run(id: string, daysAgo: number, options: { bytes?: bigint; verified?: boolean } = {}): PrunableRun {
  return {
    id,
    queuedAt: new Date(Date.UTC(2026, 7, 5) - daysAgo * 86_400_000),
    totalBytes: options.bytes ?? GiB,
    verifiedAt: options.verified ? new Date() : null,
    directory: `/backups/mainnet/${id}`,
  }
}

test('retention keeps the newest N and prunes the rest, oldest first', () => {
  const runs = [run('a', 0), run('b', 1), run('c', 2), run('d', 3), run('e', 4)]
  const { toPrune } = selectForPrune(runs, { retentionCopies: 3, ceilingBytes: 100n * GiB })

  assert.deepEqual(
    toPrune.map((r) => r.id),
    ['e', 'd'],
  )
})

test('the NEWEST succeeded set is never pruned, even at retention 1', () => {
  const runs = [run('newest', 0), run('older', 1)]
  const { toPrune } = selectForPrune(runs, { retentionCopies: 1, ceilingBytes: 1n })

  assert.ok(!toPrune.some((r) => r.id === 'newest'))
  assert.deepEqual(
    toPrune.map((r) => r.id),
    ['older'],
  )
})

test('a single run is never pruned, whatever the policy says', () => {
  const { toPrune } = selectForPrune([run('only', 5)], { retentionCopies: 1, ceilingBytes: 1n })
  assert.equal(toPrune.length, 0)
})

test('the ONLY verified set survives, even when retention would take it', () => {
  // `old-verified` is the oldest and well outside retention, but it is the only set a restore has
  // ever proven — deleting it would trade the only evidence the system works for some disk. The two
  // survivors are therefore the newest and that one, and the ordinary sets in between go instead.
  const runs = [run('a', 0), run('b', 1), run('c', 2), run('old-verified', 9, { verified: true })]
  const { toPrune } = selectForPrune(runs, { retentionCopies: 2, ceilingBytes: 100n * GiB })

  assert.ok(!toPrune.some((r) => r.id === 'old-verified'))
  assert.ok(!toPrune.some((r) => r.id === 'a'))
  assert.deepEqual(
    toPrune.map((r) => r.id),
    ['c', 'b'],
  )
})

test('when several sets are verified, the oldest of them is ordinary and may be pruned', () => {
  const runs = [
    run('a', 0, { verified: true }),
    run('b', 1, { verified: true }),
    run('c', 2, { verified: true }),
    run('d', 3, { verified: true }),
  ]
  const { toPrune } = selectForPrune(runs, { retentionCopies: 2, ceilingBytes: 100n * GiB })

  assert.deepEqual(
    toPrune.map((r) => r.id),
    ['d', 'c'],
  )
})

test('the ceiling prunes further when retention alone leaves too much', () => {
  const runs = [run('a', 0, { bytes: 4n * GiB }), run('b', 1, { bytes: 4n * GiB }), run('c', 2, { bytes: 4n * GiB })]
  const { toPrune, keptBytes } = selectForPrune(runs, { retentionCopies: 3, ceilingBytes: 9n * GiB })

  // Retention would keep all three (12 GiB); the ceiling takes the oldest until it fits.
  assert.deepEqual(
    toPrune.map((r) => r.id),
    ['c'],
  )
  assert.equal(keptBytes, 8n * GiB)
})

test('a ceiling that cannot be met without deleting a protected set says so instead of doing it', () => {
  const runs = [run('newest', 0, { bytes: 50n * GiB }), run('verified', 1, { bytes: 50n * GiB, verified: true })]
  const { toPrune, reasons, keptBytes } = selectForPrune(runs, { retentionCopies: 1, ceilingBytes: 10n * GiB })

  assert.equal(toPrune.length, 0)
  assert.equal(keptBytes, 100n * GiB)
  assert.ok(reasons.some((reason) => reason.includes('ceiling_bytes is still exceeded')))
})

test('a run with no recorded size is counted as zero rather than crashing the selection', () => {
  const runs: PrunableRun[] = [run('a', 0), { ...run('b', 1), totalBytes: null }]
  assert.doesNotThrow(() => selectForPrune(runs, { retentionCopies: 5, ceilingBytes: GiB }))
})

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
// cover the two halves that can be wrong without anything noticing: naming the wrong device, and
// turning "unreadable" into a zero.

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

test('a destination with no readable error counter publishes NOTHING, not a zero', async () => {
  // A temporary directory is on whatever filesystem the test host has, and on macOS or a tmpfs
  // there is no `/sys/fs/ext4` at all. `null` is the required answer: zero would be a claim that
  // ext4 has seen no error on this filesystem, which is precisely the unearned green light this
  // whole issue is about.
  const dir = await mkdtemp(join(tmpdir(), 'cf-fserr-'))
  try {
    const errors = await fsErrorsAt(dir)
    assert.ok(errors === null || typeof errors.count === 'bigint')
    if (errors) assert.match(errors.device, /^[a-z0-9-]+$/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a path that does not exist is unreadable rather than an exception', async () => {
  // This runs inside the /metrics handler. A throw there would be an unhandled rejection on a
  // scrape, which is a way to lose the whole exposition over a question about one gauge.
  assert.equal(await fsErrorsAt('/nonexistent-cf-backup-destination'), null)
})
