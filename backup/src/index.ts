/**
 * The composition root.
 *
 * The order below is not arbitrary and each step carries the reason it must precede the next.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **STEP 0 IS THE KEYRING REFUSAL, AND IT IS FIRST FOR A REASON.**
 *
 * Before a logger exists, before a pool is opened, before a job could possibly be claimed: if a
 * `CUSTODY_MASTER_SECRET_V<n>` is anywhere in this process's environment, this process exits. It
 * writes the custody VAULT, and §1.5 of `docs/custody-backup-restore.md` is unambiguous that the
 * vault and the keyring on one medium is "a plaintext key store with extra steps". The only way
 * that happens is a compose-file edit, and a compose-file edit is not something source review
 * catches — so the check is here, in the process that would be holding both halves.
 *
 * It exits before the logger exists on purpose. A logger would be a thing that could be asked to
 * log what it found, and what it found is a keyring.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * This process runs NO migrations. `admin_api`'s schema is admin-api's, and a data-plane process
 * that could create the tables it reads is a data-plane process that could start against a schema
 * nobody agreed to.
 */

import { createServer } from 'node:http'
import postgres from 'postgres'
import { JobQueue, JobRunner, type Sql as JobsSql } from '@cloudsforge/jobs'
import { Lifecycle, installSignalHandlers, postgresProbe } from '@cloudsforge/lifecycle'
import { Logger, Metrics, registerJobMetrics } from '@cloudsforge/telemetry'

// ── 0. THE KEYRING REFUSAL. Nothing above this line but imports.
import { assertNoKeyring, KeyringPresentError } from './keyring.ts'

try {
  assertNoKeyring(process.env)
} catch (err) {
  if (err instanceof KeyringPresentError) {
    // `err.message` names VARIABLES, never values — see `keyring.ts`. Written straight to stderr
    // rather than through a logger, because at this point there deliberately is not one.
    process.stderr.write(`${err.message}\n`)
    process.exit(1)
  }
  throw err
}

// Dynamic imports, and not for style. A static `import` is hoisted and evaluated BEFORE the block
// above runs, so `env.ts` — which reads `process.env` at module scope — would execute while the
// keyring may still be present. The guard has to be the first thing that happens, so everything
// that reads the environment has to be loaded after it.
const { env, SERVICE } = await import('./env.ts')
const { registerHandlers, RecurringSchedule, rescheduleRecurring, seedRecurring, leaseKeyFor } = await import('./jobs.ts')
const { lastSucceededAt } = await import('./catalogue.ts')
const { assertClientMatchesServer, parseDsn, readClusterFacts } = await import('./pg.ts')
const { assertDestinationIsReal, freeBytesAt } = await import('./disk.ts')

// ── 1. Telemetry, before anything that can fail, so the pool's failure is a structured line.
const logger = new Logger({ service: SERVICE, level: env.logLevel, version: env.version, env: env.env })
const metrics = registerJobMetrics(new Metrics())
  .register({ name: 'backup_artefacts_written_total', help: 'Artefacts written', kind: 'counter', labels: ['kind'] })
  .register({ name: 'backup_runs_failed_total', help: 'Backup runs that failed', kind: 'counter' })
  .register({ name: 'backup_runs_pruned_total', help: 'Backup sets removed by retention', kind: 'counter' })
  .register({ name: 'backup_restores_failed_total', help: 'Restores that failed', kind: 'counter', labels: ['mode'] })
  .register({
    name: 'backup_restores_refused_total',
    help: 'Restores refused by a gate rather than failed',
    kind: 'counter',
    labels: ['reason'],
  })
  .register({ name: 'backup_verifications_failed_total', help: 'Periodic verifications that found a bad set', kind: 'counter' })
  .register({ name: 'backup_last_success_bytes', help: 'Size of the last successful set', kind: 'gauge' })
  // `_unixtime`, deliberately, and NOT the Prometheus-idiomatic `_timestamp_seconds`. The
  // convention would be right in a greenfield exporter; here it would mean this one process
  // publishes two spellings for the same kind of value, one line apart from
  // `backup_last_verified_unixtime` below. Local consistency inside a single exporter beats a
  // convention that is only half-applied, because the cost of the half-application is a reader
  // having to know which of the two spellings any future gauge here follows.
  .register({ name: 'backup_last_success_unixtime', help: 'When the last successful run finished', kind: 'gauge' })
  .register({ name: 'backup_last_verified_unixtime', help: 'When a restore last proved a set', kind: 'gauge' })
  .register({ name: 'backup_retained_bytes', help: 'Bytes retained after the last prune', kind: 'gauge' })
  .register({ name: 'backup_destination_free_bytes', help: 'Free space at the destination', kind: 'gauge' })

logger.info('starting', {
  version: env.version,
  environment: env.env,
  composeProject: env.composeProject,
  backupRoot: env.backupRoot,
  // A PUBLIC key, and safe to log — that is the property that makes `age` the right choice here.
  // Logged so an operator can confirm which recipient a set was encrypted to without decrypting it.
  ageRecipient: env.ageRecipient ?? '(unset — the miner coinbase key will NOT be backed up)',
  custodyKeyringInProcess: false,
})

// ── 2. Two pools, two trust domains. See the header of `env.ts` for why they are in one process.
const admin = postgres(env.adminDatabaseUrl, { max: env.databasePoolMax, onnotice: () => {} })
const cluster = postgres(env.clusterUrl, { max: 2, onnotice: () => {} })
const connection = parseDsn(env.clusterUrl)

// ── 3. Prove the destination is real and the tools match the server BEFORE claiming any work.
//
//       Both failures are silent and both produce green rows: a version-skewed client does not
//       produce worse backups, it produces files that look like backups and cannot be restored; and
//       a destination snap-packaged Docker cannot see becomes an ephemeral directory in which every
//       write appears to succeed and nothing survives the container. See `disk.ts`.
try {
  await assertDestinationIsReal(env.backupRoot)
  const facts = await readClusterFacts(cluster)
  await assertClientMatchesServer(facts.serverVersion)
  logger.info('cluster', {
    serverVersion: facts.serverVersion,
    systemIdentifier: facts.systemIdentifier,
    databases: facts.databases.length,
  })
} catch (err) {
  logger.fatal('refusing to start', { err })
  await Promise.all([admin.end({ timeout: 5 }).catch(() => {}), cluster.end({ timeout: 5 }).catch(() => {})])
  process.exit(1)
}

// ── 4. Lifecycle and probes, before the routes, because `/readyz` needs something to report.
const lifecycle = new Lifecycle({
  drainDelayMs: 5_000,
  // Long, deliberately. A drain must not cut a `pg_restore` between `drop database` and the restore
  // landing — that gap is the only moment in this system where a database exists and is empty.
  drainTimeoutMs: 120_000,
  onStateChange: (state) => logger.info('lifecycle state', { state }),
})

lifecycle
  .addProbe(postgresProbe('admin', () => admin`select 1`))
  .addProbe(postgresProbe('cluster', () => cluster`select 1`))

// ── 5. The queue and the runner. ONLY `backup.*` kinds are registered, which is what stops this
//       process and admin-api ever claiming each other's work. See `jobs.ts`.
const queue = new JobQueue(admin as unknown as JobsSql, {
  owner: `${SERVICE}@${env.instanceId}`,
  leaseMs: env.jobLeaseMs,
})
const schedule = new RecurringSchedule()
const runner = new JobRunner({
  queue,
  concurrency: env.jobConcurrency,
  pollMs: env.jobPollMs,
  shouldClaim: () => lifecycle.claimingJobs,
  onEvent: (event) => {
    if (event.type === 'failed' || event.type === 'dead' || event.type === 'error') {
      logger.error('job event', { ...event })
    }
    rescheduleRecurring(queue, schedule, logger)(event)
  },
})

registerHandlers(runner, { admin, cluster, connection, env, logger, metrics }, schedule)

await seedRecurring(admin, queue, env.env, logger).catch((err: unknown) =>
  logger.error('could not seed the recurring jobs', { err }),
)

// ══════════════════════════════════════════════════════════════════════════════════════════════
// SEED `backup_last_success_unixtime` FROM THE CATALOGUE, AND DO IT BEFORE ANYTHING CAN CLAIM.
//
// A gauge written only on the success path is erased by a container restart, and `Metrics.render`
// drops a gauge that has never been set out of the exposition entirely — it emits the HELP and TYPE
// lines and no sample. So without this read, every restart would leave
// `time() - backup_last_success_unixtime > 129600` evaluating over an EMPTY VECTOR, which produces
// no series and therefore never crosses the threshold: the page reads as satisfied because there is
// nothing to compare. That silent green is the defect micro-org#310 is about, and a redeploy is not
// an exotic event — it is how every release lands.
//
// Before `runner.start()` for an ordering reason, not for tidiness: a run that completed while this
// process was booting would otherwise be overwritten by the older value read here.
//
// NOTHING IS PUBLISHED WHEN THERE IS NO SUCCEEDED RUN. Not a zero and not a sentinel — see
// `lastSucceededAt`. An absent series says "nothing has ever backed this estate up", which is a
// different fact from "the last backup is old", and `BackupNeverRun` is the rule that reads it.
// ══════════════════════════════════════════════════════════════════════════════════════════════
const lastSuccess = await lastSucceededAt(admin, env.env).catch((err: unknown) => {
  // Not fatal. A catalogue read that failed is a reason to leave the gauge absent, which the ticket
  // rule notices; refusing to start over it would stop the estate taking backups to protect a
  // metric about backups.
  logger.error('could not read the last successful backup from the catalogue', { err })
  return null
})
if (lastSuccess) {
  metrics.set('backup_last_success_unixtime', Math.floor(lastSuccess.getTime() / 1000))
}
logger.info('last successful backup', {
  environment: env.env,
  // The absence is logged as loudly as a value would be. On mainnet as of 2026-08-10 this is the
  // line an operator will see, because `/data/cloudsforge-backups` is empty and `backup_runs` has
  // never held a succeeded row for this estate.
  lastSuccessAt: lastSuccess?.toISOString() ?? '(never — this estate has no backup)',
})

runner.start()

// ── 6. A probe surface. Small on purpose: this deployable answers no domain request, and the only
//       questions worth asking it are "are you alive", "are you ready" and "what have you done".
const server = createServer((request, response) => {
  const url = request.url ?? '/'
  if (url === '/livez') {
    response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(lifecycle.livez()))
    return
  }
  if (url === '/metrics') {
    void freeBytesAt(env.backupRoot)
      .then((free) => metrics.set('backup_destination_free_bytes', Number(free)))
      .catch(() => {})
      .finally(() => response.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' }).end(metrics.render()))
    return
  }
  if (url === '/readyz') {
    void lifecycle.readyz().then((report) => {
      response
        .writeHead(report.ready ? 200 : 503, { 'content-type': 'application/json' })
        .end(JSON.stringify(report))
    })
    return
  }
  response.writeHead(404, { 'content-type': 'application/json' }).end('{"error":"not found"}')
})

server.listen(env.port, () => {
  lifecycle.markReady()
  logger.info('listening', { port: env.port })
})

// Hooks run in REVERSE registration order, so registering pools first and the runner last means the
// runner stops before the pools it needs are closed.
lifecycle
  .onShutdown(async () => {
    await Promise.all([admin.end({ timeout: 10 }).catch(() => {}), cluster.end({ timeout: 10 }).catch(() => {})])
  })
  .onShutdown(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  .onShutdown(async () => {
    // Stop claiming, then wait for what is in flight. A `pg_dump` killed mid-stream leaves a
    // truncated file, and a truncated file is exactly the artefact this system must never produce
    // silently. Two minutes is generous because the alternative is a half-written set.
    const drained = await runner.stop(120_000)
    if (!drained) logger.error('a backup job was still running at the end of the drain window')
  })

// 45 s is not enough for a dump that is mid-flight, and the drain above is what should end the
// process. This is the backstop for a drain that itself wedges.
installSignalHandlers(lifecycle, { forceExitAfterMs: 180_000 })
