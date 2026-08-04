/**
 * micro-billing: the domain where the honest answer is "this is already seeded,
 * and the rest must not be".
 *
 * ── THE BRIEF SAID BILLING WAS EMPTY. IT IS NOT ─────────────────────────────
 *
 * Counted before any seeding ran: `products = 5`, `prices = 5`. The catalogue
 * has never been empty on any migrated deployment, because migration 9
 * (`billing/src/migrations.ts:389-423`) seeds it — an Ember Cape at 250 Shards,
 * an Extra Character Slot at 400, a 90-day Season Pass at 1,000, a small Private
 * World at 750 and a monthly Guild Hall at 500. `GET /products` is deliberately
 * unauthenticated, because "a shop that needs a token to show its prices cannot
 * be browsed by anybody who has not signed up".
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
 * it debits the user's SHARD `available` liability account and credits
 * `platform` SHARD `fees` revenue (`billing/src/ledger.ts:303-333`). There is no
 * comp route, no free-grant route and no operator-grant route — `refund()` even
 * refuses to reverse a grant with no entry behind it, which proves such grants
 * are expected to arrive by a path this repository does not contain.
 *
 * So a seeded purchase would require first inventing the SHARD to pay with. That
 * is the same refusal mint makes, and it is worth stating in the same words:
 * money invented to make a surface look busy is what
 * `docs/ecosystem/21-engagement-treasury.md` §2 refuses, and it does not become
 * acceptable because the invented balance is spent inside the estate.
 *
 * ── WHAT AN OPERATOR SHOULD DO INSTEAD ──────────────────────────────────────
 *
 * The honest path to a non-empty entitlements surface is the one the engagement
 * treasury document already describes: mine EMBER, deposit it through the front
 * door, let the indexer confirm it, convert to Shards, and then buy something
 * with money that exists. That is several working seams and a real conversion,
 * and it belongs in its own change rather than smuggled into a seeding script.
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
      'route and it is a REAL financial transaction — it debits the buyer\'s SHARD and credits ' +
      'platform revenue in a balanced journal entry. There is no comp or grant route. Seeding one ' +
      'would mean first inventing the SHARD to pay with, which is 21-engagement-treasury.md §2\'s ' +
      'refusal exactly, not a smaller cousin of it.',
  )
  note(
    'the honest route to a non-empty entitlements surface is the one §3 already names: mine EMBER, ' +
      'deposit through the front door, let the indexer confirm, convert to Shards, then buy. That ' +
      'is its own change, not a line in a seeder.',
  )
}
