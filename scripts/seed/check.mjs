/**
 * Is there anything on the pages? Asked of the estate, not of the seeder.
 *
 *   ./scripts/estate-seed.mjs --check
 *
 * ── WHY THIS EXISTS, AND WHAT IT WOULD HAVE CAUGHT ───────────────────────────
 *
 * On 2026-08-05 both live estates were measured and every product surface was
 * empty: `foresight.markets` 0, `market.listings` 0, `market.collections` 0,
 * `mint.tokens` 0, `community.communities` 0, `nda.worlds` 0, `beacon.probes` 0.
 * The seeder had never run — `estate-bootstrap.sh` skipped it because the host
 * has no Node and REPORTED THAT AS `ok`, which is this repository's named defect
 * class: a check that cannot fail. Nothing else in the estate ever asked whether
 * a surface had content, so five empty products were green for months.
 *
 * A row count would have caught it. A row count is not what this asks, because a
 * row count is not what a visitor sees: `foresight.markets` counts drafts and
 * voided artefacts too, and a market that exists but is not `open` renders as an
 * empty page. So every assertion below is a REAL READ THROUGH THE REAL FRONT
 * DOOR — the same request the surface's own JavaScript makes, on the same
 * hostname, with the same headers, and anonymously wherever the visitor is
 * anonymous. What it counts is what the page will have to render.
 *
 * ── WHY IT IS A MODE OF THE SEEDER AND NOT A SECTION OF estate-verify.sh ─────
 *
 * The seeder already knows where every service is, which four have no gateway
 * route, and which read corresponds to which surface. A second copy of that map
 * in bash would be a second thing to keep true, and the copy that goes stale is
 * always the one that only runs in CI. `estate-verify.sh` calls this rather than
 * restating it.
 *
 * ── WHAT IT DOES NOT ASSERT ──────────────────────────────────────────────────
 *
 * Not "the seeder's rows are present" — it never looks for a seeded title. Any
 * content passes. The question is whether the surface has SOMETHING, because the
 * defect being closed is an empty page and not a missing fixture, and a check
 * pinned to the seeder's own strings would go red the first time an operator
 * wrote a better question by hand.
 *
 * Not the FOUR SURFACES WITH NO GATEWAY ROUTE, from the front door — `community`,
 * `nda` and `billing` are published nowhere (`gateway/dynamic/public-api.yml`
 * routes only the nine services it names, so anything unmatched on the API host
 * is Traefik's default 404), so they are read on the same
 * loopback ports `estate-verify.sh` uses and are marked `loopback` in the report.
 * Calling that "what a visitor sees" would be a lie; leaving them out entirely
 * would let three services go empty unnoticed. They are checked, and labelled.
 */

import { WEB_SUFFIX, SERVICES, api, bad, head, note, ok } from './lib.mjs'

/**
 * One surface, the read that populates it, and what an empty answer means.
 *
 * `pick` returns the array the page renders. It is deliberately the ARRAY and not
 * a `total`: several of these services report a count that includes rows the
 * public list omits, and a check that trusted the count would pass on a surface
 * that renders nothing.
 *
 * `anon: true` means the request is made with NO bearer token, because the
 * visitor has none. That is not a detail — `market` returns `{"listings":[]}` to
 * a stranger and the seeded rows to an operator would be a completely different
 * assertion. Where the read genuinely requires a principal (`mint /v1/tokens`
 * answers 401 unauthenticated) the operator token is used and the row says so.
 */
export const SURFACES = [
  {
    key: 'foresight',
    what: 'OPEN prediction markets',
    service: 'foresight',
    // ── `?status=open`, AND THE UNFILTERED LIST WOULD HAVE BEEN A CHECK THAT
    //    COULD NOT FAIL ────────────────────────────────────────────────────────
    //
    // This was `/markets?limit=200`. `foresight/src/server.ts` treats an
    // absent `status` as NO FILTER, so that read returns drafts, approved markets
    // and voided test artefacts alike — and `foresight-web/src/pages/markets.tsx`
    // opens on `useState<MarketStatus | null>('open')`. The browse page asks for
    // open markets and nothing else.
    //
    // The two diverge in a state this estate reaches every time: a market cannot
    // open until its contract is on chain (`markets.ts` requires
    // `deploy_state = 'deployed'`), and the seeder skips the deploy whenever the
    // mining key or the node is out of reach. That leaves nine `approved` rows —
    // measured today — which the unfiltered read counts and the page does not
    // show. A check written the easy way would have gone green over an empty
    // page, which is the exact defect it exists to catch.
    path: '/markets?status=open&limit=200',
    anon: true,
    pick: (b) => b.markets,
    page: (suffix) => `https://foresight${suffix}/`,
    empty:
      'the Foresight browse page renders no questions at all — the surface the owner named first. ' +
      'Markets that exist but are not `open` do not appear on it: check `select status, count(*) ' +
      'from markets` before concluding nothing was created',
  },
  {
    key: 'market.listings',
    what: 'marketplace listings',
    service: 'market',
    path: '/v1/listings',
    anon: true,
    pick: (b) => b.listings,
    page: (suffix) => `https://market${suffix}/`,
    // ── THIS ONE IS RED TODAY, AND IT IS NOT RED FOR WANT OF SEEDING ─────────
    //
    // `seed/market.mjs` creates four listings and every one of them stays
    // `draft`. Activation answers 402 `payment_refused` because
    // `listings_active_is_escrowed` requires micro-ledger to reserve the item,
    // the operator holds none, and the only way to change that from the seeder
    // would be to credit a liability with nothing behind it — the shape that
    // froze EMBER in this estate. `market-web`'s browse page reads
    // `status=active` by design, so the drafts are correct, real, and one honest
    // ledger posting away from being live.
    //
    // It is left FAILING rather than softened to "some listing exists in any
    // state". The marketplace page is empty to a visitor, which is the defect
    // the owner reported, and a check that went green on four invisible drafts
    // would be asserting the opposite of what it is for. It can pass — the day
    // the seller is honestly funded with the item, it does — so it is a true
    // statement about a live gap and not a permanent alarm.
    //
    // The `empty` line named SHARD until 2026-08-10 and was wrong on its own
    // terms, not just stale (micro-org#226). What activation escrows is the
    // ITEM's asset code, never the price's — `holdEscrow(..., assetCode:
    // listing.itemAssetCode)`, commented there as "reserving the wrong one
    // produces an entry that balances perfectly and reserves something the
    // seller is not selling". The item asset is `TOKEN:cf:brand:...`, and the
    // ledger holds ZERO accounts in any `TOKEN:` asset (measured on mainnet
    // 2026-08-10). What the price is denominated in has never had anything to do
    // with why these stay draft.
    empty:
      'the marketplace has nothing for sale. NOTE: the seeder creates four listings and they are ' +
      'all `draft` — activation needs micro-ledger to escrow the ITEM (`TOKEN:cf:brand:...`, not ' +
      'the price asset) and the operator holds none, so this is the honest-funding seam and not ' +
      'missing content. `select status, count(*) from listings` shows them',
  },
  {
    key: 'market.collections',
    what: 'marketplace collections',
    service: 'market',
    path: '/v1/collections',
    anon: true,
    pick: (b) => b.collections,
    page: (suffix) => `https://market${suffix}/`,
    empty: 'the marketplace has no collections to browse by',
  },
  {
    key: 'mint.tokens',
    what: 'minted tokens',
    service: 'mint',
    path: '/v1/tokens',
    anon: false,
    pick: (b) => b.tokens,
    page: (suffix) => `https://create${suffix}/`,
    empty: 'Create shows a catalogue and no token anybody has ever minted from it',
  },
  {
    key: 'community',
    what: 'communities',
    service: 'community',
    path: '/v1/communities?limit=200',
    anon: false,
    pick: (b) => b.communities,
    page: () => null,
    empty: 'there is no community for a member to join',
  },
  {
    key: 'nda.worlds',
    what: 'worlds',
    service: 'nda',
    path: '/v1/worlds?status=lobby,active,archived',
    anon: false,
    pick: (b) => b.worlds,
    page: () => null,
    empty: 'Ninety Days After has no world running, joinable or finished',
  },
  {
    key: 'billing.products',
    what: 'purchasable products',
    service: 'billing',
    path: '/products',
    anon: false,
    pick: (b) => b.products,
    page: () => null,
    empty: 'nothing in this estate can be bought',
  },
]

/**
 * The public status page, which is a different KIND of read and is checked apart.
 *
 * `status-web` asks its own origin for `/api/status/public` — same-origin,
 * deliberately, and its `hosts.ts` argues the case at length. The projection is
 * built from `beacon.probes`, so an estate with no probes serves
 * `{"groups":[]}` with HTTP 200 and the status page renders a heading and
 * nothing under it. That is the exact shape of the defect this file is about: a
 * 200, valid JSON, and an empty product.
 *
 * It is not in the table above because it is not in the seeder's `SERVICES` map
 * and must not be: `status${WEB_SUFFIX}` is a BUNDLE's hostname, and the
 * projection is beacon's work surfaced by somebody else's nginx. Read here with
 * `fetch` against the trust bundle, exactly as a browser would.
 */
const STATUS_PATH = '/api/status/public'

async function checkStatusPage() {
  const url = `https://status${WEB_SUFFIX}${STATUS_PATH}`
  let res
  try {
    res = await fetch(url, {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(20_000),
    })
  } catch (err) {
    bad(`status page: ${url} could not be reached — ${err.message}`)
    return
  }
  if (res.status !== 200) {
    bad(`status page: ${url} answered ${res.status}, so the public status projection is not routed`)
    return
  }
  let body
  try {
    body = JSON.parse(await res.text())
  } catch {
    bad(`status page: ${url} answered 200 with something that is not JSON`)
    return
  }
  const groups = Array.isArray(body.groups) ? body.groups : null
  if (groups === null) {
    bad(`status page: ${url} answered 200 with no \`groups\` array — the projection changed shape`)
    return
  }
  if (groups.length === 0) {
    bad(
      `status page is EMPTY: ${url} answered 200 {"groups":[]}. beacon has no probes, so ` +
        `status${WEB_SUFFIX} renders a heading and nothing under it. This is a 200 with an empty ` +
        `product, which is why a status code could never have caught it`,
    )
    return
  }
  ok(`status page: ${groups.length} group(s) at ${url}`)
}

/**
 * Read every surface and fail on any that is empty.
 *
 * `token` may be null — every `anon: true` row is read without one, and a run
 * with no token at all still asserts the four public surfaces rather than
 * refusing to assert anything. An estate that cannot sign its operator in is a
 * different failure and is reported by `login()`'s caller.
 */
export async function checkSurfaces(token) {
  head('is there anything on the pages?')
  note(
    'every read below is the request the surface\'s own page makes, through the same front door, ' +
      'anonymously wherever a visitor is anonymous.',
  )

  let empty = 0
  for (const surface of SURFACES) {
    const svc = SERVICES[surface.service]
    const where = `${svc.base}${surface.path}`
    const via = svc.gateway ? 'gateway' : 'loopback'
    if (!surface.anon && !token) {
      bad(
        `${surface.key}: needs the operator to be signed in and this run has no token, so ` +
          `${surface.what} went unchecked. That is not a pass`,
      )
      empty++
      continue
    }
    let res
    try {
      res = await api(surface.service, surface.path, {
        ...(surface.anon ? {} : { token }),
      })
    } catch (err) {
      bad(`${surface.key}: ${where} could not be read — ${err.message}`)
      empty++
      continue
    }
    if (res.status !== 200) {
      bad(
        `${surface.key}: ${where} answered ${res.status} (${via}), so ${surface.what} cannot be ` +
          `read at all — which is a worse fault than an empty one`,
      )
      empty++
      continue
    }
    const rows = surface.pick(res.body)
    if (!Array.isArray(rows)) {
      bad(`${surface.key}: ${where} answered 200 but carried no list where one was expected`)
      empty++
      continue
    }
    if (rows.length === 0) {
      const page = surface.page(WEB_SUFFIX)
      bad(
        `${surface.key} is EMPTY: ${where} answered 200 with an empty list (${via}). ` +
          `${surface.empty}${page ? ` — ${page}` : ''}. Run ./scripts/estate-seed.mjs`,
      )
      empty++
      continue
    }
    ok(`${surface.key}: ${rows.length} ${surface.what} (${via}${surface.anon ? ', anonymous' : ', as the operator'})`)
  }

  await checkStatusPage()
  return empty
}
