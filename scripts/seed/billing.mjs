/**
 * micro-billing: the domain where the honest answer is "this is already seeded,
 * and the rest must not be".
 *
 * ── THE BRIEF SAID BILLING WAS EMPTY. IT IS NOT ─────────────────────────────
 *
 * Counted before any seeding ran: `products = 5`, `prices = 5`. The catalogue
 * has never been empty on any migrated deployment, because migration 9
 * (`billing/src/migrations.ts`) seeds it — an Ember Cape at $2.50, an Extra
 * Character Slot at $4.00, a 90-day Season Pass at $10.00, a small Private
 * World at $7.50 and a monthly Guild Hall at $5.00. `GET /products` is
 * deliberately unauthenticated, because "a shop that needs a token to show its
 * prices cannot be browsed by anybody who has not signed up".
 *
 * **Those five prices were written here as Shards until 2026-08-09.** They are
 * not Shards and have not been since billing's `retire_shard_prices` migration:
 * every SHARD row was set `status = 'retired'` and a parallel `USD` row
 * inserted at the same integer, because "ONE SHARD IS EXACTLY ONE CENT" and the
 * re-denomination is the identity on the stored number
 * (`billing/src/migrations.ts`). Read back from the mainnet estate on
 * 2026-08-09, `GET /products` answers `"assetCode":"USD"` on all five and no
 * SHARD price at all. SHARD is retired (`RETIRED_ASSETS`,
 * `contracts/packages/chain/src/index.ts`), so the old wording named a retired
 * asset at an operator in prices the service had already stopped quoting.
 * micro-org #227.
 *
 * What is empty is `purchases`, `entitlements`, `subscriptions`, `invoices` and
 * `payouts` — every one of which is TRANSACTIONAL. That distinction is the whole
 * of this file.
 *
 * ── WHY NOTHING IS CREATED HERE ─────────────────────────────────────────────
 *
 * Two separate reasons, and either alone would be sufficient.
 *
 * **1. There is no catalogue-writing API to call.** `billing/src/server.ts`
 * defines nine routes and not one of them writes `products` or `prices`;
 * `catalogue.ts` exports `listCatalogue`, `resolveTarget`, `expiryFor` and
 * `nextPeriodEnd` and no insert. The supported way to add a product is a new
 * migration in the billing repository. This seeder owns `deploy` and would have
 * to write SQL to add one — which is the thing the brief forbids, for the reason
 * it gives: a row conjured into Postgres skips every invariant the service
 * enforces. So this is a finding, not a licence.
 *
 * **2. The one content-creating route IS a financial transaction.**
 * `POST /purchases` posts a balanced journal entry inside the claim transaction:
 * the USD price is quoted into billing's settlement asset and the entry then
 * debits the user's `available` liability account in THAT asset and credits
 * `platform` `fees` revenue in it (`billing/src/purchases.ts` builds the
 * postings from `deps.settlementAsset`, which `billing/src/env.ts` types
 * `IssuableAssetCode` so a retired asset cannot be configured into it, and sets
 * to `EMBER`). There is no comp route, no free-grant route and no
 * operator-grant route — `refund()` even refuses to reverse a grant with no
 * entry behind it, which proves such grants are expected to arrive by a path
 * this repository does not contain.
 *
 * So a seeded purchase would require first inventing the money to pay with. That
 * is the same refusal mint makes, and it is worth stating in the same words:
 * money invented to make a surface look busy is what
 * `docs/ecosystem/21-engagement-treasury.md` §2 refuses, and it does not become
 * acceptable because the invented balance is spent inside the estate.
 *
 * ── WHAT AN OPERATOR SHOULD DO INSTEAD ──────────────────────────────────────
 *
 * The honest path to a non-empty entitlements surface is the one the engagement
 * treasury document already describes: mine EMBER, deposit it through the front
 * door, let the indexer confirm it, and then buy something with money that
 * exists. That is several working seams, and it belongs in its own change rather
 * than smuggled into a seeding script. (The document's §3 words that last hop as
 * "conversion to Shards". It is not one any more and there is nothing to convert
 * to: the deposit lands in EMBER and billing settles in EMBER, so the leg the
 * doc names is now the identity. Whether §3 gets amended is micro-org #226's
 * question, not this file's.)
 *
 * This file therefore VERIFIES and REPORTS. It is not a placeholder; it is the
 * decision.
 */

import { api, ok, bad, skip, note, head } from './lib.mjs'

export async function seedBilling(token) {
  head('billing — already seeded where it can be, and deliberately empty where it cannot')

  const res = await api('billing', '/products', {})
  if (res.status !== 200) {
    bad(`GET /products → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
    return
  }
  const products = res.body.products ?? []
  if (products.length === 0) {
    bad(
      'the billing catalogue is EMPTY, which means migration 9 has not run. That is a deployment ' +
        'fault, not something a seeder should paper over by inserting rows.',
    )
    return
  }

  ok(`catalogue holds ${products.length} product(s), seeded by migration 9 and public without a token:`)
  for (const p of products) {
    const price = (p.prices ?? [])[0]
    note(
      `  ${p.sku.padEnd(24)} ${p.kind.padEnd(13)} scope=${String(p.scopeKind).padEnd(10)} ` +
        `${price ? `${price.unitAmount} ${price.assetCode}${price.interval ? `/${price.interval}` : ''}` : 'no active price'}`,
    )
  }

  // Reading the operator's own entitlements is a read, and it proves the surface
  // hub-web and emberkin-web consume is reachable and simply has nothing in it.
  const ent = await api('billing', '/entitlements', { token })
  if (ent.status === 200) {
    const rows = ent.body.entitlements ?? []
    ok(`the entitlements surface answers and holds ${rows.length} row(s) for the operator`)
  } else {
    note(`GET /entitlements → ${ent.status} (the surface exists; nothing was created here either way)`)
  }

  skip(
    'no product or price was added: micro-billing has NO catalogue-writing route at all. Its nine ' +
      'routes never touch products or prices, and the supported way to add one is a migration in ' +
      'the billing repository. Adding rows from here would mean writing SQL. That is a finding ' +
      'about the service, and it is reported rather than worked around.',
  )
  skip(
    'no purchase and no entitlement was created. POST /purchases is the only content-creating ' +
      'route and it is a REAL financial transaction — it quotes the USD price into billing\'s ' +
      'settlement asset, then debits the buyer\'s balance in that asset and credits platform ' +
      'revenue in it, in one balanced journal entry. There is no comp or grant route. Seeding one ' +
      'would mean first inventing the money to pay with, which is 21-engagement-treasury.md §2\'s ' +
      'refusal exactly, not a smaller cousin of it.',
  )
  note(
    'the honest route to a non-empty entitlements surface is the one §3 already names: mine EMBER, ' +
      'deposit through the front door, let the indexer confirm, then buy. That is its own change, ' +
      'not a line in a seeder.',
  )
}
