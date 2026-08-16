#!/usr/bin/env node
'use strict';
/* Deploy `ForgeReceipt` onto a Hearth chain, publish its reserve, and prove the refusal.
 *
 *   cd deploy
 *   ./scripts/hearth-receipt-run.sh --status     # read the chain, write nothing
 *   ./scripts/hearth-receipt-run.sh --drill      # the redemption rehearsal, end to end
 *   ./scripts/hearth-receipt-run.sh              # deploy fLTC, publish, attest, prove
 *
 * ── WHAT PHASE G ACTUALLY ASKS FOR ───────────────────────────────────────────
 *
 * `docs/ecosystem/39-forge-exchange.md` §6 sets the gate: "a wrapped coin, issued
 * against custody, satisfying 35 in full", passing when "a stranger can compare
 * issued supply to reserves on-chain, and a redemption completes". §4 sets the
 * constraints, and they are the hard part:
 *
 *   - The reserve must be checkable on the chain by a stranger, WITHOUT ASKING US.
 *   - A wrapped asset that cannot satisfy 35 MUST NOT BE ISSUED.
 *   - The redemption path must exist and be EXERCISED BEFORE ISSUANCE, not after.
 *
 * ── THE MEASURED FACT THIS SCRIPT IS BUILT AROUND ────────────────────────────
 *
 * No platform-controlled Litecoin address has ever received a litoshi. That is
 * not an assumption: `hearth-receipt-run.sh` re-measures it on every run with
 * `litecoin-cli scantxoutset`, over the FULL published address list, at one
 * height, and hands the result here. At the time of writing the answer is zero
 * across three addresses at Litecoin height 3,161,011.
 *
 * So the honest deliverable is not a token with coins behind it. It is a token
 * whose REFUSAL TO MINT IS STRUCTURAL, deployed against the real custody
 * addresses and the real reading, on a chain where anyone can watch it refuse.
 * `issue()` cannot exceed a fresh, on-chain, monotonic-height attestation, so
 * over-issuing is not a policy someone forgot — it requires publishing a
 * permanent on-chain lie about a number a stranger can independently check.
 *
 * ── WHY THERE IS A DRILL, AND WHY IT IS NOT A FICTION ────────────────────────
 *
 * §4 wants the redemption path exercised BEFORE issuance. With a zero reserve
 * `fLTC` can never mint, so it can never burn, so on `fLTC` alone that clause is
 * unfalsifiable. The tempting shortcut is to attest a made-up Litecoin balance on
 * testnet "just to exercise the path" — which is precisely the on-chain lie this
 * contract exists to make expensive, told on the one artifact whose entire value
 * is that its attestations are true.
 *
 * `--drill` takes the other road. It deploys a SECOND receipt whose underlying is
 * EMBER held at a named address ON THIS SAME CHAIN. The reserve is therefore
 * real, non-zero, and checkable by a stranger with one `eth_getBalance` — a
 * better audit story than any off-chain custodian can offer — and the full
 * lifecycle runs live: attest a measured balance, issue within it, redeem, pay
 * out for real, and settle with the actual transaction hash of that payout.
 * Nothing about it is pretended. It is a custody receipt whose custodian happens
 * to be legible.
 *
 * ── MAINNET ──────────────────────────────────────────────────────────────────
 *
 * This script refuses mainnet while the reserve is zero, and says why. That is
 * not caution, it is §4: an `fLTC` on the surface where people transact is a
 * promise, and a promise backed by a measured nothing is the exact object doc 39
 * forbids. When there are coins, the reading changes and the refusal lifts by
 * itself — no code change, because the gate was never a flag.
 *
 * ── IDEMPOTENCE ──────────────────────────────────────────────────────────────
 *
 * Same shape as `hearth-dex-deploy.js`: the note records every address, each is
 * checked for CODE on re-run, and only a genuinely absent contract is deployed
 * again. The note is written after every step, not at the end — a run that dies
 * on step four must not orphan steps one through three.
 */

const fs = require('fs');
const path = require('path');

// ── configuration ────────────────────────────────────────────────────────────
const HEARTH = process.env.HEARTH_REPO || path.resolve(__dirname, '../../hearth');
const ARTIFACTS = process.env.HEARTH_ARTIFACTS || path.join(HEARTH, 'contracts/out');

const EMBER_NETWORK = process.env.CF_EMBER_NETWORK || 'testnet';
const EMBER_CHAIN_IDS = { mainnet: 7411, testnet: 7412 };
const EXPECTED_CHAIN_ID = EMBER_CHAIN_IDS[EMBER_NETWORK];
if (EXPECTED_CHAIN_ID === undefined) {
  console.error(`CF_EMBER_NETWORK is "${EMBER_NETWORK}"; known: ${Object.keys(EMBER_CHAIN_IDS).join(', ')}`);
  process.exit(2);
}

const EMBER_HOME = process.env.EMBER_HOME || path.join(process.env.HOME || '/root', `.cloudsforge/ember-${EMBER_NETWORK}`);
const MINER_DATA = process.env.EMBER_MINER_DATA || path.join(EMBER_HOME, 'miner');
// Deliberately the SAME directory the exchange deployment uses: the multisig that
// will hold `issuer` is the one deployed there, and its owner keys are sealed
// beside its note. A second directory would mean a second signer set.
const EXCHANGE_DIR = process.env.HEARTH_DEX_HOME || path.join(EMBER_HOME, 'exchange');
const RPC = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545';
const DEX_NOTE = path.join(EXCHANGE_DIR, `deployment-${EXPECTED_CHAIN_ID}.json`);
const NOTE = path.join(EXCHANGE_DIR, `receipt-${EXPECTED_CHAIN_ID}.json`);

/**
 * The reserve reading, measured by the wrapper and passed in.
 *
 * It is measured OUT THERE rather than in here on purpose. `litecoin-cli` reads
 * the node's cookie from its datadir; letting this process hold an RPC
 * credential — in a script that also signs transactions and prints diagnostics —
 * would put a live secret one stray `console.error(err)` away from a transcript.
 * The wrapper knows the credential, this file knows only the number.
 */
const RESERVE = {
  // litoshis, as a decimal string: the sum over EVERY address in ADDRESSES
  sats: process.env.CF_RECEIPT_RESERVE_SATS,
  // the underlying chain's height the scan settled at
  height: process.env.CF_RECEIPT_HEIGHT,
  // that height's block hash — 32 bytes, so it lands in `ref` unpadded and a
  // stranger can re-run the identical scan at the identical block
  ref: process.env.CF_RECEIPT_REF,
  addresses: (process.env.CF_RECEIPT_ADDRESSES || '').split(',').map((s) => s.trim()).filter(Boolean),
};

/** How stale an attestation may be before `issue()` stops working, in seconds. */
const MAX_ATTESTATION_AGE = Number(process.env.CF_RECEIPT_MAX_AGE || 26 * 60 * 60);

const TX = require(path.join(HEARTH, 'node/src/chain/transaction.js'));
const { keccak256 } = require(path.join(HEARTH, 'node/src/crypto/keccak.js'));
const secp = require(path.join(HEARTH, 'node/src/crypto/secp256k1.js'));

const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const ok = (s) => console.log(`  ${green('ok')}   ${s}`);
const bad = (s) => { console.log(`  ${red('FAIL')} ${s}`); failures++; };
const note = (s) => console.log(`  ..   ${s}`);
const head = (s) => console.log(`\n── ${s} ${'─'.repeat(Math.max(0, 72 - s.length))}`);
let failures = 0;

// ── the chain ────────────────────────────────────────────────────────────────
/** One JSON-RPC call, retried on TRANSPORT failure only. See `hearth-dex-deploy.js`. */
async function rpc(method, params = [], attempts = 20) {
  let last;
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(RPC, {
        method: 'POST',
        headers: { 'content-type': 'application/json', connection: 'close' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(15_000),
      });
      const body = await res.json();
      if (body.error) throw new Error(`${method}: ${body.error.message}`);
      return body.result;
    } catch (err) {
      if (err instanceof Error && err.message.startsWith(`${method}:`)) throw err;
      last = err;
      await new Promise((r) => setTimeout(r, 2_000));
    }
  }
  throw new Error(`${method}: no answer from ${RPC} after ${attempts} attempts — ${last && last.message}`);
}

const hexToBig = (h) => BigInt(h);
const ember = (wei) => (Number(wei) / 1e18).toFixed(6);
const hex = (b) => '0x' + Buffer.from(b).toString('hex');
const strip = (h) => String(h).replace(/^0x/, '');

// ── the smallest ABI codec that can do this job ──────────────────────────────
//
// `hearth-dex-deploy.js` needed `address`, `uint256`, `bytes32` and `address[]`
// and encoded them by hand. This contract's surface is dynamic — a constructor
// with three `string`s, `setReserveAddresses(string[])`, `redeem(uint256,string)`
// — so the head/tail split has to be real rather than assumed. Still no
// dependency: this is forty lines, in a script that signs transactions, in a
// repository that has no JavaScript dependencies of its own.

function word(v) {
  if (typeof v === 'bigint' || typeof v === 'number') return Buffer.from(BigInt(v).toString(16).padStart(64, '0'), 'hex');
  return Buffer.from(strip(v).toLowerCase().padStart(64, '0'), 'hex');
}

/** A length, the bytes, and zero padding up to the next word. */
function encodeBytes(b) {
  return Buffer.concat([word(BigInt(b.length)), b, Buffer.alloc((32 - (b.length % 32)) % 32)]);
}

const encodeString = (s) => encodeBytes(Buffer.from(String(s), 'utf8'));

/** `string[]`: a length, then one offset per element, then the elements. */
function encodeStringArray(list) {
  const parts = list.map(encodeString);
  let off = 32 * parts.length;
  const offsets = parts.map((p) => { const w = word(BigInt(off)); off += p.length; return w; });
  return Buffer.concat([word(BigInt(list.length)), ...offsets, ...parts]);
}

const isDynamic = (t) => t === 'string' || t === 'bytes' || t.endsWith('[]');

function encodeArgs(types, values) {
  const heads = [];
  const tails = [];
  let offset = types.length * 32;
  types.forEach((t, i) => {
    if (!isDynamic(t)) { heads.push(word(values[i])); return; }
    // `bytes` needs its own branch and getting that wrong is not a loud failure:
    // `encodeString` on a Buffer stringifies it, so the multisig would carry a
    // proposal whose calldata is the ASCII of "<Buffer 68 02 …>". It would
    // submit, confirm, execute, and revert on a selector that does not exist.
    const tail = t === 'string' ? encodeString(values[i])
      : t === 'bytes' ? encodeBytes(values[i])
        : encodeStringArray(values[i]);
    heads.push(word(BigInt(offset)));
    tails.push(tail);
    offset += tail.length;
  });
  return Buffer.concat([...heads, ...tails]);
}

const selector = (signature) => keccak256(Buffer.from(signature, 'utf8')).subarray(0, 4);

/** `sig` is a full signature: `attest(uint256,uint64,bytes32)`. */
function callData(sig, values = []) {
  const types = sig.slice(sig.indexOf('(') + 1, sig.lastIndexOf(')')).split(',').filter(Boolean);
  return Buffer.concat([selector(sig), encodeArgs(types, values)]);
}

/** One `eth_call`, returned as raw 32-byte hex words. */
async function callWords(to, sig, values = []) {
  const raw = strip(await rpc('eth_call', [{ to, data: hex(callData(sig, values)) }, 'latest']));
  const words = [];
  for (let i = 0; i < raw.length; i += 64) words.push(raw.slice(i, i + 64));
  return words;
}

const asAddress = (w) => '0x' + w.slice(24);
const asUint = (w) => BigInt('0x' + w);
const asBytes32 = (w) => '0x' + w;
const asBool = (w) => asUint(w) === 1n;

async function readUint(to, sig, v = []) { return asUint((await callWords(to, sig, v))[0]); }
async function readAddress(to, sig, v = []) { return asAddress((await callWords(to, sig, v))[0]); }
async function readBool(to, sig, v = []) { return asBool((await callWords(to, sig, v))[0]); }

/** A lone dynamic `string` return: word 0 is an offset, word 1 a length, then bytes. */
async function readString(to, sig, v = []) {
  const words = await callWords(to, sig, v);
  const len = Number(asUint(words[1]));
  return Buffer.from(words.slice(2).join(''), 'hex').subarray(0, len).toString('utf8');
}

/**
 * An `eth_call` that is EXPECTED to fail, returning the reason.
 *
 * This is the load-bearing check of the whole run and the one thing a deploy
 * script normally has no way to state: not "we believe issuance is bounded" but
 * "the live contract, asked to issue, said EXCEEDS_RESERVE". A refusal nobody
 * demonstrated is a refusal nobody has tested.
 */
async function readRevert(to, sig, values = [], from) {
  try {
    await rpc('eth_call', [{ to, from, data: hex(callData(sig, values)) }, 'latest'], 3);
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : String(err);
  }
}

// ── keys ─────────────────────────────────────────────────────────────────────
/** The chain's miner key: read, used to sign, and never echoed. */
function minerKey() {
  const file = path.join(MINER_DATA, 'coinbase-key.json');
  if (!fs.existsSync(file)) {
    throw new Error(`no mining key at ${file} — this host does not mine EMBER ${EMBER_NETWORK}`);
  }
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return { priv: Buffer.from(strip(raw.privateKey), 'hex'), address: String(raw.address).toLowerCase() };
}

/** A multisig owner key sealed beside the exchange note by `hearth-dex-deploy.js`. */
function ownerKey(i) {
  const file = path.join(EXCHANGE_DIR, `owner-${i}.json`);
  if (!fs.existsSync(file)) throw new Error(`no owner key at ${file} — run the exchange deploy first`);
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return { priv: Buffer.from(strip(raw.privateKey), 'hex'), address: String(raw.address).toLowerCase() };
}

// ── sending ──────────────────────────────────────────────────────────────────
/** Sign, send, wait. Legacy transactions: this chain has no fee market. */
async function send(key, { to = null, data = Buffer.alloc(0), value = 0n, gasLimit }, chainId) {
  const nonce = hexToBig(await rpc('eth_getTransactionCount', [key.address, 'pending']));
  const gasPrice = hexToBig(await rpc('eth_gasPrice'));
  const signed = TX.sign({ nonce, gasPrice, gasLimit, to, value, data }, key.priv, { chainId });
  const hash = await rpc('eth_sendRawTransaction', [hex(TX.encode(signed))]);
  return waitFor(hash);
}

/** Thirty minutes, which is not padding — see `hearth-dex-deploy.js`. */
async function waitFor(hash) {
  const deadline = 1_800;
  let lastHead = -1;
  for (let i = 0; i < deadline; i++) {
    const receipt = await rpc('eth_getTransactionReceipt', [hash]);
    if (receipt) {
      if (hexToBig(receipt.status) !== 1n) throw new Error(`transaction ${hash} reverted (gas used ${receipt.gasUsed})`);
      return receipt;
    }
    if (i > 0 && i % 60 === 0) {
      const h = Number(hexToBig(await rpc('eth_blockNumber')));
      note(`${Math.round(i / 60)}m waiting for ${hash.slice(0, 18)}… — tip ${h}${h === lastHead ? ' (unchanged: the chain is stalled, not the transaction)' : ''}`);
      lastHead = h;
    }
    await new Promise((r) => setTimeout(r, 1_000));
  }
  throw new Error(`transaction ${hash} was not mined within ${deadline / 60} minutes — it may still be pending`);
}

/** A call from an EOA, gas estimated against the real state. */
async function sendCall(key, to, sig, values, chainId, value = 0n) {
  const data = callData(sig, values);
  const estimate = hexToBig(await rpc('eth_estimateGas', [{ from: key.address, to, data: hex(data), value: '0x' + value.toString(16) }]));
  return send(key, { to, data, value, gasLimit: (estimate * 12n) / 10n }, chainId);
}

/**
 * A call made BY THE MULTISIG: propose, confirm to the threshold, execute.
 *
 * Three transactions where an EOA would take one, and that is the point. The
 * issuer of a receipt is the party who can publish a reserve figure, and a
 * reserve figure one key can publish alone is a reserve figure one key can lie
 * about alone. `submitTransaction` implies the submitter's confirmation, so a
 * 2-of-3 needs exactly one more.
 *
 * On testnet all the owner keys are on this host. That is stated plainly here
 * and in the README: it exercises the CODE path — a threshold above one, a
 * proposal, an independent confirmation, an execution that bubbles the target's
 * own revert reason — without pretending to be three operators.
 */
async function sendViaMultisig(signers, multisig, target, sig, values, chainId, label) {
  const inner = callData(sig, values);
  const before = await readUint(multisig, 'transactionCount()');
  note(`${label}: proposing to ${multisig} ${dim(`(${inner.length} bytes of calldata)`)}`);
  await sendCall(signers[0], multisig, 'submitTransaction(address,uint256,bytes)', [target, 0n, inner], chainId);

  const after = await readUint(multisig, 'transactionCount()');
  if (after !== before + 1n) throw new Error(`expected one new proposal, transactionCount went ${before} → ${after}`);
  const txId = before;

  const required = await readUint(multisig, 'required()');
  for (let i = 1; i < signers.length && (await readUint(multisig, 'confirmationCount(uint256)', [txId])) < required; i++) {
    note(`${label}: confirming proposal ${txId} as owner ${i + 1}`);
    await sendCall(signers[i], multisig, 'confirmTransaction(uint256)', [txId], chainId);
  }

  const confirmations = await readUint(multisig, 'confirmationCount(uint256)', [txId]);
  if (confirmations < required) throw new Error(`proposal ${txId} has ${confirmations} of ${required} confirmations and no more keys here`);
  note(`${label}: executing proposal ${txId} ${dim(`(${confirmations} of ${required})`)}`);
  const receipt = await sendCall(signers[0], multisig, 'executeTransaction(uint256)', [txId], chainId);
  ok(`${label} ${dim(`via multisig proposal ${txId}, block ${Number(hexToBig(receipt.blockNumber))}`)}`);
  return receipt;
}

// ── artifacts and deployment ─────────────────────────────────────────────────
function artifact(name) {
  const file = path.join(ARTIFACTS, `${name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no artifact at ${file} — run \`pnpm compile\` in hearth/contracts first`);
  const a = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!a.bytecode || strip(a.bytecode).length === 0) throw new Error(`${name} has no creation bytecode`);
  return a;
}

async function hasCode(address) {
  if (!address) return false;
  const code = await rpc('eth_getCode', [address, 'latest']);
  return typeof code === 'string' && strip(code).length > 0;
}

const CTOR_TYPES = ['string', 'string', 'uint8', 'string', 'string', 'address', 'uint64'];

async function deployReceipt(key, chainId, ctor, known, dryRun, label) {
  if (await hasCode(known)) {
    ok(`${label.padEnd(16)} ${known} ${dim('already deployed')}`);
    return known;
  }
  const a = artifact('ForgeReceipt');
  const data = Buffer.concat([Buffer.from(strip(a.bytecode), 'hex'), encodeArgs(CTOR_TYPES, ctor)]);
  if (dryRun) { note(`${label.padEnd(16)} would deploy ${data.length} bytes of creation code`); return null; }
  const estimate = hexToBig(await rpc('eth_estimateGas', [{ from: key.address, data: hex(data) }]));
  const receipt = await send(key, { data, gasLimit: (estimate * 12n) / 10n }, chainId);
  const address = String(receipt.contractAddress).toLowerCase();
  if (!(await hasCode(address))) throw new Error(`${label} deployed to ${address} but that account has no code`);
  ok(`${label.padEnd(16)} ${address} ${dim(`block ${Number(hexToBig(receipt.blockNumber))}, gas ${Number(hexToBig(receipt.gasUsed))}`)}`);
  return address;
}

function readNote() { try { return JSON.parse(fs.readFileSync(NOTE, 'utf8')); } catch { return {}; } }
function writeNote(record) {
  fs.mkdirSync(EXCHANGE_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(NOTE, JSON.stringify(record, null, 2) + '\n');
}

// ── the words the token carries about itself ─────────────────────────────────
//
// These strings are on chain forever and they are the only thing standing
// between a receipt and a reader who assumes it is a bridge. `fLTC`, not `wLTC`:
// the convention `w` carries — lock on one chain, mint on another, trustlessly —
// is one this cannot honour, and borrowing the letter would be the lie the whole
// contract is arranged to avoid.
const LTC = {
  name: 'Forge Receipt: Litecoin',
  symbol: 'fLTC',
  decimals: 8,
  underlying: 'LTC held at the addresses published by reserveAddresses(), on Litecoin mainnet',
  statement: [
    'This is a receipt for Litecoin held off this chain by CloudsForge, not a trustless bridge.',
    'Its value depends entirely on CloudsForge honouring redemption. issue() cannot exceed the',
    'reserve most recently attested on chain, and that attestation names the Litecoin height it',
    'was read at, so anyone can re-read the same addresses at the same block and check it. If the',
    'attestation goes stale, issuance stops on its own; redemption never stops. There is no pause,',
    'no freeze, no blacklist and no upgrade path.',
  ].join(' '),
};

const DRILL = {
  name: 'Forge Receipt Drill: EMBER',
  symbol: 'dEMBER',
  decimals: 18,
  underlying: 'EMBER held at the address published by reserveAddresses(), on this same chain',
  statement: [
    'A rehearsal, deployed to exercise the redemption path end to end before any receipt against',
    'off-chain custody is issued, as docs/39 §4 requires. Its reserve is not a claim you have to',
    'take on faith: the backing address is on this chain, so eth_getBalance settles it. Every',
    'redemption recorded here was paid out with the transaction named in its settled txid.',
  ].join(' '),
};

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const statusOnly = process.argv.includes('--status');
  const dryRun = process.argv.includes('--dry-run');
  const drill = process.argv.includes('--drill');

  const chainId = Number(hexToBig(await rpc('eth_chainId')));
  if (chainId !== EXPECTED_CHAIN_ID) {
    bad(`the node at ${RPC} is chain ${chainId}, not ${EXPECTED_CHAIN_ID} — that is not EMBER ${EMBER_NETWORK}`);
    return 1;
  }
  const tip = Number(hexToBig(await rpc('eth_blockNumber')));
  ok(`chain ${chainId} (EMBER ${EMBER_NETWORK}) at height ${tip}, via ${RPC}`);

  const record = readNote();
  const addresses = record.addresses || {};
  const persist = (extra = {}) => {
    if (dryRun) return;
    writeNote({
      format: 'hearth-receipt-deployment/1',
      chainId,
      network: EMBER_NETWORK,
      deployedAtBlock: record.deployedAtBlock || tip,
      addresses,
      ...record.reserve ? { reserve: record.reserve } : {},
      ...record.drill ? { drill: record.drill } : {},
      ...extra,
    });
  };

  if (statusOnly) {
    if (!addresses.fltc && !addresses.drill) { bad(`no deployment recorded at ${NOTE}`); return 1; }
    await report(addresses, chainId);
    return failures === 0 ? 0 : 1;
  }

  const key = minerKey();
  const balance = hexToBig(await rpc('eth_getBalance', [key.address, 'latest']));
  ok(`deployer ${key.address} holds ${ember(balance)} EMBER`);
  if (balance < 10n ** 18n) { bad('the deployer holds under 1 EMBER — let the miner run longer'); return 1; }

  if (drill) {
    await runDrill(key, chainId, addresses, persist, dryRun);
    await report(addresses, chainId);
    return failures === 0 ? 0 : 1;
  }

  // ── the reserve reading, before anything is deployed against it ──────────
  head('the reserve, as measured, not as hoped');
  if (!RESERVE.sats || !RESERVE.height || !RESERVE.ref || RESERVE.addresses.length === 0) {
    bad('no reserve reading was supplied — CF_RECEIPT_RESERVE_SATS, CF_RECEIPT_HEIGHT,');
    bad('CF_RECEIPT_REF and CF_RECEIPT_ADDRESSES all have to be set. The wrapper measures');
    bad('them with `litecoin-cli scantxoutset`; this script will not attest a number nobody read.');
    return 1;
  }
  if (!/^[0-9]+$/.test(RESERVE.sats)) { bad(`CF_RECEIPT_RESERVE_SATS is "${RESERVE.sats}", which is not an integer count of litoshis`); return 1; }
  if (!/^0x[0-9a-fA-F]{64}$/.test(RESERVE.ref)) { bad(`CF_RECEIPT_REF is not a 32-byte block hash`); return 1; }
  const reserveSats = BigInt(RESERVE.sats);
  const underlyingHeight = BigInt(RESERVE.height);

  for (const a of RESERVE.addresses) note(`reserve address ${a}`);
  ok(`${reserveSats} litoshis (${(Number(reserveSats) / 1e8).toFixed(8)} LTC) across ${RESERVE.addresses.length} address(es)`);
  ok(`at Litecoin height ${underlyingHeight}, block ${RESERVE.ref}`);
  note(dim('reproduce with: litecoin-cli scantxoutset start \'["addr(…)",…]\' — see the README'));

  // ── §4, enforced here rather than remembered later ───────────────────────
  if (EMBER_NETWORK === 'mainnet' && reserveSats === 0n) {
    head('refusing mainnet');
    bad('The measured reserve is zero, and docs/39 §4 is not ambiguous: "A wrapped asset that');
    bad('cannot satisfy 35 must not be issued." Deploying fLTC on mainnet would put a promise on');
    bad('the surface where people transact, backed by a nothing this very script just measured.');
    bad('');
    bad('This is not a bug and there is no flag to pass. Send Litecoin to a published reserve');
    bad('address, re-run, and the refusal lifts by itself.');
    return 1;
  }
  if (reserveSats === 0n) {
    note(dim('the reserve is zero, so this deployment can publish and attest but never issue —'));
    note(dim('which is the point, and is asserted against the live chain further down.'));
  }

  // ── the issuer ───────────────────────────────────────────────────────────
  head('the issuer');
  let dex = {};
  try { dex = JSON.parse(fs.readFileSync(DEX_NOTE, 'utf8')); } catch { /* handled below */ }
  const multisig = dex.addresses && dex.addresses.multisig;
  if (!multisig || !(await hasCode(multisig))) {
    bad(`no multisig with code recorded at ${DEX_NOTE} — the exchange deploy has to run first.`);
    bad('The issuer is not going to be an EOA: one key that can publish a reserve figure is one');
    bad('key that can lie about it alone.');
    return 1;
  }
  const required = await readUint(multisig, 'required()');
  ok(`issuer will be the multisig ${multisig} ${dim(`(${required}-of-?, read from the chain)`)}`);

  const signers = [key];
  for (let i = 2; signers.length < Number(required); i++) {
    const o = ownerKey(i);
    signers.push(o);
    note(`second signer ${o.address} ${dim('read from its sealed file')}`);
  }
  if (EMBER_NETWORK !== 'mainnet') {
    note(dim('all of these keys are on this host: it exercises the code path — a threshold above'));
    note(dim('one, a proposal, an independent confirmation — it is not a custody arrangement.'));
  }

  // ── deploy ───────────────────────────────────────────────────────────────
  head('deploying');
  addresses.fltc = await deployReceipt(
    key, chainId,
    [LTC.name, LTC.symbol, LTC.decimals, LTC.underlying, LTC.statement, multisig, BigInt(MAX_ATTESTATION_AGE)],
    addresses.fltc, dryRun, 'fLTC',
  );
  persist();
  if (dryRun) { note('--dry-run: nothing was sent, nothing was recorded'); return failures === 0 ? 0 : 1; }

  // ── publish the addresses, then the reading ──────────────────────────────
  head('publishing the reserve, through the multisig');
  const live = await readCurrentAddresses(addresses.fltc);
  const wanted = RESERVE.addresses.map((a) => a);
  if (live.length === wanted.length && live.every((a, i) => a === wanted[i])) {
    ok(`reserveAddresses() already names the ${live.length} measured address(es)`);
  } else {
    await sendViaMultisig(signers, multisig, addresses.fltc, 'setReserveAddresses(string[])', [wanted], chainId, 'setReserveAddresses');
  }

  const attested = await callWords(addresses.fltc, 'attestation()');
  const attestedHeight = asUint(attested[1]);
  if (attestedHeight >= underlyingHeight) {
    ok(`attestation() already stands at height ${attestedHeight} ${dim('— attest() refuses to go backwards')}`);
  } else {
    await sendViaMultisig(
      signers, multisig, addresses.fltc, 'attest(uint256,uint64,bytes32)',
      [reserveSats, underlyingHeight, RESERVE.ref], chainId, 'attest',
    );
  }

  record.reserve = { sats: RESERVE.sats, height: RESERVE.height, ref: RESERVE.ref, addresses: RESERVE.addresses };
  persist({ reserve: record.reserve });
  ok(`recorded at ${NOTE}`);

  await report(addresses, chainId, key);
  return failures === 0 ? 0 : 1;
}

async function readCurrentAddresses(receipt) {
  const count = Number(await readUint(receipt, 'reserveAddressCount()'));
  const out = [];
  for (let i = 0; i < count; i++) out.push(await readString(receipt, 'reserveAddressAt(uint256)', [BigInt(i)]));
  return out;
}

/**
 * The redemption rehearsal, against a reserve a stranger can settle with one call.
 *
 * Issuer is the deployer EOA rather than the multisig, deliberately: `fLTC`
 * exercises the governance path, this exercises the LIFECYCLE, and wrapping six
 * lifecycle steps in eighteen multisig transactions would prove nothing extra
 * about redemption while tripling the number of blocks it has to survive.
 */
async function runDrill(key, chainId, addresses, persist, dryRun) {
  head('the redemption drill — a reserve that is real, on this chain');

  const custodian = key.address;
  const held = hexToBig(await rpc('eth_getBalance', [custodian, 'latest']));
  ok(`custodian ${custodian} holds ${ember(held)} EMBER ${dim('— eth_getBalance, not our word for it')}`);

  addresses.drill = await deployReceipt(
    key, chainId,
    [DRILL.name, DRILL.symbol, DRILL.decimals, DRILL.underlying, DRILL.statement, key.address, BigInt(MAX_ATTESTATION_AGE)],
    addresses.drill, dryRun, 'drill',
  );
  persist();
  if (dryRun) { note('--dry-run: nothing was sent, nothing was recorded'); return; }

  const receipt = addresses.drill;
  const already = await readUint(receipt, 'redemptionCount()');
  if (already > 0n) {
    ok(`the drill has already completed ${already} redemption(s) — nothing to rehearse`);
    return;
  }

  // A reserve figure that is deliberately BELOW what the custodian holds. The
  // attestation is a floor the issuer commits to, not a high-water mark: over-
  // stating it is the failure this contract exists to prevent, and understating
  // it costs nothing.
  if (await readUint(receipt, 'reserveAddressCount()') === 0n) {
    await sendCall(key, receipt, 'setReserveAddresses(string[])', [[custodian]], chainId);
    ok(`reserveAddresses() names ${custodian}`);
  }

  const emberTip = BigInt(Number(hexToBig(await rpc('eth_blockNumber'))));
  const block = await rpc('eth_getBlockByNumber', ['0x' + emberTip.toString(16), false]);

  // A TENTH of what the custodian holds, not most of it.
  //
  // An attestation is a floor the issuer commits to, and this one has to stay
  // true after the drill spends real EMBER paying the redemption out. At 80% the
  // arithmetic was uncomfortably tight — payout plus gas would have left the
  // custodian a rounding error above its own published reserve, so the contract
  // would have gone on saying something that had quietly stopped being so.
  // Understating a reserve costs nothing; overstating one is the entire failure
  // this contract exists to prevent, and a rehearsal that models it badly is
  // worse than no rehearsal.
  const reserve = held / 10n;
  const standing = await callWords(receipt, 'attestation()');
  if (asUint(standing[1]) < emberTip) {
    await sendCall(key, receipt, 'attest(uint256,uint64,bytes32)', [reserve, emberTip, block.hash], chainId);
    ok(`attested ${ember(reserve)} EMBER at this chain's height ${emberTip}, ref ${String(block.hash).slice(0, 18)}…`);
  }

  // Issue, to a holder that is not the issuer: a redemption from the issuer's own
  // balance would never touch `_transfer`, and would prove nothing about a
  // stranger holding the token.
  const holder = ownerKey(2);
  const amount = reserve / 4n;
  await sendCall(key, receipt, 'issue(address,uint256,bytes32)', [holder.address, amount, block.hash], chainId);
  ok(`issued ${ember(amount)} dEMBER to ${holder.address}`);

  const supply = await readUint(receipt, 'totalSupply()');
  if (supply !== amount) bad(`totalSupply() is ${supply}, expected ${amount}`);

  // The holder needs gas of their own to exit. A receipt whose holder cannot
  // afford the transaction that redeems it is a receipt with a hidden gate.
  const holderGas = hexToBig(await rpc('eth_getBalance', [holder.address, 'latest']));
  if (holderGas < 10n ** 17n) {
    await send(key, { to: holder.address, value: 10n ** 18n, gasLimit: 21_000n }, chainId);
    ok(`funded the holder with 1 EMBER for gas ${dim('— the exit must not depend on the issuer')}`);
  }

  const payoutTo = holder.address;
  await sendCall(holder, receipt, 'redeem(uint256,string)', [amount, payoutTo], chainId);
  const count = await readUint(receipt, 'redemptionCount()');
  const burned = await readUint(receipt, 'totalSupply()');
  ok(`redeem() burned the receipt first: totalSupply() ${supply} → ${burned}, redemption ${count - 1n} recorded`);
  if (burned !== 0n) bad(`totalSupply() is ${burned} after a full redemption, expected 0`);

  // Pay it out for real, then settle with THAT transaction's hash. A settled txid
  // nobody can look up is a settled txid nobody should believe.
  const nonce = hexToBig(await rpc('eth_getTransactionCount', [key.address, 'pending']));
  const gasPrice = hexToBig(await rpc('eth_gasPrice'));
  const signed = TX.sign({ nonce, gasPrice, gasLimit: 21_000n, to: payoutTo, value: amount, data: Buffer.alloc(0) }, key.priv, { chainId });
  const payoutHash = await rpc('eth_sendRawTransaction', [hex(TX.encode(signed))]);
  await waitFor(payoutHash);
  ok(`paid ${ember(amount)} EMBER to ${payoutTo} in ${payoutHash}`);

  await sendCall(key, receipt, 'settleRedemption(uint256,bytes32)', [count - 1n, payoutHash], chainId);
  const settled = await callWords(receipt, 'redemption(uint256)', [count - 1n]);
  // Head word 4 of five: (holder, amount, payoutAddress, requestedAt, settledTxid).
  //
  // NOT the last word. `payoutAddress` is a string, so the return is a head of
  // five words followed by that string's tail, and reading from the end lands in
  // the middle of the address text. The first run of this drill printed a txid of
  // 0x6338643261353264623500…, which is the ASCII of "c8d2a52db5" — the last ten
  // characters of the payout address — and reported a settlement failure against a
  // settlement that was in fact correct on chain. A verifier that cries wolf about
  // a good settlement is worse than no verifier: the next real one gets waved past.
  const settledTxid = asBytes32(settled[4]);
  if (settledTxid.toLowerCase() === String(payoutHash).toLowerCase()) {
    ok(`redemption ${count - 1n} settled with ${payoutHash} ${dim('— a hash that resolves on this chain')}`);
  } else {
    bad(`redemption ${count - 1n} carries txid ${settledTxid}, not the payout ${payoutHash}`);
  }

  const unsettled = await callWords(receipt, 'unsettledRedemptions()');
  if (asUint(unsettled[0]) === 0n) ok('unsettledRedemptions() is zero — the queue is empty and the loop closed');
  else bad(`unsettledRedemptions() reports ${asUint(unsettled[0])} outstanding`);

  // The point of an on-chain custodian: the claim can be audited after the fact,
  // by the same one call a stranger would use, and paying a redemption out must
  // not have quietly falsified the attestation that authorised it.
  const after = hexToBig(await rpc('eth_getBalance', [custodian, 'latest']));
  if (after >= reserve) ok(`custodian still holds ${ember(after)} EMBER, at or above the ${ember(reserve)} it attested`);
  else bad(`custodian holds ${ember(after)} EMBER but attested ${ember(reserve)} — the reserve claim is now false`);

  const drillNote = { custodian, attestedWei: reserve.toString(), issuedWei: amount.toString(), holder: holder.address, payoutTx: payoutHash };
  persist({ drill: drillNote });
}

/** Everything below is re-read from the chain. What the script intended is not evidence. */
async function report(addresses, chainId, key) {
  for (const [slot, label] of [['fltc', 'fLTC'], ['drill', 'dEMBER (drill)']]) {
    const receipt = addresses[slot];
    if (!receipt) continue;
    head(`what the chain says about ${label}`);

    const symbol = await readString(receipt, 'symbol()');
    const underlying = await readString(receipt, 'underlying()');
    const issuer = await readAddress(receipt, 'issuer()');
    const supply = await readUint(receipt, 'totalSupply()');
    const words = await callWords(receipt, 'attestation()');
    const [reserve, height, at, ref] = [asUint(words[0]), asUint(words[1]), asUint(words[2]), asBytes32(words[3])];
    const fresh = await readBool(receipt, 'attestationIsFresh()');
    const names = await readCurrentAddresses(receipt);

    ok(`${symbol} at ${receipt}`);
    note(`underlying   ${underlying}`);
    note(`issuer       ${issuer}${(await hasCode(issuer)) ? dim('  (a contract — the multisig)') : dim('  (an EOA)')}`);
    note(`totalSupply  ${supply}`);
    note(`attestation  reserve ${reserve} at underlying height ${height}, read ${at}, ref ${ref}`);
    note(`fresh        ${fresh}`);
    for (const a of names) note(`reserve at   ${a}`);

    if (supply <= reserve) ok(`issued ${supply} <= attested ${reserve} — the comparison a stranger came to make`);
    else bad(`issued ${supply} EXCEEDS attested ${reserve}: the token is short by ${supply - reserve}`);

    if (names.length === 0) bad('reserveAddresses() is empty — nobody can check the reserve without asking us');

    // ── the exit, re-read rather than remembered ─────────────────────────
    //
    // The drill run prints this once, live. It belongs here too, because the
    // claim "redemption works" ages: it has to stay checkable long after the
    // run that made it, by someone who was not there. `--status` answers it.
    const redemptions = await readUint(receipt, 'redemptionCount()');
    if (redemptions > 0n) {
      for (let id = 0n; id < redemptions; id++) {
        // Head word 4 of five — (holder, amount, payoutAddress, requestedAt,
        // settledTxid) — and NOT the last word: `payoutAddress` is a string, so
        // the return carries its tail after the head, and counting from the end
        // reads the address text as a hash.
        const r = await callWords(receipt, 'redemption(uint256)', [id]);
        const txid = asBytes32(r[4]);
        if (/^0x0{64}$/.test(txid)) bad(`redemption ${id} is burnt but unpaid — ${asUint(r[1])} owed to ${asAddress(r[0])}`);
        else ok(`redemption ${id}: ${asUint(r[1])} paid to ${asAddress(r[0])}, settled in ${txid}`);
      }
      const [outstanding, owed] = (await callWords(receipt, 'unsettledRedemptions()')).slice(0, 2).map(asUint);
      if (outstanding === 0n) ok('unsettledRedemptions() is zero — every burn has a payout named against it');
      else bad(`${outstanding} redemption(s) burnt and unpaid, ${owed} owed`);
    } else {
      note(dim('no redemptions yet — the exit is built but has not been walked here'));
    }

    // ── the refusal, demonstrated rather than described ──────────────────
    const from = issuer;
    const reason = await readRevert(receipt, 'issue(address,uint256,bytes32)', [from, reserve - supply + 1n, ref], from);
    if (reason && /EXCEEDS_RESERVE|STALE_ATTESTATION/.test(reason)) {
      ok(`issuing one unit past the reserve is refused by the live contract ${dim(`(${reason.match(/[A-Z_]{6,}/)[0]})`)}`);
    } else if (reason) {
      note(`issuing past the reserve failed with: ${reason}`);
      note(dim('not the expected reason, but a refusal; the multisig target makes the call shape awkward'));
    } else {
      bad('issuing one unit PAST the attested reserve was accepted by eth_call. Stop and read the contract.');
    }
  }

  if (addresses.fltc && key) {
    head('what a stranger can do with this, without asking us');
    console.log('  1. Read reserveAddresses() off the chain — three Litecoin addresses, in the clear.');
    console.log('  2. Read attestation() — a reserve, a Litecoin height, and that block\'s hash.');
    console.log('  3. Run `litecoin-cli scantxoutset` over those addresses themselves, at that block.');
    console.log('  4. Compare the answer to totalSupply(). Today both are zero, and the contract');
    console.log('     refuses to make the second one larger.');
  }
}

// The codec is exported so `hearth-receipt-codec.test.js` can check THIS
// implementation against a real ABI coder rather than a copy of it that drifts.
// Guarded on `require.main` so importing it does not deploy anything: a test
// that runs `main()` as a side effect of an import is a test that signs
// transactions.
module.exports = { word, encodeBytes, encodeString, encodeStringArray, encodeArgs, callData, selector };

if (require.main === module) {
  main().then(
    (code) => process.exit(code),
    (err) => { console.error(`  ${red('FAIL')} ${err.message}`); process.exit(1); },
  );
}
