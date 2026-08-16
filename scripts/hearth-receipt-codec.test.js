#!/usr/bin/env node
'use strict';
/* Prove `hearth-receipt-deploy.js`'s hand-rolled ABI codec against a real one.
 *
 *   cd deploy && node scripts/hearth-receipt-codec.test.js
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
 *
 * The deploy script encodes its own calldata. That is a deliberate choice — it
 * signs transactions on the machine that holds the mining keys, and pulling a
 * dependency in to format forty bytes is a supply chain for the sake of
 * convenience. The cost of the choice is that the encoder can be wrong, and a
 * wrong encoder in THIS script is unusually expensive:
 *
 *   - `setReserveAddresses(string[])` publishes Litecoin addresses on chain
 *     permanently. Mis-encode the tail offsets and the token's own published
 *     reserve list is garbage, and the fix is another multisig round.
 *   - `submitTransaction(address,uint256,bytes)` wraps every issuer action. Its
 *     `bytes` argument is not a string, and the first version of this codec had
 *     no branch for it — `encodeString` on a Buffer stringifies it, so the
 *     multisig would have carried the ASCII of "<Buffer 68 02 …>" as calldata.
 *     That proposal submits, confirms, executes, and reverts on a selector that
 *     does not exist: three transactions and two signatures to learn nothing.
 *     This test caught it before it reached a chain.
 *
 * The reference is `hearth/node/test/evmsim.js`'s coder — the one the contract's
 * own EVM suite encodes against, so agreement here means the deploy script and
 * the passing test suite are speaking the same language.
 *
 * ── IT IMPORTS THE SHIPPED FILE ──────────────────────────────────────────────
 *
 * The codec is `require`d out of `hearth-receipt-deploy.js`, not copied here. A
 * copy would pass forever while the original drifted, which is the specific way
 * a codec test becomes decorative. The script guards its `main()` behind
 * `require.main === module`, so importing it encodes nothing and sends nothing.
 */

const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const MICRO = path.resolve(HERE, '../..');
const HEARTH = process.env.HEARTH_REPO || path.join(MICRO, 'hearth');
const SCRIPT = path.join(HERE, 'hearth-receipt-deploy.js');

if (!fs.existsSync(path.join(HEARTH, 'node/test/evmsim.js'))) {
  console.log(`  ..   no hearth checkout at ${HEARTH} — this test needs both sides of the seam`);
  process.exit(0);
}

const { abi } = require(path.join(HEARTH, 'node/test/evmsim.js'));

// The subject under test, imported rather than reimplemented.
const { callData, encodeArgs } = require(SCRIPT);

// ── the harness ──────────────────────────────────────────────────────────────
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
let failures = 0;
const bytes = (b) => ('0x' + Buffer.from(b).toString('hex')).toLowerCase();

function same(label, mine, reference) {
  if (bytes(mine) === bytes(reference)) { console.log(`  ${green('ok')}   ${label}`); return; }
  console.log(`  ${red('FAIL')} ${label}`);
  console.log(`       script    ${bytes(mine)}`);
  console.log(`       reference ${bytes(reference)}`);
  failures++;
}

const ref = (sig, values) => abi.encodeCall(abi.resolveFunction(null, sig), values);

// The real addresses this deployment publishes. Bech32, 43 characters — not a
// multiple of 32, which is exactly the length that finds a padding bug.
const ADDRESSES = [
  'ltc1qswwly0reyr85mr9xjx4ujtep5q7nndmulpmmnq',
  'ltc1qc4uhej2g2tc2ytqc5qczxmfyun87gctafnjghp',
  'ltc1qtkkwej6dwp0m58k99ckac76qp4agyu3pr0pqvp',
];
const BLOCK = '0x1a4c066dc09e4b6efab0ba22b0089bb32bf06520ed525ff6392e89594e242617';
const MULTISIG = '0x51faced76d70981e863be2987ccc811b0712e4f8';

console.log('\n── the calls that publish a reserve ─────────────────────────────────────');
same('setReserveAddresses(string[]) — the three real addresses',
  callData('setReserveAddresses(string[])', [ADDRESSES]), ref('setReserveAddresses(string[])', [ADDRESSES]));
same('setReserveAddresses(string[]) — empty, which clears the list',
  callData('setReserveAddresses(string[])', [[]]), ref('setReserveAddresses(string[])', [[]]));
same('setReserveAddresses(string[]) — one address',
  callData('setReserveAddresses(string[])', [[ADDRESSES[0]]]), ref('setReserveAddresses(string[])', [[ADDRESSES[0]]]));
same('attest(uint256,uint64,bytes32) — the reserve as measured, zero',
  callData('attest(uint256,uint64,bytes32)', [0n, 3161011n, BLOCK]), ref('attest(uint256,uint64,bytes32)', [0, 3161011, BLOCK]));
same('attest(uint256,uint64,bytes32) — a reserve past 2^53, where a Number would lose it',
  callData('attest(uint256,uint64,bytes32)', [9007199254740993n, 3161011n, BLOCK]),
  ref('attest(uint256,uint64,bytes32)', ['9007199254740993', 3161011, BLOCK]));

console.log('\n── the calls that move the token ────────────────────────────────────────');
same('issue(address,uint256,bytes32)',
  callData('issue(address,uint256,bytes32)', [MULTISIG, 5n, BLOCK]), ref('issue(address,uint256,bytes32)', [MULTISIG, 5, BLOCK]));
same('redeem(uint256,string) — a payout address, tail-encoded',
  callData('redeem(uint256,string)', [12345n, ADDRESSES[0]]), ref('redeem(uint256,string)', [12345, ADDRESSES[0]]));
same('settleRedemption(uint256,bytes32)',
  callData('settleRedemption(uint256,bytes32)', [0n, BLOCK]), ref('settleRedemption(uint256,bytes32)', [0, BLOCK]));

console.log('\n── the multisig wrapper, whose `bytes` argument is not a string ─────────');
const attest = callData('attest(uint256,uint64,bytes32)', [0n, 3161011n, BLOCK]);
same('submitTransaction wrapping attest (a word-aligned payload)',
  callData('submitTransaction(address,uint256,bytes)', [MULTISIG, 0n, attest]),
  ref('submitTransaction(address,uint256,bytes)', [MULTISIG, 0, bytes(attest)]));
const publish = callData('setReserveAddresses(string[])', [ADDRESSES]);
same('submitTransaction wrapping setReserveAddresses (452 bytes, not word-aligned)',
  callData('submitTransaction(address,uint256,bytes)', [MULTISIG, 0n, publish]),
  ref('submitTransaction(address,uint256,bytes)', [MULTISIG, 0, bytes(publish)]));
same('confirmTransaction(uint256)', callData('confirmTransaction(uint256)', [7n]), ref('confirmTransaction(uint256)', [7]));
same('executeTransaction(uint256)', callData('executeTransaction(uint256)', [7n]), ref('executeTransaction(uint256)', [7]));

console.log('\n── the constructor: seven arguments, three of them dynamic ──────────────');
const CTOR = ['string', 'string', 'uint8', 'string', 'string', 'address', 'uint64'];
const ARGS = [
  'Forge Receipt: Litecoin',
  'fLTC',
  8,
  'LTC held at the addresses published by reserveAddresses(), on Litecoin mainnet',
  'a statement long enough to cross a 32-byte boundary several times over, which is exactly where '
  + 'a hand-rolled head/tail encoder goes wrong and where a short fixture would not notice',
  MULTISIG,
  93600n,
];
same('the fLTC constructor, as deployed',
  encodeArgs(CTOR, ARGS), abi.encodeParameters(CTOR, ARGS.map((v) => (typeof v === 'bigint' ? v.toString() : v))));
same('an empty string in a dynamic slot',
  encodeArgs(['string', 'string'], ['', 'x']), abi.encodeParameters(['string', 'string'], ['', 'x']));
same('a string of exactly 32 bytes, where padding should add nothing',
  encodeArgs(['string'], ['x'.repeat(32)]), abi.encodeParameters(['string'], ['x'.repeat(32)]));
same('a string of 33 bytes, where it should add 31',
  encodeArgs(['string'], ['x'.repeat(33)]), abi.encodeParameters(['string'], ['x'.repeat(33)]));

if (failures === 0) {
  console.log(`\n  ${green('PASS')} the shipped codec agrees with the reference on every shape it sends\n`);
  process.exit(0);
}
console.log(`\n  ${red('FAIL')} ${failures} encoding(s) disagree — do not deploy\n`);
process.exit(1);
