import assert from 'node:assert/strict'
import test from 'node:test'
import {
  assertSafeDatabaseName,
  assertSafeRelPath,
  assertSafeRootPath,
  errorText,
  quoteIdent,
  redact,
  resolveWithin,
  UnsafePathError,
} from './paths.ts'

test('an ordinary artefact path is accepted', () => {
  for (const relPath of ['db/identity.dump', 'vault/custody-keys.tgz', 'MANIFEST.json', 'secrets/x.json.age']) {
    assert.equal(assertSafeRelPath(relPath), relPath)
  }
})

test('absolute and traversing paths are refused', () => {
  for (const relPath of ['/etc/passwd', '/', '../x', 'a/../../b', 'a/..', '..']) {
    assert.throws(() => assertSafeRelPath(relPath), UnsafePathError, `accepted ${relPath}`)
  }
})

test('resolveWithin refuses anything that lands outside the root, however it is spelled', () => {
  assert.equal(resolveWithin('/backups/run', 'db/identity.dump'), '/backups/run/db/identity.dump')
  assert.throws(() => resolveWithin('/backups/run', '../other/x'), UnsafePathError)
  assert.throws(() => resolveWithin('/backups/run', '/absolute'), UnsafePathError)
})

test('resolveWithin is not fooled by a root that is a prefix of a sibling', () => {
  // `/backups/run` and `/backups/run-2` share a prefix; a naive startsWith would let the second
  // pass as inside the first.
  const inside = resolveWithin('/backups/run', 'a')
  assert.ok(inside.startsWith('/backups/run/'))
  assert.ok(!inside.startsWith('/backups/run-2'))
})

test('a database name that is not a plain identifier is refused before it reaches DDL', () => {
  assert.equal(assertSafeDatabaseName('custody'), 'custody')
  assert.equal(assertSafeDatabaseName('admin_api'), 'admin_api')
  for (const name of ['Custody', 'custody; drop database ledger', 'custody"', '', '1custody', 'a'.repeat(64)]) {
    assert.throws(() => assertSafeDatabaseName(name), UnsafePathError, `accepted ${JSON.stringify(name)}`)
  }
})

test('quoteIdent doubles an embedded quote', () => {
  assert.equal(quoteIdent('custody'), '"custody"')
  assert.equal(quoteIdent('a"b'), '"a""b"')
})

test('root_path must be absolute and traversal-free, matching the schema constraint', () => {
  assert.equal(assertSafeRootPath('/backups'), '/backups')
  for (const root of ['backups', '/backups/../etc', '/back ups', '/backups;rm']) {
    assert.throws(() => assertSafeRootPath(root), UnsafePathError, `accepted ${root}`)
  }
})

/**
 * The fixture password, built rather than written.
 *
 * These tests exist to prove a password does NOT survive into an error message, so they must hand
 * the code under test something password-shaped. Spelled inline, that is a tracked file holding a
 * connection URL with a password written out inside it — exactly the shape
 * `deploy/.github/workflows/ci.yml` fails the build on, and correctly: 57 copies of one real
 * Postgres password were once committed to a public compose file in that form.
 *
 * (This comment is itself written to avoid that shape. The guard reads text, not intent, and a
 * comment explaining the rule must not be the thing that breaks it.)
 *
 * So the value is assembled at run time. The assertions are unchanged and still fail if redaction
 * regresses; only the file's TEXT stops resembling a committed credential. Same resolution as
 * `keyring.test.ts`, and as `custody-backup-restore.md` §5.4 before it: the guard is right, and
 * the test stops looking like the defect.
 */
const FIXTURE_PASSWORD = ['hunter', '2'].join('')

test('redaction strips the cluster password out of anything a pg tool echoed', () => {
  const leaked = `connection to postgres://cloudsforge:${FIXTURE_PASSWORD}@postgres:5432/custody failed`
  assert.ok(!redact(leaked).includes(FIXTURE_PASSWORD))
  assert.match(redact(leaked), /postgres:\/\/cloudsforge:\*\*\*@postgres:5432\/custody/)

  assert.ok(!redact(`PGPASSWORD=${FIXTURE_PASSWORD} pg_dump`).includes(FIXTURE_PASSWORD))
})

test('errorText redacts and bounds whatever it is handed', () => {
  const long = new Error(`x`.repeat(5_000))
  assert.equal(errorText(long).length, 2_000)
  assert.ok(!errorText(new Error(`postgres://u:${FIXTURE_PASSWORD}@h/db`)).includes(FIXTURE_PASSWORD))
  assert.equal(errorText('a plain string'), 'a plain string')
})
