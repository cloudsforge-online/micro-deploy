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

import { ok, bad, skip, note, head, WEB_SUFFIX, SITE_HOST } from './lib.mjs'

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
]

/**
 * Seed the reads. Separate from the surface loop rather than folded into it,
 * because a shared loop would need a branch on every field that differs — url,
 * group, criticality — and the two answer different questions.
 */
async function seedApiReadProbes(token) {
  let written = 0
  for (const probe of API_READ_PROBES) {
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

  // The API read probes do not come from the registry, so they are seeded whether or not it can be
  // read. That is not a convenience: the registry failing to load is exactly the kind of estate
  // trouble during which you most want the one probe that asks a service a real question.
  const apiReads = await seedApiReadProbes(token)

  const surfaces = await loadSurfaces()
  if (!surfaces) {
    skip(
      'no SURFACE probes seeded: the surface registry at ui/packages/ui/src/surfaces.ts could not ' +
        'be read. A hand-written list here would be a ninth copy of a list the registry exists to ' +
        `stop anybody keeping, so none is written. The ${apiReads} API read probe(s) were seeded.`,
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
        enabled: true,
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
  if (apiReads !== API_READ_PROBES.length) {
    bad(`${apiReads} of ${API_READ_PROBES.length} API read probe(s) upserted; the rest failed above`)
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
