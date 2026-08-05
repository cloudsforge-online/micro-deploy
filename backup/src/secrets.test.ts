import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { assertAgeRecipient, backupMinerCoinbaseKey, readPublicAddress, SecretsError } from './secrets.ts'

// The real mainnet coinbase address, which is PUBLIC and on chain. The `privateKey` here is a
// throwaway literal that has never been an address's key and controls nothing.
const KEY_FILE = JSON.stringify({
  address: '0x980d52a868d41a34a186ce890874c8e547975b45',
  privateKey: `0x${'0'.repeat(64)}`,
  warning: 'plaintext',
})

test('only the public address is read out of the key file', () => {
  assert.equal(readPublicAddress(Buffer.from(KEY_FILE)), '0x980d52a868d41a34a186ce890874c8e547975b45')
})

test('a key file with no valid address is refused — an unprovable secrets artefact is not written', () => {
  assert.throws(() => readPublicAddress(Buffer.from('{"privateKey":"0xdead"}')), SecretsError)
  assert.throws(() => readPublicAddress(Buffer.from('{"address":"not-an-address"}')), SecretsError)
})

test('a malformed key file produces an error that does not echo its contents', () => {
  const contents = 'PRIVATE-KEY-MATERIAL-THAT-MUST-NOT-BE-ECHOED'
  try {
    readPublicAddress(Buffer.from(contents))
    assert.fail('should have refused')
  } catch (err) {
    assert.ok(err instanceof SecretsError)
    assert.ok(!err.message.includes(contents))
  }
})

test('the age recipient must be a PUBLIC key, and a pasted identity is refused', () => {
  const recipient = `age1${'q'.repeat(58)}`
  assert.equal(assertAgeRecipient(recipient), recipient)

  assert.throws(() => assertAgeRecipient('AGE-SECRET-KEY-1QQQQ'), SecretsError)
  assert.throws(() => assertAgeRecipient('age1short'), SecretsError)
  assert.throws(() => assertAgeRecipient(''), SecretsError)
})

test('WITH NO RECIPIENT, nothing is written and the manifest says why — there is no clear fallback', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-secrets-'))
  try {
    const result = await backupMinerCoinbaseKey({
      sourcePath: join(dir, 'coinbase-key.json'),
      destination: join(dir, 'out.age'),
      relPath: 'secrets/out.age',
      environment: 'mainnet',
      recipient: null,
      timeoutMs: 5_000,
    })

    assert.equal(result.artefact, null)
    assert.equal(result.warnings.length, 1)
    assert.match(result.warnings[0] ?? '', /BACKUP_AGE_RECIPIENT is unset/)
    // And critically: the source is not even read, so there is no path on which plaintext could
    // have been written to the destination.
    await assert.rejects(() => rm(join(dir, 'out.age'), { force: false }), /ENOENT/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('an absent key file is a warning, not a failed run — not every estate mines', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-secrets-'))
  try {
    const result = await backupMinerCoinbaseKey({
      sourcePath: join(dir, 'missing', 'coinbase-key.json'),
      destination: join(dir, 'out.age'),
      relPath: 'secrets/out.age',
      environment: 'testnet',
      recipient: `age1${'q'.repeat(58)}`,
      timeoutMs: 5_000,
    })
    assert.equal(result.artefact, null)
    assert.match(result.warnings[0] ?? '', /no miner coinbase key/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
