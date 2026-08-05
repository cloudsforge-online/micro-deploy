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

test('redaction strips the cluster password out of anything a pg tool echoed', () => {
  const leaked = 'connection to postgres://cloudsforge:hunter2@postgres:5432/custody failed'
  assert.ok(!redact(leaked).includes('hunter2'))
  assert.match(redact(leaked), /postgres:\/\/cloudsforge:\*\*\*@postgres:5432\/custody/)

  assert.ok(!redact('PGPASSWORD=hunter2 pg_dump').includes('hunter2'))
})

test('errorText redacts and bounds whatever it is handed', () => {
  const long = new Error(`x`.repeat(5_000))
  assert.equal(errorText(long).length, 2_000)
  assert.ok(!errorText(new Error('postgres://u:p4ssw0rd@h/db')).includes('p4ssw0rd'))
  assert.equal(errorText('a plain string'), 'a plain string')
})
