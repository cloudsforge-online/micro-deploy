/**
 * Seed micro-mint: the platform's own token orders, and the project pages that
 * describe them.
 *
 * ── WHAT IS SEEDED, AND THE LINE IT STOPS AT ────────────────────────────────
 *
 * `POST /v1/tokens` OPENS AN ORDER. It charges nothing and deploys nothing —
 * "Nothing is charged and nothing is deployed, and an order that could not be
 * built is refused here" (`mint/README.md:73`). The order lands in
 * `awaiting_payment`, and the whole of what it asserts is that somebody intends
 * to launch a token with these parameters. That is a truthful thing for the
 * platform to say about its own tokens, so it is seeded.
 *
 * **`POST /v1/tokens/:id/pay` is NOT called, and that is the honest stopping
 * point rather than an omission.** Paying debits `MINT_DEPLOY_PRICE_SHARDS`
 * (2,500) of real SHARD from the owner's micro-ledger balance
 * (`orders.ts:99-140`). The operator has no SHARD, and the only way to get some
 * would be to post a ledger entry crediting it — money invented to make a
 * surface look busy. `21-engagement-treasury.md` §2 refuses exactly that class
 * of thing, and it does not become acceptable because the invented balance is
 * spent inside the estate rather than outside it. So the orders stop where the
 * money starts.
 *
 * `POST /v1/tokens/:id/deploy` is not called either, and here the reason is
 * simply that it cannot work: `MINT_RPC_URLS` is unset in the estate's compose
 * file, and mint refuses rather than falling back to a public node nobody chose
 * (`mint/src/env.ts:270`). A deploy would loop rather than fail cleanly.
 *
 * ── WHAT THE SURFACE ACTUALLY SHOWS ─────────────────────────────────────────
 *
 * `GET /v1/catalogue` and `GET /v1/tokens/:id/page` are public; `GET /v1/tokens`
 * returns only the CALLER's own orders. So a signed-out visitor to mint-web sees
 * the catalogue, which was never empty, and a signed-in operator sees these.
 * Project pages are the part a stranger can read, which is why every order gets
 * one.
 *
 * ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
 *
 * **micro-mint has no idempotency infrastructure at all** — its own README says
 * so twice: "No helper, no table, no module, no header. Grep the repository:
 * `Idempotency-Key` appears nowhere. A retried POST /v1/tokens therefore creates
 * a second draft order" (`mint/README.md:126-129`). Nor is there a unique index
 * on `symbol`, `name`, or anything else an order carries.
 *
 * So this is check-then-create and nothing else, and the discriminator is the
 * tuple `(symbol, chain, network)` read back from `GET /v1/tokens`. Orders in
 * `failed` are ignored when matching, so a failed attempt does not block a
 * retry. That the ONLY protection against a double order here is client-side is
 * a finding about micro-mint, and it is stated rather than hidden behind a
 * working seeder.
 *
 * Project pages need no such care: `PUT /v1/tokens/:id/page` is an upsert on a
 * unique `token_id` (`migrations.ts:248`), so re-sending is free.
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { api, ok, bad, skip, note, head, ROOT, MINER_DATA } from './lib.mjs'

/**
 * The owner address every order is opened against.
 *
 * Read from the miner key file the estate already has, because that address is
 * the platform's real identity on this chain and mint stores it as the token's
 * owner. mint validates the 20-byte shape and canonicalises to EIP-55; it does
 * not verify that a wallet exists. If the key file is absent the domain is
 * skipped rather than fed a made-up address — a token order naming an address
 * nobody controls is a lie about who would own the token.
 */
function ownerAddress() {
  // `MINER_DATA` is `lib.mjs`'s, and it looks in `../miner-keys/<network>` —
  // the layout `compose/docker-compose.miners.yml:134` already declares — before
  // falling back to the laptop path this function used to be the only reader of.
  // On the deployment host the laptop path does not exist, so this returned null
  // and every token order was skipped for want of a key two directories away.
  const file = path.join(MINER_DATA, 'coinbase-key.json')
  try {
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
    return String(raw.address)
  } catch {
    return null
  }
}

/**
 * Three token orders the platform genuinely intends.
 *
 * The `features` x `cap` matrix is a hard gate with exactly three legal
 * combinations (`mint/src/catalogue.ts:39-64`, enforced at the order by
 * `assertBuildable`): `[]` is `fixed` and forbids a cap; `["mintable",
 * "burnable"]` is `mintable` and forbids a cap; `["mintable","burnable",
 * "pausable"]` is `foundry` and REQUIRES one with `cap >= supply`. One of each,
 * so the catalogue's three variants are all represented on the surface.
 *
 * Amounts cross the wire as strings; `decimals` and any bps are JSON numbers.
 * `requireQuantity` refuses a JSON number outright (`server.ts:713-719`).
 */
const ORDERS = [
  {
    chain: 'ember',
    name: 'Forge Council Voice',
    symbol: 'VOICE',
    decimals: 18,
    supply: '1000000000000000000000000',
    features: [],
    page: {
      description:
        'A fixed-supply governance token for the Forge Council, the community that governs the ' +
        'shared surfaces of this estate. Fixed supply because a governance weight that can be ' +
        'minted is a governance weight whoever holds the mint key already controls.',
      riskDisclosures:
        'This is an order on a testnet, opened by the platform against its own address. It is not ' +
        'paid for, it is not deployed, and no contract exists at any address. Nothing here is an ' +
        'offer to sell anything to anybody.',
      links: [{ label: 'The council', href: 'https://cloudsforge.localtest.me/' }],
      roadmap: [
        { milestone: 'Order opened', state: 'done' },
        { milestone: 'Paid from the engagement treasury', state: 'blocked' },
        { milestone: 'Deployed to Hearth', state: 'planned' },
      ],
    },
  },
  {
    chain: 'ember',
    name: 'Emberkin Kindling',
    symbol: 'KNDL',
    decimals: 18,
    supply: '500000000000000000000000',
    features: ['mintable', 'burnable'],
    page: {
      description:
        'The soft currency of Emberkin, mintable as the title issues rewards and burnable as they ' +
        'are spent. Art direction and identity come from the micro-emberkin-assets set already in ' +
        'this estate; nothing was generated for this listing.',
      riskDisclosures:
        'A testnet order opened by the platform against its own address, unpaid and undeployed. ' +
        'A mintable token means the holder of the mint authority can increase supply; that ' +
        'authority would sit with the title, and that is a fact about the design, not a promise.',
      links: [{ label: 'Emberkin', href: 'https://emberkin.cloudsforge.localtest.me/' }],
      roadmap: [
        { milestone: 'Order opened', state: 'done' },
        { milestone: 'Reward sinks agreed with the title', state: 'planned' },
      ],
    },
  },
  {
    chain: 'ember',
    name: 'Aetherholm Charter',
    symbol: 'CHRT',
    decimals: 18,
    supply: '200000000000000000000000',
    cap: '1000000000000000000000000',
    features: ['mintable', 'burnable', 'pausable'],
    page: {
      description:
        'A capped, pausable charter token for Aetherholm\'s two hundred islands and the lanes ' +
        'between them. The cap is five times the initial supply and is enforced by the contract ' +
        'rather than by a promise; pausable because a lane economy that cannot be halted is one ' +
        'that cannot be repaired.',
      riskDisclosures:
        'A testnet order opened by the platform against its own address, unpaid and undeployed. ' +
        'Pausable means an authority can freeze transfers. That is a real power and it is named ' +
        'here rather than discovered later.',
      links: [{ label: 'Aetherholm', href: 'https://aetherholm.cloudsforge.localtest.me/' }],
      roadmap: [
        { milestone: 'Order opened', state: 'done' },
        { milestone: 'Cap and pause authority assigned', state: 'planned' },
      ],
    },
  },
]

export async function seedMint(token) {
  head('mint — the platform\'s own token orders, stopping where the money starts')

  const owner = ownerAddress()
  if (!owner) {
    skip(
      'no token orders: there is no miner key file to read the platform\'s own chain address from, ' +
        'and opening an order against an address nobody controls would be a lie about who owns it.',
    )
    return
  }

  // The catalogue tells us the price we would have to pay and the variants that
  // are buildable. Public, no token — a shop that needs a sign-in to show its
  // prices cannot be browsed by anybody who has not signed up.
  const catalogue = await api('mint', '/v1/catalogue', { expect: 200 })
  note(
    `catalogue: ${catalogue.body.variants?.length ?? 0} variants, ` +
      `${catalogue.body.priceShards} SHARD per deploy, network ${catalogue.body.network}`,
  )

  const mine = await api('mint', '/v1/tokens', { token, expect: 200 })
  const existing = (mine.body.tokens ?? []).filter((t) => t.status !== 'failed')
  const seen = new Set(existing.map((t) => `${t.symbol}|${t.chain}|${t.network}`))

  for (const spec of ORDERS) {
    const network = catalogue.body.network ?? 'testnet'
    const fingerprint = `${spec.symbol}|${spec.chain}|${network}`
    let order = existing.find((t) => `${t.symbol}|${t.chain}|${t.network}` === fingerprint)

    if (order) {
      ok(`order ${spec.symbol} already exists (${order.id.slice(0, 8)}, ${order.status}) — not re-ordered`)
    } else if (seen.has(fingerprint)) {
      ok(`order ${spec.symbol} already exists — not re-ordered`)
      continue
    } else {
      const body = {
        chain: spec.chain,
        name: spec.name,
        symbol: spec.symbol,
        decimals: spec.decimals,
        supply: spec.supply,
        features: spec.features,
        ownerAddress: owner,
        // mint validates the address shape but does not verify a wallet exists,
        // so this names the binding rather than inventing a wallet id.
        ownerWalletId: 'estate-operator-miner-key',
        ...(spec.cap ? { cap: spec.cap } : {}),
      }
      const res = await api('mint', '/v1/tokens', { method: 'POST', token, body })
      if (res.status !== 201 && res.status !== 200) {
        bad(`order ${spec.symbol} → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
        continue
      }
      order = res.body.token
      seen.add(fingerprint)
      ok(
        `order ${order.id.slice(0, 8)} ${spec.symbol} (${spec.features.length === 0 ? 'fixed' : spec.cap ? 'foundry' : 'mintable'}) ` +
          `— ${order.status}, nothing charged and nothing deployed`,
      )
    }

    // The public half. Upsert on a unique token_id, so this is free to repeat.
    const page = await api('mint', `/v1/tokens/${order.id}/page`, {
      method: 'PUT',
      token,
      body: {
        description: spec.page.description,
        riskDisclosures: spec.page.riskDisclosures,
        links: spec.page.links,
        roadmap: spec.page.roadmap,
        team: [{ name: 'CloudsForge', role: 'Platform operator' }],
      },
    })
    if (page.status === 200 || page.status === 201) ok(`  project page written for ${spec.symbol}`)
    else bad(`  page ${spec.symbol} → ${page.status}: ${JSON.stringify(page.body).slice(0, 160)}`)
  }

  skip(
    `no order was PAID. Paying debits ${catalogue.body.priceShards} SHARD of real ledger balance, ` +
      'the operator holds none, and crediting some to make the surface busier would be inventing ' +
      'money — which is the thing 21-engagement-treasury.md §2 refuses, not a smaller cousin of it.',
  )
  skip(
    'no order was DEPLOYED: MINT_RPC_URLS is unset in the estate compose file and mint refuses ' +
      'rather than falling back to a public node nobody chose, so a deploy would loop.',
  )
  skip(
    'micro-mint has NO idempotency infrastructure — no header, no table, no helper, and no unique ' +
      'index on symbol or name. The only thing stopping a duplicate order here is this script ' +
      'checking first. That is a finding about the service, not a property of it.',
  )
}
