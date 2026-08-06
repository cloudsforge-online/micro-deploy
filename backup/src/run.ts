/**
 * `backup.run` — the sweep that produces a set.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE ORDER OF THIS FUNCTION IS THE SUBSTANCE OF IT.**
 *
 *   1. Read settings. Fresh, every run — an operator who lowers the ceiling during an incident
 *      expects the next run to obey it.
 *   2. Ask the cluster what it is. `system_identifier` and the database LIST both come from the
 *      server, so a service deployed since the last release is backed up without anyone editing a
 *      list, and a restore can tell "same cluster" from "rebuilt cluster".
 *   3. Project the size and CHECK THE SPACE. Before `mkdir`. A run that discovers it does not fit
 *      halfway through has already filled the disk that holds the chain.
 *   4. Only then write anything.
 *   5. Manifest last, and the database row after the manifest. `backup_runs_success_is_evidenced`
 *      makes 'succeeded' and its checksum one fact, so there is no window in which the catalogue
 *      claims a set that is not yet complete on disk.
 *
 * **A FAILED RUN LEAVES ITS FILES.** They are not deleted. A partial set cannot be restored from —
 * the row says `failed`, `restore_runs_environment_matches` refuses to insert a restore against a
 * non-succeeded run, and the manifest is absent so there is nothing to verify against — but the
 * files are the evidence of what went wrong, and `backup.prune` reclaims them by policy rather than
 * by panic. Deleting on failure is how a disk-full incident becomes an incident with no artefacts
 * to diagnose it from.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { chmod, mkdir, writeFile } from 'node:fs/promises'
import postgres from 'postgres'
import type { Handler, Job } from '@cloudsforge/jobs'
import type { Logger, Metrics } from '@cloudsforge/telemetry'
import { archiveDirectory, surveyDirectory } from './archive.ts'
import {
  completeRun,
  createRun,
  failRun,
  insertArtefacts,
  markRunning,
  occupiedBytes,
  readRun,
  readSettings,
  type Sql,
} from './catalogue.ts'
import { streamToFileWithDigest } from './checksum.ts'
import { assertSpaceAvailable, freeBytesAt } from './disk.ts'
import type { Env } from './env.ts'
import {
  buildManifest,
  digestOfManifest,
  EXCLUSIONS,
  MANIFEST_FILENAME,
  type ArtefactEntry,
} from './manifest.ts'
import { databaseSize, dsnFor, exactRowCount, readClusterFacts, startDump, type ClusterConnection } from './pg.ts'
import { assertSafeRootPath, errorText, resolveWithin } from './paths.ts'
import { backupMinerCoinbaseKey } from './secrets.ts'

export const BACKUP_RUN = 'backup.run'

export interface RunnerDeps {
  /** `admin_api`: the catalogue and the job queue. */
  readonly admin: Sql
  /** The cluster's maintenance database, as a role that can dump every database. */
  readonly cluster: Sql
  readonly connection: ClusterConnection
  readonly env: Env
  readonly logger: Logger
  readonly metrics: Metrics
  readonly now?: () => Date
}

/** `20260805T143000Z` — sorts lexicographically, which is also chronologically. */
export function stampFor(when: Date): string {
  return `${when.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')}`
}

interface FileSource {
  readonly kind: 'vault' | 'files'
  readonly name: string
  readonly dir: string
  readonly relPath: string
}

/**
 * The non-database sources.
 *
 * `/data/chains` is NOT one of them and never will be — it is in `EXCLUSIONS`, recorded in the
 * manifest with its reason so that its absence reads as a decision rather than as a truncated
 * backup. 553 GB of public chain data is reconstructible from the network; copying it nightly onto
 * the same disk the miner writes to would stop the chain to protect data the chain already holds.
 */
function fileSourcesFor(env: Env): readonly FileSource[] {
  return [
    // The custody VAULT — ciphertext. The keyring is not here and there is no code path that could
    // put it here. `docs/custody-backup-restore.md` §1.2: the tarball's directory names are
    // authenticated as GCM AAD, so `archive.ts` roots it at the slot directories exactly.
    { kind: 'vault', name: 'custody-keys', dir: env.custodyVaultDir, relPath: 'vault/custody-keys.tgz' },
    { kind: 'files', name: 'studio-assets', dir: env.studioAssetsDir, relPath: 'files/studio-assets.tgz' },
    { kind: 'files', name: 'world-assets', dir: env.worldAssetsDir, relPath: 'files/world-assets.tgz' },
  ]
}

/**
 * The vault tarball must hold one blob per custody row, or the backup fails.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THIS IS THE GUARD AGAINST A BACKUP THAT SUCCEEDS AND CONTAINS NOTHING.**
 *
 * `docs/custody-backup-restore.md` §2 ends its routine backup with exactly this comparison — "blob
 * count must equal keys + seeds" — and it is the one check that catches the failure mode this
 * estate has already been bitten by twice:
 *
 *   · **An empty mount.** Tessera's sprite directory was believed to be a 392-file mount and was
 *     found to be a bind holding one README. A vault mount that resolves to a fresh, empty docker
 *     volume — which is what happens if this overlay is ever run OUTSIDE the estate project, since
 *     `custody-keys` is declared non-external and compose would then create rather than attach —
 *     produces a tarball of zero blobs, a valid checksum, and a green backup row.
 *   · **A silently-dropped snap bind.** Same shape, different cause; see `disk.ts`.
 *
 * In both cases every other signal is healthy. The tar succeeds, the SHA-256 is correct, the size
 * is plausible for an empty archive, and nothing is red until somebody tries to recover a
 * customer's coins from it and finds ciphertext for zero addresses.
 *
 * The database is the independent second opinion, and it is the RIGHT one: `custody_keys` and
 * `custody_seeds` are the rows that say which blobs must exist. `FileVault` writes one `key.enc`
 * per slot (`custody/src/vault.ts`), so the counts are equal by construction and a
 * disagreement is a real defect rather than a tolerance.
 *
 * **It throws rather than warns.** A warning on a backup that cannot restore custody is a warning
 * in a log nobody reads until the day it matters. `backup_runs_success_is_evidenced` means a failed
 * run cannot be recorded as succeeded, so failing here is what stops the catalogue offering an
 * empty set as a restore source.
 *
 * Counting MORE blobs than rows is tolerated and logged, not refused: a blob whose row was deleted
 * is an orphan, which is a custody concern rather than a reason to have no backup tonight.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */
async function assertVaultIsComplete(deps: RunnerDeps, blobs: bigint): Promise<void> {
  let expected: bigint
  try {
    // A connection to `custody` specifically — `deps.cluster` is the maintenance database and does
    // not hold these tables. Same shape as the per-database row count above.
    const sql = postgres(dsnFor(deps.connection, 'custody'), { max: 1, onnotice: () => {} })
    try {
      const rows = await sql<{ keys: string; seeds: string }[]>`
        select (select count(*) from custody_keys)  as keys,
               (select count(*) from custody_seeds) as seeds
      `
      const row = rows[0]
      if (!row) return
      expected = BigInt(row.keys) + BigInt(row.seeds)
    } finally {
      await sql.end({ timeout: 5 }).catch(() => {})
    }
  } catch (err) {
    // No custody database, or the tables are not there yet. A development estate that has never
    // minted an address is a legitimate state, and refusing its backup would be wrong.
    deps.logger.warn('could not cross-check the custody vault against its rows', {
      err: err instanceof Error ? err.message : String(err),
      blobs: blobs.toString(),
    })
    return
  }

  const verdict = vaultCompleteness(blobs, expected)
  if (verdict.kind === 'incomplete') throw new Error(verdict.detail)
  if (verdict.kind === 'orphans') {
    deps.logger.warn('the custody vault holds more blobs than rows — orphaned blobs', {
      blobs: blobs.toString(),
      rows: expected.toString(),
    })
  }
  deps.logger.info('custody vault cross-checked against its rows', {
    blobs: blobs.toString(),
    rows: expected.toString(),
  })
}

export type VaultVerdict =
  | { readonly kind: 'ok' }
  | { readonly kind: 'orphans' }
  | { readonly kind: 'incomplete'; readonly detail: string }

/**
 * The decision, separated from the connection so it can be tested without a cluster.
 *
 * FEWER blobs than rows is fatal: an address whose blob is missing from the backup is an address
 * that cannot be spent after a recovery, and there is no second copy of a custody blob anywhere.
 * MORE blobs than rows is a warning: an orphan is a custody concern, and refusing tonight's backup
 * over one would trade a real, present risk for a theoretical one.
 */
export function vaultCompleteness(blobs: bigint, rows: bigint): VaultVerdict {
  if (blobs < rows) {
    return {
      kind: 'incomplete',
      detail:
        `the custody vault backup holds ${blobs} blobs but custody has ${rows} rows ` +
        '(custody_keys + custody_seeds) — the vault mount is incomplete or empty, and a backup ' +
        'that cannot recover every custodied address must not be recorded as a success. Check that ' +
        'the runner mounts the ESTATE PROJECT’s <project>_custody-keys volume rather than a ' +
        'fresh one, and see docs/estate-backup-restore.md §3 for the snap-Docker trap that ' +
        'produces an empty mount without an error.',
    }
  }
  return blobs > rows ? { kind: 'orphans' } : { kind: 'ok' }
}

export interface BackupOutcome {
  readonly backupRunId: string
  readonly directory: string
  readonly artefactCount: number
  readonly totalBytes: bigint
  readonly manifestSha256: string
}

export interface BackupOptions {
  readonly backupRunId: string
  readonly heartbeat: () => Promise<boolean>
  /**
   * Restrict the sweep to these databases. Omitted means every database the cluster reports.
   *
   * The one caller that sets it is the **pre-restore safety backup**: before a live restore
   * overwrites a database, a fresh copy of exactly that database is taken. Sweeping all 29 at that
   * moment would multiply the time an operator spends staring at a half-restored estate.
   */
  readonly databases?: readonly string[]
  readonly kind?: 'full' | 'databases'
  /** The pre-restore copy takes databases only; the volumes are not what a database restore risks. */
  readonly includeFiles?: boolean
}

/**
 * Do the work. Exported so a test, an operator's one-shot and the live-restore safety copy can
 * drive it without the queue.
 */
export async function performBackup(deps: RunnerDeps, options: BackupOptions): Promise<BackupOutcome> {
  const now = deps.now ?? (() => new Date())
  const startedAt = now()
  const settings = await readSettings(deps.admin)
  const root = assertSafeRootPath(settings.rootPath)
  const facts = await readClusterFacts(deps.cluster)
  const includeFiles = options.includeFiles ?? true

  // A requested database that the cluster does not have is a refusal, not a silent omission: it
  // means the caller and the server disagree about what exists, and continuing would produce a
  // "safety backup" that omits the very database about to be dropped.
  if (options.databases) {
    const available = new Set(facts.databases)
    for (const name of options.databases) {
      if (!available.has(name)) throw new Error(`database ${JSON.stringify(name)} is not in this cluster`)
    }
  }
  const databases = options.databases ?? facts.databases

  const directory = `${root}/${deps.env.env}/${stampFor(startedAt)}`
  const warnings: string[] = [
    // Travels with the artefact, because whoever restores this in two years will otherwise compare
    // the numbers and conclude the backup is lossy. It is not; the estate was busy. See
    // `exactRowCount` and `integrityOf` in `pg.ts`.
    'a database artefact entryCount is ADVISORY: it is an exact count taken beside the dump, not from ' +
      'inside its snapshot, so an actively-written database restores to a slightly different number. ' +
      'Judge a restore by its checksum, by pg_restore exiting 0, and by the internal consistency of the ' +
      'restored copy — never by comparing its row count to a live source',
  ]

  // ── 3. PROJECT, THEN REFUSE OR PROCEED. Nothing is written above this line.
  let projected = 0n
  for (const database of databases) projected += await databaseSize(deps.cluster, database)
  for (const source of includeFiles ? fileSourcesFor(deps.env) : []) {
    try {
      projected += (await surveyDirectory(source.dir)).byteCount
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
      // Absent source. Recorded as a warning in the manifest rather than silently omitted: a
      // missing artefact with no explanation is indistinguishable from a truncated backup.
      warnings.push(`source ${source.dir} (${source.name}) is not present on this host; its artefact is absent`)
    }
  }

  assertSpaceAvailable({
    freeBytes: await freeBytesAt(root),
    projectedBytes: projected,
    existingBytes: await occupiedBytes(deps.admin),
    minFreeBytes: settings.minFreeBytes,
    ceilingBytes: settings.ceilingBytes,
  })

  // ── 4. Write.
  for (const sub of ['', '/db', '/vault', '/files', '/secrets']) {
    await mkdir(`${directory}${sub}`, { recursive: true, mode: 0o700 })
    // Explicitly, because `mkdir`'s mode is masked by the process umask and a 0755 backup directory
    // on a shared host is every dump readable by every uid.
    await chmod(`${directory}${sub}`, 0o700)
  }
  await markRunning(deps.admin, options.backupRunId, directory)

  const artefacts: ArtefactEntry[] = []

  // ── Databases. One `pg_dump -Fc` each, hashed while streaming (never read twice — `checksum.ts`).
  for (const database of databases) {
    const relPath = `db/${database}.dump`
    const destination = resolveWithin(directory, relPath)
    const dump = startDump(deps.connection, database, deps.env.pgToolTimeoutMs)

    // Awaited together: if `pg_dump` fails mid-stream the write rejects too, and sequencing them
    // would leave whichever finishes second as an unhandled rejection.
    const [digest] = await Promise.all([streamToFileWithDigest(dump.stdout, destination), dump.finished])

    // The row count is EXACT (see `pg.ts`), taken from a connection to that database. It is what a
    // verify-mode restore is checked against, and an estimate would make that check meaningless.
    const perDatabase = postgres(dsnFor(deps.connection, database), { max: 1, onnotice: () => {} })
    let entryCount: bigint
    try {
      entryCount = await exactRowCount(perDatabase)
    } finally {
      await perDatabase.end({ timeout: 5 }).catch(() => {})
    }

    artefacts.push({ kind: 'database', name: database, relPath, bytes: digest.bytes, sha256: digest.sha256, entryCount })
    deps.metrics.increment('backup_artefacts_written_total', { kind: 'database' })
    await options.heartbeat()
  }

  // ── Volumes and binds.
  let includesCustody = false
  for (const source of includeFiles ? fileSourcesFor(deps.env) : []) {
    try {
      const result = await archiveDirectory({
        sourceDir: source.dir,
        destination: resolveWithin(directory, source.relPath),
        timeoutMs: deps.env.pgToolTimeoutMs,
      })
      artefacts.push({
        kind: source.kind,
        name: source.name,
        relPath: source.relPath,
        bytes: result.bytes,
        sha256: result.sha256,
        entryCount: result.entryCount,
      })
      if (source.kind === 'vault') {
        includesCustody = true
        await assertVaultIsComplete(deps, result.entryCount)
      }
      deps.metrics.increment('backup_artefacts_written_total', { kind: source.kind })
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err
      // Already warned about during the projection pass; nothing further to record.
    }
    await options.heartbeat()
  }

  // ── The miner coinbase key, encrypted to an off-host recipient, or a warning saying it is not
  //    here. There is no third outcome: see `secrets.ts`.
  //
  //    Skipped for a pre-restore copy. That backup exists to make one database restorable; writing
  //    a second copy of a private key on every live restore would multiply the number of places the
  //    coinbase ciphertext exists for no gain, and each copy is one more thing to destroy later.
  const secrets = includeFiles
    ? await backupMinerCoinbaseKey({
        sourcePath: `${deps.env.minerKeysDir}/${deps.env.env}/coinbase-key.json`,
        destination: resolveWithin(directory, `secrets/miner-coinbase-${deps.env.env}.json.age`),
        relPath: `secrets/miner-coinbase-${deps.env.env}.json.age`,
        environment: deps.env.env,
        recipient: deps.env.ageRecipient,
        timeoutMs: 60_000,
      })
    : { artefact: null, warnings: [] as readonly string[] }
  if (secrets.artefact) {
    artefacts.push(secrets.artefact)
    deps.metrics.increment('backup_artefacts_written_total', { kind: 'secrets' })
  }
  warnings.push(...secrets.warnings)

  // ── 5. The manifest, then the row.
  const manifest = buildManifest({
    backupRunId: options.backupRunId,
    environment: deps.env.env,
    composeProject: deps.env.composeProject,
    clusterSystemId: facts.systemIdentifier,
    kind: options.kind ?? 'full',
    pgServerVersion: facts.serverVersion,
    startedAt,
    finishedAt: now(),
    artefacts,
    excluded: EXCLUSIONS,
    warnings,
  })
  const { buffer, digest } = digestOfManifest(manifest)
  const manifestPath = resolveWithin(directory, MANIFEST_FILENAME)
  await writeFile(manifestPath, buffer, { mode: 0o600 })

  const totalBytes = artefacts.reduce((sum, artefact) => sum + artefact.bytes, 0n) + digest.bytes

  await insertArtefacts(deps.admin, options.backupRunId, artefacts)
  await completeRun(deps.admin, options.backupRunId, {
    directory,
    totalBytes,
    artefactCount: artefacts.length,
    manifestSha256: digest.sha256,
    clusterSystemId: facts.systemIdentifier,
    includesCustody,
    includesSecrets: secrets.artefact !== null,
  })

  deps.metrics.set('backup_last_success_bytes', Number(totalBytes))
  deps.logger.info('backup complete', {
    backupRunId: options.backupRunId,
    directory,
    artefacts: artefacts.length,
    totalBytes: totalBytes.toString(),
    // The DIGEST of the manifest, which commits to every artefact's digest. Never a filename list
    // and never a public address — a log line is not the catalogue.
    manifestSha256: digest.sha256,
    includesCustody,
    includesSecrets: secrets.artefact !== null,
    warnings: warnings.length,
  })

  return {
    backupRunId: options.backupRunId,
    directory,
    artefactCount: artefacts.length,
    totalBytes,
    manifestSha256: digest.sha256,
  }
}

/**
 * The job handler.
 *
 * The payload names a `backup_runs` row admin-api already created. If it does not — a scheduled
 * sweep enqueued with no row — one is created here, attributed to this service. Either way the row
 * exists before a byte is written, because a set of files on disk with nothing in the catalogue
 * pointing at them is a set nobody will ever find.
 */
export function createBackupHandler(deps: RunnerDeps): Handler {
  return async (job: Job, ctx) => {
    const payloadId = job.payload['backupRunId']
    let backupRunId = typeof payloadId === 'string' ? payloadId : null

    if (backupRunId) {
      const existing = await readRun(deps.admin, backupRunId)
      if (!existing) throw new Error(`backup_runs row ${backupRunId} does not exist`)
      if (existing.state === 'succeeded') {
        // At-least-once delivery: a lease that expired while the previous attempt was finishing
        // hands the same job to a second worker. Re-dumping would double the disk cost and produce
        // a second set nobody asked for.
        deps.logger.info('backup run already succeeded; nothing to do', { backupRunId })
        return
      }
      if (existing.environment !== deps.env.env) {
        // The row says another estate. This runner would write that row's directory under ITS OWN
        // environment path and stamp its own environment into the manifest, producing a set whose
        // catalogue row and artefact disagree — the exact confusion the two gates exist to prevent.
        throw new Error(
          `backup_runs row ${backupRunId} is for the ${existing.environment} estate and this runner is ${deps.env.env}`,
        )
      }
    } else {
      const settings = await readSettings(deps.admin)
      backupRunId = await createRun(deps.admin, {
        environment: deps.env.env,
        composeProject: deps.env.composeProject,
        kind: 'full',
        requestedBy: 'service:backup-runner',
        reason: 'scheduled full backup',
        rootPath: settings.rootPath,
      })
    }

    try {
      await performBackup(deps, { backupRunId, heartbeat: ctx.heartbeat })
    } catch (err) {
      // Recorded on the row before rethrowing, so the console can say WHY without waiting for the
      // queue's dead-letter. Redacted: `errorText` strips any DSN a pg tool echoed.
      await failRun(deps.admin, backupRunId, errorText(err)).catch(() => {})
      deps.metrics.increment('backup_runs_failed_total', {})
      throw err
    }
  }
}
