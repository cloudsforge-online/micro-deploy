/**
 * The Postgres side: what runs `pg_dump`, what runs `pg_restore`, and what asks the cluster
 * questions.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE PASSWORD IS NEVER IN `argv`.**
 *
 * The obvious call is `pg_dump -d "postgres://cloudsforge:${CF_POSTGRES_PASSWORD}@postgres:5432/custody"`. On
 * Linux `/proc/<pid>/cmdline` is world-readable, so for the whole life of that process the
 * cluster's superuser password is readable by every uid on the host, and it lands in `ps` output,
 * in any process-listing metric, and in a container runtime's inspect output. This estate has
 * already lost three keyrings to values being *displayed* rather than stolen
 * (`docs/custody-backup-restore.md` §7.1); a password in `ps` is the same class of exposure with a
 * wider audience.
 *
 * So the DSN is parsed once, in-process, and handed to the child as `PGHOST`/`PGPORT`/`PGUSER`/
 * `PGPASSWORD`/`PGDATABASE` — libpq's own environment interface. A child's environment is readable
 * only by the same uid and by root, which is a materially smaller set than "everyone".
 * `--no-password` is set on every invocation so that a missing credential fails immediately
 * instead of blocking on a prompt that nothing will ever answer, which is how a nightly job
 * becomes a hung container holding a two-hour lease.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * **CLIENT AND SERVER MUST BOTH BE 17.** `pg_restore` from an older client against a 17.10 dump
 * fails on archive-format version, and — worse — an older `pg_dump` against a 17.10 server
 * produces a dump that restores with omissions rather than an error. The Dockerfile pins the PGDG
 * 17 client for that reason and `assertClientVersion` below checks it at boot rather than at 3 a.m.
 */

import { spawn } from 'node:child_process'
import type { Readable } from 'node:stream'
import postgres from 'postgres'
import { assertSafeDatabaseName, errorText, quoteIdent, redact } from './paths.ts'

export type Sql = ReturnType<typeof postgres>

export interface ClusterConnection {
  readonly host: string
  readonly port: string
  readonly user: string
  readonly password: string
  /** The database libpq connects to when no other is named — the maintenance database. */
  readonly database: string
  readonly sslmode?: string
}

export class PgToolError extends Error {
  readonly exitCode: number | null
  readonly stderr: string

  constructor(tool: string, database: string, exitCode: number | null, signal: string | null, stderr: string) {
    super(
      `${tool} on ${database} exited ${exitCode ?? 'null'}${signal ? ` (signal ${signal})` : ''}: ${
        stderr.trim().slice(-1_500) || '(no stderr)'
      }`,
    )
    this.name = 'PgToolError'
    this.exitCode = exitCode
    this.stderr = stderr
  }
}

/**
 * Parse a `postgres://` DSN into libpq environment components.
 *
 * Rejects anything that is not a postgres URI rather than falling back to passing the string
 * through: a silently accepted malformed DSN would end up as `-d <string>` somewhere later, which
 * is the argv exposure this whole module exists to avoid.
 */
export function parseDsn(dsn: string): ClusterConnection {
  let url: URL
  try {
    url = new URL(dsn)
  } catch {
    throw new Error('the cluster DSN is not a URL')
  }
  if (url.protocol !== 'postgres:' && url.protocol !== 'postgresql:') {
    throw new Error(`the cluster DSN must be a postgres:// URL (got ${url.protocol})`)
  }
  const sslmode = url.searchParams.get('sslmode')
  return {
    host: decodeURIComponent(url.hostname),
    port: url.port || '5432',
    user: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    database: decodeURIComponent(url.pathname.replace(/^\//, '')) || 'postgres',
    ...(sslmode ? { sslmode } : {}),
  }
}

/** Rebuild a DSN for postgres.js, which takes a URL rather than libpq environment variables. */
export function dsnFor(connection: ClusterConnection, database: string): string {
  const url = new URL('postgres://placeholder')
  url.hostname = connection.host
  url.port = connection.port
  url.username = encodeURIComponent(connection.user)
  url.password = encodeURIComponent(connection.password)
  url.pathname = `/${assertSafeDatabaseName(database)}`
  if (connection.sslmode) url.searchParams.set('sslmode', connection.sslmode)
  return url.toString()
}

/**
 * The child's environment.
 *
 * Built from an explicit list rather than `{ ...process.env, PG... }`. A backup child process has
 * no business inheriting the parent's whole environment: that is how a variable added for one
 * service leaks into a `tar` two releases later, and `keyring.ts` is an argument that this process
 * should assume nothing about what is in its environment.
 */
function pgEnvFor(connection: ClusterConnection, database: string): NodeJS.ProcessEnv {
  return {
    PATH: process.env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
    PGHOST: connection.host,
    PGPORT: connection.port,
    PGUSER: connection.user,
    PGPASSWORD: connection.password,
    PGDATABASE: assertSafeDatabaseName(database),
    PGCONNECT_TIMEOUT: '15',
    ...(connection.sslmode ? { PGSSLMODE: connection.sslmode } : {}),
    // Deterministic diagnostics. A dump whose errors arrive in the container's locale is a dump
    // whose failures cannot be grepped for consistently.
    LC_ALL: 'C',
  }
}

/** Bounded stderr capture. An unbounded buffer on a failing tool is a memory exhaustion. */
function collectStderr(stream: Readable, limit = 64 * 1024): { text: () => string } {
  let buffer = ''
  stream.setEncoding('utf8')
  stream.on('data', (chunk: string) => {
    if (buffer.length < limit) buffer += chunk
  })
  return { text: () => redact(buffer) }
}

export interface DumpHandle {
  /** Custom-format archive bytes. Hash and write it in ONE pass — see `checksum.ts`. */
  readonly stdout: Readable
  /** Resolves when the child exits 0; rejects with `PgToolError` otherwise. */
  readonly finished: Promise<void>
}

/**
 * Start `pg_dump -Fc` for one database and hand back its stdout.
 *
 * Custom format, not plain SQL, and not because of the compression: `-Fc` is the only format
 * `pg_restore` can restore selectively from, which is what makes a verify-mode restore of a single
 * table possible without a 300 MB text file and a `psql` that cannot be stopped part-way.
 *
 * The caller must consume `stdout` — a dump whose reader never attaches fills the pipe buffer and
 * blocks the child for ever, holding a lease and an open transaction on a live database.
 */
export function startDump(connection: ClusterConnection, database: string, timeoutMs: number): DumpHandle {
  const name = assertSafeDatabaseName(database)
  const child = spawn(
    'pg_dump',
    [
      '--format=custom',
      // Never prompt. A daemon has nothing to answer with, and the prompt would hang for ever.
      '--no-password',
      // Keeps the archive restorable by a role that is not the original owner, which is what a
      // scratch verify database always is.
      '--no-owner',
      '--no-acl',
    ],
    {
      env: pgEnvFor(connection, name),
      stdio: ['ignore', 'pipe', 'pipe'],
      signal: AbortSignal.timeout(timeoutMs),
    },
  )

  const stderr = collectStderr(child.stderr)
  const finished = new Promise<void>((resolve, reject) => {
    child.on('error', (err) => reject(new Error(`pg_dump on ${name} could not start: ${errorText(err)}`)))
    child.on('close', (code, signal) => {
      if (code === 0) resolve()
      else reject(new PgToolError('pg_dump', name, code, signal, stderr.text()))
    })
  })

  return { stdout: child.stdout, finished }
}

/**
 * Restore a custom-format archive into an existing database.
 *
 * `--single-transaction` with `--exit-on-error` is the difference between a restore and a mess: a
 * partial restore leaves a database that has some of the old data and some of the new, and there
 * is no way to tell which rows are which. Either the whole archive lands or nothing does.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **`--dbname` IS NOT REDUNDANT WITH `PGDATABASE`, AND THAT ASYMMETRY COST THIS ESTATE EVERY
 * AUTOMATED RESTORE IT HAS EVER ATTEMPTED.**
 *
 * `pg_dump` takes its target from `PGDATABASE` like any other libpq client, so `startDump` above
 * needs no `-d` and works. `pg_restore` does not: it decides between "restore into a database" and
 * "write a SQL script" from its OWN arguments, and with neither `-d` nor `-f` it exits 1 on
 * `one of -d/--dbname and -f/--file must be specified` — before it opens a connection, so
 * `PGDATABASE` is never consulted. The two tools disagree, and the one that silently succeeds is
 * the one that writes the backup.
 *
 * Measured on the mainnet estate 2026-08-10: five nightly sets written and checksummed, and five
 * consecutive `backup.verify` jobs dead-lettered after five attempts each on exactly that message,
 * plus one dead `backup.restore`. The dumps were real. Nothing had ever been restored from them,
 * and `backup_runs.verified_at` was correctly NULL on every set — the catalogue was telling the
 * truth and there was no green tick to contradict it.
 *
 * The name goes in `argv`, which the header of this module otherwise forbids — but the rule there
 * is about the PASSWORD, not the target. `-d` also accepts a full conninfo string, which is how a
 * database name would become a password in `argv`; `assertSafeDatabaseName` admits only
 * `[a-z_][a-z0-9_]*`, so it can contain neither `=`, `:` nor `/` and can never be parsed as one.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */
export async function runRestore(
  connection: ClusterConnection,
  database: string,
  archivePath: string,
  timeoutMs: number,
): Promise<void> {
  const name = assertSafeDatabaseName(database)
  const child = spawn(
    'pg_restore',
    [
      '--no-password',
      '--no-owner',
      '--no-acl',
      '--exit-on-error',
      '--single-transaction',
      `--dbname=${name}`,
      archivePath,
    ],
    {
      env: pgEnvFor(connection, name),
      stdio: ['ignore', 'ignore', 'pipe'],
      signal: AbortSignal.timeout(timeoutMs),
    },
  )

  const stderr = collectStderr(child.stderr)
  await new Promise<void>((resolve, reject) => {
    child.on('error', (err) => reject(new Error(`pg_restore on ${name} could not start: ${errorText(err)}`)))
    child.on('close', (code, signal) => {
      if (code === 0) resolve()
      else reject(new PgToolError('pg_restore', name, code, signal, stderr.text()))
    })
  })
}

/** The major version of the installed client tools, e.g. `17`. */
export async function clientMajorVersion(): Promise<number> {
  const child = spawn('pg_dump', ['--version'], { stdio: ['ignore', 'pipe', 'ignore'] })
  let out = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk: string) => {
    out += chunk
  })
  await new Promise<void>((resolve, reject) => {
    child.on('error', reject)
    child.on('close', () => resolve())
  })
  const match = /(\d+)\.\d+/.exec(out)
  if (!match?.[1]) throw new Error(`could not read a version out of \`pg_dump --version\`: ${out.trim()}`)
  return Number(match[1])
}

/**
 * Refuse to run if the client major version does not match the server's.
 *
 * At boot, not at 3 a.m. A version-skewed client is not a degraded backup, it is a set of files
 * that look exactly like backups and cannot be restored — which this system's whole purpose is to
 * prevent being discovered on the day it matters.
 */
export async function assertClientMatchesServer(serverVersion: string): Promise<void> {
  const serverMajor = Number(/^(\d+)/.exec(serverVersion)?.[1] ?? '0')
  const clientMajor = await clientMajorVersion()
  if (serverMajor !== clientMajor) {
    throw new Error(
      `PostgreSQL client is ${clientMajor} but the server is ${serverVersion} — version skew breaks restores. ` +
        `Rebuild the image against the PGDG ${serverMajor} client.`,
    )
  }
}

export interface ClusterFacts {
  readonly systemIdentifier: string
  readonly serverVersion: string
  readonly databases: readonly string[]
}

/**
 * Ask the cluster what it is and what it holds.
 *
 * The database list is DISCOVERED, never hard-coded. There are 29 today; a hard-coded list would
 * back up 29 for ever and silently omit the thirtieth service's data from the day it is deployed
 * — a hole nobody would find until a restore.
 *
 * `datallowconn` filters out anything that cannot be connected to (and so cannot be dumped);
 * templates are excluded because they are recreated by `initdb`, not restored.
 */
export async function readClusterFacts(sql: Sql): Promise<ClusterFacts> {
  const [identity] = await sql<{ system_identifier: string; server_version: string }[]>`
    select system_identifier::text as system_identifier,
           current_setting('server_version') as server_version
      from pg_control_system()
  `
  if (!identity) throw new Error('pg_control_system() returned no row')

  const rows = await sql<{ datname: string }[]>`
    select datname from pg_database
     where not datistemplate and datallowconn
     order by datname
  `
  return {
    systemIdentifier: identity.system_identifier,
    serverVersion: identity.server_version,
    databases: rows.map((row) => row.datname),
  }
}

/** On-disk size of one database, from the server's own accounting. */
export async function databaseSize(sql: Sql, database: string): Promise<bigint> {
  const [row] = await sql<{ size: string }[]>`
    select pg_database_size(${assertSafeDatabaseName(database)})::text as size
  `
  return BigInt(row?.size ?? '0')
}

/**
 * An EXACT row count across every user table in the connected database.
 *
 * **Exact, and still only ADVISORY when compared across a dump.** Two separate points:
 *
 *   · `sum(n_live_tup)` from `pg_stat_user_tables` is an ESTIMATE maintained by autovacuum, and on
 *     a freshly restored database it reads 0 until an `analyze` runs. Comparing that against a
 *     manifest reports a perfect restore as a total loss. So this uses `query_to_xml` to run a real
 *     `count(*)` per table inside one statement.
 *
 *   · Even so, a count taken by a SEPARATE query before or after `pg_dump` is not the count inside
 *     the dump's snapshot. Measured on this estate 2026-08-05: `identity` restored 34,099 rows
 *     against a source that read 34,101 four minutes later — `users` had grown from 2,577 to 2,585
 *     while the comparison was being made. `sessions` and `refresh_tokens` matched exactly and the
 *     restored copy had zero orphaned sessions, so the dump was a perfectly coherent transactional
 *     snapshot and the "mismatch" was the live estate doing its job.
 *
 * A verify that fails on that drift trains an operator to ignore it, and an ignored alarm is worse
 * than no alarm. So the count is recorded and reported, and `integrityOf` below is what a verify
 * actually passes or fails on.
 */
export async function exactRowCount(sql: Sql): Promise<bigint> {
  const [row] = await sql<{ total: string }[]>`
    select coalesce(sum(counted), 0)::text as total
      from (
        select (xpath(
                  '/row/c/text()',
                  query_to_xml(format('select count(*) as c from %I.%I', schemaname, relname), false, true, '')
               ))[1]::text::bigint as counted
          from pg_stat_user_tables
      ) per_table
  `
  return BigInt(row?.total ?? '0')
}

export interface IntegrityReport {
  readonly tables: number
  readonly foreignKeys: number
  readonly unvalidatedConstraints: number
  readonly ok: boolean
}

/**
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **WHAT A VERIFY RESTORE ACTUALLY PROVES, AND IT IS NOT A ROW COUNT.**
 *
 * The three things that are true statements about a restored copy:
 *
 *   (a) the artefact hashes to what was written        — `checksum.ts`
 *   (b) `pg_restore` exited 0                          — `runRestore`, with `--exit-on-error`
 *   (c) the restored copy is INTERNALLY CONSISTENT     — this
 *
 * (c) is nearly free and is much stronger than it looks. `pg_restore` creates foreign keys AFTER
 * loading the data, and `ALTER TABLE ... ADD FOREIGN KEY` validates every existing row as it is
 * added. Combined with `--single-transaction --exit-on-error`, an exit of 0 already means every
 * foreign key in the schema held against every restored row — a referential-integrity sweep of the
 * whole database, performed by the server, at no extra cost.
 *
 * What this function adds is the assertion that the sweep was not skipped: a constraint left
 * `NOT VALID` is one that was created without checking the rows, and a restore of zero tables also
 * exits 0 while proving nothing at all. Both are the shapes a "successful" empty restore takes.
 *
 * Compare with a live-versus-restored row count, which is not a statement about the backup: the
 * source keeps changing (see `exactRowCount` above), so a difference means "the estate is busy" far
 * more often than it means "the backup is broken".
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */
export async function integrityOf(sql: Sql): Promise<IntegrityReport> {
  const [row] = await sql<{ tables: number; foreign_keys: number; unvalidated: number }[]>`
    select
      (select count(*)::int from pg_class c
         join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r' and n.nspname not in ('pg_catalog', 'information_schema')) as tables,
      (select count(*)::int from pg_constraint where contype = 'f') as foreign_keys,
      -- A constraint that exists but was never checked against the rows. Restoring one of these is
      -- how a database can pass every other test while holding rows it forbids.
      (select count(*)::int from pg_constraint where not convalidated) as unvalidated
  `
  const report = {
    tables: row?.tables ?? 0,
    foreignKeys: row?.foreign_keys ?? 0,
    unvalidatedConstraints: row?.unvalidated ?? 0,
  }
  return { ...report, ok: report.tables > 0 && report.unvalidatedConstraints === 0 }
}

/**
 * How many tables a LIVE database has right now.
 *
 * Opened only when a restore produced zero tables, which is the rare path — see `restore.ts`. A
 * database that legitimately has none (the cluster's own `postgres`, say) restores to zero, and
 * without this the drill calls that a mismatch and says so at `level: error` on a run in which
 * everything worked (micro-org#517).
 *
 * The claim it supports is deliberately modest and is the same one the row-drift note already
 * makes: the source is LIVE, so this is what it looks like now rather than what it looked like
 * inside the dump snapshot. That is enough to tell "this database has no tables" from "the archive
 * restored nothing", which is the only distinction being drawn.
 */
export async function tableCountOf(connection: ClusterConnection, database: string): Promise<number> {
  const sql = postgres(dsnFor(connection, database), { max: 1, onnotice: () => {} })
  try {
    return (await integrityOf(sql)).tables
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {})
  }
}

/**
 * `drop database ... with (force)`, then `create database`.
 *
 * `with (force)` terminates other sessions rather than failing on "database is being accessed by
 * other users" — which, on an estate where 46 services hold pools, is every time. It is the same
 * form `docs/custody-backup-restore.md` Appendix A.2 used in the rehearsal.
 *
 * Neither statement can take a parameter: `create database $1` is not valid SQL. The name is
 * therefore checked against a strict identifier shape AND quoted. See `paths.ts`.
 */
export async function recreateDatabase(sql: Sql, database: string, owner?: string): Promise<void> {
  const name = quoteIdent(assertSafeDatabaseName(database))
  await sql.unsafe(`drop database if exists ${name} with (force)`)
  await sql.unsafe(`create database ${name}${owner ? ` owner ${quoteIdent(assertSafeDatabaseName(owner))}` : ''}`)
}

/** Used only in the `finally` of a verify restore. Swallows nothing: a leaked scratch is a defect. */
export async function dropDatabase(sql: Sql, database: string): Promise<void> {
  await sql.unsafe(`drop database if exists ${quoteIdent(assertSafeDatabaseName(database))} with (force)`)
}
