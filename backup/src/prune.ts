/**
 * `backup.prune` — reclaiming disk, and the three sets it may never reclaim.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE SELECTION IS PURE AND IS TESTED, BECAUSE THIS IS THE ONE JOB THAT DELETES THINGS.**
 *
 * Every other handler in this deployable writes. This one removes, and a bug in it destroys the
 * artefact the system exists to hold. So the decision is a pure function over rows — no filesystem,
 * no clock, no database — and the effects are applied by a caller that does nothing else.
 *
 * Three sets are never selected, and none of the three is a nicety:
 *
 *   **The newest succeeded set.** Retention of 1 must still mean one. A prune that can empty the
 *   catalogue is a prune that, on the day someone sets `retention_copies` low by accident, leaves
 *   the estate with no backup at all and a green console.
 *
 *   **The only verified set.** `verified_at` means a restore actually proved this set works
 *   (`verify.ts`). If exactly one set has ever been proven, that set is the only evidence the whole
 *   system functions, and deleting it to save space trades the proof for the disk. When several are
 *   verified the oldest of them is ordinary and may go.
 *
 *   **Anything not `succeeded`.** A `running` set is being written to right now; a `failed` one is
 *   the evidence of what went wrong. Neither is this job's to remove — `failed` sets are cleaned by
 *   an operator who has read them.
 *
 * Oldest first, in both passes, because the oldest set is the one whose data is least like today's.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { rm } from 'node:fs/promises'
import type { Handler } from '@cloudsforge/jobs'
import { listSucceededRuns, markPruned, readSettings } from './catalogue.ts'
import { assertSafeRootPath, errorText } from './paths.ts'
import type { RunnerDeps } from './run.ts'

export const BACKUP_PRUNE = 'backup.prune'

export interface PrunableRun {
  readonly id: string
  readonly queuedAt: Date
  readonly totalBytes: bigint | null
  readonly verifiedAt: Date | null
  readonly directory: string | null
}

export interface PruneSelection<T extends PrunableRun> {
  readonly toPrune: readonly T[]
  readonly keptBytes: bigint
  readonly reasons: readonly string[]
}

/**
 * Decide what goes.
 *
 * Two passes over the same ordering, and the order matters: retention first, then the ceiling. A
 * ceiling-first pass would delete recent sets to fit a ceiling that the retention pass was about to
 * make room for anyway.
 *
 * `retentionCopies` counts SUCCEEDED sets, not directories. A failed run occupies disk and is not
 * a copy of anything, so counting it would silently reduce the number of usable backups kept.
 */
export function selectForPrune<T extends PrunableRun>(
  succeeded: readonly T[],
  policy: { retentionCopies: number; ceilingBytes: bigint },
): PruneSelection<T> {
  // Newest first for the retention decision; the tail of this list is the pruning order.
  const newestFirst = [...succeeded].sort((a, b) => b.queuedAt.getTime() - a.queuedAt.getTime())
  const verifiedCount = newestFirst.filter((run) => run.verifiedAt !== null).length

  const protectedIds = new Set<string>()
  const reasons: string[] = []

  const newest = newestFirst[0]
  if (newest) {
    protectedIds.add(newest.id)
    reasons.push(`kept ${newest.id}: it is the newest succeeded set`)
  }
  if (verifiedCount === 1) {
    const onlyVerified = newestFirst.find((run) => run.verifiedAt !== null)
    if (onlyVerified && !protectedIds.has(onlyVerified.id)) {
      protectedIds.add(onlyVerified.id)
      reasons.push(`kept ${onlyVerified.id}: it is the only set a restore has ever proven`)
    }
  }

  const toPrune: T[] = []
  const oldestFirst = [...newestFirst].reverse()

  // ── Pass 1: retention. Everything beyond `retentionCopies`, oldest first.
  const keepCount = Math.max(1, policy.retentionCopies)
  let remaining = newestFirst.length
  for (const run of oldestFirst) {
    if (remaining <= keepCount) break
    if (protectedIds.has(run.id)) continue
    toPrune.push(run)
    remaining -= 1
  }

  // ── Pass 2: the ceiling. Whatever survived pass 1 must still fit.
  const pruned = new Set(toPrune.map((run) => run.id))
  let keptBytes = newestFirst
    .filter((run) => !pruned.has(run.id))
    .reduce((sum, run) => sum + (run.totalBytes ?? 0n), 0n)

  for (const run of oldestFirst) {
    if (keptBytes <= policy.ceilingBytes) break
    if (pruned.has(run.id) || protectedIds.has(run.id)) continue
    toPrune.push(run)
    pruned.add(run.id)
    keptBytes -= run.totalBytes ?? 0n
    reasons.push(`pruned ${run.id}: the retained set still exceeded ceiling_bytes`)
  }

  if (keptBytes > policy.ceilingBytes) {
    // Said out loud rather than silently violated. The remaining sets are all protected, so the
    // honest answer is "the ceiling cannot be met without deleting the only proof this works" —
    // which is an operator's decision about the ceiling, not this job's about the artefacts.
    reasons.push(
      `ceiling_bytes is still exceeded by ${keptBytes - policy.ceilingBytes} bytes after pruning everything ` +
        `that may be pruned — raise the ceiling or lower retention_copies`,
    )
  }

  return { toPrune, keptBytes, reasons }
}

export function createPruneHandler(deps: RunnerDeps): Handler {
  return async () => {
    const settings = await readSettings(deps.admin)
    const root = assertSafeRootPath(settings.rootPath)
    const succeeded = await listSucceededRuns(deps.admin, deps.env.env)

    const selection = selectForPrune(succeeded, {
      retentionCopies: settings.retentionCopies,
      ceilingBytes: settings.ceilingBytes,
    })

    for (const run of selection.toPrune) {
      if (!run.directory) continue

      // Belt and braces on a `rm -rf`. `directory` came out of the database, and a database column
      // is not a trusted source for a recursive delete: an UPDATE that set it to `/` would
      // otherwise be a one-statement way to erase the host. The containment check is the same one
      // the manifest's relPaths go through.
      if (!run.directory.startsWith(`${root}/`) || run.directory.includes('..')) {
        deps.logger.error('refusing to prune a directory outside the backup root', {
          backupRunId: run.id,
          root,
        })
        continue
      }

      try {
        await rm(run.directory, { recursive: true, force: true })
      } catch (err) {
        // The row is NOT marked pruned when the files could not be removed. A row saying the files
        // are gone while they are still on the disk is how a ceiling is silently overrun.
        deps.logger.error('could not remove a backup directory', { backupRunId: run.id, err: errorText(err) })
        continue
      }

      await markPruned(deps.admin, run.id)
      deps.metrics.increment('backup_runs_pruned_total', {})
    }

    deps.metrics.set('backup_retained_bytes', Number(selection.keptBytes))
    deps.logger.info('prune complete', {
      considered: succeeded.length,
      pruned: selection.toPrune.length,
      retainedBytes: selection.keptBytes.toString(),
      reasons: selection.reasons,
    })
  }
}
