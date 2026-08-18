/**
 * `lastSucceededAt`, which is the read that decides whether this estate publishes a
 * "when was the last backup" series at all.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **WHAT A FAKE `sql` CAN AND CANNOT PROVE, STATED UP FRONT.**
 *
 * It cannot prove the SQL is valid, that the index is used, or that Postgres returns a `Date` — a
 * cluster is the only thing that can, and `catalogue.ts` has no test beside it today for exactly
 * that reason. What it CAN prove is the decision this function exists to make, which is not a
 * database question at all: **no row must become `null`, and never a zero.** That is the difference
 * between "nothing has ever backed this estate up" and "the last backup was in 1970", and the whole
 * of `BackupNeverRun` rests on it.
 *
 * The query text is asserted too, narrowly and for one reason each: a read that lost
 * `state = 'succeeded'` would seed the gauge from a FAILED run, and a read that lost
 * `order by ... desc` would seed it from the oldest. Both produce a plausible number, both make the
 * page green, and neither is visible in the return type.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { lastSucceededAt, lastVerifiedAt, type Sql } from './catalogue.ts'

interface Recorded {
  readonly text: string
  readonly values: readonly unknown[]
}

/** The smallest thing that answers a tagged-template query and records what it was asked. */
function fakeSql(rows: readonly unknown[]): { sql: Sql; asked: Recorded[] } {
  const asked: Recorded[] = []
  const sql = (strings: TemplateStringsArray, ...values: unknown[]) => {
    asked.push({ text: strings.join('?'), values })
    return Promise.resolve(rows)
  }
  return { sql: sql as unknown as Sql, asked }
}

test('a succeeded run comes back as the moment it FINISHED', async () => {
  const finishedAt = new Date('2026-08-10T02:15:00.000Z')
  const { sql } = fakeSql([{ finished_at: finishedAt }])

  assert.deepEqual(await lastSucceededAt(sql, 'mainnet'), finishedAt)
})

test('NO succeeded run is null — never a zero, never an epoch', async () => {
  // The one behaviour that matters. A caller seeding a gauge with `0` would publish a series
  // claiming the estate was last backed up in 1970: an age of fifty-six years, which satisfies
  // every staleness threshold anyone would write and therefore reads as a backup that happened.
  // Nothing has. Measured on mainnet 2026-08-10: `/data/cloudsforge-backups` is empty and no
  // backup-runner container exists, so this is the estate's actual state and not a hypothetical.
  const { sql } = fakeSql([])

  const result = await lastSucceededAt(sql, 'mainnet')
  assert.equal(result, null)
  assert.notEqual(result, 0)
})

test('the environment is a PARAMETER, so one estate cannot seed its gauge from the other', async () => {
  // The same refusal `manifest.ts` and the `restore_runs` trigger make on the restore path, at the
  // one place a mainnet process could otherwise read a testnet fact and publish it as its own.
  const { sql, asked } = fakeSql([])
  await lastSucceededAt(sql, 'testnet')

  assert.equal(asked.length, 1)
  assert.deepEqual(asked[0]?.values, ['testnet'])
  assert.ok(!asked[0]?.text.includes('testnet'), 'the environment must not be interpolated into the text')
})

test('the read is the NEWEST SUCCEEDED run and nothing else', async () => {
  const { sql, asked } = fakeSql([])
  await lastSucceededAt(sql, 'mainnet')
  const text = asked[0]?.text ?? ''

  // Without this, a failed run — which also carries a `finished_at`, by
  // `backup_runs_terminal_is_finished` — would seed the gauge and the age page would go green on a
  // backup that produced nothing restorable.
  assert.match(text, /state = 'succeeded'/)
  // Without this, the gauge is seeded from the OLDEST run, which is a page that fires for ever
  // against an estate that is backing itself up correctly.
  assert.match(text, /order by finished_at desc/)
  assert.match(text, /limit 1/)
})

// ══════════════════════════════════════════════════════════════════════════════════════════════
// `lastVerifiedAt` — the same decision about the twin gauge, which had no boot-time read at all
// until a host reboot on 2026-08-18 proved what that costs: sets verified every night from 08-14
// to 08-18, `backup.verify` armed and not dead, and `backup_last_verified_unixtime` absent anyway
// because the only writer is the verify path. The checker then reported the job as dead-lettered.
// ══════════════════════════════════════════════════════════════════════════════════════════════

test('a verified run comes back as the moment it was PROVEN, not the moment it was written', async () => {
  // Deliberately different from `finished_at`: the verify runs minutes-to-hours after the backup,
  // and the question this gauge answers is when a restore last succeeded — not when a file landed.
  const verifiedAt = new Date('2026-08-18T03:00:09.821Z')
  const { sql } = fakeSql([{ verified_at: verifiedAt }])

  assert.deepEqual(await lastVerifiedAt(sql, 'mainnet'), verifiedAt)
})

test('NO verified run is null — an unproven estate must not publish a proof', async () => {
  // The worse half of the same distinction. Zero here would claim a set was restored in 1970,
  // satisfying any "has this ever been verified" reading, on an estate where nothing ever has.
  const { sql } = fakeSql([])

  const result = await lastVerifiedAt(sql, 'mainnet')
  assert.equal(result, null)
  assert.notEqual(result, 0)
})

test('the verified read is scoped to its own environment', async () => {
  const { sql, asked } = fakeSql([])
  await lastVerifiedAt(sql, 'testnet')

  assert.equal(asked.length, 1)
  assert.deepEqual(asked[0]?.values, ['testnet'])
  assert.ok(!asked[0]?.text.includes('testnet'), 'the environment must not be interpolated into the text')
})

test('the verified read takes the NEWEST proof, and only from a set that still exists', async () => {
  const { sql, asked } = fakeSql([])
  await lastVerifiedAt(sql, 'mainnet')
  const text = asked[0]?.text ?? ''

  // A PRUNED row keeps the `verified_at` it earned while its files existed. Without this predicate
  // the estate would publish a proof about a set it has since deleted — the most convincing form of
  // the false green this metric exists to prevent.
  assert.match(text, /state = 'succeeded'/)
  // `verified_at is not null` and not `finished_at`: every succeeded row has the latter, so ordering
  // without this predicate would return the newest BACKUP and read its empty `verified_at` as the
  // answer, publishing nothing on an estate that verifies nightly.
  assert.match(text, /verified_at is not null/)
  assert.match(text, /order by verified_at desc/)
  assert.match(text, /limit 1/)
})
