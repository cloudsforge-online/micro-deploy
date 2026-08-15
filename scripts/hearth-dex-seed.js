#!/usr/bin/env node
'use strict';
/* Seed Forge Exchange's first pool, then trade against it and take some back out.
 *
 *   ./scripts/hearth-dex-seed-run.sh --status     # read the pool, write nothing
 *   ./scripts/hearth-dex-seed-run.sh --dry-run    # everything except the sends
 *   ./scripts/hearth-dex-seed-run.sh              # deploy the token, fund the pair, exercise it
 *   ./scripts/hearth-dex-seed-run.sh --exercise   # trade against a pool that already exists
 *
 * ── WHAT THIS IS FOR ─────────────────────────────────────────────────────────
 *
 * `hearth-dex-deploy.js` put five contracts on chain 7412 and its own closing
 * line said what was still missing: "until a pair exists nothing above has been
 * exercised by a swap". `docs/39` phase D asks for exactly that — one EMBER
 * pair, seeded from testnet mining, and a full add / swap / swap back / remove
 * cycle. This is that script.
 *
 * Contracts existing and a market existing are different claims, and the second
 * is the one a user can tell apart from nothing at all.
 *
 * ── THE GATE RUNS FIRST, BEFORE A SINGLE COIN MOVES ──────────────────────────
 *
 * `HearthV2Router02` does not ask the factory where a pair is; it derives the
 * address arithmetically from a hard-coded `INIT_CODE_HASH`. If that constant
 * disagrees with the bytecode the LIVE factory deploys, liquidity added through
 * the router lands at an address the router will never look at again. That is
 * not a failed transaction, it is coin gone.
 *
 * So `factory.pairCodeHash()` is read from the node before the token is
 * deployed, let alone funded, and a mismatch stops the run. The deploy script
 * checks the same thing; it is checked again here because the two runs are
 * separated by however long, and a factory can be replaced in between.
 *
 * ── AND THE DERIVATION IS CHECKED AGAINST THE FACTORY AFTERWARDS ─────────────
 *
 * The hash matching is necessary and not sufficient — it proves the router and
 * the factory agree about pair BYTECODE, not that this particular pair landed
 * where the router computes. So the address is derived off-chain with
 * `pairFor()` before the pair exists, and after `addLiquidityETH` the run
 * asserts that `factory.getPair(token, WEMBER)` is that same address and that it
 * now has code. If those two ever disagree, every quote this exchange gives is
 * against a pool that is not the pool.
 *
 * ── WHAT IS MEASURED, AND WHY IT IS MEASURED THIS WAY ────────────────────────
 *
 * Every number below is re-read from the node. The swap checks compare the
 * router's own `getAmountsOut` quote against the BALANCE DELTA the swap
 * produced, not against the router's return value — a router that quoted one
 * number and transferred another would pass a check on its own arithmetic and
 * fail this one.
 *
 * The round trip is expected to LOSE money, and the run asserts that it does.
 * Swapping EMBER for the token and straight back pays the 0.30% fee twice, and
 * the fee stays in the pool: `k = reserve0 * reserve1` rises across each swap,
 * which is the liquidity providers being paid, and it is asserted rather than
 * described.
 *
 * ── IDEMPOTENCE ──────────────────────────────────────────────────────────────
 *
 * `pool-<chainId>.json` is the running record, written after every step — the
 * discipline `hearth-dex-deploy.js` arrived at the expensive way. A re-run
 * reuses a token that has code and a pair that has reserves. The exercise is
 * recorded too and is NOT repeated by default: it removes liquidity, and a
 * cycle that quietly removed another slice on every re-run would drain the pool
 * one careless invocation at a time. `--exercise` asks for it explicitly.
 *
 * The record is a separate file from the deployment note on purpose.
 * `hearth-dex-deploy.js` rebuilds its note from a fixed set of fields, so
 * anything this script added to that file would be dropped, without a word, by
 * the next deploy run.
 */

const fs = require('fs');
const path = require('path');

const {
  dim, ok, bad, note, heading, failureCount,
  strip, hexToBig, units,
  tailArray, tailString, encodeArgs, connect, minerKey,
} = require('./lib/hearth-evm.js');

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
const EXCHANGE_DIR = process.env.HEARTH_DEX_HOME || path.join(EMBER_HOME, 'exchange');
const RPC = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545';
const DEPLOY_NOTE = path.join(EXCHANGE_DIR, `deployment-${EXPECTED_CHAIN_ID}.json`);
const POOL_NOTE = path.join(EXCHANGE_DIR, `pool-${EXPECTED_CHAIN_ID}.json`);

/** A decimal amount of whole units, as wei. `5000` and `0.25` both work. */
function toWei(text, decimals = 18) {
  const [whole, frac = ''] = String(text).trim().split('.');
  if (!/^\d+$/.test(whole) || !/^\d*$/.test(frac)) throw new Error(`"${text}" is not an amount`);
  if (frac.length > decimals) throw new Error(`"${text}" has more than ${decimals} decimal places`);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0');
}

/** The token this pool is against. `hearth-dex-token-artifact.mjs` says why it is mint's. */
const TOKEN_NAME = process.env.HEARTH_DEX_TOKEN_NAME || 'Forge Test Token';
const TOKEN_SYMBOL = process.env.HEARTH_DEX_TOKEN_SYMBOL || 'FTEST';
const TOKEN_SUPPLY = toWei(process.env.HEARTH_DEX_TOKEN_SUPPLY || '1000000');

/**
 * The opening depth, which `docs/39` §7 lists as an owner decision and leaves
 * open. These are testnet defaults and nothing more: 5,000 EMBER is about 6% of
 * what the testnet miner holds — deep enough that a 25-EMBER swap moves the
 * price by a readable amount rather than a rounding error, shallow enough that
 * the run is not the entire balance.
 *
 * On mainnet these must be passed in. A default opening depth is a decision
 * about how much of the estate's coin sits in a pool, and this script has no
 * business having an opinion about that.
 */
const SEED_EMBER = toWei(process.env.HEARTH_DEX_SEED_EMBER || '5000');
const SEED_TOKEN = toWei(process.env.HEARTH_DEX_SEED_TOKEN || '250000');
const SWAP_EMBER = toWei(process.env.HEARTH_DEX_SWAP_EMBER || '25');
/** How much of the position to take back out — enough to prove the exit, not enough to close the market. */
const REMOVE_PERCENT = BigInt(process.env.HEARTH_DEX_REMOVE_PERCENT || 10);
/** Gas money the run must still hold after everything it plans to spend. */
const GAS_HEADROOM = toWei('50');
/** Slippage tolerance on a quote taken a block earlier. The run then asserts the fill was exact. */
const SLIPPAGE_BPS = 50n;

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const statusOnly = process.argv.includes('--status');
  const dryRun = process.argv.includes('--dry-run');
  const forceExercise = process.argv.includes('--exercise');

  const chain = connect({ rpcUrl: RPC, hearthRepo: HEARTH });
  const {
    rpc, callWords, asUint, readAddress, readUint, readBytes32, readUintArray,
    hasCode, callContract, deployContract, chainNow, pairFor,
  } = chain;

  /** A `string` return: an offset, a length, then the bytes. */
  async function readString(to, signature) {
    const w = await callWords(to, signature);
    const len = Number(asUint(w[1]));
    return Buffer.from(w.slice(2).join('').slice(0, len * 2), 'hex').toString('utf8');
  }

  /** The pair's reserves, mapped onto (ember, token) rather than the pair's own (0, 1). */
  async function readReserves(pair, tokenAddress) {
    const w = await callWords(pair, 'getReserves()');
    const [r0, r1] = [asUint(w[0]), asUint(w[1])];
    const token0 = await readAddress(pair, 'token0()');
    return token0 === tokenAddress.toLowerCase() ? { token: r0, ember: r1 } : { token: r1, ember: r0 };
  }

  const chainId = Number(hexToBig(await rpc('eth_chainId')));
  if (chainId !== EXPECTED_CHAIN_ID) {
    bad(`the node at ${RPC} is chain ${chainId}, not ${EXPECTED_CHAIN_ID} — that is not EMBER ${EMBER_NETWORK}`);
    return 1;
  }
  const head = Number(hexToBig(await rpc('eth_blockNumber')));
  ok(`chain ${chainId} (EMBER ${EMBER_NETWORK}) at height ${head}, via ${RPC}`);

  // ── what the deploy script left behind ───────────────────────────────────
  let deployment;
  try {
    deployment = JSON.parse(fs.readFileSync(DEPLOY_NOTE, 'utf8'));
  } catch {
    bad(`no deployment recorded at ${DEPLOY_NOTE} — run hearth-dex-deploy.js first`);
    return 1;
  }
  const { factory, router, wember } = deployment.addresses || {};
  for (const [name, address] of Object.entries({ factory, router, wember })) {
    if (!(await hasCode(address))) {
      bad(`${name} is recorded as ${address}, and that account has no code on chain ${chainId}`);
      return 1;
    }
  }
  ok(`factory ${factory}`);
  ok(`router  ${router}`);
  ok(`WEMBER  ${wember}`);

  let key = null;

  /**
   * `approve`, then read the allowance back off the chain.
   *
   * The read is not ceremony. An ERC-20 that returns false instead of reverting
   * is the oldest way for a transfer to fail after its transaction succeeded,
   * and the router's next call would then revert with nothing pointing at why.
   */
  async function approve(tokenAddress, amount, label) {
    await callContract(key, chainId, tokenAddress, 'approve(address,uint256)', [router, amount], { label: `approve ${label}` });
    const allowance = await readUint(tokenAddress, 'allowance(address,address)', [key.address, router]);
    if (allowance >= amount) ok(`allowance ${label}: ${units(allowance)}`);
    else throw new Error(`approve(${label}) reported success and the allowance is ${allowance}`);
  }

  const soon = async () => BigInt((await chainNow()) + 3_600);
  const atLeast = (quoted) => (quoted * (10_000n - SLIPPAGE_BPS)) / 10_000n;

  // ── THE GATE — before the token exists, let alone the pool ───────────────
  heading('the gate');
  const initCodeHash = await readBytes32(factory, 'pairCodeHash()');
  if (initCodeHash !== deployment.initCodeHash) {
    bad(`factory.pairCodeHash() is ${initCodeHash}`);
    bad(`the router was compiled against ${deployment.initCodeHash}`);
    bad('STOP. Liquidity added through this router would land where it cannot be reached.');
    return 1;
  }
  ok(`factory.pairCodeHash() == the router's constant ${dim(initCodeHash)}`);

  const record = readPool();
  const persist = () => { if (!dryRun) writePool(record); };
  Object.assign(record, { format: 'hearth-exchange-pool/1', chainId, network: EMBER_NETWORK, initCodeHash });

  // ── the token the pair is against ────────────────────────────────────────
  heading('the token');
  let token = (process.env.HEARTH_DEX_PAIR_TOKEN || (record.token && record.token.address) || '').toLowerCase() || null;

  if (!statusOnly) {
    key = minerKey(MINER_DATA, EMBER_NETWORK);
    const balance = hexToBig(await rpc('eth_getBalance', [key.address, 'latest']));
    ok(`deployer ${key.address} holds ${units(balance)} EMBER`);
    const planned = SEED_EMBER + SWAP_EMBER + GAS_HEADROOM;
    if (balance < planned) {
      bad(`this run may spend ${units(SEED_EMBER)} + ${units(SWAP_EMBER)} EMBER and keep ${units(GAS_HEADROOM)} for gas`);
      bad(`that is ${units(planned)}, and the deployer holds ${units(balance)}`);
      return 1;
    }
  }

  if (await hasCode(token)) {
    ok(`${token} ${dim('already deployed')}`);
  } else if (statusOnly) {
    bad(`no pair token recorded at ${POOL_NOTE}`);
    return 1;
  } else if (dryRun) {
    note(`would deploy ${TOKEN_NAME} (${TOKEN_SYMBOL}), ${units(TOKEN_SUPPLY)} to the deployer`);
    note(`would add ${units(SEED_EMBER)} EMBER and ${units(SEED_TOKEN)} ${TOKEN_SYMBOL} to a pair against WEMBER`);
    note('--dry-run: nothing was sent, nothing was recorded');
    return failureCount() === 0 ? 0 : 1;
  } else {
    const artifact = readArtifact('FixedSupplyToken');
    // FixedSupplyToken(string name_, string symbol_, uint8 decimals_, uint256 initialSupply_, address recipient_)
    const ctor = encodeArgs([{ tail: tailString(TOKEN_NAME) }, { tail: tailString(TOKEN_SYMBOL) }, 18n, TOKEN_SUPPLY, key.address]);
    const creation = Buffer.concat([Buffer.from(strip(artifact.bytecode), 'hex'), ctor]);
    const deployed = await deployContract(key, chainId, creation, `${TOKEN_SYMBOL} token`);
    token = deployed.address;
    ok(`${token} ${dim(`block ${Number(hexToBig(deployed.receipt.blockNumber))}, from ${artifact.origin || 'a local artifact'}`)}`);
    record.token = { address: token, source: artifact.origin, sourceSha256: artifact.sourceSha256 };
    persist();
  }

  // Read the token back off the chain rather than trusting what was asked for.
  const symbol = await readString(token, 'symbol()');
  const decimals = Number(await readUint(token, 'decimals()'));
  const supply = await readUint(token, 'totalSupply()');
  ok(`${symbol}, ${decimals} decimals, ${units(supply, decimals)} in existence`);
  if (decimals !== 18) { bad(`this script assumes 18 decimals and the token has ${decimals}`); return 1; }
  record.token = { ...(record.token || {}), address: token, symbol, decimals, totalSupply: supply.toString() };
  persist();

  // ── where the pair must be ───────────────────────────────────────────────
  heading('the pair');
  const pair = pairFor(factory, token, wember, initCodeHash);
  note(`pairFor() derives          ${pair}`);
  note(`factory.getPair() returns  ${await readAddress(factory, 'getPair(address,address)', [token, wember])}`);
  record.pair = pair;
  persist();

  const pairExists = await hasCode(pair);
  if (pairExists) {
    const registered = await readAddress(factory, 'getPair(address,address)', [token, wember]);
    if (registered === pair) ok('the factory and the router agree about where this pool is');
    else { bad(`the factory registered ${registered}; the router will trade against ${pair}`); return 1; }
  } else {
    note(`no account at ${pair} yet — the pool does not exist`);
  }

  // ── funding it ───────────────────────────────────────────────────────────
  let reserves = pairExists ? await readReserves(pair, token) : null;
  if (reserves && reserves.token > 0n && reserves.ember > 0n) {
    heading('the pool');
    ok(`already funded: ${units(reserves.ember)} EMBER / ${units(reserves.token)} ${symbol}`);
  } else if (statusOnly) {
    bad('the pool holds nothing');
    return 1;
  } else if (dryRun) {
    heading('the pool');
    note(`would add ${units(SEED_EMBER)} EMBER and ${units(SEED_TOKEN)} ${symbol} to ${pair}`);
    note('--dry-run: nothing was sent, nothing was recorded');
    return failureCount() === 0 ? 0 : 1;
  } else {
    heading('adding liquidity');
    await approve(token, SEED_TOKEN, `${symbol} → router`);
    const receipt = await callContract(
      key, chainId, router,
      'addLiquidityETH(address,uint256,uint256,uint256,address,uint256)',
      [token, SEED_TOKEN, atLeast(SEED_TOKEN), atLeast(SEED_EMBER), key.address, await soon()],
      { value: SEED_EMBER, label: 'addLiquidityETH' },
    );
    ok(`addLiquidityETH ${dim(`block ${Number(hexToBig(receipt.blockNumber))}, gas ${Number(hexToBig(receipt.gasUsed))}`)}`);

    // THE check. Everything above it is arithmetic; this is the chain agreeing with it.
    const registered = await readAddress(factory, 'getPair(address,address)', [token, wember]);
    if (registered !== pair) {
      bad(`the factory created the pair at ${registered}, and the router will look at ${pair}`);
      bad('the liquidity just added is unreachable through the router. Add no more.');
      return 1;
    }
    if (!(await hasCode(pair))) { bad(`${pair} still has no code`); return 1; }
    ok(`factory.getPair() == pairFor() == ${pair}`);

    reserves = await readReserves(pair, token);
    record.seeded = {
      block: Number(hexToBig(receipt.blockNumber)),
      ember: reserves.ember.toString(),
      token: reserves.token.toString(),
    };
    persist();
    ok(`the pool holds ${units(reserves.ember)} EMBER / ${units(reserves.token)} ${symbol}`);
  }

  const holder = key ? key.address : deployment.deployer;
  const lp = await readUint(pair, 'balanceOf(address)', [holder]);
  const lpTotal = await readUint(pair, 'totalSupply()');
  ok(`LP tokens ${units(lp)} of ${units(lpTotal)} ${dim('(1000 wei was burned to address(0) on the first mint)')}`);

  // ── the cycle ────────────────────────────────────────────────────────────
  if (statusOnly) return report(record, symbol, reserves);
  if (dryRun) {
    heading('the cycle');
    note(`would swap ${units(SWAP_EMBER)} EMBER for ${symbol}, swap it back, and remove ${REMOVE_PERCENT}% of the position`);
    note('--dry-run: nothing was sent, nothing was recorded');
    return failureCount() === 0 ? 0 : 1;
  }
  if (record.exercised && !forceExercise) {
    heading('the cycle');
    note(`already run at block ${record.exercised.block} — pass --exercise to run it again`);
    return report(record, symbol, reserves);
  }

  const kSeeded = reserves.ember * reserves.token;

  // ── swap EMBER → token ───────────────────────────────────────────────────
  heading(`swapping ${units(SWAP_EMBER)} EMBER for ${symbol}`);
  const quoteOut = (await readUintArray(router, 'getAmountsOut(uint256,address[])', [SWAP_EMBER, { tail: tailArray([wember, token]) }]))[1];
  note(`router quotes ${units(quoteOut)} ${symbol}`);
  const tokenBefore = await readUint(token, 'balanceOf(address)', [key.address]);
  await callContract(
    key, chainId, router,
    'swapExactETHForTokens(uint256,address[],address,uint256)',
    [atLeast(quoteOut), { tail: tailArray([wember, token]) }, key.address, await soon()],
    { value: SWAP_EMBER, label: 'swapExactETHForTokens' },
  );
  const gained = (await readUint(token, 'balanceOf(address)', [key.address])) - tokenBefore;
  if (gained === quoteOut) ok(`received exactly what was quoted: ${units(gained)} ${symbol}`);
  else bad(`quoted ${units(quoteOut)} ${symbol}, received ${units(gained)}`);

  const mid = await readReserves(pair, token);
  ok(`the pool now holds ${units(mid.ember)} EMBER / ${units(mid.token)} ${symbol}`);
  if (mid.ember * mid.token > kSeeded) ok(`k rose ${dim('— the 0.30% fee stayed in the pool, which is the liquidity providers being paid')}`);
  else bad('k did not rise across a swap; the fee is not reaching the pool');

  // ── swap it all back ─────────────────────────────────────────────────────
  heading(`swapping ${units(gained)} ${symbol} back for EMBER`);
  await approve(token, gained, `${symbol} → router`);
  const quoteBack = (await readUintArray(router, 'getAmountsOut(uint256,address[])', [gained, { tail: tailArray([token, wember]) }]))[1];
  note(`router quotes ${units(quoteBack)} EMBER`);
  await callContract(
    key, chainId, router,
    'swapExactTokensForETH(uint256,uint256,address[],address,uint256)',
    [gained, atLeast(quoteBack), { tail: tailArray([token, wember]) }, key.address, await soon()],
    { label: 'swapExactTokensForETH' },
  );

  /* WHAT THE TRADER RECEIVED IS MEASURED AT THE POOL, NOT AT THE WALLET.
   *
   * The obvious meter is the trader's own EMBER balance either side of the send,
   * with the gas added back. On this chain it is wrong, and wrong by enough to
   * read as a broken contract: the key these scripts sign with IS the chain's
   * coinbase, so every block mined while the transaction waited paid it a
   * subsidy. The first run of this script measured 35.629561 EMBER against a
   * 24.850965 quote and duly reported that the 0.30% fee was not being charged.
   * Two blocks had gone by at ~5.389 EMBER each (`params.js coinbaseRewardWei`
   * — the subsidy less the Commons' 10%); the surplus was mining, not trading.
   *
   * The pair's EMBER reserve moves only when someone trades against it, so its
   * fall across the swap is exactly what left the pool for the trader — immune
   * to rewards, to gas, and to anything else that lands on that address. The
   * one thing it does assume is that no other trade settles in between, which
   * on a pool whose only counterparty is this script is safe; the moment the
   * pair has real traffic, anchor both reads to the receipt's block instead. */
  const after = await readReserves(pair, token);
  const received = mid.ember - after.ember;
  if (received === quoteBack) ok(`received exactly what was quoted: ${units(received)} EMBER`);
  else bad(`quoted ${units(quoteBack)} EMBER, received ${units(received)}`);

  if (received < SWAP_EMBER) ok(`the round trip cost ${units(SWAP_EMBER - received)} EMBER ${dim('— the 0.30% fee, paid twice, as it should be')}`);
  else bad(`the round trip RETURNED ${units(received - SWAP_EMBER)} more EMBER than it spent — the fee is not being charged`);

  if (after.ember * after.token > mid.ember * mid.token) ok('k rose again');
  else bad('k did not rise across the second swap');

  // ── take part of it back out ─────────────────────────────────────────────
  heading(`removing ${REMOVE_PERCENT}% of the position`);
  const burn = (lp * REMOVE_PERCENT) / 100n;
  if (burn === 0n) { bad('the position is too small to remove a tenth of'); return 1; }
  await approve(pair, burn, 'LP → router');
  const tokenPre = await readUint(token, 'balanceOf(address)', [key.address]);
  const removeReceipt = await callContract(
    key, chainId, router,
    'removeLiquidityETH(address,uint256,uint256,uint256,address,uint256)',
    [token, burn, 1n, 1n, key.address, await soon()],
    { label: 'removeLiquidityETH' },
  );
  ok(`removeLiquidityETH ${dim(`block ${Number(hexToBig(removeReceipt.blockNumber))}, gas ${Number(hexToBig(removeReceipt.gasUsed))}`)}`);

  const lpAfter = await readUint(pair, 'balanceOf(address)', [key.address]);
  const tokenPost = await readUint(token, 'balanceOf(address)', [key.address]);
  const final = await readReserves(pair, token);
  if (lpAfter === lp - burn) ok(`the LP balance fell by exactly the ${units(burn)} burned`);
  else bad(`the LP balance is ${units(lpAfter)}, expected ${units(lp - burn)}`);
  if (tokenPost > tokenPre) ok(`got ${units(tokenPost - tokenPre)} ${symbol} back`);
  else bad(`the ${symbol} balance did not rise`);
  if (final.ember < after.ember && final.token < after.token) ok('the pool is smaller by the share that was withdrawn');
  else bad('the reserves did not fall');

  record.exercised = {
    block: Number(hexToBig(removeReceipt.blockNumber)),
    swappedIn: SWAP_EMBER.toString(),
    swappedBack: received.toString(),
    roundTripCost: (SWAP_EMBER - received).toString(),
    removedLp: burn.toString(),
  };
  record.pool = { ember: final.ember.toString(), token: final.token.toString(), lp: lpAfter.toString() };
  persist();

  return report(record, symbol, final);
}

// ── the record ───────────────────────────────────────────────────────────────
function readPool() {
  try { return JSON.parse(fs.readFileSync(POOL_NOTE, 'utf8')); } catch { return {}; }
}
function writePool(record) {
  fs.mkdirSync(EXCHANGE_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(POOL_NOTE, JSON.stringify(record, null, 2) + '\n');
}

function readArtifact(name) {
  const file = path.join(ARTIFACTS, `${name}.json`);
  if (!fs.existsSync(file)) {
    throw new Error(`no artifact at ${file} — generate it with scripts/hearth-dex-token-artifact.mjs and copy it over`);
  }
  const a = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!a.bytecode || strip(a.bytecode).length === 0) throw new Error(`${name} has no creation bytecode`);
  return a;
}

function report(record, symbol, reserves) {
  heading('the market');
  console.log(`  pair       ${record.pair}`);
  console.log(`  token      ${record.token.address}  ${symbol}`);
  console.log(`  reserves   ${units(reserves.ember)} EMBER / ${units(reserves.token)} ${symbol}`);
  console.log(`  price      1 EMBER = ${units((reserves.token * 10n ** 18n) / reserves.ember)} ${symbol}`);
  console.log(`  recorded   ${POOL_NOTE}`);
  if (failureCount() === 0) {
    console.log('\n  A pool exists and has been traded through in both directions. What is still');
    console.log('  missing is somebody who is not us doing it from a browser (`docs/39` phase D)');
    console.log('  and something to read the contracts with (phase B).');
  }
  return failureCount() === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => { console.error(`  FAIL ${err.message}`); process.exit(1); },
);
