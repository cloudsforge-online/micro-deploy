'use strict';
/* The EVM machinery `hearth-dex-deploy.js` and `hearth-dex-seed.js` share.
 *
 * Both scripts sign transactions against a Hearth chain, and the second one was
 * about to be a second copy of the first one's RPC client, ABI codec and receipt
 * loop. Two copies of transaction-signing code is the kind of duplication that
 * drifts silently and is discovered by a transaction that cost something.
 *
 * Nothing here is Forge-Exchange-specific. It is: talk to a node, encode and
 * decode the four ABI types these contracts use, read a key without echoing it,
 * and wait for a receipt long enough that a known chain stall is not mistaken
 * for a failure.
 *
 * No dependencies. `hearth/node` supplies the cryptography, `fetch` is Node's.
 */

const fs = require('fs');
const path = require('path');

// ── output ───────────────────────────────────────────────────────────────────
const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;

let failures = 0;
const ok = (s) => console.log(`  ${green('ok')}   ${s}`);
const bad = (s) => { console.log(`  ${red('FAIL')} ${s}`); failures++; };
const note = (s) => console.log(`  ..   ${s}`);
const failureCount = () => failures;
const heading = (s) => console.log(`\n── ${s} ${'─'.repeat(Math.max(0, 72 - s.length))}`);

// ── hex ──────────────────────────────────────────────────────────────────────
const hex = (b) => '0x' + Buffer.from(b).toString('hex');
const strip = (h) => String(h).replace(/^0x/, '');
const bytes = (h) => Buffer.from(strip(h), 'hex');
const hexToBig = (h) => BigInt(h);

/** 18-decimal display. For LOGGING only — every comparison below is on bigints. */
const units = (v, decimals = 18) => {
  const d = 10n ** BigInt(decimals);
  const whole = v / d;
  const frac = (v % d).toString().padStart(decimals, '0').slice(0, 6);
  return `${whole}.${frac}`;
};

// ── the smallest ABI codec that can do this job ──────────────────────────────
//
// `address`, `uint256`, `bytes32`, `string`, `address[]`, `uint256[]`. A library
// for that would be a dependency this repository does not otherwise have, in
// scripts that sign transactions.
function word(v) {
  if (typeof v === 'bigint' || typeof v === 'number') return Buffer.from(BigInt(v).toString(16).padStart(64, '0'), 'hex');
  return Buffer.from(strip(v).toLowerCase().padStart(64, '0'), 'hex');
}

/** A dynamic tail: length, then the payload, padded to a whole number of words. */
function tailBytes(buf) {
  const pad = (32 - (buf.length % 32)) % 32;
  return Buffer.concat([word(BigInt(buf.length)), buf, Buffer.alloc(pad)]);
}
const tailString = (s) => tailBytes(Buffer.from(s, 'utf8'));
const tailArray = (items) => Buffer.concat([word(BigInt(items.length)), ...items.map(word)]);

/**
 * Encode a call whose arguments mix static and dynamic types.
 *
 * `args` is a list of either a value (static, one word) or `{ tail: Buffer }`
 * (dynamic). Offsets are computed from the real head size rather than passed in
 * by hand, because a hand-counted offset is wrong the first time an argument is
 * added and the failure is a revert with no message.
 */
function encodeArgs(args) {
  const headWords = args.length;
  const heads = [];
  const tails = [];
  let offset = BigInt(headWords * 32);
  for (const a of args) {
    if (a && typeof a === 'object' && Buffer.isBuffer(a.tail)) {
      heads.push(word(offset));
      tails.push(a.tail);
      offset += BigInt(a.tail.length);
    } else {
      heads.push(word(a));
    }
  }
  return Buffer.concat([...heads, ...tails]);
}


// ── the connection ───────────────────────────────────────────────────────────
/**
 * Everything that needs a node, bound to one URL and one chain id.
 *
 * `hearthRepo` is where `hearth/node`'s crypto and transaction encoder are read
 * from: on the chain host this runs inside the `hearth-node` image with the
 * repository bind-mounted, so the path is not derivable from `__dirname`.
 */
function connect({ rpcUrl, hearthRepo }) {
  const TX = require(path.join(hearthRepo, 'node/src/chain/transaction.js'));
  const { keccak256 } = require(path.join(hearthRepo, 'node/src/crypto/keccak.js'));
  const secp = require(path.join(hearthRepo, 'node/src/crypto/secp256k1.js'));

  /**
   * One JSON-RPC call, retried on TRANSPORT failure only.
   *
   * The measured reason, from `ember-seed.js`: on a host running ~50 containers
   * the port forwarder intermittently accepts a connection and never answers,
   * for tens of seconds. A JSON-RPC error BODY is an answer and is thrown at
   * once — repeating a question the node has already refused turns a wrong nonce
   * into a slow wrong nonce.
   */
  async function rpc(method, params = [], attempts = 20) {
    let last;
    for (let i = 0; i < attempts; i++) {
      try {
        const res = await fetch(rpcUrl, {
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
    throw new Error(`${method}: no answer from ${rpcUrl} after ${attempts} attempts — ${last && last.message}`);
  }

  const selector = (signature) => keccak256(Buffer.from(signature, 'utf8')).subarray(0, 4);

  /** One `eth_call`, returned as 32-byte words. `from` matters for nothing here but costs nothing. */
  async function callWords(to, signature, args = []) {
    const data = Buffer.concat([selector(signature), encodeArgs(args)]);
    const raw = strip(await rpc('eth_call', [{ to, data: hex(data) }, 'latest']));
    const out = [];
    for (let i = 0; i < raw.length; i += 64) out.push(raw.slice(i, i + 64));
    return out;
  }

  const asAddress = (w) => '0x' + w.slice(24);
  const asBytes32 = (w) => '0x' + w;
  const asUint = (w) => BigInt('0x' + w);

  const readAddress = async (to, sig, args) => asAddress((await callWords(to, sig, args))[0]);
  const readUint = async (to, sig, args) => asUint((await callWords(to, sig, args))[0]);
  const readBytes32 = async (to, sig, args) => asBytes32((await callWords(to, sig, args))[0]);

  /** A dynamic return: word 0 is an offset, word 1 a length, then the elements. */
  async function readArray(to, sig, args, decode) {
    const w = await callWords(to, sig, args);
    const len = Number(asUint(w[1]));
    return w.slice(2, 2 + len).map(decode);
  }
  const readAddressArray = (to, sig, args) => readArray(to, sig, args, asAddress);
  const readUintArray = (to, sig, args) => readArray(to, sig, args, asUint);

  async function hasCode(address) {
    if (!address) return false;
    const code = await rpc('eth_getCode', [address, 'latest']);
    return typeof code === 'string' && strip(code).length > 0;
  }

  const addressOf = (priv) => hex(TX.addressFromPublicKey(secp.publicKeyFromPrivate(priv, false))).toLowerCase();

  /**
   * Sign, send, and wait for the receipt.
   *
   * A legacy transaction, because this chain has no fee market: `params.js`
   * documents that `eth_feeHistory` is off in v1 and that a type-2 transaction
   * signed against zero base fees is one the chain cannot execute.
   *
   * ── THIRTY MINUTES, WHICH IS NOT PADDING ─────────────────────────────────
   *
   * This was 180 seconds and it was measured wrong on the first real run: the
   * router's deployment was reported "never mined" and had in fact been mined,
   * successfully, about a minute later. EMBER sits at its difficulty floor, and
   * a transient outside miner leaving raises the target far enough to stall the
   * tip for up to twenty minutes before the emergency rule pulls it back
   * (`hearth#13`). A deadline shorter than a KNOWN stall reports a failure about
   * a success — and then, because it threw, leaves the caller's work unrecorded,
   * which is the more expensive half.
   *
   * The progress line matters as much as the number. Twenty silent minutes and
   * twenty minutes of "still waiting, tip has not moved" are the same wait and a
   * very different thing to be sitting in front of.
   */
  async function send(key, { to = null, data = Buffer.alloc(0), value = 0n, gasLimit }, chainId, label = '') {
    const nonce = hexToBig(await rpc('eth_getTransactionCount', [key.address, 'pending']));
    const gasPrice = hexToBig(await rpc('eth_gasPrice'));
    const signed = TX.sign({ nonce, gasPrice, gasLimit, to, value, data }, key.priv, { chainId });
    const hash = await rpc('eth_sendRawTransaction', [hex(TX.encode(signed))]);
    const deadline = 1_800;
    let lastHead = -1;
    for (let i = 0; i < deadline; i++) {
      const receipt = await rpc('eth_getTransactionReceipt', [hash]);
      if (receipt) {
        if (hexToBig(receipt.status) !== 1n) throw new Error(`${label || 'transaction'} ${hash} reverted (gas used ${receipt.gasUsed})`);
        return receipt;
      }
      if (i > 0 && i % 60 === 0) {
        const head = Number(hexToBig(await rpc('eth_blockNumber')));
        note(`${Math.round(i / 60)}m waiting for ${label || hash.slice(0, 18)}… — tip ${head}${head === lastHead ? ' (unchanged: the chain is stalled, not the transaction)' : ''}`);
        lastHead = head;
      }
      await new Promise((r) => setTimeout(r, 1_000));
    }
    throw new Error(`${label || 'transaction'} ${hash} was not mined within ${deadline / 60} minutes — it may still be pending`);
  }

  /**
   * A state-changing call, with the gas limit estimated against the real
   * payload plus a fifth.
   *
   * `eth_estimateGas` runs the call, so a transaction that would revert fails
   * HERE, before it is signed and before it costs a block — with the node's own
   * reason attached rather than a bare "reverted".
   */
  async function callContract(key, chainId, to, signature, args = [], { value = 0n, label } = {}) {
    const data = Buffer.concat([selector(signature), encodeArgs(args)]);
    const tx = { from: key.address, to, data: hex(data) };
    if (value > 0n) tx.value = '0x' + value.toString(16);
    const estimate = hexToBig(await rpc('eth_estimateGas', [tx]));
    return send(key, { to, data, value, gasLimit: (estimate * 12n) / 10n }, chainId, label || signature);
  }

  async function deployContract(key, chainId, creationCode, label) {
    const estimate = hexToBig(await rpc('eth_estimateGas', [{ from: key.address, data: hex(creationCode) }]));
    const receipt = await send(key, { data: creationCode, gasLimit: (estimate * 12n) / 10n }, chainId, label);
    const address = String(receipt.contractAddress).toLowerCase();
    if (!(await hasCode(address))) throw new Error(`${label} deployed to ${address} but that account has no code`);
    return { address, receipt };
  }

  /** The block timestamp a router `deadline` must be measured against — the chain's clock, not this host's. */
  async function chainNow() {
    const block = await rpc('eth_getBlockByNumber', ['latest', false]);
    return Number(hexToBig(block.timestamp));
  }

  /**
   * Where `HearthV2Library.pairFor` says a pair lives, computed here rather than
   * asked of the factory.
   *
   * That is the point of README "After deploying" §4: the router NEVER asks. If
   * this derivation and `factory.getPair` disagree, the router is looking at an
   * empty account and the pool is unreachable.
   */
  function pairFor(factory, tokenA, tokenB, initCodeHash) {
    const [t0, t1] = [tokenA.toLowerCase(), tokenB.toLowerCase()].sort();
    const salt = keccak256(Buffer.concat([bytes(t0), bytes(t1)]));
    const digest = keccak256(Buffer.concat([Buffer.from([0xff]), bytes(factory), salt, bytes(initCodeHash)]));
    return hex(digest.subarray(12)).toLowerCase();
  }

  return {
    rpc, keccak256, secp, TX,
    selector, callWords, asAddress, asBytes32, asUint,
    readAddress, readUint, readBytes32, readAddressArray, readUintArray,
    hasCode, addressOf, send, callContract, deployContract, chainNow, pairFor,
  };
}

// ── keys ─────────────────────────────────────────────────────────────────────
/**
 * The chain's miner coinbase key: read, used to sign, and never echoed.
 *
 * `evmnode.js` writes this file at mode 0600 the first time the miner starts; if
 * it is absent the miner has never run here and there is nothing to spend.
 */
function minerKey(minerDataDir, network) {
  const file = path.join(minerDataDir, 'coinbase-key.json');
  if (!fs.existsSync(file)) {
    throw new Error(`no mining key at ${file} — this host does not mine EMBER ${network}`);
  }
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return { priv: Buffer.from(strip(raw.privateKey), 'hex'), address: String(raw.address).toLowerCase() };
}

module.exports = {
  green, red, dim, ok, bad, note, heading, failureCount,
  hex, strip, bytes, hexToBig, units,
  word, tailBytes, tailString, tailArray, encodeArgs,
  connect, minerKey,
};
