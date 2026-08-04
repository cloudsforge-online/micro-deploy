/**
 * Seed micro-foresight: nine real questions, and a decision about five test artefacts.
 *
 * ── WHAT MAKES THIS IDEMPOTENT ───────────────────────────────────────────────
 *
 * `POST /markets` has NO idempotency key — the only route in this service that
 * takes one is `/deploy` (`foresight/src/server.ts:1033-1039`), and a double
 * POST to `/markets` therefore creates two drafts. So this is check-then-create,
 * and the discriminator is the QUESTION TEXT.
 *
 * `questionHash` would be the more precise key — it is a keccak over the whole
 * question document and is returned on every view (`markets.ts:232-244`) — but it
 * is deliberately NOT used here, because it covers `closeTime` too. A seeder
 * keyed on it would create a second copy of the same question every time a close
 * date was edited, which is exactly the duplicate a re-run must not make. The
 * question text is the thing a reader would call "the same market".
 *
 * Everything after creation is driven off the market's own `status`, so a second
 * run finds every market already `open` and does nothing at all. That is the
 * property being claimed, and the counts before/after prove it rather than this
 * comment.
 *
 * ── THE HOUSE SEED, AND WHY NOTHING IS STAKED ────────────────────────────────
 *
 * `docs/ecosystem/21-engagement-treasury.md` §5 permits exactly one form of
 * platform money in a market: symmetric across all outcomes, at open only, and
 * disclosed on the surface as the platform's. micro-foresight implements it —
 * `houseSeedPerOutcomeWei` on `POST /markets/:id/approve`, gated on a policy in
 * admin-api, refusing to open until the mirror shows the exact symmetric
 * position, and rendering "CloudsForge seeded this pool with X EMBER so early
 * odds exist" on the market page (`foresight/src/houseseed.ts`).
 *
 * **This seeder does not use it, and the reason is a fact about the deployment
 * rather than a preference.** `FORESIGHT_HOUSE_ADDRESS` is not set in
 * `compose/docker-compose.estate.yml` — the only mention is a comment — so an
 * approval carrying a seed answers 409 `house_address_unconfigured`. Behind that
 * sits the harder one: the seed is staked from a funded platform wallet, and the
 * engagement treasury is funded by mined EMBER converted through the front door.
 * Manufacturing that balance to make a pool look deep would be the invisible
 * house position §2 refuses in those words.
 *
 * So the markets open with empty pools and honest odds, and the gap is reported.
 * An empty pool is a true statement about a new market. A seeded one that nobody
 * paid for is not.
 *
 * ── AND NOTHING PRETENDS TO BE A CROWD ───────────────────────────────────────
 *
 * No user is registered by this file, no stake is placed, and no position is
 * opened. Every market below is created and approved by the estate's own named
 * operator account, which is what the surface shows.
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'

import {
  ROOT,
  COMPOSE,
  api,
  ok,
  bad,
  skip,
  note,
  head,
  sleep,
  serviceToken,
} from './lib.mjs'
import {
  FORESIGHT_QUESTIONS,
  TEST_ARTEFACT_VOID_REASON,
  isTestArtefact,
} from './foresight-questions.mjs'

const require = createRequire(import.meta.url)

const CHAIN_ID = Number(process.env.EMBER_CHAIN_ID || 7412)
const RPC_URL = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545'
const HEARTH = process.env.HEARTH_REPO || path.resolve(ROOT, '../hearth')
const EMBER_HOME =
  process.env.EMBER_HOME || path.join(process.env.HOME || '', '.cloudsforge/ember-testnet')
const MINER_DATA = process.env.EMBER_MINER_DATA || path.join(EMBER_HOME, 'miner')
const TOKENS_FILE = process.env.TOKENS_FILE || 'compose/estate/tokens.env'

/** `FORESIGHT_DEPLOY_GAS_LIMIT`, and the service bids DOUBLE the quoted price against it. */
const DEPLOY_GAS_LIMIT = 3_000_000n

/* ── the chain, which is optional ──────────────────────────────────────────── */

/**
 * Load hearth's transaction codec and the owner's mining key.
 *
 * Returns `null` rather than throwing when either is absent. A machine with no
 * testnet can still seed every question, approve it, and say plainly that it
 * could not open it — which is a far more useful outcome than a stack trace, and
 * is exactly what will happen in CI.
 */
function chainOrNull() {
  try {
    const TX = require(path.join(HEARTH, 'node/src/chain/transaction.js'))
    const keyFile = path.join(MINER_DATA, 'coinbase-key.json')
    if (!fs.existsSync(keyFile)) return null
    const raw = JSON.parse(fs.readFileSync(keyFile, 'utf8'))
    return {
      TX,
      key: {
        priv: Buffer.from(String(raw.privateKey).replace(/^0x/, ''), 'hex'),
        address: raw.address,
      },
    }
  } catch {
    return null
  }
}

async function rpc(method, params = [], attempts = 10) {
  let last
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(RPC_URL, {
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
      await sleep(1_500)
    }
  }
  throw new Error(`${method}: no answer from ${RPC_URL} — ${last?.message}`)
}

const big = (h) => BigInt(h)
const ember = (w) => (Number(w) / 1e18).toFixed(6)

/**
 * One legacy (type 0) transfer, awaited to its receipt.
 *
 * Legacy because this chain has no fee market — a type-2 transaction signed
 * against zero base fees is one the chain cannot execute. Same shape custody
 * signs for foresight, for the same reason.
 */
async function send(chain, { to, value }) {
  const nonce = big(await rpc('eth_getTransactionCount', [chain.key.address, 'pending']))
  const gasPrice = big(await rpc('eth_gasPrice'))
  const signed = chain.TX.sign(
    { nonce, gasPrice, gasLimit: 21_000n, to, value, data: Buffer.alloc(0) },
    chain.key.priv,
    { chainId: CHAIN_ID },
  )
  const hash = await rpc('eth_sendRawTransaction', [
    '0x' + chain.TX.encode(signed).toString('hex'),
  ])
  for (let i = 0; i < 120; i++) {
    const receipt = await rpc('eth_getTransactionReceipt', [hash])
    if (receipt) {
      if (big(receipt.status) !== 1n) throw new Error(`funding transaction ${hash} REVERTED`)
      return hash
    }
    await sleep(1_000)
  }
  throw new Error(`funding transaction ${hash} was never mined`)
}

/* ── the ten-minute token, and the job that never re-arms ──────────────────── */

/**
 * Re-mint `FORESIGHT_SERVICE_TOKEN` and recreate the container.
 *
 * ── ONE ACT, TWO DEFECTS, AND NEITHER IS PAPERED OVER ────────────────────────
 *
 *   1. **The ten-minute cliff.** `foresight/src/index.ts:101` is `const token =
 *      () => env.serviceToken`: the value is PRESENTED, so it must be a JWT, and
 *      identity issues those with a 600s TTL. Both custody calls a deploy needs
 *      come from leased BACKGROUND jobs, so a seeding run longer than ten
 *      minutes crosses the cliff mid-flight and every deploy stalls with a 401.
 *
 *   2. **The recurring job that runs once.** Every foresight handler re-enqueues
 *      its own `(kind, key)` from INSIDE the handler, and the runner deletes the
 *      row on success AFTER the handler returns — so the self-enqueue collides
 *      with the row being run, does nothing, and is then deleted. Every
 *      recurring job in this service runs exactly once per process start.
 *      `foresight-market-journey.mjs:225-256` diagnoses this at length and works
 *      around it by INSERTing into the `jobs` table directly.
 *
 * This does not write that SQL. A recreate solves both at once: the token is
 * fresh and the process starts, which arms every recurring job the honest way.
 * It is also what an operator would actually do. Both defects belong to
 * micro-foresight — `ServiceTokenProvider` for the first, `rescheduleRecurring`
 * off the runner's completed event for the second — and this function is a
 * workaround in the open, not a fix.
 */
async function refreshForesight(userToken, why) {
  note(`recreating foresight: ${why}`)
  const token = await serviceToken(userToken, 'foresight', [
    'admin:read',
    'custody:address:create',
    'custody:sign:deployer',
    'indexer:read',
    'indexer:write',
    'ledger:post',
    'policy:decide',
  ])
  const file = path.join(ROOT, TOKENS_FILE)
  let lines = []
  try {
    lines = fs.readFileSync(file, 'utf8').split('\n')
  } catch {
    bad(`${TOKENS_FILE} is missing — run ./scripts/estate-bootstrap.sh first`)
    return false
  }
  const next = lines.filter((l) => !/^FORESIGHT_SERVICE_TOKEN=/.test(l))
  next.push(`FORESIGHT_SERVICE_TOKEN=${token}`)
  fs.writeFileSync(file, next.filter((l, i) => l !== '' || i < next.length - 1).join('\n') + '\n')

  const r = spawnSync(
    'docker',
    ['compose', '--env-file', TOKENS_FILE, '-f', COMPOSE, 'up', '-d', '--wait', 'foresight'],
    { cwd: ROOT, encoding: 'utf8' },
  )
  if (r.status !== 0) {
    bad(`could not recreate foresight: ${(r.stderr || '').slice(0, 200)}`)
    return false
  }
  // The recreate returns when the container is healthy; the job runner starts a
  // beat later. A short settle is honest and cheaper than a flaky first poll.
  await sleep(4_000)
  return true
}

/* ── the state of the registry ─────────────────────────────────────────────── */

async function allMarkets() {
  const { body } = await api('foresight', '/markets?limit=200', { expect: 200 })
  return body.markets ?? []
}

/** The custody deployer minted for this market, off the operator surface. */
async function deployerFor(marketId, userToken) {
  const { body } = await api('custody', '/v1/admin/keys', { token: userToken, expect: 200 })
  const key = (body.keys || []).find(
    (k) => k.userId === 'foresight' && k.orderId === marketId && k.purpose === 'deployer',
  )
  return key ? key.address : null
}

/* ── the five test artefacts ───────────────────────────────────────────────── */

/**
 * Void what never reached a chain; leave what did, and say why it was left.
 *
 * The rule is `contractAddress`, not a list of ids, because `POST
 * /markets/:id/void` refuses an on-chain market with 409 `on_chain` by design —
 * "void it through the oracle so the chain and the registry agree". The oracle
 * path needs the market to be `closed`, which needs it to have been `open`, and
 * two of these never opened. There is therefore NO API path that voids them.
 * That is a finding about micro-foresight, and it is reported rather than
 * routed around: reaching past the service into its database to delete a market
 * would destroy the evidence that the estate produced it.
 */
async function handleTestArtefacts(markets, userToken) {
  const artefacts = markets.filter((m) => isTestArtefact(m.question))
  if (artefacts.length === 0) {
    note('no test artefacts in the registry')
    return
  }
  for (const m of artefacts) {
    if (m.status === 'void') {
      ok(`artefact ${m.id.slice(0, 8)} is already void — nothing to do`)
      continue
    }
    if (m.contractAddress) {
      skip(
        `artefact ${m.id.slice(0, 8)} (${m.status}) LEFT AS IT IS: it is a real contract at ` +
          `${m.contractAddress.slice(0, 10)}… and /void answers 409 on_chain by design. The oracle ` +
          `path needs it closed, which needs it opened. No API voids it, so it stays.`,
      )
      continue
    }
    const res = await api('foresight', `/markets/${m.id}/void`, {
      method: 'POST',
      token: userToken,
      body: { reason: TEST_ARTEFACT_VOID_REASON },
    })
    if (res.status === 200) {
      ok(`artefact ${m.id.slice(0, 8)} (${m.status}, no contract) voided, with the reason recorded`)
    } else {
      bad(`could not void artefact ${m.id.slice(0, 8)}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
}

/* ── the nine ─────────────────────────────────────────────────────────────── */

/** Create any question not already in the registry. Returns every seeded market, by question. */
async function createMissing(existing, userToken) {
  const byQuestion = new Map(existing.map((m) => [m.question, m]))
  const seeded = []
  for (const q of FORESIGHT_QUESTIONS) {
    const found = byQuestion.get(q.question)
    if (found) {
      seeded.push(found)
      continue
    }
    if (new Date(q.closeTime).getTime() <= Date.now()) {
      // foresight refuses a close time in the past (`markets.ts:257-259`) and it
      // is right to. Saying which question aged out is more useful than a 400.
      skip(`"${q.question.slice(0, 56)}…" — its close time has passed; not created`)
      continue
    }
    const res = await api('foresight', '/markets', {
      method: 'POST',
      token: userToken,
      body: {
        question: q.question,
        resolutionCriteria: q.resolutionCriteria,
        category: q.category,
        resolutionSourceKind: q.resolutionSourceKind,
        resolutionSourceRef: q.resolutionSourceRef,
        closeTime: q.closeTime,
        disputeWindowSeconds: q.disputeWindowSeconds,
        feeBps: q.feeBps,
      },
    })
    if (res.status !== 201) {
      bad(`create "${q.question.slice(0, 48)}…" → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
      continue
    }
    ok(`draft ${res.body.market.id.slice(0, 8)} [${q.category}] ${q.question.slice(0, 58)}…`)
    seeded.push(res.body.market)
  }
  return seeded
}

/** A draft becomes approved. The one act the state machine insists a person does. */
async function approveDrafts(markets, userToken) {
  for (const m of markets) {
    if (m.status !== 'draft') continue
    const res = await api('foresight', `/markets/${m.id}/approve`, {
      method: 'POST',
      token: userToken,
      // Deliberately no `houseSeedPerOutcomeWei` — see this file's header.
      body: {},
    })
    if (res.status === 200) {
      m.status = 'approved'
      ok(`approved ${m.id.slice(0, 8)} — by operator, recorded as approved_by`)
    } else {
      bad(`approve ${m.id.slice(0, 8)} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
}

/**
 * Approved → on chain → open, for every market that is not there yet.
 *
 * Done in PHASES across all markets rather than one market at a time, and that
 * is not tidiness. The service token lives 600 seconds and the deploys are
 * driven from leased jobs; nine markets taken one at a time through a
 * submit-fund-poll-open cycle would cross the cliff halfway down the list.
 * Submitting all nine, funding all nine, then polling all nine keeps the whole
 * chain phase inside one token's life on a chain this size.
 */
async function deployAndOpen(markets, userToken, chain) {
  const pending = markets.filter((m) => m.status === 'approved')
  if (pending.length === 0) {
    ok('every seeded market is already open or beyond — nothing to deploy')
    return
  }
  if (!chain) {
    skip(
      `${pending.length} market(s) approved but NOT opened: no EMBER testnet reachable from here ` +
        `(no mining key at ${MINER_DATA}, or no hearth checkout at ${HEARTH}). A market cannot open ` +
        `until its contract is on chain, so they stay approved and invisible to the browse page.`,
    )
    return
  }

  let chainId
  try {
    chainId = Number(big(await rpc('eth_chainId')))
  } catch (err) {
    skip(`${pending.length} market(s) approved but NOT opened: the chain did not answer — ${err.message}`)
    return
  }
  if (chainId !== CHAIN_ID) {
    bad(`chain id ${chainId}, expected ${CHAIN_ID} — refusing to fund anything on it`)
    return
  }

  const balance = big(await rpc('eth_getBalance', [chain.key.address, 'latest']))
  const gasPrice = big(await rpc('eth_gasPrice'))
  // The service bids DOUBLE the quoted price against its gas limit
  // (`foresight/src/evm.ts:334`), and the funding gate is `bid * gasLimit`. A
  // deployer funded at the QUOTE sits in `awaiting_funds` for ever.
  const needed = gasPrice * 2n * DEPLOY_GAS_LIMIT
  const perMarket = (needed * 3n) / 2n
  const total = perMarket * BigInt(pending.length)
  if (balance < total) {
    skip(
      `${pending.length} market(s) approved but NOT opened: the funding address holds ` +
        `${ember(balance)} EMBER and this needs ${ember(total)}.`,
    )
    return
  }
  note(
    `funding address ${chain.key.address} holds ${ember(balance)} EMBER; ` +
      `${ember(perMarket)} per deployer (the service requires ${ember(needed)} — bid, not quote)`,
  )

  // ── phase 1: submit every deploy ───────────────────────────────────────────
  for (const m of pending) {
    const res = await api('foresight', `/markets/${m.id}/deploy`, {
      method: 'POST',
      token: userToken,
      body: {},
      // The market id is the natural key: a retry of THIS deploy is the same
      // deploy, and the key is required rather than defaulted because "the loss
      // from a double-apply here is not a double payment, it is two pools for
      // one question".
      idempotencyKey: `estate-seed-deploy-${m.id}`,
    })
    if (res.status === 202) ok(`deploy accepted for ${m.id.slice(0, 8)} (202) — it reaches no chain from the request`)
    else bad(`deploy ${m.id.slice(0, 8)} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
  }

  // ── phase 2: fund each per-market deployer custody minted ──────────────────
  const funded = new Set()
  for (let round = 0; round < 40 && funded.size < pending.length; round++) {
    for (const m of pending) {
      if (funded.has(m.id)) continue
      const deployer = await deployerFor(m.id, userToken)
      if (!deployer) continue
      try {
        await send(chain, { to: deployer, value: perMarket })
        funded.add(m.id)
        ok(`funded the deployer for ${m.id.slice(0, 8)} with ${ember(perMarket)} EMBER`)
      } catch (err) {
        // A refusal here is the estate working, not the seeder failing. EMBER can
        // be frozen by reconciliation, and a seeder that retried around a freeze
        // would be defeating the control that exists to stop exactly that.
        bad(`funding ${m.id.slice(0, 8)} was refused: ${err.message.slice(0, 160)}`)
        funded.add(m.id)
      }
    }
    if (funded.size < pending.length) await sleep(2_000)
  }

  // ── phase 3: wait for the chain to carry the code, then open ───────────────
  const deadline = Date.now() + 9 * 60_000
  let refreshedAt = Date.now()
  const opened = new Set()
  while (Date.now() < deadline && opened.size < pending.length) {
    // Nine minutes is longer than the token lives, so it is renewed on the way
    // through — which also restarts the process and re-arms the deploy job.
    if (Date.now() - refreshedAt > 7 * 60_000) {
      await refreshForesight(userToken, 'the token lives 600s and the deploy runs from a leased job')
      refreshedAt = Date.now()
    }
    for (const m of pending) {
      if (opened.has(m.id)) continue
      const { body } = await api('foresight', `/markets/${m.id}`, { expect: 200 })
      const current = body.market
      if (!current) continue
      if (current.status === 'open' || current.status === 'closed') {
        opened.add(m.id)
        m.status = current.status
        ok(`${m.id.slice(0, 8)} is ${current.status} at ${current.contractAddress}`)
        continue
      }
      if (current.status === 'void') {
        opened.add(m.id)
        bad(`${m.id.slice(0, 8)} was voided while deploying: ${current.voidReason}`)
        continue
      }
      if (!current.contractAddress) continue
      const code = await rpc('eth_getCode', [current.contractAddress, 'latest'])
      if (!code || code === '0x') continue
      const res = await api('foresight', `/markets/${m.id}/open`, {
        method: 'POST',
        token: userToken,
        body: {},
      })
      if (res.status === 200) {
        opened.add(m.id)
        m.status = 'open'
        ok(`OPEN ${m.id.slice(0, 8)} at ${current.contractAddress} — the service confirmed the mined address`)
      } else if (res.status !== 409) {
        // 409 is expected until the registry's own deploy_state says `deployed`.
        bad(`open ${m.id.slice(0, 8)} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
        opened.add(m.id)
      }
    }
    if (opened.size < pending.length) await sleep(4_000)
  }

  const stuck = pending.filter((m) => !opened.has(m.id))
  for (const m of stuck) {
    skip(
      `${m.id.slice(0, 8)} is approved and funded but never reached the chain in nine minutes — ` +
        `it stays approved, and does not appear on the browse page until it opens.`,
    )
  }
}

/** Is the disclosed house seed configured at all? Reported, never worked around. */
function reportHouseSeed() {
  let configured = false
  try {
    const text = fs.readFileSync(path.join(ROOT, COMPOSE), 'utf8')
    configured = /^\s*FORESIGHT_HOUSE_ADDRESS:\s*\S/m.test(text)
  } catch {
    /* reported as unconfigured, which is the safe reading */
  }
  if (configured) {
    skip(
      'FORESIGHT_HOUSE_ADDRESS is configured, but no house seed was staked: the engagement ' +
        'treasury holds nothing, and a pool seeded with money nobody paid for is the invisible ' +
        'house position 21-engagement-treasury.md §2 refuses.',
    )
  } else {
    skip(
      'no disclosed house seed: FORESIGHT_HOUSE_ADDRESS is unset in the compose file, so an ' +
        'approval carrying houseSeedPerOutcomeWei answers 409 house_address_unconfigured. The ' +
        'markets open with empty pools and honest odds — which is a true statement about a new ' +
        'market, and the only alternative available was a fake one.',
    )
  }
}

/* ── the domain ───────────────────────────────────────────────────────────── */

export async function seedForesight(userToken) {
  head('foresight — real questions, and a decision about the test artefacts')

  const before = await allMarkets()
  note(`${before.length} market(s) in the registry before seeding`)

  await handleTestArtefacts(before, userToken)

  const seeded = await createMissing(before, userToken)
  await approveDrafts(seeded, userToken)

  const chain = chainOrNull()
  await deployAndOpen(seeded, userToken, chain)

  reportHouseSeed()

  const after = await allMarkets()
  const open = after.filter((m) => m.status === 'open').length
  const real = after.filter((m) => !isTestArtefact(m.question)).length
  ok(`registry now holds ${after.length} market(s): ${real} real, ${open} open on the browse page`)
}
