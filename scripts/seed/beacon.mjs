/**
 * Seed micro-beacon's probes — from the surface registry, because they are facts.
 *
 * ── WHY THIS IS NOT A HAND-WRITTEN LIST ──────────────────────────────────────
 *
 * A probe says "this address should answer 200". That is not a preference, it is
 * a fact about the deployment, and this estate already has exactly one
 * declaration of it: `ui/packages/ui/src/surfaces.ts`. Its own header records
 * why it exists — "before a registry existed the same list was maintained by
 * hand in eight places… and they had already drifted apart" — so writing a ninth
 * copy here, in a seeder, would be repeating the mistake the registry was
 * created to end.
 *
 * The registry also already answers the only hard question a probe seeder has.
 * `servesUi` is a measured field, not a reasoned one: every value was taken
 * through the estate gateway on 2026-08-04 with
 * `curl --cacert deploy/gateway/certs/ca.crt`, and `true` means that request
 * returned `200 text/html`. So "which addresses should a probe expect 200 from"
 * is answered by the file, with evidence, and this script does not get a vote.
 *
 * That distinction matters for two entries in particular, which the registry
 * calls out: `lantern` and `beacon` are `inSwitcher: true` and serve NO page —
 * both answer `404 application/json` on their own hostname, because
 * `estate-web.yml` routes the whole beacon host to the API. Probing them for
 * a 200 would have manufactured two permanently red probes out of a
 * misunderstanding. `servesUi` excludes them, and it is right to.
 *
 * The registry is read as a module rather than parsed. Node 24 strips types
 * natively, so `SURFACES` arrives as data with its fields intact and a change to
 * the registry's SHAPE breaks this loudly instead of silently matching nothing —
 * which a regular expression over the file would have done.
 *
 * ── IDEMPOTENT BY CONSTRUCTION ───────────────────────────────────────────────
 *
 * `PUT /v1/probes/:name` is an upsert keyed on the name (`beacon/src/server.ts`).
 * There is nothing to check first and nothing to duplicate: running this twice
 * writes the same nineteen rows twice and the count does not move.
 *
 * ── A RETIRED ESTATE HAS NO PAGES OF ITS OWN, AND MUST NOT BE PROBED FOR ONE ─
 *
 * This is the defect that produced a total public outage over a healthy estate,
 * and it is worth stating precisely because both halves of it were correct.
 *
 * `cf-retired-web-sub` (`gateway/dynamic/estate-web.yml`, priority 550, rendered
 * only when `CF_WEB_RETIRED` is `true`) answers 302 to every `*-testnet`
 * hostname whose registry row is `servesUi: true`, sparing `/v1` so the combined
 * view's cross-estate reads keep working. That is micro-org#459 step 5 and it is
 * right: since the combined view, testnet HAS no frontends — its pages are
 * mainnet's pages with a network selected.
 *
 * The loop below chose which hostnames to probe for a 200 using `servesUi: true`.
 * Also right, and argued at length above.
 *
 * SAME PREDICATE, OPPOSITE INTENT. So from the retirement deploy on 2026-08-14
 * at 04:08 UTC, this seeder pointed 21 probes at exactly the set the gateway
 * redirects. Measured on 2026-08-16: every one of them `expect=200 got=302`,
 * `probe_state` 21 down and 1 up, `check_rollups` 128,405 down checks out of
 * 134,051 on 08-15 — and `status.<apex>` reading
 *
 *     ■ Outage — Something has stopped answering. Read across 21 product groups.
 *
 * with 28 incidents opened inside the half hour the retirement went live. The
 * one probe that stayed green was `worlds.titles`, because it is an API read and
 * `/v1` is what the retirement spares. That is the whole fix, in one row of
 * evidence: on a retired estate the API is what still exists, so the API is what
 * a probe must ask.
 *
 * So `WEB_RETIRED` splits this file's two jobs:
 *
 *   * **Surface probes are upserted `enabled: false`.** Not deleted — a disabled
 *     probe keeps its history and can be switched back on, and `listProbes(sql,
 *     true)` is what the public projection reads (`beacon/src/server.ts`), so
 *     disabling is exactly "stop publishing this" and nothing more. Their past
 *     rollups stay in the daily bars, which is honest: those hostnames really did
 *     stop serving pages on those days.
 *   * **The retirement itself gets probed**, expecting 302 rather than 200. If it
 *     breaks, a retired frontend starts serving its own stale bundle again — the
 *     pre-#459 behaviour — and nothing else in the estate would notice. The
 *     prober uses `redirect: 'manual'` (`beacon/src/probes.ts`), so a 302 is
 *     recorded as a 302 rather than followed to the mainnet 200.
 *
 *     Nothing else CAN notice, and that is verified rather than assumed:
 *     `scripts/probe-public-estate.py` is the estate's other prober, it probes
 *     the same hostnames from outside, and it is structurally blind here twice
 *     over — `urlopen` follows redirects, and its bar is "anything below 500 is
 *     an answer". A retired hostname and an un-retired one both read `OK` to it,
 *     which is correct for the question it asks ("is the public estate
 *     answering?") and is why that question cannot cover this one. It is also
 *     why the two days of false outage passed every check the estate has: the
 *     one prober that followed the redirect was happy, and the one that did not
 *     was the one publishing the page.
 *
 * ── AND `slos` IS LEFT EMPTY, DELIBERATELY ───────────────────────────────────
 *
 * `PUT /v1/slos/:name` exists and would work. It is not called.
 *
 * A probe records an address that should answer. An SLO records a THRESHOLD —
 * how much unavailability is acceptable, over what window — and nobody has
 * agreed one for this estate. A seeded SLO would not be a placeholder: it would
 * become the number the estate is judged against, in a status page and in an
 * alert, chosen by whichever script ran first. Two agents have already refused
 * to write one and this is the third refusal, for the same reason.
 *
 * An empty `slos` table is an honest statement that no availability target has
 * been agreed. A seeded one is a target nobody set, presented as one somebody
 * did.
 *
 * ── ONE PROBE IS HAND-WRITTEN, AND THAT IS THE POINT OF IT ───────────────────
 *
 * Every probe above asks a bundle host for its shell. That proves nginx is
 * serving and the gateway is routing. It proves nothing about whether the
 * service behind the API answers, because none of those requests reaches one.
 *
 * micro-org#181: Forge Worlds showed no registry on testnet for roughly an hour
 * (#150) and nothing in the estate noticed. The outage surfaced only as a
 * `t.diagnostic` in micro-worlds-web's `api-host-resolves.test.ts`, which
 * deliberately does not fail on a 5xx — a 5xx proves the hostname resolved,
 * connected and routed, which is all that test owns. That is correct behaviour
 * for that test. A diagnostic is not an alert, and no other tier asserted on it.
 *
 * So `API_READ_PROBES` below is a hand-written list, and the header's argument
 * against hand-written lists does not apply to it. The registry answers "which
 * hostnames serve a page"; it does not, and should not, answer "which reads are
 * public, unauthenticated, and cheap enough to run every ten seconds". That is
 * a fact about a ROUTE, and the registry holds no routes.
 *
 * The bar for adding an entry, and it is deliberately high:
 *
 *   1. **Unauthenticated.** Verified at the handler, not assumed from a 200 —
 *      a probe carrying a credential measures the credential too, and expires.
 *   2. **A real read.** It must touch the database, or it is a liveness probe
 *      wearing a costume and would have gone green through #150.
 *   3. **Measured through the gateway on both estates before it is added here**,
 *      for the same reason `servesUi` is a measured field: an unverified probe
 *      is a permanently red row, and a permanently red row is how a status page
 *      teaches people to ignore it.
 *
 * `servesUi: false` is why these hosts are absent from the loop above and it
 * remains right — those six hosts serve no page and probing them for one would
 * manufacture red rows. This does not relax that filter. It adds a different
 * question, asked of a path rather than of a host.
 */

import {
  ok,
  bad,
  skip,
  note,
  head,
  WEB_SUFFIX,
  SITE_HOST,
  WEB_RETIRED,
  EMBER_NETWORK,
} from './lib.mjs'

/**
 * Beacon is not in the shared SERVICES map because it is the only consumer, and
 * because its host is API-only: `estate-web.yml` says in its own words that
 * "no bundle is served at `beacon<suffix>`" and routes the whole host to the
 * service. So this is the front door, not a loopback shortcut.
 */
const BEACON_BASE = process.env.BEACON_URL || `https://beacon${WEB_SUFFIX}`

/** Ten seconds between probes, two-second deadline. Frequent enough to notice, cheap enough to run. */
const INTERVAL_MS = 10_000
const DEADLINE_MS = 2_000

async function beaconApi(path_, opts = {}) {
  const { method = 'GET', body, token, expect } = opts
  const headers = { accept: 'application/json' }
  if (body !== undefined) headers['content-type'] = 'application/json'
  if (token) headers.authorization = `Bearer ${token}`
  const res = await fetch(`${BEACON_BASE}${path_}`, {
    method,
    headers,
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20_000),
  })
  const text = await res.text()
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = { raw: text.slice(0, 200) }
  }
  if (expect !== undefined && res.status !== expect) {
    throw new Error(`${method} ${path_} → ${res.status}: ${text.slice(0, 200)}`)
  }
  return { status: res.status, body: parsed }
}

/** The registry, as data. Returns null if it cannot be read — a reason, never a guess. */
async function loadSurfaces() {
  try {
    const mod = await import('../../../ui/packages/ui/src/surfaces.ts')
    return mod.SURFACES ?? null
  } catch (err) {
    note(`could not read the surface registry as a module: ${err.message.slice(0, 160)}`)
    return null
  }
}

/**
 * `https://<subdomain><suffix><basePath>`, or the APEX SURFACE when the subdomain
 * is empty.
 *
 * The empty case is not a convenience — it is the one hostname that cannot be
 * formed by concatenation. `'' + WEB_SUFFIX` is `-testnet.cloudsforge.online`,
 * which is not a legal DNS label, so the apex surface carries its own variable
 * (`SITE_HOST`) and this branch reads it. Getting it wrong would point every
 * beacon probe of the marketing site at a hostname that does not resolve.
 */
function urlFor(surface) {
  const host = surface.subdomain === '' ? SITE_HOST : `${surface.subdomain}${WEB_SUFFIX}`
  return `https://${host}${surface.basePath ?? '/'}`
}

/**
 * Public unauthenticated reads worth probing. See this file's header for the bar.
 *
 * `worlds.titles` is the read micro-org#181 names, and it clears all three tests:
 *
 *   1. `worlds/src/server.ts` — `define('GET', '/v1/titles', …)` makes NO
 *      `authenticate` call. Its sibling `POST` does, immediately, so
 *      the omission is a decision rather than an oversight.
 *   2. It calls `listTitles(deps.sql, …)`. One table, one query — the exact read
 *      that was failing during #150 while every bundle probe stayed green.
 *   3. Measured through both gateways before being written here, not after:
 *      `api.cloudsforge.online/v1/titles` → 200 and
 *      `api-testnet.cloudsforge.online/v1/titles` → 200.
 *
 * `productGroup` is `Forge Worlds` — the name a reader recognises on the status
 * page, for the reason spelled out at the `surface.name` decision below. It
 * deliberately matches no surface probe's group: this probe reports on the
 * registry API, and folding it into the bundle's row would let a working shell
 * mask a dead API, which is precisely how #150 stayed invisible.
 *
 * `critical: true`. The `api` surface is `kind: 'service'`, and the loop above
 * would therefore have marked it non-critical — but that rule is about operator
 * tools not paging like products, and this is not an operator tool. It is the
 * read every Forge Worlds client makes before it can show anything.
 */
const API_READ_PROBES = [
  {
    key: 'worlds.titles',
    productGroup: 'Forge Worlds',
    path: '/v1/titles',
    subdomain: 'api',
    critical: true,
  },
  /*
   * ── THE FIVE ADDED ON 2026-08-16, AND WHAT EACH ONE COST TO ADD ────────────
   *
   * The retirement (see this file's header) took every surface probe off testnet
   * and left the estate with ONE probe that asks a service a question. That is
   * not a status page. These five were chosen by running the bar above over
   * every unauthenticated `GET` in the estate with no path parameter — the
   * candidate set is mechanical, the rejections are not, and both are recorded
   * here because the rejected ones look like perfectly good probes.
   *
   * MEASURED THROUGH BOTH GATEWAYS ON 2026-08-16, before being written here:
   *
   *   market<suffix>/v1/collections          200 / 200
   *   foresight<suffix>/stake-assets         200 / 200
   *   tessera<suffix>/v1/wards               200 / 200
   *   aetherholm<suffix>/v1/chronicle/seasons 200 / 200
   *   network-testnet<…>/v1/faucet           200 — and 404 on mainnet, below
   *
   * REJECTED, WITH REASONS, because each of these answers 200 on both estates
   * and would have looked like coverage:
   *
   *   * `foresight/categories`, `trade/v1/capabilities`, `mint/v1/catalogue`,
   *     `devplatform/v1/scopes` — all 200, all STATIC. Their handlers never
   *     touch `deps.sql`; they return a constant. That is test 2, and it is the
   *     test that matters: a static route is a liveness probe wearing a costume
   *     and would have gone green straight through #150.
   *   * `nda/v1/worlds` — 401. Authenticated, so it fails test 1.
   *   * `community/v1/communities` — 404 at the gateway. Publicly unrouted, so
   *     there is nothing to probe.
   *   * `beacon/api/status/public` — 200 on both, and a real read. Rejected
   *     anyway: beacon would be probing itself, so the check only runs when the
   *     answer is already known to be yes. A probe that cannot report its own
   *     subject's outage is not a probe.
   *
   * `foresight/stake-assets` is the one entry not under `/v1`, and it is the
   * right path rather than the obvious `/markets`: `estate-web.yml` routes
   * `/markets` to the API only for `Accept: application/json`, and a probe sends
   * no such header — mainnet answers it with the app shell, 200, forever green.
   * `cf-api-foresight-resources` routes `/stake-assets` to the service
   * unconditionally, and `listStakeAssets` reads the database.
   *
   * AND IT IS THE ONLY ONE HERE THE RETIREMENT DOES NOT SPARE BY NAME. The
   * retirement router's rule ends `&& !PathPrefix(`/v1`)`, which is what keeps
   * the other four reachable on a retired estate. `/stake-assets` is not under
   * `/v1`, so it is inside the redirect's rule and survives only because
   * `cf-api-foresight-resources` is priority 600 against the retirement's 550 —
   * verified by reading both, and by the 200 measured above. If that number ever
   * moves, this probe reports Forge Foresight down for the same reason 21 of
   * them did. It is the one entry in this list whose green depends on a
   * priority rather than on a path.
   */
  {
    key: 'market.collections',
    productGroup: 'Forge Market',
    path: '/v1/collections',
    subdomain: 'market',
    critical: true,
  },
  {
    key: 'foresight.stakeassets',
    productGroup: 'Forge Foresight',
    path: '/stake-assets',
    subdomain: 'foresight',
    critical: true,
  },
  {
    key: 'tessera.wards',
    productGroup: 'Tessera',
    path: '/v1/wards',
    subdomain: 'tessera',
    critical: true,
  },
  {
    key: 'aetherholm.chronicle',
    productGroup: 'Aetherholm',
    path: '/v1/chronicle/seasons',
    subdomain: 'aetherholm',
    critical: true,
  },
  /*
   * THE FAUCET EXISTS ON ONE NETWORK, so it is seeded on one network.
   *
   * `network<suffix>/v1/faucet` answers 200 on testnet and 404 on mainnet —
   * measured, and correct: there is no mainnet faucet and there must not be.
   * Seeding it on both would manufacture exactly the permanently-red row this
   * file's third test exists to prevent, on the estate where it would be seen
   * most.
   *
   * `networks` is declared rather than discovered. The alternative — probe the
   * URL at seed time and skip it on a non-200 — would mean a probe that only
   * comes into existence while its subject is healthy, which is a probe that can
   * never report an outage. The same trap as the self-probe rejected above.
   *
   * It is matched against `EMBER_NETWORK`, and that is safe for a reason worth
   * stating: `CF_EMBER_NETWORK` is not an extra label that could quietly default
   * to the wrong answer here — it is the variable that picks `compose/<net>.env`
   * in `lib.mjs`, which names `CF_TRAEFIK_ENV`, which is where `WEB_SUFFIX` and
   * `WEB_RETIRED` come from. A run with it wrong is not a run that mis-seeds one
   * faucet probe; it is a run pointed at the other estate entirely, and every
   * URL in this file would already be mainnet's.
   */
  {
    key: 'faucet.terms',
    productGroup: 'Testnet faucet',
    path: '/v1/faucet',
    subdomain: 'network',
    critical: true,
    networks: ['testnet'],
  },
]

/**
 * The retirement's own probes — seeded only on an estate whose web is retired.
 *
 * Two, because there are two routers and either can break independently:
 * `cf-retired-web-sub` covers the subdomains and `cf-retired-web-apex` covers
 * the apex, which cannot be formed by concatenation (see `urlFor`).
 *
 * `expectStatus: 302` is the assertion. The prober sends `redirect: 'manual'`
 * (`beacon/src/probes.ts`), so this records the redirect rather than following
 * it to mainnet's 200 — without that, this probe would be green whether the
 * retirement worked or not.
 *
 * `critical: false`, and the distinction is real rather than tidy. A failed
 * retirement is not a product outage: nothing goes dark, an old bookmark starts
 * serving a stale testnet bundle again. That is worth a row on a status page and
 * is not worth a page at three in the morning.
 *
 * `hub` is the subdomain probed because it is `servesUi: true` and is not in the
 * router's service-hostname exclusion — i.e. it is squarely inside the set the
 * retirement is supposed to cover. Probing an excluded hostname would assert
 * nothing about the rule.
 */
const RETIREMENT_PROBES = [
  { key: 'retired.sub', url: () => `https://hub${WEB_SUFFIX}/` },
  { key: 'retired.apex', url: () => `https://${SITE_HOST}/` },
]

/** The group these land in. Named for what a reader is looking at, not for the router. */
const RETIREMENT_GROUP = 'Retired web addresses'

/** The API reads this estate is entitled to seed. See `networks` on `faucet.terms`. */
const API_READS_HERE = API_READ_PROBES.filter(
  (probe) => !probe.networks || probe.networks.includes(EMBER_NETWORK),
)

/**
 * Seed the two probes that assert the retirement still redirects.
 *
 * Returns 0 without writing anything on an estate that is not retired, rather
 * than being called conditionally — so the caller reports one number either way
 * and a run on mainnet says out loud that it seeded none.
 */
async function seedRetirementProbes(token) {
  if (!WEB_RETIRED) return 0
  let written = 0
  for (const probe of RETIREMENT_PROBES) {
    const url = probe.url()
    const res = await beaconApi(`/v1/probes/${encodeURIComponent(probe.key)}`, {
      method: 'PUT',
      token,
      body: {
        target: probe.key,
        productGroup: RETIREMENT_GROUP,
        url,
        method: 'GET',
        expectStatus: 302,
        intervalMs: INTERVAL_MS,
        deadlineMs: DEADLINE_MS,
        critical: false,
        enabled: true,
      },
    })
    if (res.status === 200 || res.status === 201) {
      written++
      note(`retirement probe ${probe.key} → ${url} (expects 302)`)
    } else {
      bad(`probe ${probe.key} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
  return written
}

/**
 * Seed the reads. Separate from the surface loop rather than folded into it,
 * because a shared loop would need a branch on every field that differs — url,
 * group, criticality — and the two answer different questions.
 */
async function seedApiReadProbes(token) {
  let written = 0
  for (const probe of API_READ_PROBES) {
    if (!API_READS_HERE.includes(probe)) {
      note(
        `api read probe ${probe.key} is not seeded on ${EMBER_NETWORK}: it declares ` +
          `${probe.networks.join(', ')} only, and probing it here would be a permanently red row`,
      )
    }
  }
  for (const probe of API_READS_HERE) {
    const url = `https://${probe.subdomain}${WEB_SUFFIX}${probe.path}`
    const res = await beaconApi(`/v1/probes/${encodeURIComponent(probe.key)}`, {
      method: 'PUT',
      token,
      body: {
        target: probe.key,
        productGroup: probe.productGroup,
        url,
        method: 'GET',
        expectStatus: 200,
        intervalMs: INTERVAL_MS,
        deadlineMs: DEADLINE_MS,
        critical: probe.critical,
        enabled: true,
      },
    })
    if (res.status === 200 || res.status === 201) {
      written++
      note(`api read probe ${probe.key} → ${url}`)
    } else {
      bad(`probe ${probe.key} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
  return written
}

export async function seedBeacon(token) {
  head('beacon — probes from the surface registry, and no SLO nobody agreed')

  // Neither of these comes from the registry, so both are seeded whether or not it can be read.
  // That is not a convenience: the registry failing to load is exactly the kind of estate trouble
  // during which you most want the probes that ask a service a real question.
  const apiReads = await seedApiReadProbes(token)
  const retirementProbes = await seedRetirementProbes(token)

  const surfaces = await loadSurfaces()
  if (!surfaces) {
    skip(
      'no SURFACE probes seeded: the surface registry at ui/packages/ui/src/surfaces.ts could not ' +
        'be read. A hand-written list here would be a ninth copy of a list the registry exists to ' +
        `stop anybody keeping, so none is written. The ${apiReads} API read probe(s) and ` +
        `${retirementProbes} retirement probe(s) were seeded.`,
    )
    return
  }

  // `servesUi` is the measured field; see this file's header for why it, and not
  // `kind` or `inSwitcher`, is the one that decides.
  const probeable = surfaces.filter((s) => s.servesUi)
  note(
    `${surfaces.length} surface(s) in the registry, ${probeable.length} with servesUi: true — ` +
      'measured through the gateway, not reasoned about',
  )

  let written = 0
  for (const surface of probeable) {
    const res = await beaconApi(`/v1/probes/${encodeURIComponent(surface.key)}`, {
      method: 'PUT',
      token,
      body: {
        target: surface.key,
        // THE SURFACE'S NAME, not its `kind`.
        //
        // This was `surface.kind`, on the reasoning that the registry's own taxonomy is better
        // than a vocabulary invented here. That is true of the taxonomy and false of this field:
        // `kind` answers "what sort of thing is this" — `product`, `service`, `surface` — and
        // there are exactly three of them. It put all nineteen probes into three buckets and
        // labelled every auto-opened incident with its category, so the public status page read:
        //
        //     service   ◌ Investigating   SEV3   Reference df747118-…
        //
        // A reader cannot act on that. It does not say Forge Market is down; it says a thing of
        // the kind "service" is down, twenty-two times. `name` is the field a person recognises
        // — "Forge Foresight", "Lantern" — and it is still the registry's own vocabulary, just
        // the part of it addressed to humans.
        //
        // One probe per group is the honest shape today: there is one probe per surface, so a
        // group with a name is exactly as granular as the data. Grouping several surfaces under
        // a product family is a decision about how outages should READ, and nobody has made it.
        productGroup: surface.name,
        url: urlFor(surface),
        method: 'GET',
        expectStatus: 200,
        intervalMs: INTERVAL_MS,
        deadlineMs: DEADLINE_MS,
        // A product being down is an outage; an operator tool being down is not
        // the same event, and paging on both identically is how a pager gets
        // ignored.
        critical: surface.kind === 'product',
        // ON A RETIRED ESTATE THIS ROW IS WRITTEN, AND SWITCHED OFF. See this file's header:
        // `urlFor(surface)` is a hostname the gateway answers 302 to, so probing it for 200
        // measures the retirement and reports it as the product being down — which is exactly
        // what testnet published across 21 product groups for two days.
        //
        // Written rather than skipped, and disabled rather than deleted, because all three
        // states have to survive a flag flipping back. `PUT` is an upsert (header), so an
        // estate that stops being retired gets `enabled: true` on the next deploy with its
        // history intact, and one that starts being retired has its rows switched off on the
        // deploy that retires it. Nothing here needs to know which way the flag moved.
        enabled: !WEB_RETIRED,
      },
    })
    if (res.status === 200 || res.status === 201) {
      written++
    } else {
      bad(`probe ${surface.key} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
  // `written > 0` used to gate the ONLY line this function printed about its own result, so a run
  // that upserted nothing said nothing and read as a success. That is the estate's standing
  // vacuous-check shape (#38): a check must fail when it measures nothing. It now reports either
  // way, and zero is `bad`.
  if (written > 0) {
    ok(
      `${written} surface probe(s) + ${apiReads} API read probe(s) upserted — ` +
        `${probeable.filter((s) => s.kind === 'product').length} critical (the products), the rest not`,
    )
  } else {
    bad(
      `0 surface probes upserted from ${probeable.length} probeable surface(s). A beacon with no ` +
        'probes folds `worst([])` to `operational` and publishes a green status page having ' +
        'measured nothing — the defect in #14.',
    )
  }
  if (apiReads !== API_READS_HERE.length) {
    bad(`${apiReads} of ${API_READS_HERE.length} API read probe(s) upserted; the rest failed above`)
  }

  if (WEB_RETIRED) {
    // The count is the assertion, not the prose. `probeable.length` surface rows went off and
    // `apiReads` API reads carry the estate — if that second number is small, this line is where
    // somebody finds out, rather than a status page that has quietly stopped measuring anything.
    ok(
      `this estate's web is RETIRED (CF_WEB_RETIRED), so its ${probeable.length} surface probe(s) ` +
        `were upserted DISABLED — their hostnames redirect, and probing a redirect for a page ` +
        `reports the product as down. ${retirementProbes} retirement probe(s) assert the redirect ` +
        `itself, and ${apiReads} API read probe(s) are what actually measures this estate.`,
    )
    if (apiReads === 0) {
      bad(
        'a retired estate with 0 API read probes measures NOTHING: every surface probe is ' +
          'disabled and `worst([])` publishes a green page over an estate nobody is watching.',
      )
    }
  } else if (retirementProbes > 0) {
    bad(`${retirementProbes} retirement probe(s) were seeded on an estate that is not retired`)
  }

  const excluded = surfaces.filter((s) => !s.servesUi).map((s) => s.key)
  if (excluded.length > 0) {
    note(`not probed, because the registry measured them as serving no page: ${excluded.join(', ')}`)
  }

  skip(
    'no SLO was seeded, and this is the third refusal of it in this estate. A probe records an ' +
      'address that should answer; an SLO records a THRESHOLD — how much unavailability is ' +
      'acceptable, over what window — and nobody has agreed one. A seeded SLO is not a ' +
      'placeholder: it becomes the number the estate is judged against, in a status page and in ' +
      'an alert, chosen by whichever script ran first. An empty slos table honestly says no ' +
      'availability target has been agreed.',
  )
}
