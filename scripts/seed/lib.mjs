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
 * The ESTATE's env file — `compose/mainnet.env` or `compose/testnet.env` — keyed
 * on the same `CF_EMBER_NETWORK` that `docker-compose.estate.yml` keys
 * `env/chain.${CF_EMBER_NETWORK}.env` on. It is a second file from the gateway's
 * because the two hold different things: the gateway's has the hostnames, the
 * estate's has `CF_PORT_BASE`, and neither is loaded by the other's reader.
 *
 * It comes FIRST because it is what names the gateway's file, below.
 */
const ESTATE_ENV_REL =
  process.env.ESTATE_ENV ||
  `compose/${process.env.CF_EMBER_NETWORK || 'mainnet'}.env`
const ESTATE_ENV_PATH = path.join(ROOT, ESTATE_ENV_REL)

/**
 * The gateway's own env file — `env/traefik.env`, or `env/traefik.testnet.env`
 * when `CF_TRAEFIK_ENV` selects it, which is the same expression
 * `compose/docker-compose.gateway.yml`, `scripts/gateway-reload.sh` and
 * `scripts/release-deploy.sh` all use. One rule, four readers.
 *
 * ── AND THE SHELL IS NOT WHERE THAT VARIABLE LIVES ───────────────────────────
 *
 * `process.env.CF_TRAEFIK_ENV` alone was MAINNET on every testnet run started
 * the way the deploy scripts start one: `ESTATE_ENV=compose/testnet.env` names a
 * file COMPOSE reads and the shell does not, so the variable is simply unset and
 * the `|| 'traefik'` default takes over. `scripts/release-deploy.sh` carries the
 * measurement — on 2026-08-10 the same substitution one layer up put mainnet
 * hostnames into seven live testnet containers' allowlists and URLs.
 *
 * The estate's file declares the answer (`CF_TRAEFIK_ENV=traefik.testnet` in
 * `compose/testnet.env`), so ask it before falling back.
 */
const TRAEFIK_ENV = path.join(
  ROOT,
  'compose/env',
  `${process.env.CF_TRAEFIK_ENV || fromEstateEnv('CF_TRAEFIK_ENV') || 'traefik'}.env`,
)

/**
 * One variable out of the file the GATEWAY actually loads.
 *
 * `.pop()` rather than `[0]`: an env file's LAST assignment wins, which is what
 * docker compose does with it, and reading the first would take a value the
 * gateway is not using.
 */
function fromTraefikEnv(name) {
  return fromEnvFile(TRAEFIK_ENV, name)
}

/** The same read, against the estate's env file rather than the gateway's. */
function fromEstateEnv(name) {
  return fromEnvFile(ESTATE_ENV_PATH, name)
}

function fromEnvFile(file, name) {
  try {
    const line = fs
      .readFileSync(file, 'utf8')
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
 * The leading digit of the 45 loopback debug ports: `4`100-`4`144 on mainnet,
 * `5`100-`5`144 on testnet. The same one-character override
 * `compose/docker-compose.estate.yml` publishes them through.
 *
 * ── THE FOUR LOOPBACK SERVICES BELOW WERE LITERAL 41xx, AND THAT IS A WRITE ──
 *
 * This file already spends two paragraphs on exactly this hazard — `WEB_SUFFIX`
 * is READ rather than derived because a derived one "yields a real MAINNET
 * hostname that really answers, so a testnet seeding run would write its content
 * into production and report success", and `EMBER_RPC` is read for the same
 * reason after a literal 8545 nearly funded testnet deployers from the mainnet
 * miner. Every https surface in `SERVICES` was therefore correct per
 * environment, and the five loopback ones directly under them were not: `ledger`
 * 4102, `billing` 4106, `nda` 4116, `community` 4117 and `studio` 4111 are the
 * MAINNET estate's published ports on a host that runs both.
 *
 * Measured on the app host on 2026-08-10, running `estate-seed.mjs --check`
 * against testnet while mainnet was up beside it: it reported
 * `nda.worlds: http://127.0.0.1:4116/v1/worlds… answered 401` — mainnet's nda
 * refusing an unauthenticated stranger, reported as a testnet content failure.
 *
 * `--check` only reads. The seeder proper WRITES, and the write goes to whatever
 * answers: seeding testnet would have created worlds in mainnet's nda,
 * communities in mainnet's community, plans in mainnet's billing, entries in
 * mainnet's ledger and uploads in mainnet's studio, and reported success both
 * times. `CF_PORT_BASE` is read from the estate's own env file for the same
 * reason the hostnames are read from the gateway's: one fact, one place.
 */
export const PORT_BASE =
  process.env.CF_PORT_BASE || fromEstateEnv('CF_PORT_BASE') || '4'

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
 * Whether this estate's WEB surfaces are retired — i.e. whether its own page
 * hostnames redirect to the other estate rather than serving a bundle.
 *
 * ── WHY A SEEDER NEEDS TO KNOW THIS ──────────────────────────────────────────
 *
 * `true` on testnet since micro-org#459 step 5. The gateway's
 * `cf-retired-web-sub` router (priority 550, `estate-web.yml`) answers 302 to
 * every `*-testnet` hostname whose registry row is `servesUi: true`, and spares
 * `/v1` so the combined view's cross-estate reads keep working.
 *
 * `servesUi: true` is ALSO the predicate `seed/beacon.mjs` used to decide which
 * hostnames to probe for a 200. The two are keyed on the same registry field
 * with opposite intent, so between 2026-08-14 and 2026-08-16 testnet's beacon
 * probed exactly the set its own gateway redirects: 21 probes, all expecting
 * 200, all getting 302, and a public status page reading `Outage` across 21
 * product groups over an estate that was answering. Nothing was down.
 *
 * READ from the gateway's own env file for the reason `WEB_SUFFIX` above is:
 * this is a fact about how the gateway is CONFIGURED, and a seeder that guessed
 * it from the environment label would be a second declaration of it.
 *
 * Compared against the string `'true'` rather than tested for truthiness,
 * because `traefik.env` sets `CF_WEB_RETIRED=false` on mainnet and the string
 * `'false'` is truthy. `estate-web.yml` compares the same way and says so:
 * "Neither file can now be silent about whether this estate is retired."
 */
export const WEB_RETIRED =
  (process.env.CF_WEB_RETIRED || fromTraefikEnv('CF_WEB_RETIRED') || 'false') === 'true'

/**
 * The API host, read from the file the GATEWAY reads rather than guessed.
 *
 * `estate-up.sh` reads it from exactly here and refuses to start without it,
 * because an unset `CF_API_HOST` makes every public API route answer 502 with
 * nothing in Traefik's log. Guessing `api${WEB_SUFFIX}` would be right today and
 * wrong the first time somebody deploys under a real apex.
 */
export const API_HOST =
  process.env.CF_API_HOST || fromTraefikEnv('CF_API_HOST') || `api${WEB_SUFFIX}`

/**
 * The identity this estate's services actually TRUST — which since micro-org#459
 * stage 2 is not necessarily this estate's own.
 *
 * ── THE SEEDER SIGNED IN SOMEWHERE NOBODY ACCEPTS, AND SAID SO 32 TIMES ──────
 *
 * This was `https://nimbus${WEB_SUFFIX}` inline in `SERVICES` below, which is
 * right on mainnet and, since the one-login migration, wrong on testnet.
 * `compose/testnet.env` sets `CF_IDENTITY_URL=https://nimbus.cloudsforge.online`
 * and `docker-compose.estate.yml` hands it to every testnet container, so the
 * testnet estate verifies bearers against the SHARED identity's JWKS. Measured
 * on 2026-08-16, on the running containers:
 *
 *   cf-testnet-market-1     IDENTITY_JWKS_URL=https://nimbus.cloudsforge.online
 *   cf-testnet-foresight-1  IDENTITY_JWKS_URL=https://nimbus.cloudsforge.online
 *   cf-testnet-hub-api-1    IDENTITY_JWKS_URL=https://nimbus.cloudsforge.online
 *
 * `cf-testnet-identity-1` is still running and still answers `/auth/login` with
 * 200 and a signed token. Nothing in the estate accepts it. So a testnet seeding
 * run logged in successfully and then failed EVERY write with
 * `401 unauthenticated` — 32 of them in one run, each one looking like a
 * per-service authorisation problem and none of them naming the cause. That is
 * micro-org#472, seen from the seeder rather than from a browser.
 *
 * It is not a user-token network mismatch: `identity/src/tokens.ts` deliberately
 * puts NO `net` claim on user tokens, precisely so one person's token crosses
 * both estates. The token was fine. It was signed by the wrong identity.
 *
 * READ from the estate's own env file, for the same reason `WEB_SUFFIX` and
 * `WEB_RETIRED` are: it is a fact about how this estate is CONFIGURED, and the
 * file the seeder reads is the file the containers were started from.
 *
 * The `https:` guard is not decoration. `CF_IDENTITY_URL` is legitimately an
 * in-compose address on some estates (`docker-compose.estate.yml` defaults it to
 * `http://identity:4000`), and this seeder runs on the HOST, outside that
 * network. An unreachable base would fail as a connection error at login, which
 * reads as "identity is down" rather than "this address was never for you".
 *
 * `IDENTITY_TOKENS_FILE` below keys off the same answer, so it is computed once
 * here rather than twice: two readings of one variable that can disagree is the
 * exact shape of the defect this block exists to close.
 */
const DECLARED_IDENTITY = (() => {
  const declared = process.env.CF_IDENTITY_URL || fromEstateEnv('CF_IDENTITY_URL')
  return declared && declared.startsWith('https://') ? declared.replace(/\/+$/, '') : null
})()

/** The identity host this run signs in at. See the block above for why it is read. */
export const IDENTITY_BASE = DECLARED_IDENTITY || `https://nimbus${WEB_SUFFIX}`

/**
 * Whether this estate borrows another estate's identity rather than running its own.
 *
 * `login()` reports it on every run. The failure this exists to make legible is
 * silent by construction — the WRONG identity also answers 200 with a signed
 * token — so the only place it can be caught before the writes start failing is
 * a line naming where the token came from.
 */
export const IDENTITY_IS_SHARED = DECLARED_IDENTITY !== null

/**
 * Where each service is, and whether the request crosses the gateway.
 *
 * `gateway: false` is not a shortcut. It is a fact about the deployment, and it
 * is written down here so the report can name the four services whose content
 * this seeder created without a browser ever being able to reach them.
 */
export const SERVICES = {
  // NOT `https://nimbus${WEB_SUFFIX}`, which is what it said until 2026-08-16 and
  // is why a whole testnet seeding run 401'd. See `IDENTITY_BASE` above.
  identity: { base: IDENTITY_BASE, gateway: true },
  custody: { base: `https://vault${WEB_SUFFIX}`, gateway: true },
  foresight: { base: `https://foresight${WEB_SUFFIX}`, gateway: true },
  market: { base: `https://${API_HOST}`, gateway: true },
  mint: { base: `https://${API_HOST}`, gateway: true },
  // The title register. On the API host and not a surface of its own:
  // `gateway/dynamic/public-api.yml` routes `/v1/titles`, `/v1/players`,
  // `/v1/provisions` and `/v1/seasons` on `CF_API_HOST` to `http://worlds:4000`.
  //
  // NOT `https://worlds${WEB_SUFFIX}`, which is `worlds-web` — the browser
  // bundle that READS this register. Addressing that host would send
  // `POST /v1/titles` at an nginx serving static files, which answers 405 and
  // looks like the service refusing the write.
  worlds: { base: `https://${API_HOST}`, gateway: true },
  // Not published by the gateway; loopback host ports from the compose file.
  //
  // `studio` is the newest entry and the one whose `gateway: false` is currently
  // load-bearing rather than incidental: it has NO Host() rule anywhere in
  // `gateway/dynamic/estate-web.yml`, so no browser can reach it. That matters
  // more than it does for the other three, because studio is the only service in
  // this list whose output a BROWSER has to fetch directly — a cover image is an
  // `<img src>` pointing at it. Seeded covers will therefore be stored correctly
  // and will not render until studio is routed. Port 4000 inside the container,
  // published on 4111 by `docker-compose.estate.yml`.
  //
  // The address is overridable because it is the one in this list that is going
  // to move: the day studio gains a Host() rule, its base becomes an https
  // surface and this loopback port stops being the right answer. `CF_STUDIO_URL`
  // means that is a deploy variable rather than an edit here — and it is what
  // lets this seeder be driven against a studio built from a working tree, which
  // is how the upload path was exercised before the estate's container was
  // rebuilt.
  studio: {
    base: process.env.CF_STUDIO_URL || `http://127.0.0.1:${PORT_BASE}111`,
    gateway: false,
  },
  // The other four, overridable for the same reason `studio` is — and now for a
  // second one that applies to all five at once.
  //
  // ── A PUBLISHED HOST PORT IS A COMPOSE FACT, NOT AN ESTATE FACT ─────────────
  //
  // `127.0.0.1:4116` is where nda answers *because docker published it there*.
  // Kubernetes publishes nothing: the estate's forty-six host ports do not exist
  // on the k3s node, and each service is reachable only at its Service's
  // ClusterIP. So on that runtime all four of these resolve to a closed port,
  // `fetch` throws, and `--check` reports
  //
  //     community: http://127.0.0.1:4117/v1/communities?limit=200 … fetch failed
  //
  // which reads as "the community service is down" and means "this file assumed
  // docker". Measured on the migration VM on 2026-08-19: three of the five,
  // three failures, none of them about content.
  //
  // The four https surfaces above needed no such knob because a hostname is a
  // property of the ESTATE and survives the runtime change intact — which is the
  // whole argument for why these four are the exceptions. They are addressed by
  // deployment topology, so they take a deployment variable.
  //
  // `CF_STUDIO_URL` was already here and keeps its name; the other four follow
  // its shape rather than inventing a second convention, because a reader who
  // has found one of them has found all five.
  ledger: {
    base: process.env.CF_LEDGER_URL || `http://127.0.0.1:${PORT_BASE}102`,
    gateway: false,
  },
  billing: {
    base: process.env.CF_BILLING_URL || `http://127.0.0.1:${PORT_BASE}106`,
    gateway: false,
  },
  nda: {
    base: process.env.CF_NDA_URL || `http://127.0.0.1:${PORT_BASE}116`,
    gateway: false,
  },
  community: {
    base: process.env.CF_COMMUNITY_URL || `http://127.0.0.1:${PORT_BASE}117`,
    gateway: false,
  },
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
 * The two names the key file is known by, newest first.
 *
 * ── DECLARED ABOVE `MINER_DATA`, AND IT HAS TO BE ───────────────────────────
 *
 * `readMinerData()` is hoisted, so it may be CALLED from line 313 above; this
 * `const` is not, so it may not be READ from there. Declaring it below the call
 * threw `ReferenceError: Cannot access 'MINER_KEY_FILES' before initialization`
 * at import time and took the whole seeder down — every domain, not just mint.
 * `node --check` passes on that, because a temporal dead zone is a runtime fact
 * and not a syntax error; only actually running it finds this.
 *
 * ── AND THE SECOND NAME IS WHY THIS IS A LIST ────────────────────────────────
 *
 * micro-org#206 SEALED the plaintext coinbase key. `coinbase-key.json` — a file
 * with `privateKey` in it at mode 0600 — became `coinbase-keystore.json`, an
 * encrypted keystore whose passphrase lives in `miner-keys/secrets/`. That was
 * the right thing to do and it is not being undone here.
 *
 * What nobody noticed is that the seeders were reading that file, and they went
 * on looking for the old name. Measured on the app host 2026-08-11:
 *
 *     drwx------  miner-keys/
 *     -rw-------  miner-keys/secrets/coinbase-passphrase
 *     drwxr-xr-x  miner-keys/mainnet/
 *     -rw-------  miner-keys/mainnet/coinbase-keystore.json      <- the only key file
 *
 * so `readMinerData()` found no `coinbase-key.json`, fell through to the laptop
 * path that does not exist on this host, and `seed/mint.mjs` reported
 *
 *     skip  no token orders: there is no miner key file to read the platform's
 *           own chain address from
 *
 * on every run since the sealing. That is not what happened: the file is there
 * and the address in it is not a secret. The result reached the operator as
 * `estate-verify.sh`'s "mint.tokens is EMPTY", which reads as missing content
 * rather than as a path that stopped matching — the failure mode this file's
 * previous fix (the laptop path) was written to stop, recurring under a new name.
 */
export const MINER_KEY_FILES = ['coinbase-keystore.json', 'coinbase-key.json']

/**
 * The directory holding this environment's miner keys — the root, not the
 * per-network directory.
 *
 * Hoisted out of `readMinerData()` because `MINER_PASSPHRASE_FILE` below needs
 * the same root and the two must not be able to disagree: the passphrase is one
 * directory up from the keystore it opens, so a second copy of this expression
 * would be a second chance to look for a secret in the wrong place. Declared
 * above every reader for the temporal-dead-zone reason `MINER_KEY_FILES` gives.
 */
const MINER_KEYS_ROOT = process.env.CF_MINER_KEYS || path.resolve(ROOT, '../miner-keys')

/**
 * The directory holding `coinbase-key.json` for THIS environment's miner.
 *
 * `compose/docker-compose.miners.yml,161` already declares the deployed
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
  const perNetwork = path.join(MINER_KEYS_ROOT, EMBER_NETWORK)
  if (MINER_KEY_FILES.some((f) => fs.existsSync(path.join(perNetwork, f)))) return perNetwork
  const home = process.env.EMBER_HOME || path.join(process.env.HOME || '', '.cloudsforge/ember-testnet')
  return path.join(home, 'miner')
}

/**
 * The miner's ADDRESS, from whichever of the two files exists — and nothing else
 * out of either of them.
 *
 * An Ethereum keystore carries `address` in the CLEAR, beside the encrypted
 * `ciphertext`; that is what makes it possible to know which account a keystore
 * is for without unlocking it. Read on the app host, `coinbase-keystore.json`
 * has top-level keys `address, cipher, ciphertext, kdf, version, warning`, and
 * `address` is a 42-character `0x`-prefixed string. So every caller that wants
 * to say WHO the platform is can be served without the passphrase ever being
 * read, and this function deliberately cannot decrypt anything.
 *
 * `seed/foresight.mjs` is STILL not ported onto this, and now for the opposite
 * reason. This paragraph used to say it had been left behind — that it needs
 * `privateKey` to sign a market open, that a sealed keystore cannot give it one
 * without the passphrase, and that "reading a passphrase and decrypting a mining
 * key inside a seeder is a much larger decision than this fix", so it went on
 * looking for the plaintext file and skipping. That was true when it was
 * written and it stopped being true on 2026-08-11: micro-org#411 took the
 * decision, and `signingChain()` there now opens the sealed keystore through
 * hearth's own `resolveCoinbaseKey`, with the passphrase supplied as a PATH
 * (`MINER_PASSPHRASE_FILE`, below) and never as a value.
 *
 * So the two functions have DIFFERENT JOBS rather than one being behind the
 * other, and that separation is worth keeping: this one answers "who is the
 * platform on chain" and is deliberately incapable of decrypting anything, which
 * is why every caller that only needs an address — `seed/mint.mjs` is the whole
 * of that list — can be served without a passphrase existing on the machine at
 * all.
 *
 * Returns null when neither file exists — a machine with no miner is a normal
 * machine, and CI is one.
 */
export const MINER_ADDRESS = readMinerAddress()

function readMinerAddress() {
  for (const name of MINER_KEY_FILES) {
    try {
      const raw = JSON.parse(fs.readFileSync(path.join(MINER_DATA, name), 'utf8'))
      /* Keystores written by other tools omit the `0x`. Normalised here so a
       * caller that pastes this into an API cannot be refused for a prefix. */
      const addr = String(raw.address ?? '')
      if (/^(0x)?[0-9a-fA-F]{40}$/.test(addr)) return addr.startsWith('0x') ? addr : `0x${addr}`
    } catch {
      /* missing or unreadable — try the next name, then give up */
    }
  }
  return null
}

/**
 * The PATH of the file holding the keystore passphrase. Never the passphrase.
 *
 * ── A PATH, BECAUSE THE ESTATE ALREADY DECIDED THAT ──────────────────────────
 *
 * `compose/docker-compose.miners-apphost.yml:155` mounts
 * `miner-keys/secrets/coinbase-passphrase` at `/run/secrets/coinbase-passphrase`
 * read-only and sets `HEARTH_COINBASE_PASSPHRASE_FILE` to that path, and
 * `docker-compose.miners.yml` says why in one line: an env STRING "is readable by
 * anything that can read this process's environment, and `docker inspect` is one
 * of those things". `hearth/node/src/coinbase.js` supports both forms and prefers
 * the file. Nothing in this repository should ever hold the other kind, so this
 * constant is a path or it is null, and no code here reads what is in it —
 * hearth opens it, uses it and drops it.
 *
 * ── WHY THERE IS A DEFAULT AT ALL ────────────────────────────────────────────
 *
 * The passphrase's location is a FACT ABOUT THIS DEPLOYMENT, in exactly the
 * sense `CF_API_HOST` and `CF_RPC_UPSTREAM` above are, and this file's whole
 * argument is that such facts are read rather than typed at the invocation.
 * `secrets/` sits beside `mainnet/` and `testnet/` under the same
 * `CF_MINER_KEYS` root that `MINER_DATA` derives from — one root, two children,
 * one expression — so an operator who has the keystore mounted has the
 * passphrase discoverable without being told twice.
 *
 * The default is EXISTENCE-CHECKED and the explicit form is NOT, deliberately.
 * An operator who sets `HEARTH_COINBASE_PASSPHRASE_FILE` and gets the path wrong
 * wants a refusal naming their path — which hearth gives, in those words — and
 * not a silent fall back onto a file they were not thinking about.
 */
export const MINER_PASSPHRASE_FILE = readMinerPassphraseFile()

function readMinerPassphraseFile() {
  const named = process.env.HEARTH_COINBASE_PASSPHRASE_FILE
  if (named) return named
  const conventional = path.join(MINER_KEYS_ROOT, 'secrets', 'coinbase-passphrase')
  return fs.existsSync(conventional) ? conventional : null
}

export const COMPOSE = process.env.COMPOSE || 'compose/docker-compose.estate.yml'

/**
 * The `--env-file` set every `docker compose` call in this seeder must carry.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * **WITHOUT THIS, EVERY COMPOSE CALL RESOLVED TO MAINNET, ON BOTH ESTATES.**
 *
 * `docker-compose.estate.yml` is `name: ${CF_PROJECT:-cloudsforge-estate}`, and
 * `CF_PROJECT=cf-testnet` lives in `compose/testnet.env`. A compose call that does
 * not pass that file gets the DEFAULT — so it addressed the mainnet project no
 * matter which estate the run was aimed at.
 *
 * Measured on 2026-08-05: `--counts` pointed at testnet reported
 * `foresight.markets=9, market.listings=5` while `cf-testnet-postgres-1` actually
 * held 0 and 0. Those are mainnet's numbers. micro-org#194.
 *
 * Two call sites, and they failed differently:
 *
 *   * `psqlRead` passed NO env file, so every row count on a testnet run was a
 *     mainnet row count. That is also the seeder's own idempotency proof — the
 *     before/after counts this file's header says the claim rests on — measured
 *     against a database the run was not writing to, so it could not have failed.
 *   * `recreateService` passed the tokens file alone, which does not carry
 *     `CF_PROJECT` either. That one runs `up -d --wait`, so a testnet run that
 *     re-minted a service token RECREATED THE MAINNET CONTAINER.
 *
 * This is the hazard `WEB_SUFFIX` above already argues about — a testnet run that
 * "would write its content into production and report success". The hostnames
 * were fixed then. The compose project was not, and it is the same defect one
 * layer down.
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Same two files, same order, same reason as `release-deploy.sh`: repeated
 * `--env-file` flags merge and the last one wins, so tokens last means a
 * credential in the tokens file beats a placeholder in the estate file.
 */
export const ESTATE_ENV = ESTATE_ENV_REL
export const TOKENS_FILE =
  process.env.TOKENS_FILE ||
  (process.env.CF_EMBER_NETWORK && process.env.CF_EMBER_NETWORK !== 'mainnet'
    ? `compose/estate/tokens.${process.env.CF_EMBER_NETWORK}.env`
    : 'compose/estate/tokens.env')
export const ENV_FILES = ['--env-file', ESTATE_ENV, '--env-file', TOKENS_FILE]

/**
 * The tokens file holding the operator credential for `IDENTITY_BASE` — which is
 * not always this estate's own.
 *
 * The operator account is a property of the IDENTITY, not of the estate, and
 * since the one-login migration those stopped being the same thing. Measured on
 * 2026-08-16: `tokens.env` and `tokens.testnet.env` carry the same
 * `ESTATE_ADMIN_EMAIL` and DIFFERENT `ESTATE_ADMIN_PASSWORD` values. So the
 * invocation this file documents two blocks down —
 * `set -a; . compose/estate/tokens.testnet.env; set +a` before a testnet run —
 * now exports a password for an identity the run will never talk to, and the
 * only symptom is a 401 at `/auth/login` that reads as a rotated credential.
 *
 * Everything ELSE in a tokens file — service tokens, per-estate secrets — is
 * genuinely keyed on the estate, and `ENV_FILES` above still uses `TOKENS_FILE`
 * for exactly that reason. This is a second name rather than a change to the
 * first.
 */
export const IDENTITY_TOKENS_FILE = IDENTITY_IS_SHARED ? 'compose/estate/tokens.env' : TOKENS_FILE

export const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'estate-admin@example.test'

/**
 * NO DEFAULT, DELIBERATELY, AND THIS USED TO CARRY ONE.
 *
 * The fallback here was the same literal that `estate-bootstrap.sh` defaulted to
 * until 2026-08-09 — a string committed to a public repository, against an
 * estate whose `/v1/auth/login` answers from the internet. Read that file's
 * operator block for the measurement. The password is rotated, and every script
 * that signs in as the operator now has to be given the real one.
 *
 * `ESTATE_ADMIN_PASSWORD` is the name it is stored under in
 * `compose/estate/tokens.env`, so the usual invocation is to source that file
 * rather than to type a secret at a prompt where the shell will keep it:
 *
 *     set -a; . compose/estate/tokens.env; set +a
 *
 * Throwing beats falling back. A seed that silently uses the wrong credential
 * fails later, somewhere else, as a 401 nobody attributes to this line.
 *
 * A FUNCTION rather than a constant, and that is not a style choice. Eleven
 * modules import this file, and most of them never sign in as the operator —
 * `check.mjs` and `images.mjs` among them. A constant that throws does so at
 * IMPORT, so it would take down every one of those too, for a credential they
 * were never going to send. Evaluated where it is spent instead: at `login()`.
 */
export function adminPassword() {
  // THE FILE BEATS THE SHELL HERE, AND ONLY HERE.
  //
  // `ESTATE_ADMIN_PASSWORD` in the environment is almost always the wrong
  // estate's — the documented invocation sources this estate's tokens file, and
  // on an estate that borrows another's identity that is the wrong credential by
  // construction (see `IDENTITY_TOKENS_FILE`). So the password for the identity
  // this run will ACTUALLY sign in at is read from that identity's own file, and
  // the exported one is only the fallback.
  //
  // `ADMIN_PASSWORD` stays ahead of both: it is the explicit override, the name
  // nothing writes into an env file, and the one an operator types deliberately.
  const value =
    process.env.ADMIN_PASSWORD ||
    fromEnvFile(path.join(ROOT, IDENTITY_TOKENS_FILE), 'ESTATE_ADMIN_PASSWORD') ||
    process.env.ESTATE_ADMIN_PASSWORD
  if (!value) {
    throw new Error(
      `ADMIN_PASSWORD (or ESTATE_ADMIN_PASSWORD) is not set, and ${IDENTITY_TOKENS_FILE} — the ` +
        `tokens file for ${IDENTITY_BASE}, which is where this run signs in — carries no ` +
        'ESTATE_ADMIN_PASSWORD either. It has no default: the one it used to have is published ' +
        'in this repository.',
    )
  }
  return value
}

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
 * (`gateway/dynamic/estate-web.yml`). A seeder that omitted the header
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
    body: { identifier: ADMIN_EMAIL, password: adminPassword() },
    expect: 200,
  })
  if (!body.accessToken) throw new Error('identity returned no accessToken')
  // WHERE the token came from, on every run, because a token from the wrong
  // identity is indistinguishable from a good one until something rejects it.
  // The estate ran for two days with a testnet identity that answers 200 and
  // signs tokens nothing accepts (micro-org#472); the seeder's report of that
  // was 32 separate 401s, none of which named this. `note`, not `ok` — this is
  // context for the lines below it, not a check that passed.
  note(
    IDENTITY_IS_SHARED
      ? `signed in at ${IDENTITY_BASE} — this estate BORROWS that identity (CF_IDENTITY_URL), ` +
          `so the operator credential came from ${IDENTITY_TOKENS_FILE}, not from ${TOKENS_FILE}`
      : `signed in at ${IDENTITY_BASE} (this estate's own identity)`,
  )
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
 * server.ts`) because `wallet` is what a user talks to.
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
 * than exchanging a long-lived credential — `foresight/src/index.ts` and
 * `market/src/index.ts` are both `const token = () => env.serviceToken`. Both
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
      // BOTH files. The tokens file alone does not carry `CF_PROJECT`, so this
      // recreated the MAINNET container on a testnet run — a write, not just a
      // misreported count. micro-org#194.
      ...ENV_FILES,
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
    // ENV_FILES, or this reads the mainnet project's postgres on a testnet run
    // and reports its rows as testnet's. micro-org#194.
    ['compose', ...ENV_FILES, '-f', COMPOSE, 'exec', '-T', 'postgres', 'psql', '-qtA', '-U', 'cloudsforge', '-d', db, '-c', sql],
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
