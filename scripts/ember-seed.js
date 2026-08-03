#!/usr/bin/env node
'use strict';
/* Seed the EMBER custody set with coin that actually exists, and close the loop.
 *
 *   cd deploy
 *   node scripts/ember-seed.js            # fund, register, credit, reconcile
 *   node scripts/ember-seed.js --status   # report, change nothing
 *
 * ── WHY A ZERO-BALANCE CUSTODY SET WOULD PROVE NOTHING ────────────────────────
 *
 * The estate now has a complete chain-backing guarantee and has only ever
 * exercised its REFUSAL branch. `micro-ledger` migration 11 refuses, at the
 * database, to record a reconciliation whose observation came from the ledger
 * itself; `micro-indexer`'s custody route refuses rather than returning a
 * partial sum; `ledger/src/jobs.ts` now makes the call. With no chain in the
 * environment every EMBER run correctly reported `unavailable/failed`.
 *
 * A chain alone upgrades that to `0 == 0`, which is the plumbing working and the
 * arithmetic untested — and `0 == 0` is precisely the shape of the defect this
 * whole release removed one service downstream. So this script puts real,
 * DISTINCT, non-round amounts on chain and credits the ledger with exactly the
 * same numbers. If either side sums wrongly, or matches the wrong address, or
 * truncates, the totals differ and EMBER freezes. That is the check.
 *
 * The amounts are distinct primes on purpose: three addresses at 10 EMBER each
 * would still balance if the observer read one address three times.
 *
 * ── WHAT IT SEEDS, AND WHY EACH ADDRESS NEVER SPENDS ──────────────────────────
 *
 * Three addresses derived from a PUBLIC seed phrase, exactly as
 * `hearth/node/src/cli/devnet.js` derives its accounts and for the same reason:
 * reproducible, so this script is idempotent and a fixture can hard-code one,
 * and worthless, because anyone can compute them. They are registered with the
 * indexer under the `deposit:` label prefix, which is what
 * `INDEXER_CUSTODY_LABEL_PREFIXES` selects and therefore what the aggregate sums.
 *
 * They only ever RECEIVE. That is not tidiness: `eth_getBalance` at the confirmed
 * height is exact, so an address that never pays gas holds exactly what was sent
 * to it, forever, and the ledger's credit can equal it to the wei. An address
 * that spent would need the fee modelled on the ledger side, and the estate's own
 * `store.tokenBalancesAt` comment explains why that arithmetic is a plausible
 * wrong number rather than a right one.
 *
 * The owner's MINING address is deliberately NOT in the custody set. Its balance
 * changes every time it wins a block, so the two sides could only ever agree by
 * accident, between blocks.
 *
 * ── THE ONE PIECE OF TIMING THAT MATTERS ──────────────────────────────────────
 *
 * The indexer reads balances at `head − 60 + 1` (EMBER's published confirmation
 * depth), so a transfer is invisible to the aggregate until it is 60 blocks
 * deep. This script funds, then WAITS for the observation to reach the funded
 * total, and only then credits the ledger. Crediting first would produce a real
 * positive drift and freeze EMBER for as long as the wait — correct behaviour,
 * and a confusing thing to do to yourself on purpose.
 *
 * ── KEYS ──────────────────────────────────────────────────────────────────────
 *
 * The funding key is the OWNER'S MINING KEY, read from the miner's data
 * directory. It is never printed, never logged and never written anywhere by
 * this script. The seed addresses' keys are derived from a published phrase and
 * are worthless by construction. All of it is testnet coin.
 */

const fs = require('fs');
const path = require('path');

// ── configuration ────────────────────────────────────────────────────────────
const HEARTH = process.env.HEARTH_REPO || path.resolve(__dirname, '../../hearth');
const EMBER_HOME = process.env.EMBER_HOME || path.join(process.env.HOME, '.cloudsforge/ember-testnet');
const MINER_DATA = process.env.EMBER_MINER_DATA || path.join(EMBER_HOME, 'miner');
const RPC = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545';
const IDENTITY = process.env.IDENTITY || 'http://127.0.0.1:4100';
const INDEXER = process.env.INDEXER || 'http://127.0.0.1:4108';
const LEDGER = process.env.LEDGER || 'http://127.0.0.1:4102';
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'estate-admin@example.test';
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'correct-horse-battery-staple-42';

const WEI = 10n ** 18n;
/** The published seed. Its keys are public; that is the point, and it is why
 *  nothing but testnet coin may ever reach these addresses. */
const SEED_PHRASE = process.env.EMBER_SEED_PHRASE || 'cloudsforge estate custody seed';
/** Distinct, non-round, and summing to 31 EMBER. See the header. */
const AMOUNTS = [7n * WEI, 11n * WEI, 13n * WEI];
const LABEL = (i) => `deposit:ember-testnet-seed-${i}`;

const TX = require(path.join(HEARTH, 'node/src/chain/transaction.js'));
const { deriveAccounts } = require(path.join(HEARTH, 'node/src/cli/devnet.js'));

const green = (s) => `\x1b[32m${s}\x1b[0m`;
const red = (s) => `\x1b[31m${s}\x1b[0m`;
const ok = (s) => console.log(`  ${green('ok')}   ${s}`);
const bad = (s) => { console.log(`  ${red('FAIL')} ${s}`); failures++; };
const note = (s) => console.log(`  ..   ${s}`);
let failures = 0;

const ember = (wei) => (Number(wei) / 1e18).toFixed(6);

// ── the chain ────────────────────────────────────────────────────────────────
/**
 * One JSON-RPC call, retried.
 *
 * **The retry is not defensive padding, it is a measured local defect.** The
 * chain's ports are published by Docker Desktop, and under the load of ~50
 * containers its forwarder intermittently accepts a connection on 8545 and never
 * answers — for tens of seconds, while `host.docker.internal:8545` from inside a
 * container answers the same node in milliseconds and the estate's own indexer
 * only logs one `no provider answered for the tip` and recovers. It was observed
 * here twice, once for the better part of a minute, on a machine whose load
 * average was in the hundreds. A script that gave up on the first timeout would
 * report "the chain is down" about a chain at height 107.
 *
 * Twenty attempts, ten-second deadline, two seconds apart: a four-minute
 * tolerance, far longer than any healthy call and far shorter than a chain that
 * is genuinely gone. The final error names the endpoint rather than saying
 * "fetch failed".
 *
 * `connection: close` for a related reason: Node 24's undici pools this socket
 * against hearthd's `Keep-Alive: timeout=65` and makes the stall much likelier.
 *
 * It retries a TRANSPORT failure only. A JSON-RPC error body is an answer, and
 * repeating a question the node has already refused would turn a wrong nonce
 * into a slow wrong nonce.
 */
async function rpc(method, params = [], attempts = 20) {
  let last;
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(RPC, {
        method: 'POST',
        headers: { 'content-type': 'application/json', connection: 'close' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(10_000),
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

/**
 * The owner's mining key.
 *
 * Read, used to sign, and never echoed. `evmnode.js:78` writes this file at mode
 * 0600 the first time the miner starts; if it is not there the miner has never
 * run and there is nothing to spend.
 */
function ownerKey() {
  const file = path.join(MINER_DATA, 'coinbase-key.json');
  if (!fs.existsSync(file)) {
    throw new Error(`no mining key at ${file} — run ./scripts/ember-miner.sh start first`);
  }
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  return {
    priv: Buffer.from(String(raw.privateKey).replace(/^0x/, ''), 'hex'),
    address: raw.address,
  };
}

/**
 * Send exactly `value` wei, and wait for the receipt.
 *
 * A legacy transaction, because this chain has no fee market: `params.js`
 * documents that `eth_feeHistory` is off in v1 and that a type-2 transaction
 * signed against zero base fees is one the chain cannot execute.
 */
async function transfer(key, to, value, chainId) {
  const nonce = hexToBig(await rpc('eth_getTransactionCount', [key.address, 'pending']));
  const gasPrice = hexToBig(await rpc('eth_gasPrice'));
  const signed = TX.sign(
    { nonce, gasPrice, gasLimit: 21000n, to, value, data: Buffer.alloc(0) },
    key.priv,
    { chainId },
  );
  const raw = TX.encode(signed);
  const hash = await rpc('eth_sendRawTransaction', ['0x' + raw.toString('hex')]);
  for (let i = 0; i < 120; i++) {
    const receipt = await rpc('eth_getTransactionReceipt', [hash]);
    if (receipt) {
      if (hexToBig(receipt.status) !== 1n) throw new Error(`transfer to ${to} reverted (${hash})`);
      return hash;
    }
    await new Promise((r) => setTimeout(r, 1_000));
  }
  throw new Error(`transfer to ${to} was never mined (${hash})`);
}

// ── the estate ───────────────────────────────────────────────────────────────
/**
 * One estate call, retried on TRANSPORT failure only.
 *
 * Same reasoning as `rpc` above and one more: the wait for the confirmed
 * aggregate below runs for up to twenty minutes, and over that window an estate
 * on a loaded machine WILL drop a connection — identity was OOM-killed
 * (exit 137) once during this work. Giving up there would abandon a seeding that
 * had already funded the chain, leaving the two sides of the reconciliation
 * unequal: the one state this whole script exists to avoid creating by accident.
 *
 * An HTTP status is an ANSWER and is returned, never retried. A 401 retried
 * twenty times is a 401 twenty times, and the caller can read it.
 */
async function http(url, options = {}, attempts = 10) {
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
 * A service token for `wallet`, carrying the two grants this seeding needs.
 *
 * `wallet` is the honest principal rather than a convenient one: it is the
 * service that labels deposit addresses `deposit:<userId>`
 * (`wallet/src/deposits.ts:284`) and that debits the ledger's custody account
 * when one confirms (`:627`). Seeding is that flow, done by hand.
 */
async function walletToken() {
  const signin = await http(`${IDENTITY}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ identifier: ADMIN_EMAIL, password: ADMIN_PASSWORD }),
  });
  const admin = signin.body && signin.body.accessToken;
  if (!admin) throw new Error(`could not sign in as ${ADMIN_EMAIL} — run ./scripts/estate-bootstrap.sh`);
  const minted = await http(`${IDENTITY}/service-tokens`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${admin}` },
    body: JSON.stringify({ service: 'wallet', scopes: ['indexer:write', 'indexer:read', 'ledger:post', 'ledger:read'] }),
  });
  if (!minted.body || !minted.body.token) {
    throw new Error(`identity would not mint a wallet token: ${minted.status} ${JSON.stringify(minted.body).slice(0, 200)}`);
  }
  return { admin, wallet: minted.body.token };
}

/** The subject of the liability side. One dedicated account, not a real person. */
async function seedUser() {
  const email = 'ember-seed@example.test';
  const password = 'correct-horse-battery-staple-42';
  await http(`${IDENTITY}/auth/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, handle: 'emberseed', password }),
  });
  const signin = await http(`${IDENTITY}/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ identifier: email, password }),
  });
  const token = signin.body && signin.body.accessToken;
  if (!token) throw new Error('could not sign in as the seed subject');
  const me = await http(`${IDENTITY}/auth/me`, { headers: { authorization: `Bearer ${token}` } });
  const id = me.body && me.body.user && me.body.user.id;
  if (!id) throw new Error('could not resolve the seed subject id');
  return id;
}

/**
 * A wallet token that is still valid, minting a new one before the old expires.
 *
 * **A service token lives 600 seconds** (identity/src/tokens.ts:28) and the wait
 * for the confirmed aggregate below can run for twenty minutes. Holding one
 * token across that would produce a 401 in the middle of a wait — which the
 * custody route reports the same way it reports every other refusal, so the
 * script would sit there reading "not yet observable" about an expired
 * credential. That is exactly the confusion `estate-verify.sh` already calls out
 * beside `LEDGER_SERVICE_TOKEN`: an auth failure wearing a chain failure's
 * clothes. Eight minutes is comfortably inside the TTL.
 */
let cached = { token: null, at: 0 };
async function freshWalletToken() {
  if (cached.token && Date.now() - cached.at < 8 * 60_000) return cached.token;
  const { wallet } = await walletToken();
  cached = { token: wallet, at: Date.now() };
  return wallet;
}

async function custodyTotal() {
  const token = await freshWalletToken();
  return http(`${INDEXER}/v1/custody/ember/testnet/total`, {
    headers: { authorization: `Bearer ${token}` },
  });
}

// ── main ─────────────────────────────────────────────────────────────────────
async function main() {
  const statusOnly = process.argv.includes('--status');

  const chainId = Number(hexToBig(await rpc('eth_chainId')));
  if (chainId !== 7412) {
    bad(`the node at ${RPC} is chain ${chainId}, not 7412 — that is not the chain the estate indexes`);
    return 1;
  }
  const head = Number(hexToBig(await rpc('eth_blockNumber')));
  ok(`chain 7412 at height ${head}`);

  const accounts = deriveAccounts(SEED_PHRASE, AMOUNTS.length);
  const targets = accounts.map((a, i) => ({ address: a.address, want: AMOUNTS[i], label: LABEL(i) }));
  const wanted = AMOUNTS.reduce((a, b) => a + b, 0n);

  console.log('\n── the custody set ──────────────────────────────────────────────────────');
  for (const t of targets) {
    const have = hexToBig(await rpc('eth_getBalance', [t.address, 'latest']));
    t.have = have;
    note(`${t.address}  ${t.label}  holds ${ember(have)} / wants ${ember(t.want)} EMBER`);
  }

  const wallet = await freshWalletToken();
  ok('identity minted a wallet token carrying indexer:write and ledger:post');

  if (!statusOnly) {
    // ── fund ───────────────────────────────────────────────────────────────
    // Idempotent by TARGET BALANCE, not by "have I run before": a re-run tops up
    // a short address and does nothing to a correct one. A script that funded a
    // fixed amount every time would move the chain side away from the ledger
    // side on its second run, and the freeze that followed would be this
    // script's fault rather than a finding.
    const short = targets.filter((t) => t.have < t.want);
    if (short.length === 0) {
      ok('every seed address already holds its target — nothing to fund');
    } else {
      const key = ownerKey();
      const balance = hexToBig(await rpc('eth_getBalance', [key.address, 'latest']));
      const need = short.reduce((a, t) => a + (t.want - t.have), 0n);
      if (balance < need + WEI) {
        bad(`the miner holds ${ember(balance)} EMBER and ${ember(need)} is needed — let it mine longer`);
        return 1;
      }
      // Sequential, not concurrent: the nonce is read per transfer and two
      // in-flight transfers from one key would collide on it.
      for (const t of short) {
        const hash = await transfer(key, t.address, t.want - t.have, chainId);
        ok(`funded ${t.address} with ${ember(t.want - t.have)} EMBER (${hash.slice(0, 18)}…)`);
      }
    }

    // ── register ───────────────────────────────────────────────────────────
    console.log('\n── registering them as custody, which is what makes them countable ──────');
    for (const t of targets) {
      const res = await http(`${INDEXER}/v1/watch/ember/testnet/${t.address}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${wallet}` },
        body: JSON.stringify({ label: t.label }),
      });
      if (res.status === 202) ok(`watching ${t.address} as ${t.label}`);
      else bad(`indexer refused to watch ${t.address}: ${res.status} ${JSON.stringify(res.body).slice(0, 160)}`);
    }
  }

  // ── wait for the observation ─────────────────────────────────────────────
  //
  // 60 confirmations. The aggregate reads at `head − 59`, so a transfer is
  // invisible to it until then — and the route says WHICH refusal it is, so the
  // wait below reports a reason rather than a spinner.
  console.log('\n── the confirmed aggregate, at EMBER\'s published depth of 60 ────────────');
  let observed = null;
  for (let i = 0; i < 240; i++) {
    const res = await custodyTotal();
    if (res.status === 200 && res.body && typeof res.body.total === 'string') {
      const total = BigInt(res.body.total);
      if (total === wanted || statusOnly) {
        observed = res.body;
        break;
      }
      if (i % 12 === 0) {
        note(`observed ${ember(total)} of ${ember(wanted)} EMBER at block ${res.body.observedAtBlock} — waiting for depth`);
      }
    } else if (i % 12 === 0) {
      const code = res.body && res.body.error && res.body.error.code;
      note(`not yet observable: ${res.status} ${code || ''} — waiting`);
    }
    await new Promise((r) => setTimeout(r, 5_000));
  }
  if (!observed) {
    bad(`the confirmed aggregate never reached ${ember(wanted)} EMBER. The chain may not be mining.`);
    return 1;
  }
  ok(`Σ confirmed custody = ${ember(BigInt(observed.total))} EMBER over ${observed.addresses} addresses, `
    + `read at block ${observed.observedAtBlock} (head ${observed.headHeight}, depth ${observed.requiredConfirmations})`);

  if (statusOnly) return failures === 0 ? 0 : 1;

  // ── credit the ledger with the SAME number ───────────────────────────────
  //
  // One entry per address, keyed on the address, so a re-run replays rather than
  // double-posts — and so that a single address's credit can be corrected
  // without unwinding the set. Debit custody's EMBER asset account, credit a
  // subject's liability: Σ debits = Σ credits, which is all the constraint asks,
  // and the custody side is what `reconcileAsset` sums.
  console.log('\n── crediting the ledger with exactly what the chain shows ───────────────');
  const subject = await seedUser();
  const posting = await freshWalletToken();
  for (const t of targets) {
    const amount = t.want.toString();
    const entry = {
      kind: 'deposit_credited',
      originatingService: 'wallet',
      actor: 'service:wallet',
      idempotencyKey: `ember-seed:${t.address}:${amount}`,
      description: `EMBER testnet custody seed ${t.label}`,
      postings: [
        { direction: 'debit', amount, assetCode: 'EMBER', sequence: 0,
          account: { subject: 'custody', assetCode: 'EMBER', purpose: 'available', type: 'asset' } },
        { direction: 'credit', amount, assetCode: 'EMBER', sequence: 1,
          account: { subject: `user:${subject}`, assetCode: 'EMBER', purpose: 'available', type: 'liability' } },
      ],
    };
    const res = await http(`${LEDGER}/entries`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${posting}` },
      body: JSON.stringify(entry),
    });
    if (res.status === 201) ok(`posted ${ember(t.want)} EMBER into custody for ${t.label}`);
    else if (res.status === 200) ok(`${t.label} was already credited — replayed, not double-posted`);
    else bad(`ledger refused the credit for ${t.label}: ${res.status} ${JSON.stringify(res.body).slice(0, 200)}`);
  }

  console.log('\n── what happens next ────────────────────────────────────────────────────');
  console.log('  The reconciliation job is 15-minutely and leased (ledger/src/jobs.ts:108).');
  console.log('  To make it run now, and to see it go clean:');
  console.log('');
  console.log('      ./scripts/estate-verify.sh        # the EMBER section drives it');
  console.log('');
  return failures === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => { console.error(`  ${red('FAIL')} ${err.message}`); process.exit(1); },
);
