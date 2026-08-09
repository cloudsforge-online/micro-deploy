/**
 * Every read and write this deployable makes against `admin_api` — the catalogue, which it does
 * not own.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE SCHEMA IS ANOTHER REPOSITORY'S, AND ITS CONSTRAINTS ARE THE CONTRACT.**
 *
 * `admin-api/src/migrations.ts` migration 10 defines these tables and encodes the system's
 * invariants as CHECKs and a trigger. This module never works around one; where a constraint makes
 * an update awkward, the awkwardness is the invariant showing through and is documented rather than
 * routed around. Two of them shape the code below and are worth naming here:
 *
 *   `backup_runs_success_is_evidenced`  `state = 'succeeded'` is *equal to* having all four of
 *                                       manifest_sha256, directory, total_bytes, artefact_count.
 *                                       So a success is written in ONE update carrying all four —
 *                                       there is no intermediate state where the row says succeeded
 *                                       and the evidence has not landed yet.
 *   `backup_runs_terminal_is_finished`  `finished_at is not null` is *equal to* being in
 *                                       ('succeeded','failed'). `'pruned'` is in neither list, so
 *                                       marking a run pruned requires clearing `finished_at`. See
 *                                       `markPruned`, which explains what that costs.
 *
 * `restore_runs` additionally carries a BEFORE INSERT trigger that derives `environment` from the
 * backup, refuses a cross-environment restore, and refuses a live restore without an approved
 * approval for that exact backup. This module inserts `restore_runs` rows only for the periodic
 * verify — never for a live restore, which is an operator's act through admin-api's own route.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import type postgres from 'postgres'
import type { ArtefactEntry, BackupKind, Environment } from './manifest.ts'

export type Sql = ReturnType<typeof postgres>

export interface BackupSettings {
  readonly rootPath: string
  readonly retentionCopies: number
  readonly ceilingBytes: bigint
  readonly minFreeBytes: bigint
  readonly scheduleEnabled: boolean
  readonly scheduleEveryMinutes: number
  readonly verifyEnabled: boolean
  readonly verifyEveryMinutes: number
}

/**
 * The one settings row, read fresh at the start of every run.
 *
 * Not cached. An operator who lowers `ceiling_bytes` because the disk is filling expects the next
 * run to obey it, and a process that read the value at boot obeys whatever was true at boot —
 * which during an incident is the wrong answer at the worst moment.
 */
export async function readSettings(sql: Sql): Promise<BackupSettings> {
  const [row] = await sql<
    {
      root_path: string
      retention_copies: number
      ceiling_bytes: string
      min_free_bytes: string
      schedule_enabled: boolean
      schedule_every_minutes: number
      verify_enabled: boolean
      verify_every_minutes: number
    }[]
  >`
    select root_path, retention_copies, ceiling_bytes::text, min_free_bytes::text,
           schedule_enabled, schedule_every_minutes, verify_enabled, verify_every_minutes
      from backup_settings where singleton
  `
  if (!row) throw new Error('backup_settings has no row — admin-api migration 10 has not been applied')
  return {
    rootPath: row.root_path,
    retentionCopies: row.retention_copies,
    ceilingBytes: BigInt(row.ceiling_bytes),
    minFreeBytes: BigInt(row.min_free_bytes),
    scheduleEnabled: row.schedule_enabled,
    scheduleEveryMinutes: row.schedule_every_minutes,
    verifyEnabled: row.verify_enabled,
    verifyEveryMinutes: row.verify_every_minutes,
  }
}

export interface BackupRunRow {
  readonly id: string
  readonly environment: Environment
  readonly composeProject: string
  readonly kind: BackupKind
  readonly state: string
  readonly rootPath: string
  readonly directory: string | null
  readonly totalBytes: bigint | null
  readonly artefactCount: number | null
  readonly manifestSha256: string | null
  readonly clusterSystemId: string | null
  readonly verifiedAt: Date | null
  readonly queuedAt: Date
}

function toRun(row: {
  id: string
  environment: string
  compose_project: string
  kind: string
  state: string
  root_path: string
  directory: string | null
  total_bytes: string | null
  artefact_count: number | null
  manifest_sha256: string | null
  cluster_system_id: string | null
  verified_at: Date | null
  queued_at: Date
}): BackupRunRow {
  return {
    id: row.id,
    environment: row.environment as Environment,
    composeProject: row.compose_project,
    kind: row.kind as BackupKind,
    state: row.state,
    rootPath: row.root_path,
    directory: row.directory,
    totalBytes: row.total_bytes === null ? null : BigInt(row.total_bytes),
    artefactCount: row.artefact_count,
    manifestSha256: row.manifest_sha256,
    clusterSystemId: row.cluster_system_id,
    verifiedAt: row.verified_at,
    queuedAt: row.queued_at,
  }
}

const RUN_COLUMNS = `id, environment, compose_project, kind, state, root_path, directory,
                     total_bytes::text, artefact_count, manifest_sha256, cluster_system_id,
                     verified_at, queued_at`

export async function readRun(sql: Sql, id: string): Promise<BackupRunRow | null> {
  const rows = await sql.unsafe(`select ${RUN_COLUMNS} from backup_runs where id = $1`, [id])
  const row = (rows as unknown[])[0]
  return row ? toRun(row as Parameters<typeof toRun>[0]) : null
}

/**
 * Create a run row this process owns.
 *
 * Used for the scheduled sweep when nothing has pre-created a row, and for the **pre-restore safety
 * backup** — the copy taken of the live database immediately before a live restore overwrites it.
 * That one matters: a live restore that goes wrong with no fresh copy of what it replaced is a
 * one-way door, and the operator's decision to restore was not a decision to discard.
 */
export async function createRun(
  sql: Sql,
  input: {
    environment: Environment
    composeProject: string
    kind: BackupKind
    requestedBy: string
    reason: string
    rootPath: string
    correlationId?: string
  },
): Promise<string> {
  const [row] = await sql<{ id: string }[]>`
    insert into backup_runs (environment, compose_project, kind, requested_by, reason, root_path, correlation_id)
    values (${input.environment}, ${input.composeProject}, ${input.kind}, ${input.requestedBy},
            ${input.reason}, ${input.rootPath}, ${input.correlationId ?? null})
    returning id
  `
  if (!row) throw new Error('backup_runs insert returned no row')
  return row.id
}

/** `queued` → `running`, stamping the directory the artefacts will land in. */
export async function markRunning(sql: Sql, id: string, directory: string): Promise<void> {
  await sql`
    update backup_runs
       set state = 'running', started_at = coalesce(started_at, now()), directory = ${directory}
     where id = ${id}
  `
}

export interface RunEvidence {
  readonly directory: string
  readonly totalBytes: bigint
  readonly artefactCount: number
  readonly manifestSha256: string
  readonly clusterSystemId: string
  readonly includesCustody: boolean
  /**
   * Whether an `age`-encrypted miner coinbase key is in this set.
   *
   * A boolean, never a value — migration 10's own words: "this column exists so the console can say
   * a key backup EXISTS without ever showing what is in it."
   */
  readonly includesSecrets: boolean
}

/**
 * One statement, all four pieces of evidence.
 *
 * `backup_runs_success_is_evidenced` makes the state and its proof a single fact; writing them
 * separately would require an intermediate row the constraint forbids, which is the constraint
 * doing exactly what it was written to do.
 */
export async function completeRun(sql: Sql, id: string, evidence: RunEvidence): Promise<void> {
  await sql`
    update backup_runs
       set state = 'succeeded',
           finished_at = now(),
           directory = ${evidence.directory},
           total_bytes = ${evidence.totalBytes.toString()}::bigint,
           artefact_count = ${evidence.artefactCount},
           manifest_sha256 = ${evidence.manifestSha256},
           cluster_system_id = ${evidence.clusterSystemId},
           includes_custody = ${evidence.includesCustody},
           includes_secrets = ${evidence.includesSecrets},
           error = null
     where id = ${id}
  `
}

/**
 * Mark a run failed.
 *
 * The evidence columns are cleared as well, and that is required rather than tidy:
 * `backup_runs_success_is_evidenced` is an equality, so a row carrying a manifest checksum in any
 * state other than `succeeded` is unrepresentable. It is also honest — a partial set's checksum
 * describes nothing anyone should restore from.
 */
export async function failRun(sql: Sql, id: string, error: string): Promise<void> {
  await sql`
    update backup_runs
       set state = 'failed',
           finished_at = now(),
           error = ${error},
           manifest_sha256 = null,
           total_bytes = null,
           artefact_count = null
     where id = ${id}
  `
}

export async function insertArtefacts(sql: Sql, runId: string, artefacts: readonly ArtefactEntry[]): Promise<void> {
  for (const artefact of artefacts) {
    await sql`
      insert into backup_artefacts (run_id, kind, name, rel_path, bytes, sha256, entry_count, public_ref)
      values (${runId}, ${artefact.kind}, ${artefact.name}, ${artefact.relPath},
              ${artefact.bytes.toString()}::bigint, ${artefact.sha256},
              ${artefact.entryCount === undefined ? null : artefact.entryCount.toString()}::bigint,
              -- An ADDRESS or null. backup_artefacts_public_ref_is_an_address refuses anything
              -- shaped like a key, and backup_artefacts_secrets_name_their_address refuses a
              -- secrets row without one.
              ${artefact.publicRef ?? null})
      on conflict (run_id, kind, name) do update
        set rel_path = excluded.rel_path, bytes = excluded.bytes,
            sha256 = excluded.sha256, entry_count = excluded.entry_count,
            public_ref = excluded.public_ref
    `
  }
}

export interface ArtefactRow {
  readonly kind: string
  readonly name: string
  readonly relPath: string
  readonly bytes: bigint
  readonly sha256: string
  readonly entryCount: bigint | null
  readonly publicRef: string | null
}

/**
 * The catalogue's own copy of every checksum.
 *
 * Migration 10 puts it here as well as in the manifest deliberately: "a tampered manifest disagrees
 * with the database rather than with itself." The restore path compares the two, which is why this
 * read exists at all.
 */
export async function readArtefacts(sql: Sql, runId: string): Promise<ArtefactRow[]> {
  const rows = await sql<
    {
      kind: string
      name: string
      rel_path: string
      bytes: string
      sha256: string
      entry_count: string | null
      public_ref: string | null
    }[]
  >`
    select kind, name, rel_path, bytes::text, sha256, entry_count::text, public_ref
      from backup_artefacts where run_id = ${runId} order by kind, name
  `
  return rows.map((row) => ({
    kind: row.kind,
    name: row.name,
    relPath: row.rel_path,
    bytes: BigInt(row.bytes),
    sha256: row.sha256,
    entryCount: row.entry_count === null ? null : BigInt(row.entry_count),
    publicRef: row.public_ref,
  }))
}

/**
 * What this system currently occupies, across BOTH environments.
 *
 * Not filtered by environment, and that is the point: `ceiling_bytes` bounds what the backup system
 * takes from a disk that mainnet, testnet and `/data/chains` all share. A per-environment ceiling
 * would be two ceilings that each look satisfied while together they fill the disk.
 *
 * Read from the catalogue rather than from `du`, so that a run refuses on the basis of what this
 * system believes it wrote. If the two disagree, the prune job is what reconciles them.
 */
export async function occupiedBytes(sql: Sql): Promise<bigint> {
  const [row] = await sql<{ total: string }[]>`
    select coalesce(sum(total_bytes), 0)::text as total from backup_runs where state = 'succeeded'
  `
  return BigInt(row?.total ?? '0')
}

/** Newest first. Used by prune (retention) and by verify (which set to prove). */
export async function listSucceededRuns(sql: Sql, environment: Environment): Promise<BackupRunRow[]> {
  const rows = await sql.unsafe(
    `select ${RUN_COLUMNS} from backup_runs
      where environment = $1 and state = 'succeeded'
      order by queued_at desc`,
    [environment],
  )
  return (rows as unknown[]).map((row) => toRun(row as Parameters<typeof toRun>[0]))
}

/**
 * When the newest succeeded run for this environment FINISHED — or **null if there has never been
 * one**.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **NULL, NOT ZERO, AND THAT IS THE WHOLE POINT OF THE FUNCTION.**
 *
 * Its one caller seeds `backup_last_success_unixtime` at boot. A zero or an epoch sentinel would
 * publish a series saying the estate was last backed up in 1970, which reads as "very old" — and
 * "very old" is a claim that a backup once happened. It did not. Absent is the honest answer, and
 * the alert plane distinguishes the two deliberately: `BackupAgeExceeded` pages on an old series,
 * `BackupNeverRun` tickets on no series at all.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `finished_at` and not `queued_at`, because the question is when a set finished being written and
 * a run that started yesterday and finished this morning is this morning's copy.
 * `backup_runs_terminal_is_finished` makes `finished_at is not null` equal to being in
 * ('succeeded','failed'), so a succeeded row always carries one; the `is not null` in the predicate
 * is what lets the index-ordered read be sure of it rather than assume it.
 *
 * `state = 'succeeded'` also excludes `pruned`, which is correct twice over: a pruned set's files
 * are gone, and `markPruned` has to clear `finished_at` to satisfy that same constraint — so a
 * pruned run could not answer this question even if it should.
 */
export async function lastSucceededAt(sql: Sql, environment: Environment): Promise<Date | null> {
  const [row] = await sql<{ finished_at: Date }[]>`
    select finished_at from backup_runs
      where environment = ${environment} and state = 'succeeded' and finished_at is not null
      order by finished_at desc
      limit 1
  `
  return row?.finished_at ?? null
}

/**
 * Record that a set was actually restored, and by which restore.
 *
 * `backup_runs_verification_is_attributed` refuses a `verified_at` with nothing to point at.
 * "Verified" as a bare boolean is the reassuring green tick this whole exercise exists to refuse:
 * a backup nobody has restored is a wish, and a tick nobody can trace back to a restore is the
 * same wish with better presentation.
 */
export async function markVerified(sql: Sql, backupRunId: string, restoreRunId: string): Promise<void> {
  await sql`
    update backup_runs
       set verified_at = now(), verified_by_restore = ${restoreRunId}
     where id = ${backupRunId}
  `
}

/**
 * Mark a set pruned — its files are gone.
 *
 * **`directory` and `finished_at` are cleared, and that is forced by the schema rather than
 * chosen.** `backup_runs_terminal_is_finished` makes `finished_at is not null` equal to being in
 * ('succeeded','failed'); `'pruned'` is in neither, so the timestamp cannot survive the transition.
 * `backup_runs_success_is_evidenced` likewise requires at least one evidence column to go null, and
 * `directory` is the honest one to lose: the directory no longer exists.
 *
 * `manifest_sha256` and `total_bytes` are kept — they are the historical record of what was once
 * held — and `queued_at` still dates the run, so the loss of `finished_at` costs the duration of a
 * run that no longer has any files. The `backup_artefacts` rows are kept too, for the reason
 * migration 10 gives: an operator can be told "this file no longer hashes to what we wrote" without
 * the artefact being present.
 */
export async function markPruned(sql: Sql, id: string): Promise<void> {
  await sql`
    update backup_runs
       set state = 'pruned', directory = null, finished_at = null, error = null
     where id = ${id} and state = 'succeeded'
  `
}

// ─────────────────────────────────────────────────────────────────────────── restore_runs

export interface RestoreRunRow {
  readonly id: string
  readonly backupRunId: string
  readonly environment: Environment
  readonly mode: 'verify' | 'live'
  readonly state: string
  readonly targets: readonly string[]
}

/**
 * Insert a `verify` restore. **This function cannot insert a live one, and that is deliberate.**
 *
 * `mode` is not a parameter here. A live restore overwrites real money data and needs an approval
 * two operators signed (`restore_runs_live_is_confirmed`); it is an operator's act, taken through
 * admin-api's route where the typed confirmation is captured. A background process that could
 * insert one would be a background process that could start one.
 *
 * The BEFORE INSERT trigger still runs on this: if the estate identity disagrees with the backup's
 * environment the insert is refused by Postgres before this function returns, which is the first of
 * the two environment gates.
 */
export async function insertVerifyRestore(
  sql: Sql,
  input: { backupRunId: string; requestedBy: string; reason: string; targets: readonly string[]; correlationId?: string },
): Promise<RestoreRunRow> {
  const [row] = await sql<{ id: string; backup_run_id: string; environment: string; mode: string; state: string }[]>`
    insert into restore_runs (backup_run_id, environment, mode, targets, requested_by, reason, correlation_id)
    values (${input.backupRunId},
            -- Supplied only to satisfy NOT NULL; the trigger overwrites it with the backup's own
            -- environment. Migration 10: "a column the caller fills is a column the caller can lie in."
            'mainnet',
            'verify',
            ${JSON.stringify(input.targets)}::jsonb,
            ${input.requestedBy}, ${input.reason}, ${input.correlationId ?? null})
    returning id, backup_run_id, environment, mode, state
  `
  if (!row) throw new Error('restore_runs insert returned no row')
  return {
    id: row.id,
    backupRunId: row.backup_run_id,
    environment: row.environment as Environment,
    mode: row.mode as 'verify' | 'live',
    state: row.state,
    targets: input.targets,
  }
}

export async function readRestoreRun(sql: Sql, id: string): Promise<RestoreRunRow | null> {
  const [row] = await sql<
    { id: string; backup_run_id: string; environment: string; mode: string; state: string; targets: unknown }[]
  >`
    select id, backup_run_id, environment, mode, state, targets from restore_runs where id = ${id}
  `
  if (!row) return null
  const targets = Array.isArray(row.targets) ? row.targets.filter((t): t is string => typeof t === 'string') : []
  return {
    id: row.id,
    backupRunId: row.backup_run_id,
    environment: row.environment as Environment,
    mode: row.mode as 'verify' | 'live',
    state: row.state,
    targets,
  }
}

export async function markRestoreRunning(sql: Sql, id: string): Promise<void> {
  await sql`update restore_runs set state = 'running', started_at = coalesce(started_at, now()) where id = ${id}`
}

/**
 * Record what the runner found when it opened the artefact.
 *
 * `artefact_environment` is the environment read out of `MANIFEST.json`, not out of any row. It is
 * written even on the refusal path — especially on the refusal path — because the record of a
 * near-miss is the only evidence that the gate did anything.
 */
export async function recordRestoreFindings(
  sql: Sql,
  id: string,
  findings: { artefactEnvironment: string; checksumsVerified: boolean | null },
): Promise<void> {
  await sql`
    update restore_runs
       set artefact_environment = ${findings.artefactEnvironment},
           checksums_verified = ${findings.checksumsVerified}
     where id = ${id}
  `
}

export async function completeRestore(sql: Sql, id: string, outcome: Record<string, unknown>): Promise<void> {
  await sql`
    update restore_runs
       set state = 'succeeded', finished_at = now(), outcome = ${JSON.stringify(outcome)}::jsonb, error = null
     where id = ${id}
  `
}

export async function failRestore(sql: Sql, id: string, error: string, outcome: Record<string, unknown> = {}): Promise<void> {
  await sql`
    update restore_runs
       set state = 'failed', finished_at = now(), error = ${error}, outcome = ${JSON.stringify(outcome)}::jsonb
     where id = ${id}
  `
}

/**
 * `refused` — not `failed`.
 *
 * The distinction is the whole point of the state existing. A failure is the system not working; a
 * refusal is the system working exactly as designed and declining. An operator triaging a red
 * console needs to be able to tell "the backup is broken" from "you pointed a testnet artefact at
 * mainnet and we stopped you", and a single `failed` state cannot say the second thing.
 */
export async function refuseRestore(sql: Sql, id: string, error: string): Promise<void> {
  await sql`
    update restore_runs
       set state = 'refused', finished_at = now(), error = ${error}
     where id = ${id}
  `
}
