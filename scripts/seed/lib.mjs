/**
 * The plumbing every domain seeder sits on: where the estate is, how to talk to
 * it, and how to say what happened.
 *
 * ── VERIFICATION IS ON, EVERYWHERE IT CAN BE ─────────────────────────────────
 *
 * Every call that has a gateway route goes THROUGH the gateway over TLS with the
 * estate CA supplied. There is no `rejectUnauthorized: false` in this file and
 * there is no loopback fallback for a service the gateway publishes. This
 * estate's most expensive defect of the night was 183 uses of `curl -k` hiding a
 * certificate every real browser refused, and a seeder that quietly stopped
 * verifying would be the same defect wearing a different hat.
 *
 * `NODE_EXTRA_CA_CERTS` is read by Node once, at startup, so the ENTRY POINT
 * re-execs itself with it set. This module assumes that has already happened and
 * says so rather than trying to do it late, where it would silently not work.
 *
 * ── AND WHERE IT CANNOT BE, THAT IS SAID OUT LOUD ────────────────────────────
 *
 * Three of the services being seeded — `community`, `nda` and `billing` — have
 * NO gateway route at all. `deploy/gateway/dynamic/public-api.yml` publishes
 * pricing, activity, foresight, identity, wallet, market, mint, worlds and
 * devplatform on the API host and routes nothing else, so anything unmatched is
 * Traefik's own `404 page not found`. (It used to be a `cf-api-catchall` router
 * pointing at `http://127.0.0.1:1`, which answered 502 — an unrouted resource
 * that claimed to be a broken one.) `micro-ledger` is deliberately not
 * publishable at all — it has no third-party-reachable surface by design. Those
 * four are reached on the loopback host ports the compose file binds, exactly as
 * `estate-verify.sh` reaches them, and `viaGateway` records which is which so
 * the report can say it rather than imply everything went through the front door.
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const HERE = path.dirname(fileURLToPath(import.meta.url))
/** `deploy/`, the directory every script in this repository runs relative to. */
export const ROOT = path.resolve(HERE, '../..')
/**
 * The trust BUNDLE, not the estate CA alone: `ca.crt` plus every public root in
 * `gateway/trust/`, rebuilt by `scripts/gateway-cert.sh` on every run.
 *
 * The mainnet gateway terminates on a Cloudflare Origin CA leaf now — see
 * `gateway/dynamic/tls.yml` — while testnet still serves the estate leaf, so a
 * seeder pointed at `ca.crt` verifies in one environment and fails in the other.
 * One bundle keeps this a single path and adds ISSUERS rather than exemptions:
 * a wrong SAN, an expired leaf and an unknown issuer all still fail.
 */
export const CA = process.env.CF_ESTATE_CA || path.join(ROOT, 'gateway/certs/trust.crt')

/**
 * The gateway's own env file — `env/traefik.env`, or `env/traefik.testnet.env`
 * when `CF_TRAEFIK_ENV` selects it, which is the same expression
 * `compose/docker-compose.gateway.yml:50`, `scripts/gateway-reload.sh:100` and
 * `scripts/release-deploy.sh:78` all use. One rule, four readers.
 */
const TRAEFIK_ENV = path.join(
  ROOT,
  'compose/env',
  `${process.env.CF_TRAEFIK_ENV || 'traefik'}.env`,
)

/**
 * One variable out of the file the GATEWAY actually loads.
 *
 * `.pop()` rather than `[0]`: an env file's LAST assignment wins, which is what
 * docker compose does with it, and reading the first would take a value the
 * gateway is not using.
 */
function fromTraefikEnv(name) {
  try {
    const line = fs
      .readFileSync(TRAEFIK_ENV, 'utf8')
      .split('\n')
      .filter((l) => new RegExp(`^${name}=`).test(l))
      .pop()
    if (line) return line.slice(name.length + 1).trim() || null
  } catch {
    /* the file is optional on a developer machine; the caller has a default */
  }
  return null
}

/**
 * The apex the fifteen browser surfaces are served on — READ, not guessed.
 *
 * ── THIS WAS `process.env.CF_WEB_APEX || 'cloudsforge.localtest.me'` ─────────
 *
 * and it was wrong on the only host that matters. `CF_API_HOST` below has always
 * been read out of the gateway's env file, with a comment saying why guessing it
 * "would be right today and wrong the first time somebody deploys under a real
 * apex" — and the line above it then guessed the apex. On the live estate that
 * produced a seeder addressing `foresight.cloudsforge.localtest.me` (404, the
 * public wildcard resolves to loopback and nothing there serves it) while
 * addressing `api.cloudsforge.online` correctly, from the same run. Two hosts,
 * one deployment, one of them invented.
 *
 * The default is unchanged for a machine with no gateway env file at all, which
 * is a developer's laptop and is where `localtest.me` is the right answer.
 */
export const APEX =
  process.env.CF_WEB_APEX || fromTraefikEnv('CF_WEB_APEX') || 'cloudsforge.localtest.me'

/**
 * Everything after a surface's own name. `nimbus` + this is identity's hostname.
 *
 * ── AN ENVIRONMENT IS A SUFFIX NOW, NOT A PREFIX ON THE APEX ─────────────────
 *
 * Changed 2026-08-05. Testnet used to be `hub.testnet.cloudsforge.online`, and
 * every hostname of that shape was configured and unreachable: Cloudflare's
 * Universal SSL is `*.cloudsforge.online`, a wildcard matches exactly ONE label,
 * so the TLS handshake failed at Cloudflare's edge before a request reached the
 * box. It is `hub-testnet.cloudsforge.online` now, and BOTH environments share
 * the zone `cloudsforge.online`.
 *
 * READ from the gateway's own env file, exactly as `APEX` above is, and NOT
 * derived as `.${APEX}`. That derivation is why this variable exists rather than
 * being a one-line expression: with a shared apex it yields a real MAINNET
 * hostname that really answers, so a testnet seeding run would write its content
 * into production and report success. The `.${APEX}` fallback is reached only
 * when there is no gateway env file at all, which is a laptop under
 * `cloudsforge.localtest.me` where there is no second environment to confuse.
 */
export const WEB_SUFFIX =
  process.env.CF_WEB_SUFFIX || fromTraefikEnv('CF_WEB_SUFFIX') || `.${APEX}`

/**
 * The apex surface — the marketing site — whose registry subdomain is the EMPTY
 * STRING.
 *
 * It needs a variable of its own because `'' + WEB_SUFFIX` is
 * `-testnet.cloudsforge.online`, which is not a legal DNS label. The environment
 * label stands alone instead: `testnet.cloudsforge.online`, and on mainnet this is
 * the bare apex.
 */
export const SITE_HOST =
  process.env.CF_SITE_HOST || fromTraefikEnv('CF_SITE_HOST') || APEX

/**
 * The API host, read from the file the GATEWAY reads rather than guessed.
 *
 * `estate-up.sh:117` reads it from exactly here and refuses to start without it,
 * because an unset `CF_API_HOST` makes every public API route answer 502 with
 * nothing in Traefik's log. Guessing `api${WEB_SUFFIX}` would be right today and
 * wrong the first time somebody deploys under a real apex.
 */
export const API_HOST =
  process.env.CF_API_HOST || fromTraefikEnv('CF_API_HOST') || `api${WEB_SUFFIX}`

/**
 * Where each service is, and whether the request crosses the gateway.
 *
 * `gateway: false` is not a shortcut. It is a fact about the deployment, and it
 * is written down here so the report can name the four services whose content
 * this seeder created without a browser ever being able to reach them.
 */
export const SERVICES = {
  identity: { base: `https://nimbus${WEB_SUFFIX}`, gateway: true },
  custody: { base: `https://vault${WEB_SUFFIX}`, gateway: true },
  foresight: { base: `https://foresight${WEB_SUFFIX}`, gateway: true },
  market: { base: `https://${API_HOST}`, gateway: true },
  mint: { base: `https://${API_HOST}`, gateway: true },
  // Not published by the gateway; loopback host ports from the compose file.
  ledger: { base: 'http://127.0.0.1:4102', gateway: false },
  billing: { base: 'http://127.0.0.1:4106', gateway: false },
  nda: { base: 'http://127.0.0.1:4116', gateway: false },
  community: { base: 'http://127.0.0.1:4117', gateway: false },
}

/* ── the chain, in the places this deployment actually keeps it ─────────────── */

/**
 * Which EMBER this project is. The same variable `docker-compose.estate.yml`
 * keys `env/chain.${CF_EMBER_NETWORK}.env` and `LEDGER_RECONCILE_NETWORK` on,
 * with the same `mainnet` default.
 */
export const EMBER_NETWORK = process.env.CF_EMBER_NETWORK || 'mainnet'

/**
 * The EMBER node, as reachable FROM THE HOST.
 *
 * ── THE DEFAULT WAS A LITERAL 8545 IN TWO FILES, AND IT IS THE TESTNET THAT
 *    SUFFERS FOR IT ───────────────────────────────────────────────────────────
 *
 * `seed/foresight.mjs` defaulted to `http://127.0.0.1:8545`, which is the
 * MAINNET seed on this host — `compose/env/traefik.testnet.env` puts the testnet
 * node on 8745 and says at length why the two must never be confused: "a miner
 * pointed at testnet crediting blocks on the other environment's ledger… nothing
 * can detect it from outside: both nodes speak the same protocol and both answer
 * correctly, about the wrong chain." A seeder carrying its own 8545 would have
 * funded testnet market deployers out of the mainnet miner's balance.
 *
 * So it is READ from the gateway's own env file, per environment, exactly as
 * `API_HOST` is — one fact, one place. `host.docker.internal` is rewritten to
 * loopback because that value is written for a CONTAINER and this runs on the
 * host; the port, which is the part that differs, is taken as it is found.
 */
export const EMBER_RPC_HOST = readEmberRpc()

function readEmberRpc() {
  if (process.env.EMBER_HOST_RPC) return process.env.EMBER_HOST_RPC
  const upstream = fromTraefikEnv('CF_RPC_UPSTREAM')
  if (upstream) return upstream.replace('host.docker.internal', '127.0.0.1')
  return 'http://127.0.0.1:8545'
}

/**
 * The directory holding `coinbase-key.json` for THIS environment's miner.
 *
 * `compose/docker-compose.miners.yml:134,161` already declares the deployed
 * layout — `${CF_MINER_KEYS}/mainnet` and `${CF_MINER_KEYS}/testnet` — and this
 * is the same expression rather than a second convention. Before it, the seeders
 * looked only at `~/.cloudsforge/ember-testnet/miner`, a developer-laptop path
 * that does not exist on the deployment host, so every market was created,
 * approved and then SKIPPED at the deploy step for want of a key that was
 * sitting two directories away. An approved market does not appear on the browse
 * page, so the surface stayed empty and the seeder reported a reasoned skip.
 *
 * The laptop path remains the last fallback, unchanged, for the machine where it
 * is right.
 */
export const MINER_DATA = readMinerData()

function readMinerData() {
  if (process.env.EMBER_MINER_DATA) return process.env.EMBER_MINER_DATA
  const keys = process.env.CF_MINER_KEYS || path.resolve(ROOT, '../miner-keys')
  const perNetwork = path.join(keys, EMBER_NETWORK)
  if (fs.existsSync(path.join(perNetwork, 'coinbase-key.json'))) return perNetwork
  const home = process.env.EMBER_HOME || path.join(process.env.HOME || '', '.cloudsforge/ember-testnet')
  return path.join(home, 'miner')
}

export const COMPOSE = process.env.COMPOSE || 'compose/docker-compose.estate.yml'
export const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'estate-admin@example.test'
export const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'correct-horse-battery-staple-42'

/* ── saying what happened ──────────────────────────────────────────────────── */

const green = (s) => `\x1b[32m${s}\x1b[0m`
const red = (s) => `\x1b[31m${s}\x1b[0m`
const yellow = (s) => `\x1b[33m${s}\x1b[0m`

export const tally = { ok: 0, bad: 0, skipped: 0, created: 0, replayed: 0 }

export const ok = (s) => {
  tally.ok++
  console.log(`  ${green('ok')}   ${s}`)
}
export const bad = (s) => {
  tally.bad++
  console.log(`  ${red('FAIL')} ${s}`)
}
/**
 * Something this seeder deliberately did not do, and why.
 *
 * Distinct from `bad` on purpose. "The engagement treasury holds nothing, so no
 * house seed was staked" is not a failure of seeding; it is seeding refusing to
 * invent money. A run that reported it as a failure would train an operator to
 * ignore failures.
 */
export const skip = (s) => {
  tally.skipped++
  console.log(`  ${yellow('skip')} ${s}`)
}
export const note = (s) => console.log(`  ..   ${s}`)
export const head = (s) => console.log(`\n── ${s} ${'─'.repeat(Math.max(0, 74 - s.length))}`)

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* ── one request ──────────────────────────────────────────────────────────── */

export class ApiError extends Error {
  constructor(method, url, status, body) {
    super(`${method} ${url} → ${status}: ${JSON.stringify(body).slice(0, 300)}`)
    this.status = status
    this.body = body
  }
}

/**
 * One estate call.
 *
 * `accept: application/json` is sent on EVERY request, not only where a body is
 * expected back, because the foresight gateway rule discriminates on it: the
 * router for `/markets` is `HeaderRegexp('Accept', 'application/json')` at
 * priority 700 and without it the same path is served by the SPA bundle
 * (`gateway/dynamic/estate-web.yml:499-503`). A seeder that omitted the header
 * would receive an HTML page with status 200 and report success.
 */
export async function api(service, path_, opts = {}) {
  const { method = 'GET', body, token, expect, idempotencyKey, timeoutMs = 30_000 } = opts
  const svc = SERVICES[service]
  if (!svc) throw new Error(`no such service in the seeding map: ${service}`)
  const url = `${svc.base}${path_}`

  const headers = { accept: 'application/json' }
  if (body !== undefined) headers['content-type'] = 'application/json'
  if (token) headers.authorization = `Bearer ${token}`
  if (idempotencyKey) headers['idempotency-key'] = idempotencyKey

  const res = await fetch(url, {
    method,
    headers,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(timeoutMs),
  })
  const text = await res.text()
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = { raw: text.slice(0, 300) }
  }
  if (expect !== undefined) {
    const wanted = Array.isArray(expect) ? expect : [expect]
    if (!wanted.includes(res.status)) throw new ApiError(method, url, res.status, parsed)
  }
  return { status: res.status, body: parsed }
}

/** The operator, signed in. Every write in this seeder is made as a real, named user. */
export async function login() {
  const { body } = await api('identity', '/auth/login', {
    method: 'POST',
    body: { identifier: ADMIN_EMAIL, password: ADMIN_PASSWORD },
    expect: 200,
  })
  if (!body.accessToken) throw new Error('identity returned no accessToken')
  return body.accessToken
}

/** The signed-in operator's own user id, which several services need as a subject. */
export async function whoami(token) {
  const { body } = await api('identity', '/auth/me', { token, expect: 200 })
  const id = body.user?.id ?? body.id
  if (!id) throw new Error(`identity /auth/me returned no user id: ${JSON.stringify(body).slice(0, 200)}`)
  return id
}

/**
 * A ten-minute service token for a named service's own grant.
 *
 * Used only where a route refuses a user principal outright — micro-ledger is
 * the whole of that list, and it refuses users by design (`ledger/src/
 * server.ts:575`) because `wallet` is what a user talks to.
 */
export async function serviceToken(userToken, service, scopes) {
  const { body } = await api('identity', '/service-tokens', {
    method: 'POST',
    token: userToken,
    body: { service, scopes },
    expect: 201,
  })
  if (!body.token) throw new Error(`identity minted no token for ${service}`)
  return body.token
}

/**
 * Re-mint one service's ten-minute token and recreate its container.
 *
 * ── WHY A SEEDER NEEDS THIS AT ALL ───────────────────────────────────────────
 *
 * Two services this seeder drives still PRESENT a ten-minute JWT verbatim rather
 * than exchanging a long-lived credential — `foresight/src/index.ts:101` and
 * `market/src/index.ts:83` are both `const token = () => env.serviceToken`. Both
 * compose entries default that variable to
 * `estate-placeholder-token-0000000000000000`, so ANY plain `docker compose up`
 * silently replaces a working credential with a string that is not a JWT.
 *
 * The consequence is not a clean failure. micro-market sends the placeholder to
 * micro-policy, policy answers 401 `Invalid Compact JWS`, and market's policy
 * client treats any peer-decided 4xx as a DENY (`market/src/policyclient.ts`) —
 * so every listing on the platform is refused 403 `policy_denied`. That file's
 * own header says this must never happen: "failing CLOSED here would mean a
 * policy outage stops every seller on the platform from listing anything… the
 * failure looks to a seller exactly like being banned." A credential fault is
 * not policy deciding, and the marketplace should not close for one.
 *
 * ── AND WHY IT RECREATES RATHER THAN JUST RE-MINTING ─────────────────────────
 *
 * The value lives in the container's environment, so a new token only takes
 * effect on a recreate. The recreate has a second effect this seeder relies on
 * for foresight: every recurring job in that service re-arms only at process
 * start, so recreating is also how a stalled `market.deploy` is retried without
 * INSERTing into the jobs table.
 *
 * This is a workaround in the open for a defect in two other repositories. The
 * fix belongs to them — `ServiceTokenProvider`, as micro-foresight has now
 * adopted for its other seam — and the deploy-side half is an empty default
 * instead of a placeholder that looks like a value, so an unset token is loud.
 */
export async function refreshServiceToken(userToken, service, varName, scopes) {
  const token = await serviceToken(userToken, service, scopes)
  const file = path.join(ROOT, process.env.TOKENS_FILE || 'compose/estate/tokens.env')
  let lines
  try {
    lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l !== '')
  } catch {
    bad(`${file} is missing — run ./scripts/estate-bootstrap.sh first`)
    return false
  }
  const next = lines.filter((l) => !new RegExp(`^${varName}=`).test(l))
  next.push(`${varName}=${token}`)
  fs.writeFileSync(file, next.join('\n') + '\n')

  const r = spawnSync(
    'docker',
    [
      'compose',
      '--env-file',
      process.env.TOKENS_FILE || 'compose/estate/tokens.env',
      '-f',
      COMPOSE,
      'up',
      '-d',
      '--wait',
      service,
    ],
    { cwd: ROOT, encoding: 'utf8' },
  )
  if (r.status !== 0) {
    bad(`could not recreate ${service}: ${(r.stderr || '').slice(0, 200)}`)
    return false
  }
  // The recreate returns when the container is healthy; a job runner or an
  // upstream client starts a beat later.
  await sleep(4_000)
  return true
}

/** Does a container hold the compose placeholder rather than a real credential? */
export function holdsPlaceholderToken(container, varName) {
  const r = spawnSync(
    'docker',
    ['inspect', container, '--format', `{{range .Config.Env}}{{println .}}{{end}}`],
    { encoding: 'utf8' },
  )
  if (r.status !== 0) return false
  const line = (r.stdout || '').split('\n').find((l) => l.startsWith(`${varName}=`))
  return Boolean(line && line.includes('estate-placeholder-token'))
}

/* ── reading the estate's own row counts, for the idempotency proof ────────── */

/**
 * Run one read-only statement against a service database.
 *
 * ── THIS IS THE ONE PLACE SQL APPEARS, AND IT ONLY EVER READS ────────────────
 *
 * The brief is explicit: content is created through the real APIs, because a row
 * conjured into Postgres skips every invariant the service enforces — the
 * ledger's balancing trigger, the outbox, the policy checks. Nothing in this
 * seeder writes SQL. `select` is a different act: proving that a second run
 * changed nothing requires counting rows, and counting them from the database is
 * the only count an API cannot flatter.
 */
export function psqlRead(db, sql) {
  const r = spawnSync(
    'docker',
    ['compose', '-f', COMPOSE, 'exec', '-T', 'postgres', 'psql', '-qtA', '-U', 'cloudsforge', '-d', db, '-c', sql],
    { cwd: ROOT, encoding: 'utf8' },
  )
  if (r.status !== 0) return null
  return (r.stdout || '').trim()
}

/** `{ foresight: { markets: 5 }, market: { listings: 0 }, … }` — the shape the report needs. */
export const COUNTED = {
  foresight: ['markets'],
  market: ['collections', 'listings'],
  mint: ['tokens', 'project_pages'],
  community: ['communities', 'memberships', 'treasury_accounts', 'proposals', 'discussion_posts'],
  // `reports` and `objectives` rather than `world_events`: the first two are
  // written by every resolved day, and the third is a random event that simply
  // did not fire in the two days seeded. Counting a table the seeding does not
  // determine would make the idempotency proof depend on a dice roll.
  nda: ['worlds', 'players', 'reports', 'objectives'],
  billing: ['products', 'prices', 'entitlements', 'purchases'],
  // `slos` is counted precisely because it must STAY zero — see seed/beacon.mjs.
  beacon: ['probes', 'slos'],
}

export function counts() {
  const out = {}
  for (const [db, tables] of Object.entries(COUNTED)) {
    out[db] = {}
    for (const table of tables) {
      const n = psqlRead(db, `select count(*) from ${table}`)
      out[db][table] = n === null ? null : Number(n)
    }
  }
  return out
}

export function printCounts(label, c) {
  console.log(`\n  ${label}`)
  for (const [db, tables] of Object.entries(c)) {
    const parts = Object.entries(tables).map(([t, n]) => `${t}=${n === null ? '?' : n}`)
    console.log(`    ${db.padEnd(10)} ${parts.join('  ')}`)
  }
}

/** Assert the CA is present before anything makes a request. Fails, never falls back. */
export function requireCa() {
  if (fs.existsSync(CA)) return
  console.error(`FAIL: no estate CA at ${CA} — run ./scripts/gateway-cert.sh first.`)
  console.error('      This seeder will not fall back to an unverified request.')
  process.exit(1)
}
