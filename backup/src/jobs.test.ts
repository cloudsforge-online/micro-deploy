/**
 * Tests for the recurring-job scheduler.
 *
 * It had none, and what it got wrong was not subtle: it re-armed EVERY completed `backup.run`,
 * including the one-shots admin-api queues for a single requested artefact. Each of those became a
 * permanent nightly job pinned to a `backup_runs` row that had already succeeded. Measured on
 * mainnet 2026-08-10 — five one-shots drained, five re-armed for the next midnight, on the disk the
 * chain data shares.
 *
 * The scheduler is a pure function over job events, so this needs no queue and no database: a
 * recording double for `JobQueue.enqueue` is enough to assert exactly which rows come back.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BACKUP_PRUNE, BACKUP_RESTORE, BACKUP_RUN, BACKUP_VERIFY, leaseKeyFor, rescheduleRecurring } from './jobs.ts'
import { RecurringSchedule } from './jobs.ts'

const SCHEDULE_KEY = leaseKeyFor('mainnet')

interface Enqueued {
  kind: string
  key: string
  runAt?: Date
}

function harness() {
  const enqueued: Enqueued[] = []
  const queue = {
    enqueue: (job: Enqueued) => {
      enqueued.push(job)
      return Promise.resolve()
    },
  }
  const logged: string[] = []
  const logger = {
    info: (message: string) => logged.push(message),
    error: (message: string) => logged.push(message),
    warn: (message: string) => logged.push(message),
    debug: () => {},
  }
  const onEvent = rescheduleRecurring(
    queue as never,
    new RecurringSchedule(),
    logger as never,
    SCHEDULE_KEY,
  )
  return { enqueued, logged, onEvent }
}

test('the nightly schedule comes back after it completes', () => {
  const { enqueued, onEvent } = harness()
  onEvent({ type: 'completed', kind: BACKUP_RUN, key: SCHEDULE_KEY })

  assert.equal(enqueued.length, 1)
  assert.equal(enqueued[0]?.kind, BACKUP_RUN)
  assert.equal(enqueued[0]?.key, SCHEDULE_KEY)
  // A day out, not immediately — the whole point of a recurring tick.
  assert.ok((enqueued[0]?.runAt?.getTime() ?? 0) > Date.now() + 23 * 60 * 60_000)
})

test('a one-shot backup keyed by run id is run once and NOT put back', () => {
  // The defect, stated as a test. admin-api queues an operator-requested or schedule-driven backup
  // as `backup:<backup_run id>`; re-arming it makes a permanent nightly job out of a single
  // requested artefact, and pins it to a row that has already succeeded.
  const { enqueued, logged, onEvent } = harness()
  onEvent({ type: 'completed', kind: BACKUP_RUN, key: 'backup:7d33845e-521d-45cb-9931-8a91b47398d4' })

  assert.deepEqual(enqueued, [], 'a one-shot backup rescheduled itself')
  assert.ok(logged.some((line) => line.includes('one-shot')), 'the decision was not recorded anywhere')
})

test('five drained one-shots produce five backups and no sixth schedule', () => {
  // The estate's actual 2026-08-10 shape: a five-day backlog draining at once. Before the fix this
  // armed five nightly jobs; admin-api's own tick would then have added a sixth the next day, and
  // one more every day after that.
  const { enqueued, onEvent } = harness()
  for (const id of ['7d33845e', '38fee86a', 'b268e4ea', 'ba0943c6', 'ac5f19d8']) {
    onEvent({ type: 'completed', kind: BACKUP_RUN, key: `backup:${id}` })
  }
  assert.deepEqual(enqueued, [])
})

test('a failed or dead recurring job is not re-enqueued — the queue already owns the retry', () => {
  const { enqueued, onEvent } = harness()
  for (const type of ['failed', 'dead', 'error', 'started']) {
    onEvent({ type, kind: BACKUP_VERIFY, key: SCHEDULE_KEY })
  }
  assert.deepEqual(enqueued, [], 'rescheduling a failed row would be a second schedule for one key')
})

test('verify and prune recur; restore never does, however it is keyed', () => {
  const { enqueued, onEvent } = harness()
  onEvent({ type: 'completed', kind: BACKUP_VERIFY, key: SCHEDULE_KEY })
  onEvent({ type: 'completed', kind: BACKUP_PRUNE, key: SCHEDULE_KEY })
  // A restore happens because a person decided it should. One that came back on a timer would run
  // against live data with nobody asking.
  onEvent({ type: 'completed', kind: BACKUP_RESTORE, key: SCHEDULE_KEY })

  assert.deepEqual(
    enqueued.map((job) => job.kind),
    [BACKUP_VERIFY, BACKUP_PRUNE],
  )
})
