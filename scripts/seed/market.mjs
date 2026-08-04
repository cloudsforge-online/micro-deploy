/**
 * Seed micro-market: a collection the platform owns, and listings for things it
 * actually has — stopping, deliberately, one step short of the browse page.
 *
 * ── WHAT IS CREATED ─────────────────────────────────────────────────────────
 *
 * One collection and four listings, all owned by the estate's operator account,
 * for brand assets the platform genuinely holds: the FLUX 2 Pro sets already in
 * this estate (`micro-brand`, `micro-emberkin-assets`, `micro-aetherholm-assets`,
 * `micro-tessera-assets`). Nothing was generated and nothing is hotlinked; the
 * `itemUrn` of each listing names the set it refers to.
 *
 * **No bid, no offer and no purchase is made.** `21-engagement-treasury.md` §5
 * is unusually direct about this service: the engagement account "never places
 * bids: a bid the platform does not mean is ghost demand, and ghost demand is
 * the 'fake it' this document refuses." Supply the platform owns is fine; demand
 * it does not feel is not. So this seeds supply and stops.
 *
 * ── AND WHY THE LISTINGS STAY DRAFTS ────────────────────────────────────────
 *
 * This is the finding, and it is the reason market-web's browse page is still
 * empty after this runs.
 *
 * `POST /v1/listings/:id/activate` does not merely flip a status. It posts a
 * reservation to micro-ledger in the same transaction, moving `quantity` of the
 * listing's `itemAssetCode` from the seller's `available` account to their
 * `reserved` one (`market/src/listings.ts:538-552` → `escrow.ts:138-169`). The
 * schema then makes the rule permanent: `listings_active_is_escrowed` — "a
 * listing cannot be active unless it names the ledger reservation holding its
 * item. Nothing is ever for sale that the seller has not actually put up"
 * (`market/README.md:64`). A seller who holds nothing gets a 402 and the listing
 * stays a draft.
 *
 * The operator holds none of these item assets in the ledger, and there are
 * exactly two ways to change that.
 *
 *   1. **Post a journal entry crediting them.** This was considered at length
 *      and REFUSED. It is a liability credited with nothing behind it, which is
 *      the precise shape that froze EMBER in this estate tonight: micro-wallet
 *      posted five EMBER of unbacked liability and reconciliation caught it at
 *      `drift_exceeded`. Doing the same thing deliberately, in a seeding script,
 *      to make a page look populated, would be indefensible — and it would be
 *      indefensible for the same reason whether the asset is money or an item.
 *
 *   2. **Fund the seller honestly** — mine EMBER, deposit it through the front
 *      door, let the indexer confirm it, convert to Shards, and acquire or issue
 *      the item against something real. That is the path §3 already describes,
 *      and it is currently blocked anyway: EMBER is frozen. A seeder that
 *      retried around a freeze would be defeating the control that exists to
 *      catch exactly this.
 *
 * So the drafts are real, they are correct, and they are one ledger posting away
 * from being live. That posting is not this script's to invent. `market-web`'s
 * browse page reads `status=active` by default and deliberately does not show
 * drafts — "a browse page that asked for drafts would be showing sellers'
 * unpublished work to buyers" (`market-web/src/pages/browse.tsx:33-35`) — so the
 * public surface stays empty and the reason is a real blocker in the estate
 * rather than a gap in the seeding.
 *
 * ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
 *
 *   * `POST /v1/listings` REQUIRES an `Idempotency-Key` of 8-200 characters
 *     matching `[A-Za-z0-9_:.-]` (`market/src/server.ts:260, 1206-1234`), and a
 *     replay comes back 200 with `replayed: true`. Fixed keys are used so a
 *     retry inside one run replays.
 *   * `POST /v1/collections` has NO idempotency wrapper, and a duplicate `slug`
 *     is an unmapped unique violation that surfaces as **500 internal**
 *     (`server.ts:502-503`) rather than a 409. So the collection is listed for
 *     first, always.
 *   * Listings have no unique constraint of any kind, so beyond the key they are
 *     matched client-side on `itemUrn` — and the list route defaults to
 *     `status=active`, so `status=draft` has to be asked for explicitly or every
 *     re-run would look like a first run.
 */

import {
  api,
  ok,
  bad,
  skip,
  note,
  head,
  whoami,
  refreshServiceToken,
  holdsPlaceholderToken,
} from './lib.mjs'

/**
 * micro-market's grant, from `IDENTITY_SERVICE_TOKEN_GRANTS`. Narrow by
 * construction: identity de-duplicates but never widens, so asking for exactly
 * these is what makes the refreshed token least-privilege.
 */
const MARKET_SCOPES = ['indexer:read', 'ledger:post', 'policy:decide']
const MARKET_CONTAINER = process.env.CF_MARKET_CONTAINER || 'cloudsforge-estate-market-1'

/**
 * Make sure market can talk to policy before a single listing is attempted.
 *
 * Found by running this seeder, not by reading: every listing came back 403
 * `policy_denied`, and policy's log said `Invalid Compact JWS` — market was
 * presenting `estate-placeholder-token-0000000000000000`, the compose default,
 * because some earlier plain `docker compose up` had replaced the real one.
 *
 * A credential fault is not policy deciding, and this is a workaround for that
 * in the open. The estate-side half of the fix is an empty default rather than a
 * placeholder that looks like a value; the service-side half is market adopting
 * `ServiceTokenProvider` as micro-foresight has.
 */
async function ensureMarketCanReachPolicy(token) {
  if (!holdsPlaceholderToken(MARKET_CONTAINER, 'MARKET_SERVICE_TOKEN')) return
  note(
    `${MARKET_CONTAINER} holds the compose PLACEHOLDER for MARKET_SERVICE_TOKEN, not a JWT — ` +
      'policy answers 401 and market turns that into a 403 on every listing. Re-minting.',
  )
  const done = await refreshServiceToken(token, 'market', 'MARKET_SERVICE_TOKEN', MARKET_SCOPES)
  if (done) ok('market recreated with a real service token — its policy calls can authenticate again')
}

const COLLECTION = {
  slug: 'cloudsforge-house-collection',
  name: 'The CloudsForge House Collection',
  description:
    'Brand and world assets owned by the platform and offered by it. Every item here is listed by ' +
    'CloudsForge itself — this is the platform selling things it holds, not a third-party seller ' +
    'and not a simulated market. The art is from the estate\'s existing FLUX 2 Pro asset sets; ' +
    'nothing was generated for the shop.',
  // Empty rather than a made-up split: a non-empty royalties array must sum to
  // exactly 10000 across real subjects (`listings.ts:197-212`), and inventing a
  // recipient would be inventing a party.
  royalties: [],
}

/**
 * Four items, one per asset set the estate actually has.
 *
 * `assetKind: 'brand_asset'` is one of the six the service allows and is the
 * honest one. `settlementMode: 'custodial'` because onchain settlement cannot be
 * activated in this estate at all — `INDEXER_CHAINS` is unset, so the escrow
 * status check fails closed with 503.
 *
 * Amounts cross the wire as decimal strings (`money.ts:222-227` refuses a JSON
 * number outright); bps are JSON numbers. Prices are in SHARD.
 */
const LISTINGS = [
  {
    itemUrn: 'cf:brand:cloudsforge:identity-suite-v1',
    label: 'CloudsForge identity suite',
    quantity: '1',
    price: '250000',
    note: 'Wordmark, favicon, social and og sheets from micro-brand.',
  },
  {
    itemUrn: 'cf:brand:emberkin:species-sheet-v1',
    label: 'Emberkin species sheet',
    quantity: '3',
    price: '90000',
    note: 'Species and biome sheets from micro-emberkin-assets.',
  },
  {
    itemUrn: 'cf:brand:aetherholm:keyart-v1',
    label: 'Aetherholm key art',
    quantity: '2',
    price: '140000',
    note: 'Key art, island and ship-icon sheets from micro-aetherholm-assets.',
  },
  {
    itemUrn: 'cf:brand:tessera:terrain-set-v1',
    label: 'Tessera terrain set',
    quantity: '5',
    price: '60000',
    note: 'Terrain, chrome and object sheets from micro-tessera-assets (FLUX 2 Pro).',
  },
]

const key = (...parts) => ['estate-seed', ...parts].join(':').slice(0, 200)

async function ensureCollection(token, sellerSubject) {
  const list = await api('market', `/v1/collections?ownerSubject=${encodeURIComponent(sellerSubject)}`, {})
  const found = (list.body.collections ?? []).find((c) => c.slug === COLLECTION.slug)
  if (found) {
    ok(`collection ${COLLECTION.slug} already exists (${found.id.slice(0, 8)}) — not re-created`)
    return found
  }
  const res = await api('market', '/v1/collections', { method: 'POST', token, body: COLLECTION })
  if (res.status !== 201 && res.status !== 200) {
    bad(`create collection → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
    return null
  }
  ok(`collection ${COLLECTION.slug} created and owned by the platform operator`)
  return res.body.collection
}

export async function seedMarket(token) {
  head('market — supply the platform owns, and no demand it does not feel')

  await ensureMarketCanReachPolicy(token)

  const userId = await whoami(token)
  const sellerSubject = `user:${userId}`

  const collection = await ensureCollection(token, sellerSubject)

  // The list route defaults to `status=active`; drafts have to be asked for by
  // name or a re-run would not see what the last run made.
  const drafts = await api('market', `/v1/listings?status=draft&sellerSubject=${encodeURIComponent(sellerSubject)}`, {})
  const have = new Map((drafts.body.listings ?? []).map((l) => [l.itemUrn, l]))

  const made = []
  for (const spec of LISTINGS) {
    const existing = have.get(spec.itemUrn)
    if (existing) {
      ok(`listing ${existing.id.slice(0, 8)} for ${spec.label} already exists (${existing.status})`)
      made.push(existing)
      continue
    }
    const res = await api('market', '/v1/listings', {
      method: 'POST',
      token,
      idempotencyKey: key('market', 'listing', spec.itemUrn),
      body: {
        assetKind: 'brand_asset',
        pricingMode: 'fixed',
        settlementMode: 'custodial',
        itemUrn: spec.itemUrn,
        // What the LEDGER would call the item, as distinct from what the price
        // is denominated in. Both are free strings on this service.
        itemAssetCode: `TOKEN:${spec.itemUrn}`,
        assetCode: 'SHARD',
        price: spec.price,
        quantity: spec.quantity,
        royaltyBps: 0,
        ...(collection ? { collectionId: collection.id } : {}),
      },
    })
    if (res.status !== 201 && res.status !== 200) {
      bad(`listing ${spec.label} → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
      continue
    }
    const listing = res.body.listing
    made.push(listing)
    ok(
      `listing ${listing.id.slice(0, 8)} ${spec.label} — ${spec.quantity} x ${spec.price} SHARD, ` +
        `${listing.status}${res.body.replayed ? ' (replayed)' : ''}`,
    )
    note(`    ${spec.note}`)
  }

  // ── the step that is not taken, and exactly why ────────────────────────────
  //
  // Attempted for ONE listing rather than none, so the refusal in the report is
  // the estate's own answer rather than this script's prediction. Whatever it
  // says, nothing is retried and nothing is worked around.
  if (made.length > 0) {
    const probe = made[0]
    const res = await api('market', `/v1/listings/${probe.id}/activate`, {
      method: 'POST',
      token,
      body: {},
    })
    if (res.status === 200) {
      ok(`listing ${probe.id.slice(0, 8)} ACTIVATED — the ledger held the item after all`)
    } else {
      skip(
        `activation refused, as expected: ${res.status} ` +
          `${JSON.stringify(res.body?.error?.code ?? res.body).slice(0, 80)}. A listing cannot go ` +
          `active until micro-ledger reserves its item (listings_active_is_escrowed), the operator ` +
          `holds none, and the only way to change that from here would be to credit a liability ` +
          `with nothing behind it — the exact shape that froze EMBER in this estate tonight.`,
      )
    }
  }

  skip(
    'no bid, offer or purchase was made. 21-engagement-treasury.md §5 is explicit about this ' +
      'service: the platform "never places bids: a bid the platform does not mean is ghost demand". ' +
      'Supply the platform owns is seeded; demand it does not feel is not.',
  )
  skip(
    'market-web\'s browse page therefore still shows nothing. It reads status=active by design — ' +
      '"a browse page that asked for drafts would be showing sellers\' unpublished work to buyers" ' +
      '— so these drafts are correct, real, and one honest ledger posting away from being live. ' +
      'That posting needs a funded seller, which needs the deposit-and-convert seam, which is ' +
      'blocked while EMBER is frozen. Reported rather than routed around.',
  )
}
