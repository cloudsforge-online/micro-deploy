import assert from 'node:assert/strict'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import {
  assertAgeRecipient,
  backupMinerCoinbaseKey,
  buildMinerEnvelope,
  MINER_ENVELOPE_FORMAT,
  minerKeySources,
  readPublicAddress,
  SecretsError,
  assertMinerAddress,
} from './secrets.ts'

// The real mainnet coinbase address, which is PUBLIC and on chain. The `privateKey` here is a
// throwaway literal that has never been an address's key and controls nothing.
const KEY_FILE = JSON.stringify({
  address: '0x980d52a868d41a34a186ce890874c8e547975b45',
  privateKey: `0x${'0'.repeat(64)}`,
  warning: 'plaintext',
})

// The shape the miners actually read since the seal: scrypt + AES-256-GCM, `address` still in the
// clear beside the ciphertext. Every field below is a placeholder — there is no key here to lose.
const KEYSTORE_FILE = JSON.stringify({
  version: 1,
  address: '0x980d52a868d41a34a186ce890874c8e547975b45',
  kdf: 'scrypt',
  kdfparams: { n: 262144, r: 8, p: 1, dklen: 32, salt: '00'.repeat(16) },
  cipher: 'aes-256-gcm',
  cipherparams: { iv: '00'.repeat(12) },
  ciphertext: 'PLACEHOLDER',
  tag: '00'.repeat(16),
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
      sources: minerKeySources(dir, 'mainnet'),
      destination: join(dir, 'out.age'),
      relPath: 'secrets/out.age',
      environment: 'mainnet',
      recipient: null,
      expectedAddress: null,
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

test('an absent key file is a warning, not a failed run — but it no longer reads as benign', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-secrets-'))
  try {
    const result = await backupMinerCoinbaseKey({
      sources: minerKeySources(join(dir, 'missing'), 'testnet'),
      destination: join(dir, 'out.age'),
      relPath: 'secrets/out.age',
      environment: 'testnet',
      recipient: `age1${'q'.repeat(58)}`,
      expectedAddress: null,
      timeoutMs: 5_000,
    })
    assert.equal(result.artefact, null)
    // BOTH paths are named. The old wording said "no miner coinbase key at <one path>", which on an
    // estate that had sealed its key was a true statement about the wrong file (micro-org#206).
    assert.match(result.warnings[0] ?? '', /NO MINER COINBASE KEY IN THIS SET/)
    assert.match(result.warnings[0] ?? '', /coinbase-keystore\.json/)
    assert.match(result.warnings[0] ?? '', /coinbase-key\.json/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

// ── THE REGRESSION THAT COST THE ESTATE EVERY `secrets` ARTEFACT IT NEVER HAD ──────────────────
//
// `minerKeySources` is a pure path derivation, so this is the cheapest possible test and it is the
// one that would have caught the bug: the caller asked for `coinbase-key.json` by name for weeks
// after the miners moved to `coinbase-keystore.json`, and nothing anywhere asserted which file the
// backup was supposed to be reading.
test('the keystore is the preferred source, and the plaintext remains a fallback', () => {
  const sources = minerKeySources('/miner-keys', 'mainnet')
  assert.equal(sources.keystorePath, '/miner-keys/mainnet/coinbase-keystore.json')
  assert.equal(sources.plaintextPath, '/miner-keys/mainnet/coinbase-key.json')
  // Both hosts' layouts, because one runner image runs on both.
  assert.ok(sources.passphrasePaths.includes('/miner-keys/secrets/coinbase-passphrase'))
  assert.ok(sources.passphrasePaths.includes('/miner-keys/secrets/ember-coinbase-mainnet.pass'))
})

test('the environment is baked into every path, so a mainnet runner cannot reach the testnet key', () => {
  const sources = minerKeySources('/miner-keys', 'testnet')
  assert.ok(sources.keystorePath.includes('/testnet/'))
  assert.ok(sources.plaintextPath.includes('/testnet/'))
  assert.ok(!sources.keystorePath.includes('mainnet'))
  assert.ok(!sources.passphrasePaths.some((path) => path.includes('mainnet')))
})

// Preference proven at the I/O level, and without `age` — which is not installed in the test image
// and must not become a prerequisite for testing which FILE gets read.
//
// The trick is to make the two candidates distinguishable by their effect rather than their bytes:
// the keystore here has no `address`, so if it is the one read the call refuses with `SecretsError`
// long before encryption. A run that reaches `age` instead would prove the plaintext won.
test('with both files present the keystore is read, not the plaintext beside it', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-secrets-'))
  try {
    const sources = minerKeySources(dir, 'mainnet')
    await mkdir(join(dir, 'mainnet'), { recursive: true })
    await writeFile(sources.keystorePath, '{"kdf":"scrypt","ciphertext":"PLACEHOLDER"}', { mode: 0o600 })
    await writeFile(sources.plaintextPath, KEY_FILE, { mode: 0o600 })

    await assert.rejects(
      () =>
        backupMinerCoinbaseKey({
          sources,
          destination: join(dir, 'out.age'),
          relPath: 'secrets/out.age',
          environment: 'mainnet',
          recipient: `age1${'q'.repeat(58)}`,
          expectedAddress: null,
          timeoutMs: 5_000,
        }),
      (err: unknown) => err instanceof SecretsError && /no valid `address` field/.test((err as Error).message),
    )
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a keystore envelope carries the passphrase, because a keystore without one recovers nothing', () => {
  const envelope = buildMinerEnvelope({
    environment: 'mainnet',
    address: '0x980d52a868d41a34a186ce890874c8e547975b45',
    key: Buffer.from(KEYSTORE_FILE),
    fromKeystore: true,
    passphrase: { path: '/miner-keys/secrets/coinbase-passphrase', contents: Buffer.from('THROWAWAY') },
  })
  const parsed = JSON.parse(envelope.toString('utf8'))

  assert.equal(parsed.format, MINER_ENVELOPE_FORMAT)
  assert.equal(parsed.source, 'keystore')
  assert.equal(parsed.address, '0x980d52a868d41a34a186ce890874c8e547975b45')
  assert.equal(parsed.keystore, KEYSTORE_FILE)
  assert.equal(parsed.passphrase, 'THROWAWAY')
  assert.equal(parsed.passphraseFrom, '/miner-keys/secrets/coinbase-passphrase')
  // `key` is the plaintext-source field name and must not appear beside a keystore, or a restorer
  // parsing the envelope has two candidate fields and no rule for choosing.
  assert.equal(parsed.key, undefined)
})

test('a plaintext-sourced envelope carries the key and no passphrase field', () => {
  const envelope = buildMinerEnvelope({
    environment: 'testnet',
    address: '0x91a11854b364178ed96054d8a6e9be1dbd751d33',
    key: Buffer.from(KEY_FILE),
    fromKeystore: false,
    passphrase: null,
  })
  const parsed = JSON.parse(envelope.toString('utf8'))

  assert.equal(parsed.source, 'plaintext')
  assert.equal(parsed.key, KEY_FILE)
  assert.equal(parsed.keystore, undefined)
  assert.equal(parsed.passphrase, undefined)
})

test('the keystore address is readable without touching the ciphertext, so public_ref is satisfiable', () => {
  // The whole reason the keystore can be backed up by this module unchanged: it carries the same
  // plaintext `address` field the schema's public_ref constraint is checked against.
  assert.equal(readPublicAddress(Buffer.from(KEYSTORE_FILE)), '0x980d52a868d41a34a186ce890874c8e547975b45')
})

/*
 * micro-org#532. The estate mines from two hosts, and for at least seventeen sets the runner
 * encrypted the WRONG one under the right one's name — same path, same valid JSON, different key.
 * Every check that existed passed, because every check was about the path.
 */
const OTHER_HOST_KEY_FILE = JSON.stringify({
  address: '0x2098b519aaf94e704534c6de35c5c516723dcca8', // the k8s VM's coinbase
  privateKey: `0x${'0'.repeat(64)}`,
  warning: 'plaintext',
})
const CHAIN_HOST_ADDRESS = '0x980d52a868d41a34a186ce890874c8e547975b45'

test('a key that is not the one this run is for is REFUSED, not written under its name', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-secrets-'))
  try {
    const sources = minerKeySources(dir, 'mainnet')
    await mkdir(join(dir, 'mainnet'), { recursive: true })
    await writeFile(sources.plaintextPath, OTHER_HOST_KEY_FILE, { mode: 0o600 })

    const result = await backupMinerCoinbaseKey({
      sources,
      destination: join(dir, 'out.age'),
      relPath: 'secrets/out.age',
      environment: 'mainnet',
      recipient: `age1${'q'.repeat(58)}`,
      expectedAddress: CHAIN_HOST_ADDRESS,
      timeoutMs: 5_000,
    })

    // No artefact is the entire fix. `run.ts` sets `backup_secrets_included` from exactly this, so
    // refusing is what makes `MinerCoinbaseKeyUnbacked` fire — and its text is then true. Writing it
    // with a warning attached would leave the gauge at 1 and reproduce the silence.
    assert.equal(result.artefact, null)
    assert.equal(result.warnings.length, 1)
    // Both addresses named. They are public, and a warning that says only "mismatch" sends whoever
    // reads it back to the database to find out which key it actually got.
    assert.match(result.warnings[0] ?? '', /0x2098b519aaf94e704534c6de35c5c516723dcca8/)
    assert.match(result.warnings[0] ?? '', /0x980d52a868d41a34a186ce890874c8e547975b45/)

    // And nothing reached the destination: a refusal that leaves a half-written file is a file a
    // later manifest can still describe.
    await assert.rejects(() => rm(join(dir, 'out.age'), { force: false }), /ENOENT/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('the expected address is compared case-insensitively, so a checksummed paste still matches', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'cf-secrets-'))
  try {
    const sources = minerKeySources(dir, 'mainnet')
    await mkdir(join(dir, 'mainnet'), { recursive: true })
    await writeFile(sources.plaintextPath, KEY_FILE, { mode: 0o600 })

    // EIP-55 mixed case is what an operator copies out of a block explorer.
    const checksummed = `0x${CHAIN_HOST_ADDRESS.slice(2).toUpperCase()}`
    let refused = false
    try {
      const result = await backupMinerCoinbaseKey({
        sources,
        destination: join(dir, 'out.age'),
        relPath: 'secrets/out.age',
        environment: 'mainnet',
        recipient: `age1${'q'.repeat(58)}`,
        expectedAddress: checksummed,
        timeoutMs: 5_000,
      })
      refused = result.artefact === null && /BACKUP_MINER_EXPECTED_ADDRESS/.test(result.warnings[0] ?? '')
    } catch {
      // `age` is not necessarily on this machine, and reaching it is already past the guard. What
      // this test denies is a REFUSAL, not a successful encryption.
    }
    assert.equal(refused, false, 'a checksummed form of the same address must not trip the guard')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('a configured expected address is shape-checked at boot, and normalised', () => {
  // Lower-cased on the way in so the comparison never has to think about it.
  assert.equal(assertMinerAddress(`0x${CHAIN_HOST_ADDRESS.slice(2).toUpperCase()}`), CHAIN_HOST_ADDRESS)
  assert.equal(assertMinerAddress(CHAIN_HOST_ADDRESS), CHAIN_HOST_ADDRESS)

  // The failure this catches is a truncated paste, which must stop the process at boot rather than
  // silently widen the guard to "matches nothing" on the night it is needed.
  assert.throws(() => assertMinerAddress('0x980d52a8'), SecretsError)
  assert.throws(() => assertMinerAddress('980d52a868d41a34a186ce890874c8e547975b45'), SecretsError)
  assert.throws(() => assertMinerAddress(''), SecretsError)
})
