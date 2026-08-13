import { test } from 'node:test'
import assert from 'node:assert/strict'
import { decide, observePublicAddress, usableAsPublicEndpoint } from './observe.ts'

/**
 * The refusals are the product. A test suite that only proved the happy path would be proving the
 * easy half of a service whose entire purpose is to not publish a wrong address.
 */

test('CGNAT is refused, and the reason says why a port-forward cannot save it', () => {
  const r = usableAsPublicEndpoint('100.72.14.9')
  assert.equal(r.ok, false)
  if (r.ok) return
  // The operator reading this line is about to go and check their router. Tell them not to.
  assert.match(r.why, /carrier/i)
})

test('every private and reserved range is refused', () => {
  for (const addr of ['10.0.0.4', '172.16.5.1', '192.168.1.129', '127.0.0.1', '169.254.1.1', '0.0.0.0', '239.1.1.1']) {
    assert.equal(usableAsPublicEndpoint(addr).ok, false, `${addr} was accepted as public`)
  }
})

test('an ordinary public address is accepted', () => {
  assert.equal(usableAsPublicEndpoint('81.4.108.22').ok, true)
})

test('malformed input is refused rather than parsed loosely', () => {
  for (const bad of ['', 'not-an-ip', '1.2.3', '1.2.3.4.5', '999.1.1.1', '1.2.3.4\n5.6.7.8']) {
    assert.equal(usableAsPublicEndpoint(bad).ok, false, `${JSON.stringify(bad)} was accepted`)
  }
})

test('two resolvers agreeing is the only thing that yields an address', async () => {
  const observed = await observePublicAddress(
    ['a', 'b'],
    async (u) => (u === 'a' ? '81.4.108.22' : '81.4.108.22'),
  )
  assert.deepEqual(observed, { kind: 'agreed', address: '81.4.108.22' })
})

test('resolvers that disagree publish NOTHING — it is a signal, not a retry', async () => {
  const observed = await observePublicAddress(['a', 'b'], async (u) =>
    u === 'a' ? '81.4.108.22' : '203.0.113.7',
  )
  assert.equal(observed.kind, 'disagreed')
  // And the decision that follows must leave the live value alone.
  assert.equal(decide(observed, '81.4.108.22').kind, 'refuse')
})

test('one resolver answering is not a quorum, however confident it sounds', async () => {
  const observed = await observePublicAddress(['a', 'b'], async (u) => {
    if (u === 'a') return '81.4.108.22'
    throw new Error('timeout')
  })
  assert.equal(observed.kind, 'unreachable')
})

test('an agreed but PRIVATE address is refused, not published', async () => {
  const observed = await observePublicAddress(['a', 'b'], async () => '192.168.1.129')
  assert.equal(observed.kind, 'unusable')
  const d = decide(observed, null)
  assert.equal(d.kind, 'refuse')
  if (d.kind !== 'refuse') return
  assert.match(d.reason, /private/i)
})

test('an unchanged address is a no-op, so the pool is not recreated for nothing', () => {
  const d = decide({ kind: 'agreed', address: '81.4.108.22' }, '81.4.108.22')
  assert.deepEqual(d, { kind: 'keep' })
})

test('a changed address publishes, and carries the previous one for the log', () => {
  const d = decide({ kind: 'agreed', address: '81.4.108.23' }, '81.4.108.22')
  assert.deepEqual(d, { kind: 'publish', address: '81.4.108.23', previous: '81.4.108.22' })
})

test('the first observation publishes, with no previous value', () => {
  const d = decide({ kind: 'agreed', address: '81.4.108.22' }, null)
  assert.deepEqual(d, { kind: 'publish', address: '81.4.108.22', previous: null })
})

test('a refusal NEVER clears an address that is already published', () => {
  // The regression this guards: treating "I cannot tell" as "there is no endpoint" would take a
  // working pool offline every time a resolver had a bad minute.
  for (const observed of [
    { kind: 'disagreed', saw: ['1.1.1.1', '2.2.2.2'] },
    { kind: 'unreachable', errors: ['timeout'] },
    { kind: 'unusable', address: '10.0.0.1', why: 'private' },
  ] as const) {
    assert.equal(decide(observed, '81.4.108.22').kind, 'refuse', `${observed.kind} did not refuse`)
  }
})
