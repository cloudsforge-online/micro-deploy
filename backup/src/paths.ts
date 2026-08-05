/**
 * Path validation, and the redaction every log line and every `error` column goes through.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **A MANIFEST IS UNTRUSTED INPUT.** It is a JSON file on a disk, and a restore reads it to decide
 * which files to open and which databases to overwrite. If `relPath` is taken at face value then:
 *
 *   `"relPath": "/etc/cron.d/x"`      is a write primitive aimed at the host, on the *pre-restore
 *                                     backup* path where this process WRITES beside the manifest.
 *   `"relPath": "../../etc/shadow"`   is the same primitive spelled portably.
 *   `"name": "postgres\"; drop ..."`  is a database name interpolated into `create database`,
 *                                     which cannot be parameterised.
 *
 * `backup_artefacts_rel_path_is_relative` says the same thing in the schema, but the schema is on
 * the machine that TOOK the backup. A restore reads the manifest off a disk that may have come
 * from anywhere — that is what a cold restore IS — so the check has to exist on this side too, and
 * this is that side.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { isAbsolute, normalize, resolve, sep } from 'node:path'

export class UnsafePathError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'UnsafePathError'
  }
}

/**
 * The character class from `backup_artefacts_rel_path_is_relative`, deliberately identical.
 *
 * Two independent checks that disagree are worse than one: the run would write a path the database
 * refuses, fail at the INSERT, and leave the bytes on disk with no row pointing at them.
 */
const REL_PATH_SHAPE = /^[A-Za-z0-9._/-]{1,255}$/

/**
 * Validate a manifest-supplied relative path and return it unchanged.
 *
 * Returns the input rather than a resolved absolute path so that a caller cannot accidentally use
 * this as "make it safe"; joining is `resolveWithin`, which checks the result as well as the input.
 */
export function assertSafeRelPath(relPath: string): string {
  if (!REL_PATH_SHAPE.test(relPath)) {
    throw new UnsafePathError(
      `relPath ${JSON.stringify(relPath)} is not of the permitted shape — a manifest is untrusted input`,
    )
  }
  if (isAbsolute(relPath)) {
    throw new UnsafePathError(
      `relPath ${JSON.stringify(relPath)} is absolute — an absolute path in a manifest is a write primitive aimed anywhere on the host`,
    )
  }
  // Checked on the raw string AND on the normalised form: `a/./../../b` normalises to `../b`, and
  // `a/..%2f` does not, so neither check alone covers the other.
  if (relPath.includes('..') || normalize(relPath).split('/').includes('..')) {
    throw new UnsafePathError(`relPath ${JSON.stringify(relPath)} traverses upwards`)
  }
  if (relPath.endsWith('/')) {
    throw new UnsafePathError(`relPath ${JSON.stringify(relPath)} names a directory, not a file`)
  }
  return relPath
}

/**
 * Join a validated relative path onto a root and prove the result is still inside it.
 *
 * The second check is not redundant with the first. `assertSafeRelPath` rejects the strings we can
 * enumerate; this rejects everything else by construction, including whatever a future Node version
 * decides a path separator is. A containment check that is performed on the resolved path is the
 * only form of this that is not a blocklist.
 */
export function resolveWithin(root: string, relPath: string): string {
  assertSafeRelPath(relPath)
  const rootResolved = resolve(root)
  const full = resolve(rootResolved, relPath)
  if (full !== rootResolved && !full.startsWith(rootResolved + sep)) {
    throw new UnsafePathError(`${JSON.stringify(relPath)} resolves outside ${JSON.stringify(root)}`)
  }
  return full
}

/**
 * `backup_settings.root_path`'s own constraint, re-stated here.
 *
 * The setting is operator-editable from the panel, and this string becomes the parent of every
 * `tar` and `pg_restore` this process runs. Filling the wrong disk on this host stops the miner and
 * the chain, which is a second failure the backup system would have caused rather than survived.
 */
export function assertSafeRootPath(root: string): string {
  if (!/^\/[A-Za-z0-9._/-]{0,255}$/.test(root) || root.includes('..')) {
    throw new UnsafePathError(`root_path ${JSON.stringify(root)} is not an absolute, traversal-free path`)
  }
  return root
}

/**
 * A Postgres database name that is safe to put in `create database` / `drop database`.
 *
 * Those statements take no parameters — there is no placeholder form — so the only defence is that
 * the identifier was never attacker-shaped in the first place. Quoting as well (`quoteIdent`) is
 * belt and braces; this is the belt.
 */
export function assertSafeDatabaseName(name: string): string {
  if (!/^[a-z_][a-z0-9_]{0,62}$/.test(name)) {
    throw new UnsafePathError(
      `database name ${JSON.stringify(name)} is not a plain lower-case identifier — refusing to interpolate it into DDL`,
    )
  }
  return name
}

/** Double-quote an identifier for DDL that cannot be parameterised. */
export function quoteIdent(name: string): string {
  return `"${name.replaceAll('"', '""')}"`
}

/**
 * Strip anything credential-shaped out of a string before it reaches a log line, a `last_error`, or
 * the `error` column of `backup_runs`.
 *
 * `pg_restore` and `psql` echo the connection they failed on, and a `postgres://` URI carries the
 * cluster password in the middle of it. The `error` column is read by an operator console, so an
 * unredacted failure would publish the estate's database password to every operator session and,
 * from there, to whatever transcript is recording it — which is precisely how three keyrings were
 * lost on 2026-08-05 (§7.1). Passwords are never in argv here (see `pg.ts`), so this is the second
 * line of defence rather than the first.
 */
export function redact(text: string): string {
  return text
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/)([^:@/\s]+):([^@/\s]+)@/gi, '$1$2:***@')
    .replace(/\b(PGPASSWORD|password)\s*=\s*\S+/gi, '$1=***')
}

/** Reduce any thrown value to a redacted, length-bounded string fit for a database column. */
export function errorText(err: unknown, limit = 2_000): string {
  const raw = err instanceof Error ? err.message : String(err)
  return redact(raw).slice(0, limit)
}
