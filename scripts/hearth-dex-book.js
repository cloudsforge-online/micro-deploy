#!/usr/bin/env node
'use strict';
/* Book the liquidity Forge Exchange seeded into a Hearth V2 pair, and prove the
 * solvency invariant did not move.
 *
 *   cd deploy
 *   set -a; . compose/estate/tokens.env; set +a
 *   node scripts/hearth-dex-book.js --status    # read everything, post nothing
 *   node scripts/hearth-dex-book.js             # post the entry
 *
 * ── WHY THIS SCRIPT EXISTS ────────────────────────────────────────────────────
 *
 * `docs/ecosystem/39-forge-exchange.md` §6 gates phase F on one sentence: "the
 * estate's own solvency reporting books the seeded liquidity". Seeding a pool
 * moves real EMBER out of a miner's coinbase and into a contract, and until that
 * movement is in the journal the estate's books say the coin is somewhere it is
 * not. This is the entry that says where it went.
 *
 * ── THE ACCOUNT THIS MUST NEVER TOUCH, AND WHY ────────────────────────────────
 *
 * `ledger/src/reconcile.ts` sums exactly (type = 'asset' AND subject = 'custody')
 * for an asset and compares it to what micro-indexer observes across every
 * address labelled with a prefix in `INDEXER_CUSTODY_LABEL_PREFIXES`
 * (`deposit:`, `treasury:`). EMBER's tolerance is ZERO — one wei of disagreement
 * freezes every EMBER withdrawal on the estate.
 *
 * An AMM reserve is a number no one controls. It changes whenever an outsider
 * swaps, in the same block they swap. Putting it on either side of an equality
 * that has no slack would freeze EMBER the first time a stranger traded, and the
 * freeze would be correct — the two sides really would disagree. So:
 *
 *   - the pair address is NOT registered with the indexer, and must not be;
 *   - the entry below carries subject `platform` on both sides, never `custody`.
 *
 * `docs/ecosystem/35` G1 names the opposite mistake — an address watched but not
 * booked — "an invented insolvency". Booking a pool as custody is its mirror
 * image, and this script asserts the custody total is byte-identical before and
 * after it posts.
 *
 * ── WHAT IT POSTS ─────────────────────────────────────────────────────────────
 *
 *   DEBIT   platform / EMBER / reserved   (asset)   the position: owned, illiquid
 *   CREDIT  platform / EMBER / treasury   (equity)  mining income, now recognised
 *
 * The credit is equity because the seeded EMBER was mined by the estate and was
 * never anyone's claim — no user, no organisation, no custody arrangement. The
 * debit is `reserved` rather than `available` because the estate cannot spend it
 * without burning LP tokens first, and `reserved` is the purpose that already
 * means exactly that everywhere else in the chart of accounts.
 *
 * ── THE AMOUNT IS READ FROM THE CHAIN, NOT FROM THE SEEDER'S INTENTION ────────
 *
 * The number booked is the estate's CLAIM on the pool at a stated block:
 *
 *     claim = reserveEMBER × lpHeldByTheEstate ÷ lpTotalSupply
 *
 * which is what burning every LP token the estate holds would return, less
 * slippage against itself. Three reasons it is that rather than "what was sent
 * to addLiquidity":
 *
 *   - the seeding run ends by REMOVING part of the position, on purpose, to
 *     prove the exit works. The contributed amount stopped being the position a
 *     few blocks after it was contributed;
 *   - a stranger swapping changes the split between the two reserves, so a
 *     figure taken at seeding time drifts away from the truth immediately;
 *   - it is recomputable. Anyone with an RPC endpoint can check this entry
 *     against the chain, which is the property `docs/35` is built around.
 *
 * The reads are anchored: the head is taken before and after, and a block
 * landing in between makes the script read again rather than mix two states.
 * The block it settled on goes in the entry's metadata, so the number is not
 * "roughly now" but "exactly there".
 *
 * ── IDEMPOTENCE, AND WHAT THIS ENTRY DOES NOT DO ──────────────────────────────
 *
 * One key per pair, for ever: `hearth-dex-book:<chainId>:<pair>:seed`. A re-run
 * replays and the ledger answers 200 instead of 201. The key deliberately does
 * NOT carry the amount — if it did, running this after a trade would mint a
 * second entry for the same act.
 *
 * That means this books the OPENING position once and does not track it. A pool
 * that is traded heavily will drift from the booked figure, and closing that gap
 * is proof-of-reserves work — `docs/39` phase G, where a wrapped asset has to
 * satisfy `docs/35` in full. Until then the honest statement is the one this
 * entry makes: at block N the estate's claim on this pair was X.
 */

const fs = require('fs');
const path = require('path');

// ── configuration ────────────────────────────────────────────────────────────
const EMBER_NETWORK = process.env.CF_EMBER_NETWORK || 'mainnet';
const EMBER_CHAIN_IDS = { mainnet: 7411, testnet: 7412 };
const EXPECTED_CHAIN_ID = EMBER_CHAIN_IDS[EMBER_NETWORK];
if (EXPECTED_CHAIN_ID === undefined) {
  console.error(`CF_EMBER_NETWORK is "${EMBER_NETWORK}"; known: ${Object.keys(EMBER_CHAIN_IDS).join(', ')}`);
  process.exit(2);
}

// The chain lives on the other host. From inside the estate it is reachable over
// the WireGuard link; from the chain host itself it is loopback. Neither is
// hard-coded as the only answer, because this script has to be runnable from the
// machine that has the ledger, which is not the machine that has the node.
const RPC = process.env.EMBER_HOST_RPC || 'http://10.10.0.1:8545';

// `4`1xx on mainnet, `5`1xx on testnet — the one-character override
// `docker-compose.estate.yml` publishes all the debug ports through. Read from
// the estate's own env file so there is one statement of it, exactly as
// `ember-seed.js` does and for the reason recorded there.
const PORT_BASE =
  process.env.CF_PORT_BASE ||
  (() => {
    try {
      const file = path.join(__dirname, '..', 'compose', `${EMBER_NETWORK}.env`);
      const line = fs
        .readFileSync(file, 'utf8')
        .split('\n')
        .filter((l) => /^CF_PORT_BASE=/.test(l))
        .pop();
      if (line) return line.slice('CF_PORT_BASE='.length).trim() || null;
    } catch {
      /* absent on a developer machine; the default below is the right answer there */
    }
    return null;
  })() ||
  '4';
const IDENTITY = process.env.IDENTITY || `http://127.0.0.1:${PORT_BASE}100`;
const LEDGER = process.env.LEDGER || `http://127.0.0.1:${PORT_BASE}102`;
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'estate-admin@example.test';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || process.env.ESTATE_ADMIN_PASSWORD;
if (!ADMIN_PASSWORD) {
  console.error('ADMIN_PASSWORD (or ESTATE_ADMIN_PASSWORD) is not set, and it has no default.');
  console.error('Source compose/estate/tokens.env first:  set -a; . compose/estate/tokens.env; set +a');
  process.exit(2);
}

// The seeder's record, which is written on the chain host. Copy it over, or point
// at it. Everything this script books comes from it; nothing is invented here.
const EXCHANGE_DIR = process.env.HEARTH_DEX_HOME
  || path.join(process.env.HOME || '/root', `.cloudsforge/ember-${EMBER_NETWORK}/exchange`);
const POOL_NOTE = process.env.HEARTH_DEX_POOL_NOTE || path.join(EXCHANGE_DIR, `pool-${EXPECTED_CHAIN_ID}.json`);
const DEPLOY_NOTE = process.env.HEARTH_DEX_DEPLOY_NOTE || path.join(EXCHANGE_DIR, `deployment-${EXPECTED_CHAIN_ID}.json`);

const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const dim = (s) => `\x1b[2m${s}\x1b[0m`;
const ok = (s) => console.log(`  ${green('ok')}   ${s}`);
const bad = (s) => { console.log(`  ${red('FAIL')} ${s}`); failures++; };
const note = (s) => console.log(`  ..   ${s}`);
const heading = (s) => console.log(`\n── ${s} ${'─'.repeat(Math.max(0, 71 - s.length))}`);
let failures = 0;

const WEI = 10n ** 18n;
// Signed, because one line here prints a difference and a difference can be
// negative: `-249n / 10n**18n` is `0n` and `-249n % 10n**18n` is negative, so the
// naive form renders `-249.-40923…`. The sign is taken off the front once.
const units = (v) => {
  const sign = v < 0n ? '-' : '';
  const abs = v < 0n ? -v : v;
  const whole = abs / WEI;
  const frac = (abs % WEI).toString().padStart(18, '0').replace(/0+$/, '');
  return frac ? `${sign}${whole}.${frac}` : `${sign}${whole}`;
};
const hexToBig = (h) => BigInt(h);
const strip = (h) => (h.startsWith('0x') ? h.slice(2) : h);

// ── the chain ────────────────────────────────────────────────────────────────
async function rpc(method, params = []) {
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(30_000),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

// The four-byte selector of a signature, computed with hearth's own keccak so
// this script and the chain cannot disagree about what a call means.
const HEARTH = process.env.HEARTH_REPO || path.resolve(__dirname, '../../hearth');
const { keccak256 } = require(path.join(HEARTH, 'node/src/crypto/keccak.js'));
const selector = (sig) => '0x' + Buffer.from(keccak256(Buffer.from(sig, 'utf8'))).toString('hex').slice(0, 8);
const word = (v) => {
  const hex = typeof v === 'bigint' ? v.toString(16) : strip(String(v)).toLowerCase();
  return hex.padStart(64, '0');
};

async function callRead(to, signature, args = []) {
  const data = selector(signature) + args.map(word).join('');
  return rpc('eth_call', [{ to, data }, 'latest']);
}
async function readAddress(to, signature, args = []) {
  return '0x' + strip(await callRead(to, signature, args)).slice(-40).toLowerCase();
}
async function readUint(to, signature, args = []) {
  const raw = strip(await callRead(to, signature, args));
  return raw ? BigInt('0x' + raw.slice(0, 64)) : 0n;
}
/** `getReserves()` returns (uint112,uint112,uint32) in three words. */
async function readReserves(pair, wember) {
  const raw = strip(await callRead(pair, 'getReserves()'));
  const r0 = BigInt('0x' + raw.slice(0, 64));
  const r1 = BigInt('0x' + raw.slice(64, 128));
  const token0 = await readAddress(pair, 'token0()');
  return token0 === wember.toLowerCase() ? { ember: r0, other: r1 } : { ember: r1, other: r0 };
}

/**
 * The estate's claim on a pair, read at ONE block.
 *
 * `eth_call` with the `latest` tag answers from whatever the head is at that
 * instant, so four calls made in sequence can straddle a block and describe a
 * pool that never existed — reserves from before a swap, LP supply from after.
 * The head is taken either side and the whole read is repeated if it moved. It
 * settles in one attempt on a chain with 30-second blocks; the loop is there so
 * that when it does not, the answer is still a single consistent state.
 */
async function readClaim(pair, wember, holder) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const before = Number(hexToBig(await rpc('eth_blockNumber')));
    const reserves = await readReserves(pair, wember);
    const lpTotal = await readUint(pair, 'totalSupply()');
    const lpHeld = await readUint(pair, 'balanceOf(address)', [holder]);
    const after = Number(hexToBig(await rpc('eth_blockNumber')));
    if (before !== after) continue;
    if (lpTotal === 0n) throw new Error(`${pair} has no LP supply — nothing was ever added to it`);
    return { block: before, reserves, lpTotal, lpHeld, claim: (reserves.ember * lpHeld) / lpTotal };
  }
  throw new Error('the head moved on every attempt — the chain is too busy to take a consistent read');
}

// ── the estate ───────────────────────────────────────────────────────────────
async function http(url, options = {}, attempts = 5) {
  let last;
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(url, { ...options, signal: AbortSignal.timeout(30_000) });
      const text = await res.text();
      let body;
      try { body = JSON.parse(text); } catch { body = text; }
      return { status: res.status, body };
    } catch (err) {
      last = err;
      await new Promise((r) => setTimeout(r, 3_000));
    }
  }
  throw new Error(`no answer from ${url} after ${attempts} attempts — ${last && last.message}`);
}

/**
 * A service token carrying `ledger:post` and `ledger:read`.
 *
 * The principal is `wallet`, which is the service that already debits and credits
 * the estate's own chain positions. Nothing here needs an indexer grant: this
 * script must not register an address, and asking for the scope that would let it
 * would be asking for the one power it exists to refuse.
 */
async function ledgerToken() {
  const signin = await http(`${IDENTITY}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ identifier: ADMIN_EMAIL, password: ADMIN_PASSWORD }),
  });
  const admin = signin.body && signin.body.accessToken;
  if (!admin) throw new Error(`could not sign in as ${ADMIN_EMAIL} at ${IDENTITY}`);
  const minted = await http(`${IDENTITY}/service-tokens`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${admin}` },
    body: JSON.stringify({ service: 'wallet', scopes: ['ledger:post', 'ledger:read'] }),
  });
  if (!minted.body || !minted.body.token) {
    throw new Error(`identity would not mint a token: ${minted.status}`);
  }
  return minted.body.token;
}

/** Σ of one asset's balances for a subject, as the ledger reports them. */
async function balanceOf(token, subject, assetCode, purpose) {
  const res = await http(`${LEDGER}/accounts/${encodeURIComponent(subject)}/balances`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (res.status !== 200) throw new Error(`ledger ${res.status} reading ${subject} balances`);
  const rows = (res.body && res.body.balances) || [];
  return rows
    .filter((b) => b.assetCode === assetCode && (purpose === undefined || b.purpose === purpose))
    .reduce((sum, b) => sum + BigInt(b.amount ?? b.balance ?? 0), 0n);
}

function readNote(file, what) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    bad(`no ${what} at ${file}`);
    return null;
  }
}

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const statusOnly = process.argv.includes('--status');

  heading('what is on chain');
  const chainId = Number(hexToBig(await rpc('eth_chainId')));
  if (chainId !== EXPECTED_CHAIN_ID) {
    bad(`the node at ${RPC} is chain ${chainId}, not ${EXPECTED_CHAIN_ID} — that is not EMBER ${EMBER_NETWORK}`);
    return 1;
  }
  const head = Number(hexToBig(await rpc('eth_blockNumber')));
  ok(`chain ${chainId} (EMBER ${EMBER_NETWORK}) at height ${head}`);

  const deployment = readNote(DEPLOY_NOTE, 'deployment record');
  const pool = readNote(POOL_NOTE, 'pool record');
  if (!deployment || !pool) {
    console.log('\n  Both records are written by the scripts that did the work, on the chain host:');
    console.log('    hearth-dex-deploy.js  ->  deployment-<chainId>.json');
    console.log('    hearth-dex-seed.js    ->  pool-<chainId>.json');
    console.log('  Copy them to this host, or point HEARTH_DEX_DEPLOY_NOTE / HEARTH_DEX_POOL_NOTE at them.');
    return 1;
  }
  const wember = String(deployment.addresses && deployment.addresses.wember || '').toLowerCase();
  const pair = String(pool.pair || '').toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(wember)) { bad('the deployment record has no WEMBER address'); return 1; }
  if (!/^0x[0-9a-f]{40}$/.test(pair)) { bad('the pool record has no pair address'); return 1; }
  if (!pool.seeded || !pool.seeded.ember) {
    bad('the pool record has no `seeded` block — nothing was ever added to this pair');
    return 1;
  }

  const holder = String(deployment.deployer || '').toLowerCase();
  if (!/^0x[0-9a-f]{40}$/.test(holder)) { bad('the deployment record has no deployer address'); return 1; }
  ok(`pair ${pair} ${dim(`seeded at block ${pool.seeded.block}`)}`);

  const state = await readClaim(pair, wember, holder);
  ok(`read at block ${state.block} ${dim('(head unchanged either side of the read)')}`);
  ok(`reserves ${units(state.reserves.ember)} EMBER / ${units(state.reserves.other)} of the pair token`);
  ok(`LP ${units(state.lpHeld)} of ${units(state.lpTotal)} held by ${holder}`
    + ` ${dim('(1000 wei was burned to address(0) on the first mint)')}`);

  const contributed = BigInt(pool.seeded.ember);
  const claim = state.claim;
  ok(`the estate's claim on this pair is ${units(claim)} EMBER`);
  if (claim !== contributed) {
    const delta = claim - contributed;
    note(`${units(contributed)} EMBER was contributed at block ${pool.seeded.block};`
      + ` the claim is ${delta > 0n ? '+' : ''}${units(delta)} against that`);
    note(dim('trading fees raise it, a withdrawal lowers it, and the seeding run removes a slice on purpose'));
  }
  if (claim === 0n) { bad('the claim is zero — there is nothing to book'); return 1; }

  // ── the invariant, before ──────────────────────────────────────────────────
  heading('the solvency invariant, before');
  const token = await ledgerToken();
  const custodyBefore = await balanceOf(token, 'custody', 'EMBER');
  const reservedBefore = await balanceOf(token, 'platform', 'EMBER', 'reserved');
  ok(`custody/EMBER    ${units(custodyBefore)} EMBER ${dim('(this is the number reconcile.ts sums)')}`);
  ok(`platform/EMBER/reserved  ${units(reservedBefore)} EMBER`);

  if (statusOnly) {
    heading('nothing was posted');
    note('--status: read everything, changed nothing');
    return failures === 0 ? 0 : 1;
  }

  // ── the entry ──────────────────────────────────────────────────────────────
  heading('booking it');
  const amount = claim.toString();
  const entry = {
    kind: 'liquidity_seed',
    originatingService: 'deploy',
    actor: 'system',
    idempotencyKey: `hearth-dex-book:${chainId}:${pair}:seed`,
    description: `Forge Exchange opening liquidity, pair ${pair} on EMBER ${EMBER_NETWORK}`,
    metadata: {
      chainId,
      network: EMBER_NETWORK,
      pair,
      wember,
      token: pool.token && pool.token.address,
      // Everything needed to recompute the amount from an RPC endpoint alone.
      measuredAtBlock: state.block,
      reserveEmber: state.reserves.ember.toString(),
      lpHeld: state.lpHeld.toString(),
      lpTotalSupply: state.lpTotal.toString(),
      lpHolder: holder,
      contributedAtBlock: pool.seeded.block,
      contributedEmber: contributed.toString(),
      doc: 'docs/ecosystem/39-forge-exchange.md §6 phase F',
    },
    postings: [
      { direction: 'debit', amount, assetCode: 'EMBER', sequence: 0,
        account: { subject: 'platform', assetCode: 'EMBER', purpose: 'reserved', type: 'asset' } },
      { direction: 'credit', amount, assetCode: 'EMBER', sequence: 1,
        account: { subject: 'platform', assetCode: 'EMBER', purpose: 'treasury', type: 'equity' } },
    ],
  };
  const res = await http(`${LEDGER}/entries`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify(entry),
  });
  if (res.status === 201) ok(`posted ${units(claim)} EMBER into platform/EMBER/reserved`);
  else if (res.status === 200) ok('already booked — replayed, not double-posted');
  else {
    bad(`the ledger refused it: ${res.status} ${JSON.stringify(res.body).slice(0, 300)}`);
    return 1;
  }

  // ── the invariant, after ───────────────────────────────────────────────────
  //
  // The whole point of the account choice, asserted rather than asserted about.
  heading('the solvency invariant, after');
  const custodyAfter = await balanceOf(token, 'custody', 'EMBER');
  const reservedAfter = await balanceOf(token, 'platform', 'EMBER', 'reserved');
  if (custodyAfter === custodyBefore) {
    ok(`custody/EMBER unchanged at ${units(custodyAfter)} EMBER — reconciliation cannot have moved`);
  } else {
    bad(`custody/EMBER moved from ${units(custodyBefore)} to ${units(custodyAfter)}`);
    bad('that is the freeze this script exists to avoid. Reverse the entry.');
  }
  ok(`platform/EMBER/reserved  ${units(reservedBefore)} → ${units(reservedAfter)} EMBER`);

  const recon = await http(`${LEDGER}/reconciliation`, { headers: { authorization: `Bearer ${token}` } });
  const runs = (recon.body && recon.body.runs) || [];
  const ember = runs.filter((r) => r.assetCode === 'EMBER')[0];
  if (ember) ok(`last EMBER reconciliation: ${ember.status}, drift ${ember.drift ?? '0'}`);
  const freezes = (recon.body && recon.body.freezes) || [];
  if (freezes.length === 0) ok('no asset is frozen');
  else bad(`frozen: ${freezes.map((f) => f.assetCode).join(', ')}`);

  return failures === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => { console.error(`  ${red('FAIL')} ${err.message}`); process.exit(1); },
);
