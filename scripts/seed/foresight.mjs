/**
 * Seed micro-foresight: twenty real questions, and a decision about five test artefacts.
 *
 * ── WHAT MAKES THIS IDEMPOTENT ───────────────────────────────────────────────
 *
 * `POST /markets` has NO idempotency key — the only route in this service that
 * takes one is `/deploy` (`foresight/src/server.ts`), and a double
 * POST to `/markets` therefore creates two drafts. So this is check-then-create,
 * and the discriminator is the QUESTION TEXT.
 *
 * `questionHash` would be the more precise key — it is a keccak over the whole
 * question document and is returned on every view (`markets.ts`) — but it
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
 * engagement treasury is funded by mined EMBER arriving through the front door
 * as an ordinary deposit — this said "converted through the front door" until
 * 2026-08-10, and 21 §3 deleted the "→ conversion to Shards" step it referred to
 * on 2026-08-07. The treasury's own ledger legs are EMBER wei as of admin-api's
 * migration 13 (micro-org#226), so there is no conversion anywhere on this path.
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
  EMBER_NETWORK,
  EMBER_RPC_HOST,
  MINER_DATA,
  MINER_KEY_FILES,
  MINER_PASSPHRASE_FILE,
  TOKENS_FILE,
  ENV_FILES,
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
import { adoptExisting, generateCover, reportImageBackend, studioReachable } from './images.mjs'

const require = createRequire(import.meta.url)

// `EMBER_CHAIN_ID` stays the explicit override; what changed is the FALLBACK,
// which was the literal 7412 and is now derived from the same `CF_EMBER_NETWORK`
// the estate keys its chain `env_file:` on. `EMBER_HOST_RPC` below defaults to
// 8545 — the MAINNET seed, chain 7411 — so a 7412 fallback beside it was a pair
// that could not both be right (`hearth/node/src/params.js`).
const CHAIN_ID = Number(
  process.env.EMBER_CHAIN_ID || { mainnet: 7411, testnet: 7412 }[EMBER_NETWORK],
)
if (!Number.isSafeInteger(CHAIN_ID)) {
  throw new Error(`CF_EMBER_NETWORK is "${EMBER_NETWORK}"; known: mainnet, testnet`)
}
// The node and the key directory are `lib.mjs`'s now, per environment, and the
// literal `http://127.0.0.1:8545` that used to be here is gone: it is the
// MAINNET seed on this host, so on the testnet estate this file funded market
// deployers out of the wrong chain's node. See `EMBER_RPC_HOST` there.
const RPC_URL = EMBER_RPC_HOST
const HEARTH = process.env.HEARTH_REPO || path.resolve(ROOT, '../hearth')
// `TOKENS_FILE` is IMPORTED, not redefined. The line that used to be here read
//   process.env.TOKENS_FILE || 'compose/estate/tokens.env'
// which ignores `CF_EMBER_NETWORK` — so a testnet run that did not export
// TOKENS_FILE by hand rewrote the MAINNET tokens file. `lib.mjs` derives it from
// the network for exactly the reason its psql helper gives one line later: "or
// this reads the mainnet project's postgres on a testnet run".

/** `FORESIGHT_DEPLOY_GAS_LIMIT`, and the service bids DOUBLE the quoted price against it. */
const DEPLOY_GAS_LIMIT = 3_000_000n

/* ── the chain, which is optional ──────────────────────────────────────────── */

/**
 * Load hearth's transaction codec and a key that can sign with it.
 *
 * ── THIS READ `coinbase-key.json` DIRECTLY, AND THAT FILE NO LONGER EXISTS ───
 *
 * micro-org#206 sealed the mining key: `coinbase-key.json` — the private key in
 * the clear at mode 600 — became `coinbase-keystore.json`, scrypt N=2^18 over a
 * passphrase and AES-256-GCM over the key, with the passphrase supplied as a
 * PATH rather than a value. Measured on the app host on 2026-08-11 there is no
 * plaintext file anywhere under `miner-keys/`, only the keystore and
 * `miner-keys/secrets/coinbase-passphrase`.
 *
 * The old body of this function returned `null` for that, and `null` here is not
 * an error — it is the documented "this machine has no chain" path, meant for
 * CI. So every new market was created, approved, and then skipped one state
 * short of `open`:
 *
 *     draft → approved → deployed → open
 *                     ^ they stopped here
 *
 * and an APPROVED MARKET DOES NOT APPEAR ON THE BROWSE PAGE. A seeding run
 * against a correctly configured estate printed a reasoned skip, exited 0, and
 * changed nothing a visitor could see. micro-org#411.
 *
 * ── AND THE UNSEALER IS HEARTH'S, NOT A SECOND ONE WRITTEN HERE ──────────────
 *
 * `hearth/node/src/coinbase.js` already resolves a coinbase key from four
 * sources in precedence order — `HEARTH_COINBASE_KEY`, `HEARTH_COINBASE_KEY_FILE`
 * (a path), `<data>/coinbase-keystore.json` + `HEARTH_COINBASE_PASSPHRASE_FILE`,
 * and `<data>/coinbase-key.json` — and it is the code the estate's three miners
 * run in production. Reimplementing scrypt-and-GCM in a seeder would be a second
 * thing to get right, reviewed by nobody, diverging the first time the keystore
 * format moves. This file already `require`s hearth for the transaction codec,
 * so the resolver costs one more `require`.
 *
 * `create: false` IS LOAD-BEARING. `resolveCoinbaseKey` generates a fresh key and
 * WRITES IT IN THE CLEAR when it finds nothing and nobody has said not to — that
 * is the right default for a developer's first `hearthd` and a catastrophic one
 * for a seeder, which would mint a new key into the miner's data directory,
 * fund market deployers from an account with no balance, and leave a plaintext
 * private key behind on a host that had just been cleaned of one.
 *
 * ── WHAT THIS FUNCTION WILL NOT PUT ON A STREAM ──────────────────────────────
 *
 * The private key, the passphrase, or any part or digest of either. The
 * passphrase is never read HERE at all: hearth reads it from the path it is
 * given, uses it, and drops it, and this file only ever names the variable. The
 * one thing that does get printed is the funding ADDRESS, which is public, is
 * already in the compose file, and is what an operator needs to see to know
 * which account paid.
 *
 * `err.message` is passed through ONLY for hearth's own tagged refusals, whose
 * text is written to this rule — they name files, environment variable names and
 * addresses and nothing else. Anything else that throws gets its constructor
 * name and no message, because a `JSON.parse` failure on a key file is exactly
 * the error that would carry a fragment of the file into a log.
 *
 * @returns {{chain: object|null, why: string|null}} the chain, or a specific
 *   reason it could not be had. Never a silent null.
 */
function signingChain() {
  let TX
  let CB
  try {
    TX = require(path.join(HEARTH, 'node/src/chain/transaction.js'))
    CB = require(path.join(HEARTH, 'node/src/coinbase.js'))
  } catch {
    return {
      chain: null,
      why:
        `no hearth checkout at ${HEARTH}: this needs node/src/chain/transaction.js to encode a ` +
        `transaction and node/src/coinbase.js to obtain the key that signs it. Set HEARTH_REPO to ` +
        `a checkout, or put one beside the deploy checkout.`,
    }
  }

  // What is actually on disk, said before anything is opened — a refusal that
  // names the file it found is a different instruction to an operator from one
  // that says nothing is there.
  const present = MINER_KEY_FILES.filter((f) => fs.existsSync(path.join(MINER_DATA, f)))
  const sealedOnly = present.length > 0 && !present.includes('coinbase-key.json')

  if (present.length === 0 && !process.env.HEARTH_COINBASE_KEY && !process.env.HEARTH_COINBASE_KEY_FILE) {
    return {
      chain: null,
      why:
        `no coinbase key under ${MINER_DATA}: neither ${MINER_KEY_FILES.join(' nor ')} is there, and ` +
        `neither HEARTH_COINBASE_KEY nor HEARTH_COINBASE_KEY_FILE is set. Point CF_MINER_KEYS at the ` +
        `directory holding <network>/, or EMBER_MINER_DATA straight at the directory itself.`,
    }
  }
  if (sealedOnly && !MINER_PASSPHRASE_FILE) {
    return {
      chain: null,
      why:
        `the coinbase key at ${path.join(MINER_DATA, 'coinbase-keystore.json')} is SEALED and there ` +
        `is no passphrase to open it. Set HEARTH_COINBASE_PASSPHRASE_FILE to the PATH of the file ` +
        `holding it — never the value; that is the convention ` +
        `compose/docker-compose.miners-apphost.yml already mounts at /run/secrets/coinbase-passphrase.`,
    }
  }

  /* A copy, not `process.env`. The passphrase path is a fact this deployment
   * knows (`lib.mjs`) and the seeder should not have to be told twice — but
   * writing it into the real environment would hand it to every child process
   * `spawnSync` starts below, including `docker compose`. */
  const env = {
    ...process.env,
    ...(MINER_PASSPHRASE_FILE ? { HEARTH_COINBASE_PASSPHRASE_FILE: MINER_PASSPHRASE_FILE } : {}),
  }

  let got
  try {
    got = CB.resolveCoinbaseKey(MINER_DATA, { env, create: false })
  } catch (err) {
    const tagged = err && err.code === CB.COINBASE_KEY_REFUSED
    return {
      chain: null,
      why: tagged
        ? `the coinbase key under ${MINER_DATA} could not be obtained: ${err.message}`
        : `the coinbase key under ${MINER_DATA} could not be obtained: hearth's resolver threw a ` +
          `${err?.constructor?.name ?? 'non-Error'}. Its message is deliberately NOT printed — a ` +
          `parse failure on a key file is the error that carries a fragment of the file into a log.`,
    }
  }

  return {
    chain: {
      TX,
      source: got.source,
      key: { priv: got.key.privateKey, address: got.key.addressHex },
    },
    why: null,
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
 *   1. **The ten-minute cliff.** `foresight/src/index.ts` is `const token =
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
 *      `foresight-market-journey.mjs` diagnoses this at length and works
 *      around it by INSERTing into the `jobs` table directly.
 *
 * This does not write that SQL. A recreate solves both at once: the token is
 * fresh and the process starts, which arms every recurring job the honest way.
 * It is also what an operator would actually do. Both defects belong to
 * micro-foresight — `ServiceTokenProvider` for the first, `rescheduleRecurring`
 * off the runner's completed event for the second — and this function is a
 * workaround in the open, not a fix.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * ── AND ON THE ESTATE AS IT IS TODAY, DOING THAT WOULD TAKE FORESIGHT DOWN ───
 *
 * Defect 1 was fixed on the OTHER side, and this workaround did not follow it.
 * micro-org#222 retired the static bearer: `foresight/src/env.ts` now guards
 * `FORESIGHT_SERVICE_TOKEN` with `assertServiceCredential`, which REFUSES A JWT
 * BY NAME, and that file states the consequence in as many words — "a deployment
 * that still sets `FORESIGHT_SERVICE_TOKEN` to a token will not boot — neither
 * `foresight` nor `foresight-migrate`". The service takes a long-lived
 * `FORESIGHT_IDENTITY_CREDENTIAL` instead and renews itself from it, which is
 * why `FORESIGHT_SERVICE_TOKEN` IS NOT SET AT ALL on either running container
 * (measured on the app host, 2026-08-11).
 *
 * So the old body — mint a 600s JWT, write it into the tokens file as
 * `FORESIGHT_SERVICE_TOKEN=`, recreate the container — was a seeding run that
 * KILLS THE SERVICE IT IS SEEDING, at the seven-minute mark, half way through
 * opening the markets it had just funded.
 *
 * Two smaller faults in the same three lines, both of the class this repository
 * already knows about:
 *
 *   * it passed `--env-file TOKENS_FILE` and NOT `ESTATE_ENV`, so the recreate
 *     dropped every per-network value — the failure `lib.mjs`'s psql helper
 *     guards against one line after it defines `ENV_FILES`, and the one that
 *     turns public hostnames into `localtest.me`;
 *   * it passed only `COMPOSE`, while both containers were created from
 *     `docker-compose.estate.yml` AND `docker-compose.release.yml`, so the
 *     recreate would drop the pinned release overlay and run something else;
 *   * and with `cwd` set to a worktree it would have derived a PROJECT NAME from
 *     the directory, building a stray `foresight` in a project nobody watches
 *     while the real one carried on unchanged.
 *
 * Rather than repair three guesses, this now ASKS whether the renewal is needed
 * at all, which on the credential path it is not. A deployment still on the
 * static token keeps the old behaviour, because for that deployment it is right.
 * ══════════════════════════════════════════════════════════════════════════════
 */
async function refreshForesight(userToken, why) {
  // Which credential path is this DEPLOYMENT on? A fact about the deployment,
  // so it is read out of the deployment, the way every other such fact in these
  // seeders is. `FORESIGHT_IDENTITY_CREDENTIAL` present means the service holds
  // a long-lived `cfsc_…` it renews itself from, and there is nothing here to
  // refresh — writing a JWT into the other variable would stop it booting.
  const tokensPath = path.join(ROOT, TOKENS_FILE)
  let tokensText = null
  try {
    tokensText = fs.readFileSync(tokensPath, 'utf8')
  } catch {
    bad(`${TOKENS_FILE} is missing — run ./scripts/estate-bootstrap.sh first`)
    return false
  }
  // The NAME only. Nothing here reads, prints or compares the value.
  if (/^FORESIGHT_IDENTITY_CREDENTIAL=.+$/m.test(tokensText)) {
    note(
      `not recreating foresight (${why}): this deployment sets FORESIGHT_IDENTITY_CREDENTIAL, so ` +
        `the service renews its own credential and FORESIGHT_SERVICE_TOKEN is refused by name ` +
        `(micro-org#222) — writing one would stop it booting`,
    )
    return true
  }

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
  const next = tokensText.split('\n').filter((l) => !/^FORESIGHT_SERVICE_TOKEN=/.test(l))
  next.push(`FORESIGHT_SERVICE_TOKEN=${token}`)
  fs.writeFileSync(tokensPath, next.filter((l, i) => l !== '' || i < next.length - 1).join('\n') + '\n')

  // ENV_FILES, not TOKENS_FILE alone: both files, in the order `lib.mjs` fixed
  // them, or the recreate drops every per-network value and the container comes
  // back answering on `localtest.me`.
  const r = spawnSync(
    'docker',
    ['compose', ...ENV_FILES, '-f', COMPOSE, 'up', '-d', '--wait', 'foresight'],
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

/* ── the twenty ───────────────────────────────────────────────────────────── */

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
      // foresight refuses a close time in the past (`markets.ts`) and it
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
 * driven from leased jobs; markets taken one at a time through a
 * submit-fund-poll-open cycle would cross the cliff halfway down the list. It
 * mattered at nine and it matters more at twenty. Submitting them all, funding
 * them all, then polling them all keeps the whole chain phase inside one token's
 * life on a chain this size — and the nine-minute poll below is why the eleven
 * added in 2026-08 are the batch that tests whether that still holds.
 */
async function deployAndOpen(markets, userToken, { chain, why }) {
  const pending = markets.filter((m) => m.status === 'approved')
  if (pending.length === 0) {
    ok('every seeded market is already open or beyond — nothing to deploy')
    return
  }
  if (!chain) {
    // The reason is `signingChain()`'s, not a guess made here. The sentence this
    // replaced guessed — "no mining key at <dir>" — and was WRONG for eight days
    // after micro-org#206, because the key was there and sealed. micro-org#411.
    skip(
      `${pending.length} market(s) approved but NOT opened — ${why.replace(/\.?$/, '.')} A market ` +
        `cannot open until its contract is on chain, so they stay approved and invisible to the ` +
        `browse page.`,
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
  // (`foresight/src/evm.ts`), and the funding gate is `bid * gasLimit`. A
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
    `funding address ${chain.key.address} (from the ${chain.source} key source) holds ` +
      `${ember(balance)} EMBER; ${ember(perMarket)} per deployer (the service requires ` +
      `${ember(needed)} — bid, not quote)`,
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

/**
 * A header image for each seeded question.
 *
 * ── WHY THESE ARE GENERATED AND MARKET'S ARE ADOPTED ────────────────────────
 *
 * A Foresight question has no artwork anywhere in this estate — there is no
 * "will BTC close above X" picture in `brand/` to adopt — so this is the path
 * that asks studio to make one. `market.mjs` is the other case: it lists the
 * estate's own FLUX 2 Pro asset sets, and the right cover for a listing OF those
 * assets is one of those assets, read and uploaded rather than reinvented.
 *
 * ── THE COVERS ARE COMMITTED FLUX 2 PRO ART, ADOPTED RATHER THAN GENERATED ──
 *
 * Each seeded question has a real FLUX 2 Pro cover in `assets/seed/foresight/`,
 * generated once against the live Azure resource and committed. This adopts them
 * the way `market.mjs` adopts the estate's existing asset sets: read-only, and
 * deduplicated by studio on the content address.
 *
 * Committing them rather than generating at seed time buys three things. Bootstrap
 * runs several times an hour and each generation is real money, so generating here
 * would bill the owner on every run. The art is reviewable in a diff instead of
 * appearing differently on each bootstrap. And the covers no longer depend on
 * studio having a working image model at seed time — which it did not, for this
 * service's entire history.
 *
 * `generateCover` remains the fallback for a question with no committed cover, so
 * adding a tenth question still produces something rather than nothing.
 *
 * A failure to attach a cover is NOT a failure of the seeding run. A question
 * without a picture is still a question; a bootstrap that aborted because an
 * image did not render would be a worse trade than a plain page.
 */
/**
 * The filename a question's committed cover is stored under.
 *
 * Derived from the question rather than recorded beside it, so a cover cannot drift away from the
 * market it belongs to: rewording a question changes the slug, the adopt misses, and the fallback
 * generates a new one rather than silently attaching the old picture to a different question.
 */
function coverSlug(question) {
  return question
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60)
}

async function coverImages(markets, userToken) {
  if (markets.length === 0) return
  await reportImageBackend()
  if (!(await studioReachable())) return

  for (const m of markets) {
    // Idempotent by asking first. A re-run must not generate a second image, and
    // must never replace one that is already there.
    const current = await api('foresight', `/markets/${m.id}`, { expect: 200 })
    if (current.body.market?.image?.assetId) continue

    // The committed FLUX cover for this question, if there is one.
    const spec = FORESIGHT_QUESTIONS.find((q) => q.question === m.question)
    const file = spec ? `deploy/assets/seed/foresight/${coverSlug(spec.question)}.png` : ''

    const asset = file
      ? await adoptExisting(userToken, file)
      : // No committed cover — a question added since the art was generated. Ask studio, which
        // reaches FLUX when a model is configured. The `cover` KIND matters: `banner` is a brand
        // kind and would return a logo with the kit slug lettered across it.
        await generateCover(userToken, {
          slug: `foresight-${m.id.slice(0, 8)}`,
          stylePrompt: spec?.cover ?? m.question,
          kind: 'cover',
        })
    if (!asset) continue

    const res = await api('foresight', `/markets/${m.id}/image`, {
      method: 'PUT',
      token: userToken,
      body: { assetId: asset.id, checksum: asset.checksum },
    })
    if (res.status === 200) {
      ok(`cover set on ${m.id.slice(0, 8)} — ${asset.checksum.slice(0, 14)}…`)
    } else {
      bad(`cover on ${m.id.slice(0, 8)} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
}

export async function seedForesight(userToken) {
  head('foresight — real questions, and a decision about the test artefacts')

  const before = await allMarkets()
  note(`${before.length} market(s) in the registry before seeding`)

  await handleTestArtefacts(before, userToken)

  const seeded = await createMissing(before, userToken)
  await approveDrafts(seeded, userToken)

  await deployAndOpen(seeded, userToken, signingChain())

  await coverImages(seeded, userToken)

  reportHouseSeed()

  const after = await allMarkets()
  const open = after.filter((m) => m.status === 'open').length
  const real = after.filter((m) => !isTestArtefact(m.question)).length
  ok(`registry now holds ${after.length} market(s): ${real} real, ${open} open on the browse page`)
}
