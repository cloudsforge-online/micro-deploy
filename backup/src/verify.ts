/**
 * `backup.verify` — the periodic self-check, and the only thing that distinguishes a working backup
 * from a broken one.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **A SILENTLY-BROKEN BACKUP IS BYTE-FOR-BYTE INDISTINGUISHABLE FROM A WORKING ONE UNTIL YOU
 * RESTORE IT.**
 *
 * Both are a directory of files with plausible sizes and a green row in a console. Every failure
 * mode this system can have — a version-skewed `pg_dump` producing archives 17 cannot read, a
 * dump truncated by a full disk, a tarball rooted one directory too high so every custody blob
 * fails its GCM tag (§1.2) — produces exactly that same directory and exactly that same green row.
 *
 * So `verified_at` on `backup_runs` means one thing and only one thing: **somebody actually
 * restored this set and it came back**. `backup_runs_verification_is_attributed` refuses a
 * `verified_at` that cannot name the restore that earned it, and this job is what earns it.
 *
 * A checksum is not that proof. A checksum says the bytes are the bytes that were written; it says
 * nothing about whether those bytes were ever restorable. That is why this runs a real
 * `pg_restore` into a real (scratch) database and counts the rows that arrive.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * **A REPRESENTATIVE SUBSET, NOT ALL 29.** A full verify would restore ~290 MB into 29 scratch
 * databases every night, on the disk the live cluster is serving from. The subset is chosen for
 * consequence rather than convenience: the databases whose loss is unrecoverable, plus the
 * catalogue itself.
 */

import type { Handler } from '@cloudsforge/jobs'
import {
  insertVerifyRestore,
  listSucceededRuns,
  markVerified,
  readArtefacts,
  readSettings,
  completeRestore,
  failRestore,
  markRestoreRunning,
  recordRestoreFindings,
  refuseRestore,
} from './catalogue.ts'
import { EnvironmentMismatchError } from './manifest.ts'
import { errorText } from './paths.ts'
import { performVerifyRestore, readGatedManifest, verifyArtefacts } from './restore.ts'
import type { RunnerDeps } from './run.ts'

export const BACKUP_VERIFY = 'backup.verify'

/**
 * The databases a nightly verify proves, in priority order.
 *
 * `custody` first: its rows say which address belongs to whom at which derivation path, and
 * `docs/custody-backup-restore.md` §1.5 is explicit that without artefact A the vault is "a list of
 * addresses you cannot spend" — losing the database loses the coins just as surely as losing the
 * keyring does. `ledger` is the money record; `identity` is who everyone is; `admin_api` is the
 * catalogue, without which no other backup can even be found.
 *
 * Intersected with what the set actually contains, so a set taken before a service existed still
 * verifies rather than failing on a database that was never in it.
 */
export const REPRESENTATIVE_SUBSET: readonly string[] = Object.freeze([
  'custody',
  'ledger',
  'identity',
  'admin_api',
])

/**
 * Pick the set to prove.
 *
 * The NEWEST succeeded set, always — an old set that verifies says nothing about the one that would
 * actually be restored tonight, and the newest is the one an operator would reach for first.
 * Exported and pure so the choice is testable without a database.
 */
export function chooseSetToVerify<T extends { id: string; queuedAt: Date; verifiedAt: Date | null }>(
  succeeded: readonly T[],
): T | null {
  return [...succeeded].sort((a, b) => b.queuedAt.getTime() - a.queuedAt.getTime())[0] ?? null
}

export function createVerifyHandler(deps: RunnerDeps): Handler {
  return async (_job, ctx) => {
    const settings = await readSettings(deps.admin)
    if (!settings.verifyEnabled) {
      deps.logger.info('periodic verification is disabled in backup_settings; skipping')
      return
    }

    const candidate = chooseSetToVerify(await listSucceededRuns(deps.admin, deps.env.env))
    if (!candidate?.directory) {
      // Not an error. A fresh estate has no succeeded backup yet, and a job that failed here would
      // dead-letter before the first backup ever ran.
      deps.logger.info('no succeeded backup to verify yet')
      return
    }

    const catalogued = await readArtefacts(deps.admin, candidate.id)
    const targets = REPRESENTATIVE_SUBSET.filter((name) =>
      catalogued.some((row) => row.kind === 'database' && row.name === name),
    )

    // Inserted through the catalogue, which means the `restore_runs` BEFORE INSERT trigger runs:
    // the first environment gate fires here, in Postgres, before this process opens anything.
    // `insertVerifyRestore` cannot insert a live restore — see its own comment.
    const restore = await insertVerifyRestore(deps.admin, {
      backupRunId: candidate.id,
      requestedBy: 'service:backup-runner',
      reason: 'periodic self-check',
      targets,
    })
    await markRestoreRunning(deps.admin, restore.id)

    try {
      // The SECOND gate, on the artefact itself.
      const manifest = await readGatedManifest(candidate.directory, deps.env.env)

      const report = await verifyArtefacts(candidate.directory, manifest, catalogued)
      await recordRestoreFindings(deps.admin, restore.id, {
        artefactEnvironment: manifest.environment,
        checksumsVerified: report.verified,
      })
      if (!report.verified) {
        throw new Error(
          `checksums do not match for ${report.mismatches.length} of ${report.checked} artefacts: ` +
            report.mismatches.slice(0, 5).join('; '),
        )
      }
      await ctx.heartbeat()

      const result = await performVerifyRestore(deps, { directory: candidate.directory, manifest, targets })
      await completeRestore(deps.admin, restore.id, {
        mode: 'verify',
        periodic: true,
        checksumsVerified: true,
        ok: result.ok,
        targets: result.outcomes,
      })

      if (result.ok) {
        // ONLY on a clean restore. Stamping `verified_at` after a failed one would put the
        // reassuring tick on exactly the set that does not work — the single most damaging thing
        // this job could do, because it would make the broken set look like the safest one.
        await markVerified(deps.admin, candidate.id, restore.id)
        deps.metrics.set('backup_last_verified_unixtime', Math.floor(Date.now() / 1000))
        deps.logger.info('backup verified by restore', {
          backupRunId: candidate.id,
          restoreRunId: restore.id,
          targets,
        })
        return
      }

      deps.metrics.increment('backup_verifications_failed_total', {})
      // Thrown so the job fails, retries, and shows up as a failure rather than as a quiet log
      // line. A backup that does not restore is the condition this entire deployable exists to
      // detect; detecting it and saying nothing loud would be pointless.
      throw new Error(
        `the newest ${deps.env.env} backup did not restore cleanly: ` +
          result.outcomes
            .filter((outcome) => !outcome.restored)
            .map((outcome) => `${outcome.name} — ${outcome.note ?? 'restore failed'}`)
            .join(', '),
      )
    } catch (err) {
      if (err instanceof EnvironmentMismatchError) {
        await recordRestoreFindings(deps.admin, restore.id, {
          artefactEnvironment: err.manifestEnvironment,
          checksumsVerified: null,
        })
        await refuseRestore(deps.admin, restore.id, err.message)
        deps.logger.error('periodic verification REFUSED: environment mismatch', {
          restoreRunId: restore.id,
          artefactEnvironment: err.manifestEnvironment,
          runnerEnvironment: err.runnerEnvironment,
        })
        // A refusal here means a set belonging to the other estate is sitting in this estate's
        // directory. That is a serious finding and worth a failed job — but the restore row is
        // `refused`, not `failed`, because the system did exactly what it should.
        throw new Error(`a ${err.manifestEnvironment} backup is filed under this ${err.runnerEnvironment} estate`)
      }
      await failRestore(deps.admin, restore.id, errorText(err)).catch(() => {})
      throw err
    }
  }
}
