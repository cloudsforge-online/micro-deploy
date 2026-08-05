/**
 * Configuration, validated at import.
 *
 * Rule 9 — "a repo declares the variables it needs; the deploy provides exactly those" — is a
 * property of this file. Every variable this deployable reads is named here and nowhere else.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **TWO DSNs, ON PURPOSE, AND THAT IS WHY THIS IS NOT PART OF admin-api.**
 *
 *   `BACKUP_ADMIN_DATABASE_URL`  the control plane's own database. Where `jobs`, `backup_runs`,
 *                                `backup_artefacts`, `restore_runs` and `backup_settings` live.
 *                                Ordinary application credentials.
 *   `BACKUP_CLUSTER_URL`         the cluster, as a role that can `pg_dump` every database and
 *                                `create`/`drop` them. This is the estate's most powerful
 *                                credential after the keyring.
 *
 * Rule 1 gives a service exactly one database and CI greps `admin-api/src` for a second DSN.
 * Migration 10's own header explains the split: "a process that dumps twenty-nine OTHER databases
 * cannot live in admin-api/src — and should not, because reading every database in the cluster is
 * a different trust domain from composing an operator's console." An admin-api RCE reaches an
 * operator console; an RCE here reaches the dumps. Keeping them apart is what makes those two
 * different sentences.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * **`BACKUP_ENVIRONMENT` IS NOT A PARAMETER.** It is baked into the container at creation and is
 * one half of the refusal in `manifest.ts`. It is never accepted from a job payload, a route or a
 * manifest — the 2026-08-05 defect was a target parameter that was ignored, so a parameter is
 * exactly the thing that must not decide this.
 *
 * **NO VARIABLE HERE NAMES CUSTODY KEY MATERIAL, AND NONE EVER MAY.** `keyring.ts` refuses to boot
 * if one is present in the environment at all.
 */

import { hostname } from 'node:os'
import { assertSafeRootPath } from './paths.ts'
import { assertAgeRecipient } from './secrets.ts'
import type { Environment } from './manifest.ts'

/** A property of the repository, not of the deployment. */
export const SERVICE = 'backup-runner'

export class EnvError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'EnvError'
  }
}

type Source = Readonly<Record<string, string | undefined>>

function required(source: Source, name: string): string {
  const value = source[name]?.trim()
  if (!value) throw new EnvError(`${name} is required — ${SERVICE} refuses to start without it`)
  return value
}

function optional(source: Source, name: string, fallback: string): string {
  const value = source[name]?.trim()
  return value && value.length > 0 ? value : fallback
}

function integer(source: Source, name: string, fallback: number, min: number, max: number): number {
  const raw = source[name]?.trim()
  if (!raw) return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new EnvError(`${name} must be a whole number between ${min} and ${max} (got ${raw})`)
  }
  return value
}

const ENVIRONMENTS: ReadonlySet<string> = new Set(['mainnet', 'testnet', 'development'])

export interface Env {
  readonly env: Environment
  readonly composeProject: string
  readonly version: string
  readonly logLevel: 'debug' | 'info' | 'warn' | 'error' | 'fatal'
  readonly instanceId: string
  readonly port: number

  readonly adminDatabaseUrl: string
  readonly clusterUrl: string
  readonly databasePoolMax: number

  /** Where backups are written. `backup_settings.root_path` overrides it per run; this is the mount. */
  readonly backupRoot: string

  /**
   * The three source directories, each mounted read-only.
   *
   * `custodyVaultDir` points at the directory whose CONTENTS become the tarball — the `keys/`
   * subdirectory of the `<project>_custody-keys` volume, not the volume root. That is not a detail:
   * `docs/custody-backup-restore.md` §2 tars `-C /vault/keys .` and §3 extracts `-C /vault/keys`,
   * and §1.2 explains why the level matters — the slot name is authenticated as GCM AAD, so a
   * tarball rooted one directory higher restores every blob one directory deeper and every single
   * one of them then fails its GCM tag. The vault must be restored with its directory names intact.
   */
  readonly custodyVaultDir: string
  readonly studioAssetsDir: string
  readonly worldAssetsDir: string

  /**
   * Where the miner coinbase keys are mounted, read-only. The file taken is
   * `<minerKeysDir>/<BACKUP_ENVIRONMENT>/coinbase-key.json` — derived from the environment rather
   * than configured, so a mainnet runner cannot be pointed at the testnet key by a settings edit.
   */
  readonly minerKeysDir: string

  /**
   * An `age1…` **public** key, or null.
   *
   * Not a secret and not validated as one: it is safe in compose, in a log line and in a git
   * history. Its private half must never exist on this host — that is the entire property. Null
   * means the miner coinbase key is left out of the set and the manifest says so; see `secrets.ts`
   * for why there is no unencrypted fallback.
   */
  readonly ageRecipient: string | null

  /** How long a claimed backup job may run before another worker may take it. */
  readonly jobLeaseMs: number
  readonly jobPollMs: number
  /**
   * One at a time. Two concurrent `pg_dump` sweeps of the same cluster would double the read load
   * on the disk holding the live databases and race for the same destination directory.
   */
  readonly jobConcurrency: number
  readonly pgToolTimeoutMs: number
}

export function loadEnv(source: Source = process.env): Env {
  const environment = required(source, 'BACKUP_ENVIRONMENT')
  if (!ENVIRONMENTS.has(environment)) {
    throw new EnvError(
      `BACKUP_ENVIRONMENT must be one of mainnet, testnet, development (got ${JSON.stringify(environment)}) — ` +
        `it is one half of the cross-environment restore refusal and cannot be guessed`,
    )
  }

  const level = optional(source, 'LOG_LEVEL', 'info')
  if (!['debug', 'info', 'warn', 'error', 'fatal'].includes(level)) {
    throw new EnvError(`LOG_LEVEL must be one of debug, info, warn, error, fatal (got ${level})`)
  }

  return {
    env: environment as Environment,
    composeProject: required(source, 'BACKUP_COMPOSE_PROJECT'),
    version: optional(source, 'SERVICE_VERSION', '1.0.0'),
    logLevel: level as Env['logLevel'],
    instanceId: optional(source, 'INSTANCE_ID', hostname()),
    port: integer(source, 'PORT', 4130, 1, 65_535),

    adminDatabaseUrl: required(source, 'BACKUP_ADMIN_DATABASE_URL'),
    clusterUrl: required(source, 'BACKUP_CLUSTER_URL'),
    databasePoolMax: integer(source, 'BACKUP_DATABASE_POOL_MAX', 4, 1, 20),

    backupRoot: assertSafeRootPath(optional(source, 'BACKUP_ROOT', '/backups')),

    custodyVaultDir: optional(source, 'BACKUP_CUSTODY_VAULT_DIR', '/vault/custody-keys/keys'),
    studioAssetsDir: optional(source, 'BACKUP_STUDIO_ASSETS_DIR', '/volumes/studio-assets'),
    worldAssetsDir: optional(source, 'BACKUP_WORLD_ASSETS_DIR', '/world-assets'),
    minerKeysDir: optional(source, 'BACKUP_MINER_KEYS_DIR', '/miner-keys'),
    // Shape-checked here so a truncated paste fails at boot rather than after a nightly run has
    // already written every other artefact.
    ageRecipient: source['BACKUP_AGE_RECIPIENT']?.trim()
      ? assertAgeRecipient(source['BACKUP_AGE_RECIPIENT'].trim())
      : null,

    // Two hours. A full sweep of ~290 MB across 29 databases takes minutes, but the lease has to
    // exceed the SLOWEST plausible run — a restore under load — or a second worker takes the job
    // while the first is still writing to the same directory. Handlers heartbeat as well.
    jobLeaseMs: integer(source, 'BACKUP_JOB_LEASE_MS', 7_200_000, 60_000, 86_400_000),
    jobPollMs: integer(source, 'BACKUP_JOB_POLL_MS', 5_000, 250, 60_000),
    jobConcurrency: integer(source, 'BACKUP_JOB_CONCURRENCY', 1, 1, 4),
    pgToolTimeoutMs: integer(source, 'BACKUP_PG_TOOL_TIMEOUT_MS', 3_600_000, 30_000, 86_400_000),
  }
}

export const env: Env = loadEnv()
