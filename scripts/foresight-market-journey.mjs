#!/usr/bin/env node
/* A prediction market, end to end, on the live EMBER testnet.
 *
 *   cd deploy
 *   node scripts/foresight-market-journey.mjs
 *   node scripts/foresight-market-journey.mjs --close-in 420   # seconds until close
 *
 * ── WHY THIS EXISTS, AND WHY IT IS NOT PART OF estate-verify.sh ───────────────
 *
 * `estate-verify.sh` proves seams: a request crosses a boundary and the answer is
 * the right shape. That is the correct thing for 212 checks to do and it is not
 * what this repository most needed proving. micro-foresight is the only service
 * in the estate whose product IS a contract on a chain — `ForesightMarket.sol`
 * takes a stranger's EMBER from `msg.sender` with no allowlist and pays it back
 * to `msg.sender` — and a container answering `/readyz` says nothing whatever
 * about whether that works. Everything up to the broadcast can be right while the
 * bytecode reverts, the deployer is unfunded, custody refuses the payload shape,
 * or the oracle cannot reach the market it is resolving.
 *
 * So this drives the whole life of one market against the real chain: draft,
 * approve, deploy, open, two stakes from two different addresses, close, resolve
 * through custody's oracle, and a claim that moves EMBER back to a winner. It
 * ends by comparing the winner's balance change against the contract's own
 * parimutuel arithmetic, which is the only assertion here that could not have
 * been made by reading.
 *
 * It is separate from `estate-verify.sh` because it takes MINUTES rather than
 * seconds — a market cannot be resolved before its close time, and the close time
 * is chain time, not wall time — and because it spends real testnet gas. A check
 * that costs five minutes does not belong in the one an operator runs constantly.
 *
 * ── VERIFICATION IS ON, AND THAT IS THE POINT ────────────────────────────────
 *
 * Every estate call goes through the GATEWAY over TLS with the estate CA
 * supplied, never `rejectUnauthorized: false` and never a loopback port that
 * skips the gateway. This estate's signature defect — found five separate times
 * in one day — is a check that passes because it stopped checking: `curl -k` 183
 * times, `ignoreHTTPSErrors: true`, and a compose comment calling it "correct for
 * loopback", while the gateway served `CN=TRAEFIK DEFAULT CERT` and every real
 * browser fetch failed. A script that verified the certificate would have caught
 * it on the first run.
 *
 * `NODE_EXTRA_CA_CERTS` is set by re-execing ourselves once, because Node reads
 * it at startup and there is no API to add a root afterwards. If the CA file is
 * missing this script FAILS rather than falling back to an unverified request.
 *
 * ── THE TEN-MINUTE TOKEN, WHICH THIS SCRIPT WILL WALK INTO ───────────────────
 *
 * `FORESIGHT_SERVICE_TOKEN` is presented verbatim by `foresight/src/index.ts:101`
 * and lives 600 seconds. Both custody calls this journey needs — the deploy and
 * the resolution — are made from LEASED BACKGROUND JOBS, so a journey longer than
 * ten minutes crosses the cliff mid-flight. Rather than pretend otherwise, this
 * script RE-RUNS THE BOOTSTRAP before each of the two custody-dependent phases
 * and says so. When micro-foresight adopts `ServiceTokenProvider` those two calls
 * can be deleted, and their deletion is how you will know it landed.
 *
 * ── KEYS ─────────────────────────────────────────────────────────────────────
 *
 * The funding key is the owner's mining key, read from the miner's data directory
 * exactly as `ember-seed.js` reads it, never printed and never written anywhere.
 * The two stakers' keys are derived from a PUBLISHED phrase — worthless by
 * construction, which is the only kind of key that may appear in a script.
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..')
const CA = process.env.CF_ESTATE_CA || path.join(ROOT, 'gateway/certs/ca.crt')

// ── the CA, before anything else can make a request ──────────────────────────
//
// Node reads NODE_EXTRA_CA_CERTS once, at startup. Setting it here and re-execing
// is the only way to have it apply, and it is preferable to the alternative every
// other verifier in this estate reached for.
if (!fs.existsSync(CA)) {
  console.error(`FAIL: no estate CA at ${CA} — run ./scripts/gateway-cert.sh first.`)
  console.error('      This script will not fall back to an unverified request; that is the defect it exists to avoid.')
  process.exit(1)
}
if (process.env.NODE_EXTRA_CA_CERTS !== CA) {
  const { spawnSync } = await import('node:child_process')
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: { ...process.env, NODE_EXTRA_CA_CERTS: CA },
  })
  process.exit(r.status ?? 1)
}

const require = createRequire(import.meta.url)

// ── configuration ────────────────────────────────────────────────────────────
const APEX = process.env.CF_WEB_APEX || 'cloudsforge.localtest.me'
const FORESIGHT = process.env.FORESIGHT_URL || `https://foresight.${APEX}`
const IDENTITY = process.env.IDENTITY_URL || `https://nimbus.${APEX}`
const CUSTODY = process.env.CUSTODY_URL || `https://vault.${APEX}`
const RPC = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545'
const HEARTH = process.env.HEARTH_REPO || path.resolve(ROOT, '../hearth')
const EMBER_HOME = process.env.EMBER_HOME || path.join(process.env.HOME, '.cloudsforge/ember-testnet')
const MINER_DATA = process.env.EMBER_MINER_DATA || path.join(EMBER_HOME, 'miner')
const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'estate-admin@example.test'
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'correct-horse-battery-staple-42'
// THE CHAIN THIS JOURNEY SIGNS FOR, and it must be derived rather than written.
//
// This was the literal 7412. `CHAIN_ID` reaches `TX.sign(..., { chainId })` at
// :180, so a wrong value here is not a wrong message — it is a transaction bound
// by EIP-155 to a chain the node will refuse, and the refusal arrives as an
// opaque RPC error in the middle of a market deploy. There are two chains now:
// `hearth`/7411 on the mainnet estate and `hearth-testnet`/7412 on the testnet
// one (`hearth/node/src/params.js:37-38`), and `EMBER_HOST_RPC` above defaults to
// 8545, which is the MAINNET seed. `CF_EMBER_NETWORK` is the same variable the
// estate keys its chain `env_file:` on.
const EMBER_NETWORK = process.env.CF_EMBER_NETWORK || 'mainnet'
const CHAIN_ID = { mainnet: 7411, testnet: 7412 }[EMBER_NETWORK]
if (CHAIN_ID === undefined) {
  console.error(`CF_EMBER_NETWORK is "${EMBER_NETWORK}"; known: mainnet, testnet`)
  process.exit(2)
}

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`)
  return i === -1 ? fallback : args[i + 1]
}
/** Seconds from now until the market closes. Long enough to deploy, open and stake in. */
const CLOSE_IN = Number(flag('close-in', '360'))
const SKIP_BOOTSTRAP = args.includes('--no-bootstrap')

const TX = require(path.join(HEARTH, 'node/src/chain/transaction.js'))
const { keccak256 } = require(path.join(HEARTH, 'node/src/crypto/keccak.js'))
const { deriveAccounts } = require(path.join(HEARTH, 'node/src/cli/devnet.js'))

const WEI = 10n ** 18n
const green = (s) => `\x1b[32m${s}\x1b[0m`
const red = (s) => `\x1b[31m${s}\x1b[0m`
let failures = 0
const ok = (s) => console.log(`  ${green('ok')}   ${s}`)
const bad = (s) => { console.log(`  ${red('FAIL')} ${s}`); failures++ }
const note = (s) => console.log(`  ..   ${s}`)
const ember = (w) => (Number(w) / 1e18).toFixed(9)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* ── the chain ─────────────────────────────────────────────────────────────── */

/** One JSON-RPC call, retried on TRANSPORT failure only — `ember-seed.js`'s reasoning verbatim. */
async function rpc(method, params = [], attempts = 20) {
  let last
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(RPC, {
        method: 'POST',
        headers: { 'content-type': 'application/json', connection: 'close' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(10_000),
      })
      const body = await res.json()
      if (body.error) throw new Error(`${method}: ${body.error.message}`)
      return body.result
    } catch (err) {
      if (err instanceof Error && err.message.startsWith(`${method}:`)) throw err
      last = err
      await sleep(2_000)
    }
  }
  throw new Error(`${method}: no answer from ${RPC} after ${attempts} attempts — ${last?.message}`)
}

const big = (h) => BigInt(h)
const selector = (sig) => keccak256(Buffer.from(sig, 'utf8')).subarray(0, 4)
const word = (v) => Buffer.from(BigInt(v).toString(16).padStart(64, '0'), 'hex')
const addressWord = (a) => Buffer.from(a.replace(/^0x/, '').toLowerCase().padStart(64, '0'), 'hex')

/** The owner's mining key. Read, used to sign, never echoed. */
function ownerKey() {
  const file = path.join(MINER_DATA, 'coinbase-key.json')
  if (!fs.existsSync(file)) throw new Error(`no mining key at ${file} — run ./scripts/ember-miner.sh start first`)
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
  return { priv: Buffer.from(String(raw.privateKey).replace(/^0x/, ''), 'hex'), address: raw.address }
}

/**
 * Send one legacy transaction and wait for its receipt.
 *
 * Legacy (type 0) because this chain has no fee market — `hearth/node/src/params.js` documents
 * `eth_feeHistory` as off in v1, and a type-2 transaction signed against zero base fees is one the
 * chain cannot execute. It is the same shape custody signs for foresight, for the same reason.
 */
async function send(key, { to = null, value = 0n, data = Buffer.alloc(0), gasLimit = 21_000n }) {
  const nonce = big(await rpc('eth_getTransactionCount', [key.address, 'pending']))
  const gasPrice = big(await rpc('eth_gasPrice'))
  const signed = TX.sign({ nonce, gasPrice, gasLimit, to, value, data }, key.priv, { chainId: CHAIN_ID })
  const hash = await rpc('eth_sendRawTransaction', ['0x' + TX.encode(signed).toString('hex')])
  for (let i = 0; i < 180; i++) {
    const receipt = await rpc('eth_getTransactionReceipt', [hash])
    if (receipt) {
      if (big(receipt.status) !== 1n) throw new Error(`transaction ${hash} REVERTED`)
      return { hash, receipt }
    }
    await sleep(1_000)
  }
  throw new Error(`transaction ${hash} was never mined`)
}

const call = (to, data) => rpc('eth_call', [{ to, data: '0x' + data.toString('hex') }, 'latest'])
const balanceOf = async (a) => big(await rpc('eth_getBalance', [a, 'latest']))

/* ── the estate ────────────────────────────────────────────────────────────── */

/**
 * One estate call, through the gateway, with the certificate VERIFIED.
 *
 * There is no `rejectUnauthorized` here and there is no loopback fallback. A TLS failure is
 * reported as a TLS failure, because a verifier that quietly stops verifying is this estate's
 * most expensive recurring defect.
 */
async function api(base, path_, { method = 'GET', body, token, expect, idempotencyKey } = {}) {
  const headers = { accept: 'application/json' }
  if (body !== undefined) headers['content-type'] = 'application/json'
  if (token) headers.authorization = `Bearer ${token}`
  if (idempotencyKey) headers['idempotency-key'] = idempotencyKey
  const res = await fetch(`${base}${path_}`, {
    method,
    headers,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(30_000),
  })
  const text = await res.text()
  let parsed
  try { parsed = JSON.parse(text) } catch { parsed = { raw: text.slice(0, 200) } }
  if (expect && res.status !== expect) {
    throw new Error(`${method} ${base}${path_} → ${res.status} (expected ${expect}): ${text.slice(0, 300)}`)
  }
  return { status: res.status, body: parsed }
}

/**
 * Put a foresight job back on its queue.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THIS STANDS IN FOR A RE-ARM micro-foresight DOES NOT HAVE, AND THE DEFECT WAS FOUND BY
 * RUNNING THIS SCRIPT.** Every one of foresight's handlers re-enqueues its own `(kind, key)` from
 * INSIDE the handler — `jobs.ts:177` for `market.deploy`, `:233` for `market.close`, `:259` for
 * `mirror.sync`, `:291` for `resolution.post`, and the same for `idea.propose` and `fee.report`.
 * `JobRunner` deletes the row on success AFTER the handler returns (`runtime/packages/jobs/src/
 * index.ts:407` → `complete()` → `delete from jobs where id = $1`), and the unique constraint is
 * on `(kind, key)` — so the self-enqueue collides with the row the handler is running, does
 * nothing, and is then deleted. **Every recurring job in this service runs exactly once per
 * process start and never again.**
 *
 * micro-ledger names this exact trap in its own source, which is how the diagnosis was confirmed
 * rather than guessed: "It cannot re-arm itself from inside its own handler: the runner deletes
 * the row on success *after* the handler returns, so a self-enqueue would be deleted a moment
 * later and the schedule would stop. Doing it from the completion event is the only point at which
 * the row is gone." (`ledger/src/jobs.ts:132-137`, `rescheduleRecurring`.) Ledger, wallet,
 * settlement, indexer, mint, market, emberkin, beacon and faucet all have live future-dated rows
 * in their `jobs` tables right now; foresight's table was EMPTY ten minutes after boot.
 *
 * The consequence is not cosmetic. A market whose deployer needs funding reports `awaiting_funds`
 * and is never retried, so it never deploys; a market past its close time is never closed, so it
 * can never be resolved; the mirror syncs once.
 *
 * THE FIX BELONGS TO micro-foresight — `rescheduleRecurring` off the runner's `completed` event,
 * exactly as ledger does it — and this function exists so the chain journey can be proven TONIGHT
 * without editing a repository that is not mine. Delete it when that lands; if the journey still
 * passes, the fix is real.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */
function rearm(kind, key, payload = {}) {
  const { spawnSync } = require('node:child_process')
  const sql =
    `insert into jobs (kind, key, payload) values ` +
    `('${kind}', '${key}', '${JSON.stringify(payload)}'::jsonb) ` +
    // `least` rather than `now()`: a job already scheduled sooner must not be pushed back, and a
    // row currently LOCKED by the runner keeps its lock — this only ever makes work due earlier.
    `on conflict (kind, key) do update set run_at = least(jobs.run_at, now()), updated_at = now()`
  spawnSync(
    'docker',
    ['compose', '-f', 'compose/docker-compose.estate.yml', 'exec', '-T', 'postgres',
     'psql', '-qtA', '-U', 'cloudsforge', '-d', 'foresight', '-c', sql],
    { cwd: ROOT, stdio: 'ignore' },
  )
}

/** Re-mint the ten-minute tokens. See the header: this is a defect being worked around, in the open. */
async function rebootstrap(why) {
  if (SKIP_BOOTSTRAP) { note(`skipping the re-bootstrap (${why}) — --no-bootstrap`); return }
  const { spawnSync } = await import('node:child_process')
  note(`re-running estate-bootstrap.sh: ${why}`)
  const r = spawnSync('./scripts/estate-bootstrap.sh', [], {
    cwd: ROOT,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, CF_WEB_APEX: APEX },
  })
  if (r.status !== 0) throw new Error(`estate-bootstrap.sh failed:\n${r.stdout}\n${r.stderr}`)
  // The recreate at section 6 returns when the containers are healthy, but foresight's job runner
  // starts a beat later. A short settle is honest here and cheaper than a flaky first poll.
  await sleep(3_000)
}

async function login() {
  const { body } = await api(IDENTITY, '/auth/login', {
    method: 'POST',
    body: { identifier: ADMIN_EMAIL, password: ADMIN_PASSWORD },
    expect: 200,
  })
  if (!body.accessToken) throw new Error('identity returned no accessToken')
  return body.accessToken
}

/** The deployer custody minted for this market, off the operator surface. */
async function deployerFor(marketId, utok) {
  const { body } = await api(CUSTODY, '/v1/admin/keys', { token: utok })
  const key = (body.keys || []).find(
    (k) => k.userId === 'foresight' && k.orderId === marketId && k.purpose === 'deployer',
  )
  return key ? key.address : null
}

/* ── the journey ───────────────────────────────────────────────────────────── */

async function main() {
  console.log('── 0. the chain, and the estate, both answering ──────────────────────────')
  const chainId = Number(big(await rpc('eth_chainId')))
  chainId === CHAIN_ID ? ok(`EMBER ${EMBER_NETWORK} chain id ${chainId}, height ${Number(big(await rpc('eth_blockNumber')))}`)
                       : bad(`chain id ${chainId}, expected ${CHAIN_ID}`)
  // `/categories` rather than `/readyz`, and the difference was found by running this: the gateway
  // routes the API RESOURCES on `foresight.<apex>` and deliberately not the health endpoints, so
  // `/readyz` there is the BUNDLE's 404 page. That is correct — a health endpoint is for the
  // orchestrator, not the internet — and `/categories` is a better probe anyway: it is public,
  // unauthenticated by design ("a refusal list behind a token is a refusal list nobody can hold
  // the platform to"), and answering it proves the service and not nginx.
  const cats = await api(FORESIGHT, '/categories')
  Array.isArray(cats.body.categories)
    ? ok(`foresight answering through the gateway, certificate VERIFIED — ${cats.body.categories.length} categories, ${cats.body.refusals.length} refusals`)
    : bad(`foresight /categories: ${JSON.stringify(cats.body).slice(0, 200)}`)

  const owner = ownerKey()
  const ownerBalance = await balanceOf(owner.address)
  ok(`funding address ${owner.address} holds ${ember(ownerBalance)} EMBER`)
  if (ownerBalance < 2n * WEI) { bad('the funding address cannot pay for this journey'); return }

  await rebootstrap('the deploy calls custody from a leased job, and the token lives 600s')
  let utok = await login()
  ok('operator signed in')

  console.log('── 1. a draft market ─────────────────────────────────────────────────────')
  const closeTime = new Date(Date.now() + CLOSE_IN * 1_000)
  const draft = {
    question: `Will the EMBER ${EMBER_NETWORK} (chain ${CHAIN_ID}) be above block height ${Number(big(await rpc('eth_blockNumber'))) + 10} at ${closeTime.toISOString()}?`,
    resolutionCriteria:
      'YES if the chain\'s reported head height at the close time is strictly greater than the height named in the question, read from the node named below. NO otherwise.',
    category: 'protocol_network',
    resolutionSourceKind: 'chain_rpc',
    // A NAMED source, and it is genuinely the one that settles this question. `httpSourceProbe`
    // treats a non-URL reference as unprobeable and therefore resolvable — the operator's own
    // check is the resolution for those — which is the honest reading for an RPC endpoint that is
    // not an HTTP GET surface.
    resolutionSourceRef: `${EMBER_NETWORK === 'mainnet' ? 'hearth-seed' : 'hearth-testnet-seed'} eth_getBlockByNumber(latest) on chain ${CHAIN_ID}`,
    closeTime: closeTime.toISOString(),
    // ZERO, deliberately, and it is the one parameter chosen for this script rather than for a
    // market. The default is 86,400s (foresight/src/env.ts:351) — "long enough that a wrong
    // resolution can be noticed by somebody who was asleep" — and a claim cannot be made until it
    // elapses. A day-long wait would make this journey unrunnable and would prove nothing extra:
    // `_claim` checks `block.timestamp < resolvedAt + disputeWindowSeconds`, which is the same
    // arithmetic at 0 as at 86,400.
    disputeWindowSeconds: 0,
    feeBps: 200,
  }
  const created = await api(FORESIGHT, '/markets', { method: 'POST', body: draft, token: utok, expect: 201 })
  const market = created.body.market
  ok(`draft ${market.id} — closes ${market.closeTime}, fee ${market.feeBps}bps, questionHash ${market.questionHash.slice(0, 18)}…`)

  console.log('── 2. a person approves, and then it may deploy ──────────────────────────')
  await api(FORESIGHT, `/markets/${market.id}/approve`, { method: 'POST', body: {}, token: utok, expect: 200 })
  ok('approved by the operator — the one act the state machine insists on')

  // The key is REQUIRED (foresight/src/server.ts, `idempotencyKeyOf`), and its absence is a 400
  // rather than a default. That is right: "the loss from a double-apply here is not a double
  // payment, it is two pools for one question". The market id is the natural key — a retry of
  // THIS deploy is the same deploy.
  await api(FORESIGHT, `/markets/${market.id}/deploy`, {
    method: 'POST', body: {}, token: utok, expect: 202,
    idempotencyKey: `journey-deploy-${market.id}`,
  })
  ok('deploy accepted (202) — it reaches no chain from the request')

  console.log('── 3. fund the per-market deployer, then watch it land ───────────────────')
  let deployer = null
  for (let i = 0; i < 60 && !deployer; i++) {
    deployer = await deployerFor(market.id, utok)
    if (!deployer) await sleep(1_000)
  }
  if (!deployer) { bad('custody never minted a deployer address for this market'); return }
  ok(`custody minted a deployer for this market: ${deployer}`)

  // 3,000,000 gas (FORESIGHT_DEPLOY_GAS_LIMIT) at the BID, not at the quote. `gasPriceBid`
  // (foresight/src/evm.ts:334) doubles whatever the chain quotes, and the funding gate is
  // `bid * gasLimit` — so funding against the quote leaves the deploy one factor of two short and
  // stuck in `awaiting_funds` for ever. Found by running it: the service logged
  // `required: 6000000000000000` against a 1 gwei quote.
  const gasPrice = big(await rpc('eth_gasPrice'))
  const needed = gasPrice * 2n * 3_000_000n
  const funded = (needed * 3n) / 2n
  await send(owner, { to: deployer, value: funded })
  ok(`funded the deployer with ${ember(funded)} EMBER (the service requires ${ember(needed)} — bid, not quote)`)

  // The address is COMMITTED WITH THE BYTES, before the broadcast — `createAddress(deployer,
  // nonce)` is a total function of two values the service already holds, which is what makes a
  // lost broadcast response produce one contract rather than two. So a non-null `contractAddress`
  // means "signed", never "mined", and this loop waits for the CHAIN to agree.
  let contract = null
  for (let i = 0; i < 180 && !contract; i++) {
    if (i % 4 === 0) rearm('market.deploy', market.id, { marketId: market.id })
    const { body } = await api(FORESIGHT, `/markets/${market.id}`)
    if (body.market?.status === 'void') { bad(`the market was voided while deploying: ${body.market.voidReason}`); return }
    const addr = body.market?.contractAddress
    if (addr) {
      const code = await rpc('eth_getCode', [addr, 'latest'])
      if (code && code !== '0x') {
        contract = addr
        ok(`CONTRACT DEPLOYED at ${addr} — ${(code.length - 2) / 2} bytes of runtime code on chain`)
        break
      }
      if (i % 10 === 0) note(`${addr} is signed and derived; waiting for the chain to carry its code`)
    }
    await sleep(2_000)
  }
  if (!contract) { bad('no contract on chain after six minutes — see `docker logs cloudsforge-estate-foresight-1`'); return }

  console.log('── 4. open for stakes, then two strangers stake ──────────────────────────')
  // The service opens a market only once its own row says `deployed`, which it writes from the
  // RECEIPT — after checking the mined address against the one it derived. That check is the whole
  // point ("a derived address that disagrees with the mined one means the nonce moved under us"),
  // so this waits for it rather than routing around it.
  let opened = false
  for (let i = 0; i < 60 && !opened; i++) {
    rearm('market.deploy', market.id, { marketId: market.id })
    const res = await api(FORESIGHT, `/markets/${market.id}/open`, { method: 'POST', body: {}, token: utok })
    if (res.status === 200) { opened = true; break }
    if (res.status !== 409) { bad(`open → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`); return }
    await sleep(2_000)
  }
  opened ? ok('open — the service confirmed the mined address against the one it derived')
         : bad('the market never reached `deployed` in the registry')
  if (!opened) return

  // Two stakers, from a PUBLISHED phrase: worthless keys, reproducible addresses. Two rather than
  // one because a market with an empty losing pool takes no fee and pays every winner exactly
  // their stake back — true, and it would leave the parimutuel arithmetic untested.
  const [yes, no] = deriveAccounts('cloudsforge foresight journey', 2).map((a) => ({
    address: a.address,
    priv: Buffer.from(a.privateKey.replace(/^0x/, ''), 'hex'),
  }))
  const YES_STAKE = 3n * WEI / 10n   // 0.3 EMBER
  const NO_STAKE = 7n * WEI / 10n    // 0.7 EMBER — distinct and non-round, ember-seed's discipline
  for (const [who, amount] of [[yes, YES_STAKE], [no, NO_STAKE]]) {
    await send(owner, { to: who.address, value: amount + WEI / 10n })
  }
  ok(`funded two staker addresses: ${yes.address} (YES), ${no.address} (NO)`)

  const stakeSel = selector('stake(uint8)')
  const yesTx = await send(yes, { to: contract, value: YES_STAKE, data: Buffer.concat([stakeSel, word(0)]), gasLimit: 200_000n })
  ok(`STAKED ${ember(YES_STAKE)} EMBER on YES — ${yesTx.hash}`)
  const noTx = await send(no, { to: contract, value: NO_STAKE, data: Buffer.concat([stakeSel, word(1)]), gasLimit: 200_000n })
  ok(`STAKED ${ember(NO_STAKE)} EMBER on NO  — ${noTx.hash}`)

  const held = await balanceOf(contract)
  held === YES_STAKE + NO_STAKE
    ? ok(`the contract holds ${ember(held)} EMBER — the pool is the contract's, never the service's`)
    : bad(`the contract holds ${ember(held)}, expected ${ember(YES_STAKE + NO_STAKE)}`)

  console.log('── 5. wait for close — CHAIN time, not wall time ─────────────────────────')
  //
  // `oracleAct` reverts `NotYetClosed` while `block.timestamp < closeTime`, and block timestamps
  // on a 15-second chain are not the clock on this laptop. So the wait is on the head block's own
  // timestamp, which is the only clock the contract can see.
  const closeAt = BigInt(Math.floor(new Date(market.closeTime).getTime() / 1000))
  for (let i = 0; i < 240; i++) {
    const head = await rpc('eth_getBlockByNumber', ['latest', false])
    const ts = big(head.timestamp)
    if (ts >= closeAt) { ok(`chain time ${ts} has passed the close time ${closeAt}`); break }
    if (i % 6 === 0) note(`chain time ${ts}, close at ${closeAt} — ${closeAt - ts}s of chain time to go`)
    await sleep(5_000)
  }

  console.log('── 6. the oracle resolves, by CREATING a contract ────────────────────────')
  await rebootstrap('the resolution calls custody from a leased job, and the token has expired by now')
  utok = await login()

  // The registry-side close, which `planResolution` requires ("a market is resolved after it
  // closes"). It is bookkeeping — the CONTRACT stopped taking stakes by itself at `closeTime` —
  // but it is bookkeeping the `market.close` sweep does, and that sweep is one of the recurring
  // jobs that stopped. See `rearm`.
  let closed = false
  for (let i = 0; i < 60 && !closed; i++) {
    rearm('market.close', 'global')
    await sleep(2_000)
    const { body } = await api(FORESIGHT, `/markets/${market.id}`)
    closed = body.market?.status === 'closed'
  }
  closed ? ok('the registry agrees the market is closed') : bad('the market never closed in the registry')

  // ══ FUND THE ORACLE BEFORE THE RESOLUTION IS PLANNED, NOT AFTER ═════════════════════════════
  // It broadcasts a real creation and pays its own gas, and a freshly derived custody address
  // holds nothing. Funding it after planning is too late and this script proved it: the job ran
  // first, the node answered `insufficient funds for gas * price + value`, and `driveResolution`
  // treats a chain REFUSAL as permanent — `resolutions.state` went to `failed` and
  // `on conflict (market_id) do nothing` means the route will hand back that dead plan for ever.
  // An unfunded oracle is therefore not a delay, it is a market whose winners can never be paid.
  const oracle = (await api(CUSTODY, '/v1/admin/keys', { token: utok })).body.keys.find(
    (k) => k.userId === 'foresight-estate' && k.orderId === 'foresight-estate-oracle-1' && k.purpose === 'deployer',
  )
  if (!oracle) { bad('custody holds no oracle key for foresight — estate-bootstrap.sh §5f did not run'); return }
  const oracleBalance = await balanceOf(oracle.address)
  if (oracleBalance < gasPrice * 2n * 300_000n) {
    await send(owner, { to: oracle.address, value: gasPrice * 2n * 3_000_000n })
    ok(`funded the oracle ${oracle.address} — it held ${ember(oracleBalance)} EMBER and must pay its own gas`)
  } else {
    ok(`the oracle ${oracle.address} already holds ${ember(oracleBalance)} EMBER`)
  }

  const resolved = await api(FORESIGHT, `/markets/${market.id}/resolve`, {
    method: 'POST',
    body: { outcome: 0, rationale: 'The chain head is above the height named in the question, read from the node named in the market.' },
    token: utok,
    expect: 202,
  })
  ok(`resolution planned: action ${resolved.body.resolution.action} (0 = YES), state ${resolved.body.resolution.state}`)

  let resolution = null
  for (let i = 0; i < 180; i++) {
    if (i % 4 === 0) rearm('resolution.post', 'oracle:ember:testnet')
    const { body } = await api(FORESIGHT, `/markets/${market.id}/resolution`, { token: utok })
    resolution = body.resolution
    if (resolution?.state === 'confirmed') break
    if (resolution?.state === 'failed') { bad(`the resolution failed: ${resolution.lastError}`); return }
    await sleep(2_000)
  }
  resolution?.state === 'confirmed'
    ? ok(`RESOLVED ON CHAIN — ${resolution.txHash}, oracle nonce ${resolution.oracleNonce}`)
    : bad(`the resolution never confirmed (state ${resolution?.state}, ${resolution?.lastError ?? 'no error'})`)

  const status = Number(big(await call(contract, selector('status()'))))
  status === 1 ? ok('the CONTRACT says Resolved — read from its own storage, not from the mirror')
               : bad(`the contract's status is ${status} (0 Open, 1 Resolved, 2 Void)`)
  const winner = Number(big(await call(contract, selector('winningOutcome()'))))
  winner === 0 ? ok('winning outcome: YES') : bad(`winning outcome is ${winner}, expected 0`)

  console.log('── 7. a winner claims, and the EMBER moves ───────────────────────────────')
  const owed = big(await call(contract, Buffer.concat([selector('payoutOf(address)'), addressWord(yes.address)])))
  // The contract's own arithmetic, restated here so a disagreement is caught rather than trusted:
  // fee = losing * feeBps / 10_000; the winners divide (total - fee) in proportion to their stake.
  const fee = (NO_STAKE * 200n) / 10_000n
  const expected = ((YES_STAKE) * (YES_STAKE + NO_STAKE - fee)) / YES_STAKE
  owed === expected
    ? ok(`payoutOf(winner) = ${ember(owed)} EMBER, and it matches the parimutuel arithmetic exactly`)
    : bad(`payoutOf(winner) = ${owed}, this script computes ${expected}`)

  const before = await balanceOf(yes.address)
  const claimTx = await send(yes, { to: contract, data: selector('claim()'), gasLimit: 200_000n })
  const after = await balanceOf(yes.address)
  const spentOnGas = big(claimTx.receipt.gasUsed) * gasPrice
  const gained = after - before + spentOnGas
  gained === owed
    ? ok(`CLAIMED — the winner's balance rose by exactly ${ember(owed)} EMBER (net of ${ember(spentOnGas)} gas). ${claimTx.hash}`)
    : bad(`the winner gained ${gained} wei, expected ${owed}`)

  // The fee is a separate, permissionless push. It is exercised because a treasury that cannot be
  // paid is a market that cannot be settled, and nothing else in the estate would find that.
  const treasuryAddr = '0x' + (await call(contract, selector('treasury()'))).slice(-40)
  const treasuryBefore = await balanceOf(treasuryAddr)
  await send(yes, { to: contract, data: selector('settle()'), gasLimit: 200_000n })
  const treasuryAfter = await balanceOf(treasuryAddr)
  treasuryAfter - treasuryBefore === fee
    ? ok(`the settlement fee of ${ember(fee)} EMBER reached the treasury ${treasuryAddr}`)
    : bad(`the treasury gained ${treasuryAfter - treasuryBefore} wei, expected ${fee}`)

  console.log('')
  console.log(`  market   ${market.id}`)
  console.log(`  contract ${contract}`)
}

main().then(
  () => {
    console.log('')
    if (failures === 0) { console.log(green('a market was deployed, staked, resolved and claimed on the live chain.')); process.exit(0) }
    console.log(red(`${failures} failure(s).`)); process.exit(1)
  },
  (err) => { console.error(red(`\nFAIL ${err.message}`)); process.exit(1) },
)
