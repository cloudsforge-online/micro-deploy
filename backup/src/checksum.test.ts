import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'
import test from 'node:test'
import { digestOfBuffer, digestOfFile, digestsMatch, streamToFileWithDigest } from './checksum.ts'

test('the streamed digest equals the digest of the file that was written', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-backup-'))
  try {
    // Several chunks, so the transform is genuinely incremental rather than seeing one buffer.
    const chunks = [randomBytes(64 * 1024), randomBytes(11), randomBytes(1024 * 1024)]
    const destination = join(dir, 'artefact.bin')

    const digest = await streamToFileWithDigest(Readable.from(chunks), destination)
    const written = await readFile(destination)

    assert.equal(digest.sha256, createHash('sha256').update(written).digest('hex'))
    assert.equal(digest.bytes, BigInt(written.length))
    // The size is a bigint: `Number` silently rounds above 2^53 and dumps only grow.
    assert.equal(typeof digest.bytes, 'bigint')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('the digest is taken in ONE pass — a second read of the file is not what is hashed', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-backup-'))
  try {
    const destination = join(dir, 'artefact.bin')
    const digest = await streamToFileWithDigest(Readable.from([Buffer.from('the bytes as written')]), destination)

    // Corrupting the file AFTER the write cannot change the digest that was returned: it committed
    // to the bytes this process produced, which is the property a second-pass hash would not have.
    await writeFile(destination, 'something else entirely')
    assert.equal(digest.sha256, createHash('sha256').update('the bytes as written').digest('hex'))
    assert.notEqual((await digestOfFile(destination)).sha256, digest.sha256)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a failing source rejects rather than leaving a plausible short file with a digest', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-backup-'))
  try {
    const source = new Readable({
      read() {
        this.push(Buffer.from('half a dump'))
        this.destroy(new Error('pg_dump died'))
      },
    })
    await assert.rejects(() => streamToFileWithDigest(source, join(dir, 'artefact.bin')), /pg_dump died/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('an empty stream digests to the empty sha256 rather than throwing', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-backup-'))
  try {
    const digest = await streamToFileWithDigest(Readable.from([]), join(dir, 'empty.bin'))
    assert.equal(digest.sha256, createHash('sha256').update('').digest('hex'))
    assert.equal(digest.bytes, 0n)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('digestOfBuffer matches node:crypto for the manifest itself', () => {
  const buffer = Buffer.from('{"manifestVersion":1}\n')
  assert.equal(digestOfBuffer(buffer).sha256, createHash('sha256').update(buffer).digest('hex'))
  assert.equal(digestOfBuffer(buffer).bytes, BigInt(buffer.length))
})

test('digestsMatch refuses anything that is not a pair of real digests', () => {
  assert.equal(digestsMatch('a'.repeat(64), 'a'.repeat(64)), true)
  assert.equal(digestsMatch('a'.repeat(64), 'b'.repeat(64)), false)
  // The shape check is the point: `undefined === undefined` compares equal, and a refactor that let
  // one side go missing would otherwise verify every artefact successfully.
  assert.equal(digestsMatch(undefined as unknown as string, undefined as unknown as string), false)
  assert.equal(digestsMatch('', ''), false)
  assert.equal(digestsMatch('A'.repeat(64), 'A'.repeat(64)), false)
})
