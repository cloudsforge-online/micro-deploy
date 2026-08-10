import assert from 'node:assert/strict'
import test from 'node:test'
import { selectForPrune, type PrunableRun } from './prune.ts'

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
