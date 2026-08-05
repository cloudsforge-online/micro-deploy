import assert from 'node:assert/strict'
import test from 'node:test'
import { assertNoKeyring, FORBIDDEN_ARCHIVE_ENTRY, KeyringPresentError, keyringVariablesIn } from './keyring.ts'

test('a clean environment starts', () => {
  assert.doesNotThrow(() => assertNoKeyring({ BACKUP_ENVIRONMENT: 'mainnet', PATH: '/usr/bin' }))
})

test('ANY CUSTODY_MASTER_SECRET_V<n> refuses the boot — this process writes the vault', () => {
  for (const name of ['CUSTODY_MASTER_SECRET_V1', 'CUSTODY_MASTER_SECRET_V2', 'CUSTODY_MASTER_SECRET_V47']) {
    assert.throws(() => assertNoKeyring({ [name]: 'anything at all' }), KeyringPresentError, `allowed ${name}`)
  }
})

test('the version is matched by PATTERN, so a rotation to a new version cannot slip past', () => {
  // §1.3: custody itself assembles the keyring by scanning for the pattern rather than by name.
  // A hard-coded V1..V3 list here would stop catching it the day somebody adds V4.
  assert.deepEqual(keyringVariablesIn({ CUSTODY_MASTER_SECRET_V9001: 'x' }), ['CUSTODY_MASTER_SECRET_V9001'])
})

test('the miner coinbase key variables are caught too — same position, same rule', () => {
  assert.throws(() => assertNoKeyring({ MINER_COINBASE_KEY: 'x' }), KeyringPresentError)
})

test('the refusal names VARIABLES and never a value', () => {
  const secret = 'this-value-must-never-appear-anywhere'
  try {
    assertNoKeyring({ CUSTODY_MASTER_SECRET_V2: secret })
    assert.fail('should have refused')
  } catch (err) {
    assert.ok(err instanceof KeyringPresentError)
    assert.deepEqual(err.variables, ['CUSTODY_MASTER_SECRET_V2'])
    // The single most important assertion in this file. §7: a printed secret is an exposed secret,
    // and on 2026-08-05 three of four keyrings were rotated because values reached a transcript.
    assert.ok(!err.message.includes(secret))
    assert.ok(!JSON.stringify(err).includes(secret))
  }
})

test('CUSTODY_KEY_VERSION alone is not key material and does not refuse the boot', () => {
  // §1.3: it selects the WRITE version. It is a number, not a secret.
  assert.doesNotThrow(() => assertNoKeyring({ CUSTODY_KEY_VERSION: '3' }))
})

test('the archiver refuses credential-shaped filenames rather than skipping them', () => {
  for (const name of ['.env', '.env.local', 'custody.mainnet.env', 'secrets', 'custody.env.gpg', 'id_ed25519']) {
    assert.ok(FORBIDDEN_ARCHIVE_ENTRY.test(name), `did not catch ${name}`)
  }
  for (const name of ['key.enc', '0x009a18993cEF21d5230370F51195D765786D03db', 'SET.json', 'sprite.png']) {
    assert.ok(!FORBIDDEN_ARCHIVE_ENTRY.test(name), `wrongly caught ${name}`)
  }
})
