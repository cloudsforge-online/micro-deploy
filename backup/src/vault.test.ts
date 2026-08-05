/**
 * The custody vault cross-check.
 *
 * This is the guard against the one failure that looks exactly like success: a tarball of zero
 * blobs, a valid checksum, a plausible size and a green backup row. Every other signal is healthy,
 * and nothing is red until somebody tries to recover a customer's coins and finds ciphertext for no
 * addresses at all. `docs/custody-backup-restore.md` §2 ends its routine backup with this same
 * comparison for the same reason.
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { vaultCompleteness } from './run.ts'

test('an EMPTY vault against a populated custody is fatal', () => {
  // The measured shape of the failure: mainnet custody held 257 keys + 245 seeds when this was
  // written, and a mount that resolved to a fresh docker volume would tar zero of them.
  const verdict = vaultCompleteness(0n, 502n)
  assert.equal(verdict.kind, 'incomplete')
  assert.match(verdict.kind === 'incomplete' ? verdict.detail : '', /holds 0 blobs but custody has 502 rows/)
  // The message must name the two causes an operator can actually act on, or it is a dead end at
  // three in the morning.
  assert.match(verdict.kind === 'incomplete' ? verdict.detail : '', /custody-keys volume/)
  assert.match(verdict.kind === 'incomplete' ? verdict.detail : '', /snap-Docker trap/)
})

test('ONE missing blob is as fatal as all of them', () => {
  // Not a tolerance. There is no second copy of a custody blob anywhere, so a single missing one
  // is one address that can never be spent again.
  assert.equal(vaultCompleteness(501n, 502n).kind, 'incomplete')
})

test('an exact match passes', () => {
  assert.equal(vaultCompleteness(502n, 502n).kind, 'ok')
  // A genuinely empty estate that has never minted an address is a legitimate state.
  assert.equal(vaultCompleteness(0n, 0n).kind, 'ok')
})

test('MORE blobs than rows warns rather than refusing', () => {
  // An orphaned blob is a custody concern. Refusing tonight's backup over one would trade a real,
  // present risk (no backup) for a theoretical one.
  assert.equal(vaultCompleteness(503n, 502n).kind, 'orphans')
})

test('the counts are bigint, so a large estate cannot silently lose precision', () => {
  // Blob counts will never approach 2^53 — but the money columns in this estate are bigint by rule,
  // and a comparison that quietly went through Number would be the kind of thing nobody re-reads.
  assert.equal(vaultCompleteness(9_007_199_254_740_993n, 9_007_199_254_740_992n).kind, 'orphans')
  assert.equal(vaultCompleteness(9_007_199_254_740_992n, 9_007_199_254_740_993n).kind, 'incomplete')
})
