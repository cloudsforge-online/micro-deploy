/**
 * `backup.restore` — the dangerous half, and the two things that make it safe to have at all.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE ORDER IS THE CONTROL. IT IS, EXACTLY:**
 *
 *   1. Read `MANIFEST.json` and compare its `environment` to this runner's own `BACKUP_ENVIRONMENT`.
 *      **On mismatch: state `refused`, an error naming both, and not one further byte read.**
 *   2. Verify every artefact's sha256 against the manifest, and the manifest's own entries against
 *      the `backup_artefacts` rows. Record `checksums_verified`.
 *   3. Only then restore.
 *
 * Step 1 comes before step 2 and not after, and the difference is not pedantry: "we hashed 300 MB
 * of a mainnet backup and then decided not to restore it into testnet" describes a process that
 * already opened the wrong set. The gate is on the door, not on the safe.
 *
 * **WHY A SECOND ENVIRONMENT GATE EXISTS AT ALL.** The first is `restore_runs_environment_guard`,
 * a trigger in `admin_api` that refuses the INSERT when the backup's environment differs from the
 * immutable `estate_identity` row. This one compares the environment written INSIDE the artefact
 * against the environment baked into this container. They fail independently: the trigger cannot
 * see a directory copied onto this host by hand, and this cannot see an approval. Environment
 * confusion has happened on this estate twice, and both times the thing that failed was a
 * parameter. Neither side of this comparison is a parameter.
 *
 * **`verify` NEVER TOUCHES A LIVE DATABASE.** It restores into `scratch_verify_<name>_<short-uuid>`
 * and drops it in a `finally`. That asymmetry — verify is cheap and needs no approval, live needs
 * two operators and a typed phrase — is deliberate, and migration 10 says why: "a system whose only
 * restore is terrifying is a system whose restores are never rehearsed."
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import postgres from 'postgres'
import type { Handler, Job } from '@cloudsforge/jobs'
import {
  completeRestore,
  createRun,
  failRestore,
  markRestoreRunning,
  readSettings,
  readArtefacts,
  readRestoreRun,
  readRun,
  recordRestoreFindings,
  refuseRestore,
  type ArtefactRow,
  type BackupRunRow,
} from './catalogue.ts'
import { digestOfFile, digestsMatch } from './checksum.ts'
import {
  assertEnvironmentMatches,
  EnvironmentMismatchError,
  MANIFEST_FILENAME,
  parseManifest,
  type ArtefactEntry,
  type Manifest,
} from './manifest.ts'
import { assertSafeDatabaseName, errorText, resolveWithin } from './paths.ts'
import { dropDatabase, dsnFor, exactRowCount, integrityOf, recreateDatabase, runRestore } from './pg.ts'
import { performBackup, type RunnerDeps } from './run.ts'

export const BACKUP_RESTORE = 'backup.restore'

/**
 * Read the manifest and apply the environment gate — in that order and nothing between them.
 *
 * The manifest is parsed with `parseManifest`, which validates every field including `relPath`.
 * That matters here more than anywhere: this function's caller is about to open the files those
 * paths name. See the header of `paths.ts`.
 */
export async function readGatedManifest(directory: string, runnerEnvironment: string): Promise<Manifest> {
  const raw = await readFile(resolveWithin(directory, MANIFEST_FILENAME))
  const manifest = parseManifest(raw)
  assertEnvironmentMatches(manifest.environment, runnerEnvironment)
  return manifest
}

export interface ChecksumReport {
  readonly verified: boolean
  readonly checked: number
  readonly mismatches: readonly string[]
}

/**
 * Hash every artefact and compare it to the manifest AND to the catalogue.
 *
 * The double comparison is migration 10's design: the checksum is stored in `backup_artefacts` as
 * well as in `MANIFEST.json` "so a tampered manifest disagrees with the database rather than with
 * itself". A manifest edited on disk to match a swapped dump passes a manifest-only check
 * perfectly. It cannot also match a row in a database on another machine.
 *
 * Where the catalogue has no row — a cold restore on a rebuilt host, which is the disaster this
 * system is for — the manifest stands alone and this says so rather than pretending to a check it
 * did not perform.
 */
export async function verifyArtefacts(
  directory: string,
  manifest: Manifest,
  catalogued: readonly ArtefactRow[],
): Promise<ChecksumReport> {
  const byName = new Map(catalogued.map((row) => [`${row.kind}:${row.name}`, row]))
  const mismatches: string[] = []

  for (const artefact of manifest.artefacts) {
    const path = resolveWithin(directory, artefact.relPath)
    const digest = await digestOfFile(path)

    if (!digestsMatch(artefact.sha256, digest.sha256)) {
      mismatches.push(`${artefact.relPath}: on disk ${digest.sha256}, manifest says ${artefact.sha256}`)
      continue
    }
    if (digest.bytes !== artefact.bytes) {
      mismatches.push(`${artefact.relPath}: ${digest.bytes} bytes on disk, manifest says ${artefact.bytes}`)
      continue
    }
    const row = byName.get(`${artefact.kind}:${artefact.name}`)
    if (row && !digestsMatch(row.sha256, artefact.sha256)) {
      mismatches.push(
        `${artefact.relPath}: the manifest and the catalogue disagree — one of them has been altered`,
      )
    }
  }

  return { verified: mismatches.length === 0, checked: manifest.artefacts.length, mismatches }
}

/**
 * The scratch database a verify restore lands in.
 *
 * A uuid fragment rather than a timestamp, so two verifies of the same database at the same second
 * cannot collide and silently verify each other's data. Postgres identifiers are capped at 63
 * bytes; `scratch_verify_` (15) + a database name (≤ 63 in principle, ≤ 12 here) + `_` + 8 hex
 * leaves ample room, and `assertSafeDatabaseName` rejects the result if it ever does not.
 */
export function scratchNameFor(database: string, uuid: string = randomUUID()): string {
  const short = uuid.replaceAll('-', '').slice(0, 8)
  return assertSafeDatabaseName(`scratch_verify_${assertSafeDatabaseName(database).slice(0, 30)}_${short}`)
}

export interface TargetOutcome {
  readonly name: string
  readonly kind: string
  /** The pass/fail. Driven by `pg_restore` exiting 0 and by internal consistency — never by row drift. */
  readonly restored: boolean
  /** Advisory. See `exactRowCount` in `pg.ts` for why this is not the criterion. */
  readonly rowsAtDumpTime?: string
  readonly rowsRestored?: string
  readonly rowDrift?: string
  readonly tables?: number
  readonly foreignKeys?: number
  readonly note?: string
}

/**
 * Restore into a scratch database, count what arrived, and drop it — whatever happens.
 *
 * **The drop is in a `finally`.** A verify that fails partway and leaves `scratch_verify_ledger_…`
 * behind consumes disk on the same spindle as the chain, once per failed nightly verify, for ever.
 * The failure that made the verify fail is exactly the condition under which nobody is watching the
 * database list.
 */
async function verifyOneDatabase(
  deps: RunnerDeps,
  artefact: ArtefactEntry,
  archivePath: string,
): Promise<TargetOutcome> {
  const scratch = scratchNameFor(artefact.name)
  await recreateDatabase(deps.cluster, scratch)
  try {
    // (b) `--single-transaction --exit-on-error`. Returning at all means the whole archive landed
    //     AND every foreign key it defines validated against every restored row, because
    //     `pg_restore` adds foreign keys after the data and `ADD FOREIGN KEY` checks as it goes.
    await runRestore(deps.connection, scratch, archivePath, deps.env.pgToolTimeoutMs)

    const scratchSql = postgres(dsnFor(deps.connection, scratch), { max: 1, onnotice: () => {} })
    let rows: bigint
    let integrity
    try {
      // (c) The consistency probe, which is what this passes or fails on.
      integrity = await integrityOf(scratchSql)
      rows = await exactRowCount(scratchSql)
    } finally {
      // Closed before the DROP: `drop database … with (force)` would terminate this connection
      // anyway, and relying on that would make the outcome depend on a race.
      await scratchSql.end({ timeout: 5 }).catch(() => {})
    }

    // ── The row count is RECORDED, never adjudicated on.
    //
    //    Measured on this estate 2026-08-05: identity restored 34,099 rows against a source reading
    //    34,101, because `users` grew by 8 while the comparison was being made. The dump was a
    //    coherent snapshot; the source was simply four minutes older than the question. A verify
    //    that failed on that would cry wolf nightly, and an operator who has learned to dismiss
    //    this alarm is an operator who will dismiss the real one.
    const atDumpTime = artefact.entryCount
    const drift = atDumpTime === undefined ? undefined : rows - atDumpTime

    return {
      name: artefact.name,
      kind: 'database',
      restored: integrity.ok,
      ...(atDumpTime === undefined ? {} : { rowsAtDumpTime: atDumpTime.toString() }),
      rowsRestored: rows.toString(),
      ...(drift === undefined || drift === 0n ? {} : { rowDrift: drift.toString() }),
      tables: integrity.tables,
      foreignKeys: integrity.foreignKeys,
      ...(integrity.ok
        ? drift !== undefined && drift !== 0n
          ? {
              note:
                'row count differs from the count taken beside the dump. Advisory only: the source is live ' +
                'and the count was not taken inside the dump snapshot. Integrity held, so the set is good',
            }
          : {}
        : {
            note:
              integrity.tables === 0
                ? 'the archive restored zero tables — pg_restore succeeded at doing nothing'
                : `${integrity.unvalidatedConstraints} constraint(s) restored NOT VALID: the copy may hold rows its own schema forbids`,
          }),
    }
  } finally {
    await dropDatabase(deps.cluster, scratch)
  }
}

/**
 * `verify` mode. Non-destructive by construction: nothing here names a live database.
 *
 * Non-database artefacts are checksum-only, and that is stated rather than glossed. Extracting a
 * 152 MB sprite tarball to prove it extracts would double the disk cost of every verify; and a
 * `secrets` artefact **cannot** be opened here at all, because this host holds no age identity by
 * design. The honest claim is "the ciphertext is intact", and the real proof of a key backup is an
 * off-host decrypt that re-derives the address and compares it to `publicRef` — addresses, never
 * keys, exactly as `docs/custody-backup-restore.md` §5.3 does it.
 */
export async function performVerifyRestore(
  deps: RunnerDeps,
  input: { directory: string; manifest: Manifest; targets: readonly string[] },
): Promise<{ outcomes: TargetOutcome[]; ok: boolean }> {
  const wanted = new Set(input.targets)
  const outcomes: TargetOutcome[] = []

  for (const artefact of input.manifest.artefacts) {
    if (wanted.size > 0 && !wanted.has(artefact.name)) continue
    const path = resolveWithin(input.directory, artefact.relPath)

    if (artefact.kind === 'database') {
      outcomes.push(await verifyOneDatabase(deps, artefact, path))
      continue
    }
    outcomes.push({
      name: artefact.name,
      kind: artefact.kind,
      restored: true,
      note:
        artefact.kind === 'secrets'
          ? 'checksum only: this host holds no age identity and cannot decrypt. Prove recovery off-host by ' +
            're-deriving the address and comparing it to publicRef'
          : 'checksum only: archives are verified by digest, not by extraction',
    })
  }

  return { outcomes, ok: outcomes.every((outcome) => outcome.restored) }
}

/**
 * `live` mode. This overwrites real data, and the safety copy is not optional.
 *
 * The pre-restore backup is taken FIRST, of exactly the databases about to be replaced. An operator
 * who authorised a restore authorised replacing the current data with the backup's — they did not
 * authorise discarding the current data, and until this dump exists that distinction has no
 * mechanism behind it. Appendix A.2's rehearsal is the shape of what follows:
 * `drop database … with (force)`, `create`, `pg_restore`.
 *
 * `with (force)` because 46 services hold pools against these databases and a plain DROP fails
 * every time with "database is being accessed by other users".
 */
export async function performLiveRestore(
  deps: RunnerDeps,
  input: { directory: string; manifest: Manifest; targets: readonly string[]; heartbeat: () => Promise<boolean> },
): Promise<{ outcomes: TargetOutcome[]; ok: boolean; safetyBackupRunId: string }> {
  const wanted = new Set(input.targets)
  const databases = input.manifest.artefacts
    .filter((artefact) => artefact.kind === 'database' && (wanted.size === 0 || wanted.has(artefact.name)))
    .map((artefact) => artefact.name)

  if (databases.length === 0) throw new Error('a live restore names no database in this backup set')

  const { backupRunId: safetyBackupRunId } = await performBackup(deps, {
    backupRunId: await createSafetyRunRow(deps, databases),
    heartbeat: input.heartbeat,
    databases,
    kind: 'databases',
    includeFiles: false,
  })

  const outcomes: TargetOutcome[] = []
  for (const artefact of input.manifest.artefacts) {
    if (artefact.kind !== 'database' || !databases.includes(artefact.name)) continue
    const path = resolveWithin(input.directory, artefact.relPath)

    await recreateDatabase(deps.cluster, artefact.name)
    await runRestore(deps.connection, artefact.name, path, deps.env.pgToolTimeoutMs)

    const restored = postgres(dsnFor(deps.connection, artefact.name), { max: 1, onnotice: () => {} })
    let rows: bigint
    let integrity
    try {
      integrity = await integrityOf(restored)
      rows = await exactRowCount(restored)
    } finally {
      await restored.end({ timeout: 5 }).catch(() => {})
    }

    // Same criterion as the verify path, and it must be the same: a live restore adjudicated on row
    // drift would report the estate's own liveness as a failed restore, at the moment an operator is
    // least able to tell the difference.
    const atDumpTime = artefact.entryCount
    outcomes.push({
      name: artefact.name,
      kind: 'database',
      restored: integrity.ok,
      ...(atDumpTime === undefined ? {} : { rowsAtDumpTime: atDumpTime.toString() }),
      rowsRestored: rows.toString(),
      tables: integrity.tables,
      foreignKeys: integrity.foreignKeys,
    })
    await input.heartbeat()
  }

  return { outcomes, ok: outcomes.every((outcome) => outcome.restored), safetyBackupRunId }
}

async function createSafetyRunRow(deps: RunnerDeps, databases: readonly string[]): Promise<string> {
  const settings = await readSettings(deps.admin)
  return createRun(deps.admin, {
    environment: deps.env.env,
    composeProject: deps.env.composeProject,
    kind: 'databases',
    requestedBy: 'service:backup-runner',
    reason: `pre-restore safety copy of ${databases.join(', ')}`,
    rootPath: settings.rootPath,
  })
}

/**
 * The job handler.
 *
 * A refusal is **not** a job failure. `EnvironmentMismatchError` is caught, written to the row as
 * `refused`, and the handler returns normally so the queue completes the job. Retrying a refusal
 * with exponential backoff five times and then dead-lettering it would turn a correct, deliberate
 * decision into an alert that looks like a broken system — and would re-open the artefact each time.
 */
export function createRestoreHandler(deps: RunnerDeps): Handler {
  return async (job: Job, ctx) => {
    const restoreRunId = job.payload['restoreRunId']
    if (typeof restoreRunId !== 'string') throw new Error('backup.restore payload has no restoreRunId')

    const restore = await readRestoreRun(deps.admin, restoreRunId)
    if (!restore) throw new Error(`restore_runs row ${restoreRunId} does not exist`)
    if (restore.state !== 'queued' && restore.state !== 'running') {
      deps.logger.info('restore already terminal; nothing to do', { restoreRunId, state: restore.state })
      return
    }

    const backup: BackupRunRow | null = await readRun(deps.admin, restore.backupRunId)
    if (!backup) throw new Error(`backup_runs row ${restore.backupRunId} does not exist`)
    if (!backup.directory) {
      // A pruned set has had its directory cleared. Failing loudly is the only honest answer: the
      // catalogue still remembers the run, and an operator asking to restore it deserves to be told
      // the files are gone rather than to watch a restore of nothing succeed.
      throw new Error(`backup ${backup.id} has no directory on disk — it has been pruned`)
    }

    await markRestoreRunning(deps.admin, restoreRunId)

    let manifest: Manifest
    try {
      // ── 1. THE GATE. Before anything else touches this directory.
      manifest = await readGatedManifest(backup.directory, deps.env.env)
    } catch (err) {
      if (err instanceof EnvironmentMismatchError) {
        await recordRestoreFindings(deps.admin, restoreRunId, {
          artefactEnvironment: err.manifestEnvironment,
          checksumsVerified: null,
        })
        await refuseRestore(deps.admin, restoreRunId, err.message)
        deps.metrics.increment('backup_restores_refused_total', { reason: 'environment_mismatch' })
        deps.logger.error('restore REFUSED: environment mismatch', {
          restoreRunId,
          backupRunId: backup.id,
          artefactEnvironment: err.manifestEnvironment,
          runnerEnvironment: err.runnerEnvironment,
        })
        // Returns, so the job completes. The refusal is the outcome, not a failure to reach one.
        return
      }
      await failRestore(deps.admin, restoreRunId, errorText(err))
      throw err
    }

    try {
      // ── 2. Checksums, before anything is restored, always.
      const report = await verifyArtefacts(backup.directory, manifest, await readArtefacts(deps.admin, backup.id))
      await recordRestoreFindings(deps.admin, restoreRunId, {
        artefactEnvironment: manifest.environment,
        checksumsVerified: report.verified,
      })
      if (!report.verified) {
        throw new Error(
          `refusing to restore: ${report.mismatches.length} of ${report.checked} artefacts do not match their ` +
            `recorded checksum — ${report.mismatches.slice(0, 5).join('; ')}`,
        )
      }
      await ctx.heartbeat()

      // ── 3. Restore.
      if (restore.mode === 'verify') {
        const result = await performVerifyRestore(deps, {
          directory: backup.directory,
          manifest,
          targets: restore.targets,
        })
        await completeRestore(deps.admin, restoreRunId, {
          mode: 'verify',
          checksumsVerified: true,
          ok: result.ok,
          targets: result.outcomes,
        })
        if (!result.ok) {
          // Recorded as succeeded-with-a-bad-outcome rather than as a job failure: the verify DID
          // run and its finding is the product. `backup.verify` reads `outcome.ok` and declines to
          // stamp `verified_at`, which is the consequence that matters.
          deps.logger.error('verify restore found a mismatch', { restoreRunId, targets: result.outcomes })
        }
        return
      }

      const result = await performLiveRestore(deps, {
        directory: backup.directory,
        manifest,
        targets: restore.targets,
        heartbeat: ctx.heartbeat,
      })
      await completeRestore(deps.admin, restoreRunId, {
        mode: 'live',
        checksumsVerified: true,
        ok: result.ok,
        safetyBackupRunId: result.safetyBackupRunId,
        targets: result.outcomes,
      })
      deps.logger.warn('LIVE restore complete', {
        restoreRunId,
        backupRunId: backup.id,
        safetyBackupRunId: result.safetyBackupRunId,
        targets: result.outcomes.map((outcome) => outcome.name),
      })
    } catch (err) {
      await failRestore(deps.admin, restoreRunId, errorText(err)).catch(() => {})
      deps.metrics.increment('backup_restores_failed_total', { mode: restore.mode })
      throw err
    }
  }
}
