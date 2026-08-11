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
 * `reserved` one (`market/src/listings.ts` → `escrow.ts`). The
 * schema then makes the rule permanent: `listings_active_is_escrowed` — "a
 * listing cannot be active unless it names the ledger reservation holding its
 * item. Nothing is ever for sale that the seller has not actually put up"
 * (`market/README.md`). A seller who holds nothing gets a 402 and the listing
 * stays a draft.
 *
 * The operator holds none of these item assets in the ledger, and the refusal to
 * change that stands. **The REASON given here was wrong until 2026-08-11 and is
 * restated below, because a correct refusal resting on a false premise is one
 * somebody eventually disproves and then walks straight through.** micro-org#407
 * measured all of it.
 *
 * What this comment used to say was that issuing the item would be "a liability
 * credited with nothing behind it, the precise shape that froze EMBER", and that
 * the honest path was blocked anyway because "EMBER is frozen". Both are false:
 *
 *   * **Reconciliation would never see it.** The sweep covers exactly the assets
 *     named in `LEDGER_RECONCILE_ASSETS`, which is `SHARD,EMBER,LTC` on this
 *     estate, one job per named asset (`ledger/src/jobs.ts`, `env.ts`). A
 *     `TOKEN:` item asset is not in the list and is never swept, so an issuance
 *     would drift against nothing and freeze nothing. Note the trap in that: if
 *     a `TOKEN:` asset were ever ADDED to the list, `reconcileAsset` would take
 *     the `liability_sum` branch, compare Σ custody (0) against Σ liabilities
 *     (N), and freeze the item on its first sweep. The reconciled set and any
 *     issuable set must never intersect.
 *
 *   * **EMBER is not frozen.** `select * from asset_freezes` returns no rows on
 *     mainnet, read 2026-08-11. The only freeze anywhere is testnet LTC, for a
 *     missing indexer observation, unrelated to this.
 *
 *   * **The double entry is expressible and already designed.** micro-tessera
 *     works out the exact cells (`tessera/src/ledgerclient.ts`): debit
 *     `clearing / TOKEN:<urn> / suspense`, credit `user:<holder> / .. /
 *     available`, with the clearing side allowed to go negative because
 *     `ledger_assert_no_overdraft` exempts it, and the negative BEING the count
 *     in circulation. `LedgerAssetCode` is open (`TOKEN:${string}`), so nothing
 *     would need declaring in contracts either.
 *
 * So the easy objections do not hold, and the refusal has to rest on the real
 * one, which is not about accounting at all:
 *
 *   **THE PLATFORM CANNOT SELL WHAT IT HAS NO WAY TO DELIVER.** On settlement,
 *   market moves the item from the seller's `reserved` to the buyer's
 *   `available` and that is the ENTIRE delivery (`market/src/ledgerclient.ts`,
 *   kind `market_settled`) — no bytes, no licence, no download, no entitlement.
 *   For a Tessera object that is enough, because the asset code is derived from
 *   the sha256 of bytes micro-studio actually produced and the URN resolves back
 *   to them. `cf:brand:cloudsforge:identity-suite-v1` resolves to nothing: the
 *   four `itemUrn` strings below are the ONLY occurrences of `cf:brand:` in the
 *   estate, no service owns the namespace, there is no `TITLE_SLUG = 'brand'`,
 *   and the URNs do not even parse into the roles their segments occupy
 *   (`parseTitleUrn` wants `cf:<title>:<kind>:<id>`, so these read as title
 *   `brand`, kind `emberkin`). The quantities are edition sizes nobody decided.
 *
 *   Issuing them would be a balanced entry, invisible to every control the
 *   estate has, crediting the platform with N units of a thing a buyer could
 *   never receive. That is quieter than the EMBER defect rather than safer:
 *   reconciliation caught EMBER in one sweep, and nothing in the estate audits
 *   whether a sold item can be handed over.
 *
 * Two things would have to exist first, and neither is a seeding script's to
 * invent: a namespace with an owner and a decided edition size, and a mechanism
 * by which a buyer receives the thing. micro-org#407 lists the rest.
 *
 * So the drafts are real, they are correct, and they are further from being live
 * than "one ledger posting" — which is what this comment claimed while the
 * posting it named was the only missing piece. `market-web`'s browse page reads
 * `status=active` by default and deliberately does not show drafts — "a browse
 * page that asked for drafts would be showing sellers' unpublished work to
 * buyers" (`market-web/src/pages/browse.tsx`) — so the public surface stays
 * empty, and it is honestly empty rather than broken.
 *
 * ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
 *
 *   * `POST /v1/listings` REQUIRES an `Idempotency-Key` of 8-200 characters
 *     matching `[A-Za-z0-9_:.-]` (`market/src/server.ts, 1206-1234`), and a
 *     replay comes back 200 with `replayed: true`. Fixed keys are used so a
 *     retry inside one run replays.
 *   * `POST /v1/collections` has NO idempotency wrapper, and a duplicate `slug`
 *     is an unmapped unique violation that surfaces as **500 internal**
 *     (`server.ts`) rather than a 409. So the collection is listed for
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
import { adoptExisting, reportImageBackend, studioReachable } from './images.mjs'

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
  // exactly 10000 across real subjects (`listings.ts`), and inventing a
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
 * Amounts cross the wire as decimal strings (`money.ts` refuses a JSON
 * number outright); bps are JSON numbers.
 *
 * ── PRICES ARE EMBER WEI, AND THEY WERE SHARD UNTIL 2026-08-10 ───────────────
 *
 * micro-org#226. SHARD is retired — `RETIRED_ASSETS`, and
 * `assertIssuable('SHARD')` throws "SHARD is retired and may not denominate
 * anything new" (`contracts/packages/chain`). A listing created today is
 * something new, and `assetCode` here is a free string on micro-market
 * (`listings.ts` calls it "what the price is denominated in", distinct from
 * `itemAssetCode`), so nothing refused it on the way in. Four such listings sit
 * on mainnet right now, created by this script on 2026-08-04 and measured again
 * on 2026-08-10: `select status, asset_code, count(*) from listings` returns
 * 5 draft SHARD (these four plus one probe) and 3 draft EMBER. Zero active, in
 * any asset — which is why `GET /v1/listings` still answers `{"listings":[]}`:
 * the route defaults to `status=active`, not because the listings are missing.
 *
 * CONVERTED AT THE FROZEN RATE, NOT RELABELLED. SHARD has 0 decimals and EMBER
 * has 18. Setting `assetCode: 'EMBER'` and keeping '250000' would have priced
 * the identity suite at 250,000 wei — 2.5e-13 EMBER, about six hundredths of a
 * nanocent — i.e. free, which is a worse lie than the retired asset was. One
 * Shard is one US cent (`SHARDS_PER_USD`) and one EMBER is the administered
 * 0.25 USD (`pricing.administered_prices`, `usd_scaled` 250000 against
 * `RATE_SCALE` 1e6 — read on mainnet 2026-08-10, unchanged since 2026-08-04),
 * so one Shard is 4e16 wei and every price below is its old figure x 4e16.
 *
 * The USD each item asks for is therefore UNCHANGED: 2,500 / 1,400 / 900 / 600.
 * That is deliberate and not laziness. These are prices for real brand assets
 * the platform actually owns; retiring the currency they were quoted in does
 * not make the art cheaper. Re-choosing the figures to look tidier in EMBER
 * would be this script inventing prices, which it refuses to do a few lines up
 * ("Empty rather than a made-up split ... inventing a recipient would be
 * inventing a party"), and it is the same discipline admin-api's migration 13
 * applied when it converted the engagement cap and noted the result "is still
 * exactly the USD 10,000,000 per transfer version 8 chose".
 *
 * Yes, 10,000 EMBER is more EMBER than the whole estate holds (50.200042 EMBER
 * across 31 ledger accounts, 2026-08-10). It was equally more than the estate
 * held when it read USD 2,500 of Shards, and it changes nothing: these listings
 * are `draft` and cannot activate for a reason that has nothing to do with the
 * price asset. See the seam note below.
 */
const LISTINGS = [
  {
    itemUrn: 'cf:brand:cloudsforge:identity-suite-v1',
    label: 'CloudsForge identity suite',
    quantity: '1',
    // 250,000 Shards = USD 2,500 = 10,000 EMBER.
    price: '10000000000000000000000',
    note: 'Wordmark, favicon, social and og sheets from micro-brand.',
    cover: 'brand/review/sheet-og.png',
  },
  {
    itemUrn: 'cf:brand:emberkin:species-sheet-v1',
    label: 'Emberkin species sheet',
    quantity: '3',
    // 90,000 Shards = USD 900 = 3,600 EMBER.
    price: '3600000000000000000000',
    note: 'Species and biome sheets from micro-emberkin-assets.',
    cover: 'emberkin-assets/review/sheet-species.png',
  },
  {
    itemUrn: 'cf:brand:aetherholm:keyart-v1',
    label: 'Aetherholm key art',
    quantity: '2',
    // 140,000 Shards = USD 1,400 = 5,600 EMBER.
    price: '5600000000000000000000',
    note: 'Key art, island and ship-icon sheets from micro-aetherholm-assets.',
    cover: 'aetherholm-assets/review/sheet-keyart.png',
  },
  {
    itemUrn: 'cf:brand:tessera:terrain-set-v1',
    label: 'Tessera terrain set',
    quantity: '5',
    // 60,000 Shards = USD 600 = 2,400 EMBER.
    price: '2400000000000000000000',
    note: 'Terrain, chrome and object sheets from micro-tessera-assets (FLUX 2 Pro).',
    cover: 'tessera-assets/review/flux-2-pro/sheet-objects.png',
  },
]

/**
 * Wei for the wire, EMBER for the human reading the run.
 *
 * The report line printed a bare price string when prices were Shards and that
 * was legible; a 23-digit wei figure is not, and an operator skimming it cannot
 * tell 1e22 from 1e21 at a glance — which is exactly the class of mistake
 * micro-org#226 is about. Every price above is a whole number of EMBER, so this
 * divides exactly; the `%` guard means a price that is not stays honest and
 * shows its wei rather than being silently rounded into a lie.
 */
const WEI_PER_EMBER = 10n ** 18n
const inEmber = (wei) => {
  const n = BigInt(wei)
  return n % WEI_PER_EMBER === 0n
    ? `${(n / WEI_PER_EMBER).toLocaleString('en-US')} EMBER`
    : `${n.toString()} wei`
}

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

/**
 * A cover image for each seeded listing, taken from the set the listing is FOR.
 *
 * ── WHY THESE ARE ADOPTED RATHER THAN GENERATED ─────────────────────────────
 *
 * Every listing above sells one of the estate's own FLUX 2 Pro asset sets, and
 * those sets are already in this tree — seven hundred-odd PNGs across
 * `micro-brand`, `micro-emberkin-assets`, `micro-aetherholm-assets` and
 * `micro-tessera-assets`. The honest cover for a listing OF those assets is one
 * of those assets. Asking a model to invent a picture of artwork that is sitting
 * on disk would cost money to produce something less accurate.
 *
 * `foresight.mjs` is the other case and takes the other path: a prediction
 * question has no artwork anywhere, so it generates one.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * **THE SOURCE FILES ARE READ AND NOTHING ELSE.** `adoptExisting` opens the path
 * read-only and uploads a copy of the bytes to studio. No FLUX asset in this tree
 * is written, moved, overwritten or regenerated by this script, and there is no
 * code path here that could.
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Idempotent twice over: the listing's existing gallery is read first, and
 * studio deduplicates an identical upload per owner on its content address
 * anyway, so a re-run neither attaches a second copy nor stores a second file.
 */
async function coverImages(listings, token) {
  if (listings.length === 0) return
  await reportImageBackend()
  if (!(await studioReachable())) return

  for (const listing of listings) {
    const spec = LISTINGS.find((l) => l.itemUrn === listing.itemUrn)
    if (!spec?.cover) continue

    // Ask before acting. A gallery that already has this listing's cover must not
    // gain a second one, and market caps a listing at ten images.
    const current = await api('market', `/v1/listings/${listing.id}`, {})
    if ((current.body.listing?.images ?? []).length > 0) continue

    const asset = await adoptExisting(token, spec.cover)
    if (!asset) continue

    const res = await api('market', `/v1/listings/${listing.id}/images`, {
      method: 'POST',
      token,
      idempotencyKey: key('market', 'cover', listing.itemUrn),
      body: { studioAssetId: asset.id, checksum: asset.checksum },
    })
    if (res.status === 201 || res.status === 200) {
      ok(`cover on ${listing.id.slice(0, 8)} ${spec.label} — ${spec.cover}`)
    } else {
      bad(`cover on ${listing.id.slice(0, 8)} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
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
        assetCode: 'EMBER',
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
      `listing ${listing.id.slice(0, 8)} ${spec.label} — ${spec.quantity} x ${inEmber(spec.price)}, ` +
        `${listing.status}${res.body.replayed ? ' (replayed)' : ''}`,
    )
    note(`    ${spec.note}`)
  }

  await coverImages(made, token)

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
          `active until micro-ledger reserves its item (listings_active_is_escrowed) and the ` +
          `operator holds none. Issuing one would balance, and no control in the estate would ` +
          `object — the item asset is not in LEDGER_RECONCILE_ASSETS, so it drifts against ` +
          `nothing. It is refused because a cf:brand: URN resolves to nothing a buyer could be ` +
          `given: the sale would move a ledger balance and deliver no bytes. micro-org#407.`,
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
      '— so these drafts are correct and real. What they are NOT is one posting away from live: ' +
      'the item needs a namespace with an owner, a decided edition size, and some way for a buyer ' +
      'to receive it, none of which exist. The marketplace is honestly empty. micro-org#407.',
  )
}
