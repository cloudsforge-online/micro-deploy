/**
 * The four kinds this process claims, and nothing else.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **ONE QUEUE, TWO PROCESSES, NO HANDLER COLLISION.**
 *
 * `JobRunner.claim()` filters by REGISTERED kind (`runtime/packages/jobs/src/index.ts:377`). This
 * process registers only `backup.*`; admin-api registers only its own four. Neither can take the
 * other's work even though both poll the same `jobs` table in the same database, and neither needs
 * to know the other exists. Migration 10's header states the consequence: if no runner is deployed,
 * the rows sit `queued` and the console says so — which is honest rather than silent.
 *
 * **THE LEASE KEY NAMES THE CONTENDED RESOURCE, NOT THE ROW.** That is the doctrine of
 * `@cloudsforge/jobs` and the thing most likely to be got wrong by someone extending this. Here the
 * contended resource for every one of the four kinds is **this environment's backup destination**:
 * two concurrent runs would write two directories to one disk against one ceiling; a prune racing a
 * run would delete a set being written; a verify racing a prune would restore from a directory
 * being removed. So the key is `backup:<environment>` for all four kinds, and the different KINDS
 * are what keep them from colliding with each other in the unique `(kind, key)`.
 *
 * **NO `setInterval` ANYWHERE.** Rule 8: every background timer is a leased job. A recurring job is
 * enqueued once and re-enqueued on completion, so the schedule survives a restart and cannot be run
 * twice by two replicas. CI greps the estate for `setInterval` doing domain work.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { JobQueue, JobRunner, backoffFor, type Handler } from '@cloudsforge/jobs'
import type { Logger } from '@cloudsforge/telemetry'
import { readSettings, type Sql } from './catalogue.ts'
import { BACKUP_RUN, createBackupHandler, type RunnerDeps } from './run.ts'
import { BACKUP_RESTORE, createRestoreHandler } from './restore.ts'
import { BACKUP_VERIFY, createVerifyHandler } from './verify.ts'
import { BACKUP_PRUNE, createPruneHandler } from './prune.ts'

export const SERVICE_PRINCIPAL = 'service:backup-runner'
export { BACKUP_RUN, BACKUP_RESTORE, BACKUP_VERIFY, BACKUP_PRUNE }

/** The lease key. One backup destination per environment; see the header. */
export function leaseKeyFor(environment: string): string {
  return `backup:${environment}`
}

/**
 * The kinds that come back on their own after they finish.
 *
 * `backup.restore` is NOT one of them, and that is the point of the list. A restore happens because
 * a person decided it should; a restore that rescheduled itself would be a restore nobody asked for
 * running against live data on a timer.
 */
export const RECURRING: ReadonlyArray<{ kind: string; defaultEveryMs: number }> = Object.freeze([
  { kind: BACKUP_RUN, defaultEveryMs: 24 * 60 * 60_000 },
  { kind: BACKUP_VERIFY, defaultEveryMs: 24 * 60 * 60_000 },
  // More often than the others: it is cheap, it only ever removes what policy says may go, and the
  // condition it relieves — a full disk — is shared with the chain.
  { kind: BACKUP_PRUNE, defaultEveryMs: 6 * 60 * 60_000 },
])

/**
 * The live intervals, as last read from `backup_settings`.
 *
 * A cadence an operator changes in the panel should take effect on the next cycle, and the handlers
 * are the things that read the settings — so they publish what they read here and the rescheduler
 * uses it. Defaults apply until the first run of each kind.
 */
export class RecurringSchedule {
  readonly #everyMs = new Map<string, number>(RECURRING.map((entry) => [entry.kind, entry.defaultEveryMs]))

  set(kind: string, everyMs: number): void {
    this.#everyMs.set(kind, everyMs)
  }

  get(kind: string): number {
    return this.#everyMs.get(kind) ?? 24 * 60 * 60_000
  }
}

export function registerHandlers(runner: JobRunner, deps: RunnerDeps, schedule: RecurringSchedule): JobRunner {
  return runner
    .register(BACKUP_RUN, withScheduleRefresh(deps, schedule, BACKUP_RUN, createBackupHandler(deps)))
    .register(BACKUP_RESTORE, createRestoreHandler(deps))
    .register(BACKUP_VERIFY, withScheduleRefresh(deps, schedule, BACKUP_VERIFY, createVerifyHandler(deps)))
    .register(BACKUP_PRUNE, createPruneHandler(deps))
}

/**
 * Publish the cadence this kind should next run at, read from the settings row the handler is about
 * to act on anyway.
 *
 * Wrapped rather than folded into each handler so that the handlers stay about backups and this
 * stays about scheduling.
 */
function withScheduleRefresh(
  deps: RunnerDeps,
  schedule: RecurringSchedule,
  kind: string,
  handler: Handler,
): Handler {
  return async (job, ctx) => {
    try {
      const settings = await readSettings(deps.admin)
      const minutes = kind === BACKUP_VERIFY ? settings.verifyEveryMinutes : settings.scheduleEveryMinutes
      schedule.set(kind, minutes * 60_000)
      if (kind === BACKUP_RUN && !settings.scheduleEnabled) {
        // Disabled means "do not take scheduled backups", not "stop scheduling" — the row is still
        // re-enqueued below so that re-enabling it in the panel takes effect without a restart.
        // An operator-requested run carries a backupRunId in its payload and is never skipped.
        if (typeof job.payload['backupRunId'] !== 'string') {
          deps.logger.info('scheduled backups are disabled in backup_settings; skipping this cycle')
          return
        }
      }
    } catch (err) {
      // A settings read that fails must not stop the work: the defaults are sane and a backup not
      // taken because a settings query timed out is a worse outcome than one taken on last cycle's
      // cadence.
      deps.logger.warn('could not refresh the schedule from backup_settings', { kind, err })
    }
    await handler(job, ctx)
  }
}

/**
 * Put the recurring jobs in the queue once — **unless something already schedules them.**
 *
 * admin-api owns `backup_settings` and the operator console, and may well enqueue the schedule
 * itself. If it does, seeding a second row here under a different key would give the estate two
 * nightly backups: the unique `(kind, key)` collapses duplicates only when the keys agree, and two
 * processes that each chose a key have no reason to agree.
 *
 * So this seeds a kind only when NO row of that kind exists at all. Whoever gets there first owns
 * the schedule, and `rescheduleRecurring` re-enqueues under the completed job's own key, so the
 * ownership survives every cycle. The cost is that a kind whose only row is dead-lettered will not
 * be re-seeded — which is correct: a dead-lettered recurring job is a durable record that the work
 * was requested and never done, and quietly creating a fresh one would erase it.
 */
export async function seedRecurring(sql: Sql, queue: JobQueue, environment: string, logger: Logger): Promise<void> {
  const key = leaseKeyFor(environment)
  for (const entry of RECURRING) {
    const existing = await sql<{ kind: string }[]>`select kind from jobs where kind = ${entry.kind} limit 1`
    if (existing.length > 0) continue
    await queue.enqueue({ kind: entry.kind, key, onConflict: 'keep' })
    logger.info('seeded a recurring job', { kind: entry.kind, key })
  }
}

/**
 * Put a recurring job back after it runs.
 *
 * **Only on `completed`.** `JobQueue.fail` already reschedules a failed row with backoff, so
 * re-enqueueing after a failure would be a second schedule for the same key. The verify job depends
 * on that: a backup that does not restore throws, the queue retries with backoff, and the retries
 * stop being free once the row dead-letters — which is what leaves a durable record that
 * verification could not pass.
 *
 * The event's OWN key is reused rather than this process's, so a schedule seeded by admin-api stays
 * where admin-api put it.
 */
export function rescheduleRecurring(
  queue: JobQueue,
  schedule: RecurringSchedule,
  logger: Logger,
): (event: { type: string; kind?: string; key?: string }) => void {
  const kinds = new Set(RECURRING.map((entry) => entry.kind))
  return (event) => {
    if (event.type !== 'completed' || !event.kind || !event.key || !kinds.has(event.kind)) return
    void queue
      .enqueue({
        kind: event.kind,
        key: event.key,
        runAt: new Date(Date.now() + schedule.get(event.kind)),
        onConflict: 'earliest',
      })
      .catch((err: unknown) => logger.error('could not reschedule a recurring job', { kind: event.kind, err }))
  }
}

export { backoffFor }
