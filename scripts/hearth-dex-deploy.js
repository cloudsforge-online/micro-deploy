#!/usr/bin/env node
'use strict';
/* Deploy Forge Exchange's contracts onto a Hearth chain, and prove they landed right.
 *
 *   cd deploy
 *   CF_EMBER_NETWORK=testnet node scripts/hearth-dex-deploy.js            # deploy, then check
 *   CF_EMBER_NETWORK=testnet node scripts/hearth-dex-deploy.js --status   # check only, write nothing
 *   CF_EMBER_NETWORK=testnet node scripts/hearth-dex-deploy.js --dry-run  # everything but the sends
 *
 * ── WHAT THIS IS FOR ─────────────────────────────────────────────────────────
 *
 * `hearth/contracts/README.md` says, in its own words: "Nothing here is deployed
 * automatically, and nothing has been deployed." That was true because there was
 * no consumer — the same shape as the release manifest that had a generator and
 * no reader. This is the consumer.
 *
 * It deploys the five contracts in the order that README's table fixes, in one
 * run, from one key, and then reads the result back OFF THE CHAIN rather than
 * off its own variables. Every check below re-queries the node. A deploy script
 * that reports what it intended is a deploy script that cannot tell you it was
 * wrong.
 *
 * ── THE ORDER IS NOT A PREFERENCE ────────────────────────────────────────────
 *
 *   1  HearthMultisig(address[] owners_, uint256 required_)      —
 *   2  WEMBER()                                                  —
 *   3  HearthV2Factory(address _feeToSetter)                     needs 1
 *   4  HearthV2Router02(address _factory, address _WEMBER)       needs 2, 3
 *   5  Multicall3()                                              —
 *
 * 1 cannot move. `feeToSetter` is the only privileged role in the system and the
 * only way to move it off an address is a transaction FROM that address — so a
 * factory deployed with the deployer EOA in the slot can only be repaired by the
 * very key you would be trying to stop relying on. The multisig has to exist
 * before the factory does or it never usefully exists at all.
 *
 * ── THE GATE ─────────────────────────────────────────────────────────────────
 *
 * `HearthV2Router02` derives pair addresses arithmetically from a hard-coded
 * `INIT_CODE_HASH` instead of asking the factory. If that constant disagrees with
 * the bytecode the live factory actually deploys, the router looks for pools at
 * addresses where no account exists and every swap reverts or silently reads
 * zeroes. Compiling proves the constant matches what solc emitted HERE; only
 * `factory.pairCodeHash()` proves it matches what is running THERE.
 *
 * So the run fails, loudly, if the live hash is not
 *
 *     0x46b4122ae9db4a03c913cfbed4e6321064741545c60aafe3ed9410be7657a537
 *
 * and it fails BEFORE anything is asked to seed liquidity. That ordering is the
 * whole value: a wrong hash discovered after a pool is funded is coin sent to an
 * address the router will never look at again.
 *
 * ── KEYS, AND WHAT THE TESTNET SIGNER SET DOES AND DOES NOT PROVE ────────────
 *
 * The deployer is the chain's miner coinbase key, read from the miner's data
 * directory exactly as `ember-seed.js` reads it, used to sign, and never printed.
 *
 * The multisig's other owners are generated ONCE by this script and sealed beside
 * it at mode 0600. On testnet all of them live on one host, which means the
 * testnet wallet is one operator holding three keys, not three operators. That is
 * stated here rather than implied: it exercises the CODE path — a threshold above
 * one, proposals, confirmations, an owner set that can be rotated — without
 * pretending to be a custody arrangement. Mainnet's signer set is a different
 * question (`docs/39` §7–§8) and this script will refuse to invent an answer to
 * it: on mainnet the owners must be supplied explicitly through
 * `HEARTH_DEX_OWNERS`.
 *
 * ── IDEMPOTENCE ──────────────────────────────────────────────────────────────
 *
 * The deployment note records every address. On a re-run each recorded address is
 * checked for code and reused; only a contract that is genuinely absent is
 * deployed again. There is no "have I run before" flag, because a flag can be
 * true about a chain that was reset underneath it.
 */

const fs = require('fs');
const path = require('path');

// ── configuration ────────────────────────────────────────────────────────────
const HEARTH = process.env.HEARTH_REPO || path.resolve(__dirname, '../../hearth');
const ARTIFACTS = process.env.HEARTH_ARTIFACTS || path.join(HEARTH, 'contracts/out');

// The same two-chain assertion `ember-seed.js` carries, and for the same reason:
// 8545 is whichever chain this host stood up, and deploying an exchange onto the
// wrong one is a set of addresses the estate will publish and nobody can use.
const EMBER_NETWORK = process.env.CF_EMBER_NETWORK || 'testnet';
const EMBER_CHAIN_IDS = { mainnet: 7411, testnet: 7412 };
const EXPECTED_CHAIN_ID = EMBER_CHAIN_IDS[EMBER_NETWORK];
if (EXPECTED_CHAIN_ID === undefined) {
  console.error(`CF_EMBER_NETWORK is "${EMBER_NETWORK}"; known: ${Object.keys(EMBER_CHAIN_IDS).join(', ')}`);
  process.exit(2);
}

// `|| '/root'` rather than a bare `process.env.HOME`: this runs inside the
// `hearth-node` image on the chain host, where the miner keys live, and a
// container started with `--user` has no HOME — `path.join(undefined, …)` would
// throw at module load, before any of the messages below could explain why.
const EMBER_HOME = process.env.EMBER_HOME || path.join(process.env.HOME || '/root', `.cloudsforge/ember-${EMBER_NETWORK}`);
const MINER_DATA = process.env.EMBER_MINER_DATA || path.join(EMBER_HOME, 'miner');
const EXCHANGE_DIR = process.env.HEARTH_DEX_HOME || path.join(EMBER_HOME, 'exchange');
const RPC = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545';
const NOTE = path.join(EXCHANGE_DIR, `deployment-${EXPECTED_CHAIN_ID}.json`);

/** The constant `HearthV2Router02` was compiled against. See THE GATE above. */
const INIT_CODE_HASH = '0x46b4122ae9db4a03c913cfbed4e6321064741545c60aafe3ed9410be7657a537';

/** Threshold and size of the wallet that will hold `feeToSetter`. */
const OWNER_COUNT = Number(process.env.HEARTH_DEX_OWNER_COUNT || 3);
const REQUIRED = Number(process.env.HEARTH_DEX_REQUIRED || 2);

const TX = require(path.join(HEARTH, 'node/src/chain/transaction.js'));
const { keccak256 } = require(path.join(HEARTH, 'node/src/crypto/keccak.js'));
const secp = require(path.join(HEARTH, 'node/src/crypto/secp256k1.js'));

const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const ok = (s) => console.log(`  ${green('ok')}   ${s}`);
const bad = (s) => { console.log(`  ${red('FAIL')} ${s}`); failures++; };
const note = (s) => console.log(`  ..   ${s}`);
let failures = 0;

// ── the chain ────────────────────────────────────────────────────────────────
/**
 * One JSON-RPC call, retried on TRANSPORT failure only.
 *
 * Copied in shape from `ember-seed.js`, which documents the measured reason: on a
 * host running ~50 containers Docker Desktop's port forwarder intermittently
 * accepts a connection on 8545 and never answers, for tens of seconds. A JSON-RPC
 * error BODY is an answer and is thrown immediately — repeating a question the
 * node has already refused turns a wrong nonce into a slow wrong nonce.
 */
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

// ── the smallest ABI codec that can do this job ──────────────────────────────
//
// Five constructors and eleven `view` calls, all over `address`, `uint256`,
// `bytes32` and `address[]`. A dependency for that would be a dependency this
// repository does not otherwise have, in a script that signs transactions.
const hex = (b) => '0x' + Buffer.from(b).toString('hex');
const strip = (h) => String(h).replace(/^0x/, '');

function word(v) {
  if (typeof v === 'bigint' || typeof v === 'number') return Buffer.from(BigInt(v).toString(16).padStart(64, '0'), 'hex');
  const s = strip(v).toLowerCase();
  return Buffer.from(s.padStart(64, '0'), 'hex');
}

/** `address[]`, tail-encoded: the head carries an offset, the tail a length and the elements. */
function encodeAddressArray(addresses, headWords) {
  const head = word(BigInt(headWords * 32));
  const tail = Buffer.concat([word(BigInt(addresses.length)), ...addresses.map((a) => word(a))]);
  return { head, tail };
}

const selector = (signature) => keccak256(Buffer.from(signature, 'utf8')).subarray(0, 4);

/** One `eth_call` against a deployed contract, returning the raw 32-byte words. */
async function callWords(to, signature, args = []) {
  const data = Buffer.concat([selector(signature), ...args.map((a) => word(a))]);
  const raw = strip(await rpc('eth_call', [{ to, data: hex(data) }, 'latest']));
  const words = [];
  for (let i = 0; i < raw.length; i += 64) words.push(raw.slice(i, i + 64));
  return words;
}

const asAddress = (w) => '0x' + w.slice(24);
const asBytes32 = (w) => '0x' + w;
const asUint = (w) => BigInt('0x' + w);

async function readAddress(to, sig) { return asAddress((await callWords(to, sig))[0]); }
async function readUint(to, sig) { return asUint((await callWords(to, sig))[0]); }
async function readBytes32(to, sig) { return asBytes32((await callWords(to, sig))[0]); }

/** A dynamic `address[]` return: word 0 is an offset, then a length, then elements. */
async function readAddressArray(to, sig) {
  const words = await callWords(to, sig);
  const len = Number(asUint(words[1]));
  return words.slice(2, 2 + len).map(asAddress);
}

// ── keys ─────────────────────────────────────────────────────────────────────
/**
 * The chain's miner key: the deployer, and owner #1 of the wallet.
 *
 * Read, used to sign, and never echoed. `evmnode.js` writes this file at mode
 * 0600 the first time the miner starts; if it is not there the miner has never
 * run here and there is nothing to spend.
 */
function minerKey() {
  const file = path.join(MINER_DATA, 'coinbase-key.json');
  if (!fs.existsSync(file)) {
    throw new Error(`no mining key at ${file} — this host does not mine EMBER ${EMBER_NETWORK}`);
  }
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return {
    priv: Buffer.from(strip(raw.privateKey), 'hex'),
    address: String(raw.address).toLowerCase(),
  };
}

function addressOf(priv) {
  return hex(TX.addressFromPublicKey(secp.publicKeyFromPrivate(priv, false))).toLowerCase();
}

/**
 * The wallet's remaining owners.
 *
 * Generated once, written at mode 0600, and read on every run after that. NOT
 * derived from a phrase: `devnet.js`-style derivation is deliberately public, and
 * an owner anybody can compute is an owner that makes the threshold decorative.
 *
 * On MAINNET this refuses to generate anything. A signer set is a decision about
 * who can turn the protocol fee on, and a script inventing one silently would be
 * answering a question (`docs/39` §7–§8) that is not its to answer.
 */
function ownerKeys(count, dryRun) {
  const out = [];
  fs.mkdirSync(EXCHANGE_DIR, { recursive: true, mode: 0o700 });
  for (let i = 2; i <= count; i++) {
    const file = path.join(EXCHANGE_DIR, `owner-${i}.json`);
    if (fs.existsSync(file)) {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      out.push({ priv: Buffer.from(strip(raw.privateKey), 'hex'), address: String(raw.address).toLowerCase(), fresh: false });
      continue;
    }
    if (EMBER_NETWORK === 'mainnet') {
      throw new Error(
        `no owner key at ${file}, and this script will not generate one on mainnet. `
        + 'Set HEARTH_DEX_OWNERS to the signer set the estate has decided on.',
      );
    }
    if (dryRun) { out.push({ priv: null, address: '0x' + '0'.repeat(40), fresh: true }); continue; }
    const priv = secp.randomPrivateKey();
    const address = addressOf(priv);
    fs.writeFileSync(file, JSON.stringify({ address, privateKey: hex(priv) }, null, 2) + '\n', { mode: 0o600 });
    fs.chmodSync(file, 0o600);
    out.push({ priv, address, fresh: true });
  }
  return out;
}

/**
 * An explicitly supplied signer set, which is the only accepted form on mainnet.
 * Comma-separated addresses; the deployer does not have to be among them.
 */
function explicitOwners() {
  const raw = process.env.HEARTH_DEX_OWNERS;
  if (!raw) return null;
  const list = raw.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  for (const a of list) {
    if (!/^0x[0-9a-f]{40}$/.test(a)) throw new Error(`HEARTH_DEX_OWNERS contains "${a}", which is not an address`);
  }
  if (new Set(list).size !== list.length) throw new Error('HEARTH_DEX_OWNERS repeats an address — the constructor rejects duplicates');
  return list;
}

// ── sending ──────────────────────────────────────────────────────────────────
/**
 * Sign, send, and wait for the receipt.
 *
 * A legacy transaction, because this chain has no fee market: `params.js`
 * documents that `eth_feeHistory` is off in v1 and that a type-2 transaction
 * signed against zero base fees is one the chain cannot execute.
 */
async function send(key, { to = null, data = Buffer.alloc(0), value = 0n, gasLimit }, chainId) {
  const nonce = hexToBig(await rpc('eth_getTransactionCount', [key.address, 'pending']));
  const gasPrice = hexToBig(await rpc('eth_gasPrice'));
  const signed = TX.sign({ nonce, gasPrice, gasLimit, to, value, data }, key.priv, { chainId });
  const hash = await rpc('eth_sendRawTransaction', [hex(TX.encode(signed))]);
  // ── THIRTY MINUTES, WHICH IS NOT PADDING ─────────────────────────────────
  //
  // This was 180 seconds and it was measured wrong on the first real run: the
  // router's transaction was reported "never mined" and had in fact been mined,
  // successfully, about a minute later. EMBER sits at its difficulty floor, and
  // a transient outside miner leaving raises the target so far that the tip
  // stalls for up to twenty minutes before the emergency rule pulls it back
  // (`hearth#13`). A deploy script whose deadline is shorter than a KNOWN stall
  // reports a failure about a success — and then, because it threw, leaves the
  // deployment unrecorded, which is the more expensive half.
  //
  // The progress line matters as much as the number. Twenty silent minutes and
  // twenty minutes of "still waiting, tip has not moved" are the same wait and
  // a very different thing to be sitting in front of.
  const deadline = 1_800;
  let lastHead = -1;
  for (let i = 0; i < deadline; i++) {
    const receipt = await rpc('eth_getTransactionReceipt', [hash]);
    if (receipt) {
      if (hexToBig(receipt.status) !== 1n) throw new Error(`transaction ${hash} reverted (gas used ${receipt.gasUsed})`);
      return receipt;
    }
    if (i > 0 && i % 60 === 0) {
      const head = Number(hexToBig(await rpc('eth_blockNumber')));
      note(`${Math.round(i / 60)}m waiting for ${hash.slice(0, 18)}… — tip ${head}${head === lastHead ? ' (unchanged: the chain is stalled, not the transaction)' : ''}`);
      lastHead = head;
    }
    await new Promise((r) => setTimeout(r, 1_000));
  }
  throw new Error(`transaction ${hash} was not mined within ${deadline / 60} minutes — it may still be pending`);
}

function artifact(name) {
  const file = path.join(ARTIFACTS, `${name}.json`);
  if (!fs.existsSync(file)) {
    throw new Error(`no artifact at ${file} — run \`pnpm compile\` in hearth/contracts first`);
  }
  const a = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!a.bytecode || strip(a.bytecode).length === 0) throw new Error(`${name} has no creation bytecode`);
  return a;
}

async function hasCode(address) {
  if (!address) return false;
  const code = await rpc('eth_getCode', [address, 'latest']);
  return typeof code === 'string' && strip(code).length > 0;
}

/**
 * Deploy one contract, unless the note already names a live one.
 *
 * The gas limit comes from `eth_estimateGas` against the creation payload, with
 * a fifth added. Hearth's block gas limit is 30,000,000 and the router is the
 * largest of these by a wide margin; a hard-coded ceiling would either be
 * generous enough to be meaningless or tight enough to fail on the next compile.
 */
async function deployOne(key, chainId, name, ctorArgs, known, dryRun) {
  if (await hasCode(known)) {
    ok(`${name.padEnd(18)} ${known} ${dim('already deployed')}`);
    return known;
  }
  const a = artifact(name);
  const data = Buffer.concat([Buffer.from(strip(a.bytecode), 'hex'), ctorArgs]);
  if (dryRun) {
    note(`${name.padEnd(18)} would deploy ${data.length} bytes of creation code`);
    return null;
  }
  const estimate = hexToBig(await rpc('eth_estimateGas', [{ from: key.address, data: hex(data) }]));
  const receipt = await send(key, { data, gasLimit: (estimate * 12n) / 10n }, chainId);
  const address = String(receipt.contractAddress).toLowerCase();
  if (!(await hasCode(address))) throw new Error(`${name} deployed to ${address} but that account has no code`);
  ok(`${name.padEnd(18)} ${address} ${dim(`block ${Number(hexToBig(receipt.blockNumber))}, gas ${Number(hexToBig(receipt.gasUsed))}`)}`);
  return address;
}

function readNote() {
  try { return JSON.parse(fs.readFileSync(NOTE, 'utf8')); } catch { return {}; }
}

/**
 * Record what exists, after EVERY deployment rather than after the last one.
 *
 * Measured on the first real run against chain 7412: four of the five contracts
 * deployed, the fifth threw on a receipt deadline (above), and because the note
 * was written at the end the script lost the addresses of the four that had
 * SUCCEEDED. A re-run would have deployed a second multisig, a second WEMBER and
 * a second factory — and a second factory is not a duplicate, it is a different
 * `feeToSetter` domain and a different set of pair addresses.
 *
 * So the note is the running record, not the summary. Anything already on chain
 * survives any failure after it.
 */
function writeNote(record) {
  fs.mkdirSync(EXCHANGE_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(NOTE, JSON.stringify(record, null, 2) + '\n');
}

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const statusOnly = process.argv.includes('--status');
  const dryRun = process.argv.includes('--dry-run');

  const chainId = Number(hexToBig(await rpc('eth_chainId')));
  if (chainId !== EXPECTED_CHAIN_ID) {
    bad(`the node at ${RPC} is chain ${chainId}, not ${EXPECTED_CHAIN_ID} — that is not EMBER ${EMBER_NETWORK}`);
    return 1;
  }
  const head = Number(hexToBig(await rpc('eth_blockNumber')));
  ok(`chain ${chainId} (EMBER ${EMBER_NETWORK}) at height ${head}, via ${RPC}`);

  const record = readNote();
  const addresses = record.addresses || {};

  if (statusOnly) {
    if (!addresses.factory) { bad(`no deployment recorded at ${NOTE}`); return 1; }
  } else {
    // ── the signer set ─────────────────────────────────────────────────────
    const key = minerKey();
    const balance = hexToBig(await rpc('eth_getBalance', [key.address, 'latest']));
    ok(`deployer ${key.address} holds ${ember(balance)} EMBER`);
    if (balance < 10n ** 18n) { bad('the deployer holds under 1 EMBER — let the miner run longer'); return 1; }

    console.log('\n── the wallet that will hold feeToSetter ────────────────────────────────');
    let owners = explicitOwners();
    if (owners) {
      ok(`${owners.length} owner(s) supplied through HEARTH_DEX_OWNERS`);
    } else {
      const extra = ownerKeys(OWNER_COUNT, dryRun);
      owners = [key.address, ...extra.map((k) => k.address)];
      for (const k of extra) {
        note(`owner ${k.address} ${dim(k.fresh ? 'generated now, sealed at mode 0600' : 'read from its sealed file')}`);
      }
      if (EMBER_NETWORK !== 'mainnet') {
        note(dim('all of these keys are on this host: the testnet wallet exercises the code path,'));
        note(dim('it is not a custody arrangement. Mainnet must pass HEARTH_DEX_OWNERS.'));
      }
    }
    if (REQUIRED < 2) { bad(`required is ${REQUIRED}; a threshold of one is an EOA with extra steps`); return 1; }
    if (REQUIRED > owners.length) { bad(`required is ${REQUIRED} but there are ${owners.length} owner(s)`); return 1; }
    ok(`${REQUIRED}-of-${owners.length}`);

    // ── deploy, in the order the README fixes ──────────────────────────────
    console.log('\n── deploying ────────────────────────────────────────────────────────────');
    const persist = () => {
      if (dryRun) return;
      writeNote({
        format: 'hearth-exchange-deployment/1',
        chainId,
        network: EMBER_NETWORK,
        deployedAtBlock: record.deployedAtBlock || head,
        deployer: key.address,
        required: REQUIRED,
        owners,
        initCodeHash: INIT_CODE_HASH,
        addresses,
      });
    };
    const step = async (name, ctorArgs, slot) => {
      addresses[slot] = await deployOne(key, chainId, name, ctorArgs, addresses[slot], dryRun);
      persist();
    };

    const arr = encodeAddressArray(owners, 2);
    await step('HearthMultisig', Buffer.concat([arr.head, word(BigInt(REQUIRED)), arr.tail]), 'multisig');
    await step('WEMBER', Buffer.alloc(0), 'wember');
    await step('HearthV2Factory', word(addresses.multisig || '0x0'), 'factory');
    await step('HearthV2Router02', Buffer.concat([word(addresses.factory || '0x0'), word(addresses.wember || '0x0')]), 'router');
    await step('Multicall3', Buffer.alloc(0), 'multicall3');

    if (dryRun) { note('--dry-run: nothing was sent, nothing was recorded'); return failures === 0 ? 0 : 1; }
    ok(`recorded at ${NOTE}`);
  }

  // ── the checks, every one of them re-read from the chain ─────────────────
  console.log('\n── what the chain says, not what this script intended ───────────────────');

  const liveHash = await readBytes32(addresses.factory, 'pairCodeHash()');
  if (liveHash === INIT_CODE_HASH) {
    ok(`factory.pairCodeHash() == the router's constant ${dim(INIT_CODE_HASH)}`);
  } else {
    bad(`factory.pairCodeHash() is ${liveHash}, the router was compiled against ${INIT_CODE_HASH}.`);
    bad('STOP. The router will look for pools at addresses that do not exist. Seed no liquidity.');
  }

  const feeToSetter = await readAddress(addresses.factory, 'feeToSetter()');
  if (feeToSetter === addresses.multisig) ok(`factory.feeToSetter() == the multisig ${feeToSetter}`);
  else bad(`factory.feeToSetter() is ${feeToSetter}, not the multisig ${addresses.multisig} — unrecoverable`);

  const feeTo = await readAddress(addresses.factory, 'feeTo()');
  if (/^0x0{40}$/.test(feeTo)) ok('factory.feeTo() is unset — the whole 0.3% accrues to liquidity providers');
  else bad(`factory.feeTo() is ${feeTo}; launch with the protocol fee off`);

  const liveOwners = await readAddressArray(addresses.multisig, 'owners()');
  const liveRequired = await readUint(addresses.multisig, 'required()');
  ok(`multisig is ${liveRequired}-of-${liveOwners.length}`);
  for (const o of liveOwners) note(`owner ${o}`);
  if (liveRequired < 2n) bad('the live threshold is below two');

  const routerFactory = await readAddress(addresses.router, 'factory()');
  const routerWeth = await readAddress(addresses.router, 'WETH()');
  const routerWember = await readAddress(addresses.router, 'WEMBER()');
  if (routerFactory === addresses.factory) ok(`router.factory() == ${routerFactory}`);
  else bad(`router.factory() is ${routerFactory}, not ${addresses.factory}`);
  if (routerWeth === addresses.wember && routerWember === addresses.wember) ok(`router.WETH() == router.WEMBER() == ${routerWeth}`);
  else bad(`router points at ${routerWeth} / ${routerWember}, not WEMBER ${addresses.wember}`);

  const pairs = await readUint(addresses.factory, 'allPairsLength()');
  note(`factory.allPairsLength() == ${pairs}`);

  const chainIdSeen = await readUint(addresses.multicall3, 'getChainId()');
  if (chainIdSeen === BigInt(chainId)) ok(`multicall3.getChainId() == ${chainIdSeen}`);
  else bad(`multicall3.getChainId() is ${chainIdSeen}, not ${chainId}`);

  console.log('\n── the addresses ────────────────────────────────────────────────────────');
  for (const [k, v] of Object.entries(addresses)) console.log(`  ${k.padEnd(12)} ${v}`);

  if (failures === 0) {
    console.log('\n  Next: seed liquidity (README "After deploying" §5). A DEX with empty pools');
    console.log('  attracts nobody, and until a pair exists nothing above has been exercised');
    console.log('  by a swap.');
  }
  return failures === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => { console.error(`  ${red('FAIL')} ${err.message}`); process.exit(1); },
);
