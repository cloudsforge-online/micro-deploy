/**
 * Tests for the Postgres side.
 *
 * This file exists because `pg.ts` was the one module here with no test at all, and the defect that
 * found is the worst one this deployable can have: `runRestore` was spawning `pg_restore` with no
 * `-d`, so every automated restore — the nightly verify AND the operator-triggered restore — failed
 * on argument parsing, while `pg_dump` beside it kept writing perfectly good archives. Five nights
 * of green backups and five dead-lettered verifies on the mainnet estate, 2026-08-10.
 *
 * The tests below therefore run the REAL `pg_restore` binary. They need no server: the tool
 * validates its arguments and reads the archive header before it opens a connection, so a closed
 * port and a junk file are enough to tell "refused to start" apart from "started and then failed",
 * which is exactly the distinction the bug turned on. A test that asserted on the argv array we
 * happen to build would have been written from the same wrong belief as the code and passed.
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { parseDsn, dsnFor, PgToolError, runRestore, type ClusterConnection } from './pg.ts'

/** The message `pg_restore` prints when it has been given neither a database nor an output file. */
const NEEDS_A_TARGET = 'must be specified'

const HAVE_PG_RESTORE = spawnSync('pg_restore', ['--version'], { stdio: 'ignore' }).status === 0
const skip = HAVE_PG_RESTORE ? false : 'pg_restore is not installed on this machine'

/**
 * A cluster nothing is listening on. Deliberate: if any test here ever reaches the network it has
 * stopped testing argument handling, and it should fail loudly rather than depend on a live estate.
 */
const NOWHERE: ClusterConnection = {
  host: '127.0.0.1',
  port: '1',
  user: 'cloudsforge',
  password: 'not-a-real-password',
  database: 'postgres',
}

async function withJunkArchive<T>(body: (path: string) => Promise<T>): Promise<T> {
  const directory = await mkdtemp(join(tmpdir(), 'cf-pg-'))
  const path = join(directory, 'not-really.dump')
  await writeFile(path, 'this is not a custom-format archive')
  try {
    return await body(path)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

test('pg_restore does not treat PGDATABASE as an implied -d — the asymmetry the bug was built on', { skip }, () => {
  // The belief that produced the defect, stated as an executable claim. `pg_dump` reads PGDATABASE;
  // this asserts that `pg_restore` does NOT, so the next person to "simplify" the argv away has to
  // delete a failing test rather than a comment.
  const result = spawnSync('pg_restore', ['--no-password', '/dev/null'], {
    env: { PATH: process.env['PATH'] ?? '', PGDATABASE: 'somedb', PGHOST: '127.0.0.1', PGPORT: '1' },
    encoding: 'utf8',
  })

  assert.notEqual(result.status, 0, 'pg_restore accepted PGDATABASE alone — re-read runRestore before trusting this')
  assert.match(result.stderr, /one of -d\/--dbname and -f\/--file must be specified/)
})

test('runRestore names its target, so pg_restore gets as far as reading the archive', { skip }, async () => {
  const error = await withJunkArchive(async (path) => {
    return await runRestore(NOWHERE, 'scratch_verify_identity_0badc0de', path, 20_000).then(
      () => null,
      (err: unknown) => err,
    )
  })

  // It must fail — the archive is junk and the port is closed. WHICH failure is the whole test.
  assert.ok(error instanceof PgToolError, `expected a PgToolError, got ${String(error)}`)
  assert.ok(
    !error.stderr.includes(NEEDS_A_TARGET),
    `pg_restore refused to start for want of a target: ${error.stderr.trim()}`,
  )
  // Named in the message, so an operator reading `restore_runs.error` learns which database it was.
  assert.match(error.message, /scratch_verify_identity_0badc0de/)
})

/**
 * A password containing `@` and `:` — the case that breaks naive DSN splitting, which is why
 * `parseDsn` exists and why `paths.ts` warns that `[^@]*` runs across a whole JSON object.
 *
 * Assembled rather than written out, and not because it is secret: `ci.yml` refuses any
 * `postgres://user:...@host` literal in a tracked file, having once found that spelling fifty-six
 * times in a public compose file (micro-org#157). A test fixture is exactly the shape a careless
 * edit reintroduces one at a time, so it gets no exemption and asks for none — including this
 * sentence, which is elided the same way `ci.yml`'s own prose is and for the same reason.
 */
const AWKWARD_PASSWORD = 'p@ss:word'
const DSN = `postgres://cloudsforge:${encodeURIComponent(AWKWARD_PASSWORD)}@postgres:5432/admin_api?sslmode=require`

test('runRestore refuses a database name that could be read as a conninfo string', async () => {
  // `-d` accepts a full connection string, which is the one way a database name could smuggle a
  // password into argv. The guard is what makes passing the name on the command line safe at all.
  await assert.rejects(
    () => runRestore(NOWHERE, DSN, '/dev/null', 1_000),
    /not a plain lower-case identifier/,
  )
})

test('parseDsn keeps the password out of the parsed shape only insofar as it round-trips', () => {
  const parsed = parseDsn(DSN)
  assert.equal(parsed.host, 'postgres')
  assert.equal(parsed.port, '5432')
  assert.equal(parsed.user, 'cloudsforge')
  // Percent-decoded once, exactly once.
  assert.equal(parsed.password, AWKWARD_PASSWORD)
  assert.equal(parsed.database, 'admin_api')
  assert.equal(parsed.sslmode, 'require')

  // And back out again for postgres.js, re-encoded so it survives the round trip.
  const url = new URL(dsnFor(parsed, 'custody'))
  assert.equal(decodeURIComponent(url.password), AWKWARD_PASSWORD)
  assert.equal(url.pathname, '/custody')
  assert.equal(url.searchParams.get('sslmode'), 'require')
})

test('parseDsn rejects anything that is not a postgres URL rather than passing it through', () => {
  assert.throws(() => parseDsn('postgres'), /not a URL/)
  assert.throws(() => parseDsn('mysql://cloudsforge@db/identity'), /must be a postgres:\/\/ URL/)
})
