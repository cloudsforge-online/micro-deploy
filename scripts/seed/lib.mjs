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
 * devplatform on the API host and sends everything else to `cf-api-catchall`,
 * which points at `http://127.0.0.1:1`. `micro-ledger` is deliberately not
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

export const APEX = process.env.CF_WEB_APEX || 'cloudsforge.localtest.me'
/**
 * The API host, read from the file the GATEWAY reads rather than guessed.
 *
 * `estate-up.sh:117` reads it from exactly here and refuses to start without it,
 * because an unset `CF_API_HOST` makes every public API route answer 502 with
 * nothing in Traefik's log. Guessing `api.${APEX}` would be right today and
 * wrong the first time somebody deploys under a real apex.
 */
export const API_HOST = readApiHost()

function readApiHost() {
  if (process.env.CF_API_HOST) return process.env.CF_API_HOST
  const file = path.join(ROOT, 'compose/env/traefik.env')
  try {
    const line = fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .filter((l) => /^CF_API_HOST=/.test(l))
      .pop()
    if (line) return line.slice('CF_API_HOST='.length).trim()
  } catch {
    /* fall through to the derived default, which estate-up.sh also suggests */
  }
  return `api.${APEX}`
}

/**
 * Where each service is, and whether the request crosses the gateway.
 *
 * `gateway: false` is not a shortcut. It is a fact about the deployment, and it
 * is written down here so the report can name the four services whose content
 * this seeder created without a browser ever being able to reach them.
 */
/**
 * The scheme the GATEWAY-CROSSING entries use, which is not always `https`.
 *
 * The same `CF_GATEWAY_TLS` the gateway itself reads, defaulted the same way, so
 * an environment that does not set it seeds exactly what it always seeded. A
 * deployment behind Cloudflare Tunnel sets it `false` and the gateway terminates
 * no TLS there — cloudflared validates a certificate against the hostname in its
 * service URL, that hostname is `127.0.0.1`, and no Origin CA will ever sign an
 * IP literal. `gateway/dynamic/tls.yml` carries the diagnosis.
 *
 * The four `gateway: false` entries below are untouched by it: they are loopback
 * container ports that were never TLS in the first place, which is exactly the
 * distinction that flag was written down to make.
 */
export const GW_SCHEME = process.env.CF_GATEWAY_TLS === 'false' ? 'http' : 'https'

export const SERVICES = {
  identity: { base: `${GW_SCHEME}://nimbus.${APEX}`, gateway: true },
  custody: { base: `${GW_SCHEME}://vault.${APEX}`, gateway: true },
  foresight: { base: `${GW_SCHEME}://foresight.${APEX}`, gateway: true },
  market: { base: `${GW_SCHEME}://${API_HOST}`, gateway: true },
  mint: { base: `${GW_SCHEME}://${API_HOST}`, gateway: true },
  // Not published by the gateway; loopback host ports from the compose file.
  ledger: { base: 'http://127.0.0.1:4102', gateway: false },
  billing: { base: 'http://127.0.0.1:4106', gateway: false },
  nda: { base: 'http://127.0.0.1:4116', gateway: false },
  community: { base: 'http://127.0.0.1:4117', gateway: false },
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
