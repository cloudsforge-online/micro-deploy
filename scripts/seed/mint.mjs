/**
 * Seed micro-mint: the platform's own token orders, and the project pages that
 * describe them.
 *
 * ── WHAT IS SEEDED, AND THE LINE IT STOPS AT ────────────────────────────────
 *
 * `POST /v1/tokens` OPENS AN ORDER. It charges nothing and deploys nothing —
 * "Nothing is charged and nothing is deployed, and an order that could not be
 * built is refused here" (`mint/README.md`). The order lands in
 * `awaiting_payment`, and the whole of what it asserts is that somebody intends
 * to launch a token with these parameters. That is a truthful thing for the
 * platform to say about its own tokens, so it is seeded.
 *
 * **`POST /v1/tokens/:id/pay` is NOT called, and that is the honest stopping
 * point rather than an omission.** Paying quotes the catalogue's USD price into
 * mint's settlement asset at micro-pricing's rate and debits that much real
 * money from the owner's micro-ledger balance (`mint/src/orders.ts`, whose
 * `payForDeploy` calls `deps.pricing.quote(deps.settlementAsset, cents)` and
 * then posts the debit in `deps.settlementAsset`). The operator holds nothing
 * to pay it with, and that is measured rather than assumed: on 2026-08-09 the
 * mainnet ledger held 39 accounts and NOT ONE of them belonged to
 * `user:019fcd54-…`, the estate admin — no account in any asset, so no balance
 * in any asset. The only way to make one appear would be to post a ledger entry
 * crediting it — money invented to make a surface look busy.
 * `21-engagement-treasury.md` §2 refuses exactly that class of thing, and it
 * does not become acceptable because the invented balance is spent inside the
 * estate rather than outside it. So the orders stop where the money starts.
 *
 * **This paragraph said `MINT_DEPLOY_PRICE_SHARDS` (2,500) of real SHARD until
 * 2026-08-09, and every clause of that is now false.** SHARD was retired on
 * 2026-08-04, and mint does not merely ignore the old variable — it refuses to
 * start with it set: "MINT_DEPLOY_PRICE_SHARDS is retired with the asset it
 * names" (`mint/src/env.ts`). The price is `MINT_DEPLOY_PRICE_USD_CENTS` and
 * the debit is in the settlement asset, neither of which is a Shard.
 * micro-org #227.
 *
 * `POST /v1/tokens/:id/deploy` is not called either, and here the reason is
 * simply that it cannot work: `MINT_RPC_URLS` is unset in the estate's compose
 * file, and mint refuses rather than falling back to a public node nobody chose
 * (`mint/src/env.ts`). A deploy would loop rather than fail cleanly.
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
 * a second draft order" (`mint/README.md`). Nor is there a unique index
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
 * unique `token_id` (`migrations.ts`), so re-sending is free.
 */

import process from 'node:process'
import { api, ok, bad, skip, note, head, ROOT, MINER_ADDRESS } from './lib.mjs'

/**
 * What one deploy costs, in the units the catalogue itself states — or `null`
 * when it states none.
 *
 * ── THIS REPLACES `${catalogue.body.priceShards} SHARD`, WHICH PRINTED THE
 *    WORD "undefined" AT AN OPERATOR ─────────────────────────────────────────
 *
 * Two call sites below interpolated `priceShards`. mint REMOVED that field from
 * `GET /v1/catalogue` rather than renaming it in place, and said why at the
 * point of removal: "A removed field is a 'undefined' a client can notice; a
 * silently re-based one is not" (`mint/src/server.ts`). The notice was never
 * taken here, so both sites emitted `undefined SHARD per deploy`.
 *
 * Measured against mainnet mint from the estate host on 2026-08-09,
 * `GET /v1/catalogue` answers
 *
 *   {"priceUsdCents":"2500","settlementAsset":"EMBER","network":"mainnet",…}
 *
 * with no `priceShards` key at all. micro-org #227.
 *
 * ── THE UNIT IS READ, NEVER TYPED ──────────────────────────────────────────
 *
 * `settlementAsset` comes off the response instead of a literal `'EMBER'` here.
 * A hand-typed asset code in a seeder is precisely how `SHARD` outlived its own
 * retirement in seven repositories: the service that owns the decision changes
 * it, and the copy that named it does not. mint types that field
 * `IssuableAssetCode` (`mint/src/env.ts`), so whatever arrives here cannot be a
 * retired asset — a guarantee no string in this file could offer.
 *
 * ── AND AN ABSENT PRICE IS `null`, NEVER `0` ───────────────────────────────
 *
 * `priceUsdCents` is nullable on mint's wire: `toWire` serves
 * `token.priceUsdCents?.toString() ?? null` for any order row written before
 * mint's migration 6 (`mint/src/tokens.ts`). A `?? 0` anywhere on this path
 * would render a paid order as free — the one wrong answer an operator has no
 * reason to question — so "not stated" is reported as not stated. The catalogue
 * route always states a price today; the decoding does not depend on that
 * staying true.
 */
function deployPrice(body) {
  const cents = body?.priceUsdCents
  // `/^\d+$/` before `BigInt`, because `BigInt('')` is `0n` and `BigInt(' 7 ')`
  // is `7n` — an empty or padded string would otherwise print as a real price.
  if (typeof cents !== 'string' || !/^\d+$/.test(cents)) return null
  const n = BigInt(cents)
  const usd = `$${(n / 100n).toString()}.${(n % 100n).toString().padStart(2, '0')}`
  const asset = typeof body?.settlementAsset === 'string' ? body.settlementAsset : null
  return asset ? `${usd} (${cents} US cents), settled in ${asset}` : `${usd} (${cents} US cents)`
}

/**
 * The owner address every order is opened against.
 *
 * Read from the miner key the estate already has, because that address is the
 * platform's real identity on this chain and mint stores it as the token's
 * owner. mint validates the 20-byte shape and canonicalises to EIP-55; it does
 * not verify that a wallet exists. If no key is present the domain is skipped
 * rather than fed a made-up address — a token order naming an address nobody
 * controls is a lie about who would own the token.
 *
 * ── THIS USED TO READ THE KEY FILE ITSELF, AND BROKE WHEN IT WAS SEALED ─────
 *
 * There was an `ownerAddress()` here that opened `coinbase-key.json` under
 * `MINER_DATA`. micro-org#206 encrypted that file into `coinbase-keystore.json`,
 * so from the sealing onward the address sat in the same directory under a name
 * this reader did not know, `ownerAddress()` returned null, and every token
 * order was skipped. The operator saw that as `estate-verify.sh`'s "mint.tokens
 * is EMPTY" — which reads as missing content, not as a reader that quietly
 * stopped matching, so it went uninvestigated for as long as it did.
 *
 * `lib.mjs` now owns the reading, tries both filenames, and exports the result.
 * Nothing is decrypted to get it: a keystore carries `address` in the clear
 * beside the encrypted `ciphertext` — that is the field's whole purpose — so
 * the platform can say WHO it is without the passphrase being anywhere near
 * this process. One reader, so the next rename breaks one place and is fixed
 * in one place.
 */
const ownerAddress = () => MINER_ADDRESS

/**
 * Three token orders the platform genuinely intends.
 *
 * The `features` x `cap` matrix is a hard gate with exactly three legal
 * combinations (`mint/src/catalogue.ts`, enforced at the order by
 * `assertBuildable`): `[]` is `fixed` and forbids a cap; `["mintable",
 * "burnable"]` is `mintable` and forbids a cap; `["mintable","burnable",
 * "pausable"]` is `foundry` and REQUIRES one with `cap >= supply`. One of each,
 * so the catalogue's three variants are all represented on the surface.
 *
 * Amounts cross the wire as strings; `decimals` and any bps are JSON numbers.
 * `requireQuantity` refuses a JSON number outright (`server.ts`).
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
      'no token orders: no coinbase-keystore.json or coinbase-key.json under the miner key directory ' +
        'carries a readable address, so the platform\'s own chain identity is unknown here, and opening ' +
        'an order against an address nobody controls would be a lie about who owns it. ' +
        'Set CF_MINER_KEYS to the directory holding <network>/coinbase-keystore.json.',
    )
    return
  }

  // The catalogue tells us the price we would have to pay and the variants that
  // are buildable. Public, no token — a shop that needs a sign-in to show its
  // prices cannot be browsed by anybody who has not signed up.
  const catalogue = await api('mint', '/v1/catalogue', { expect: 200 })
  const price = deployPrice(catalogue.body)
  note(
    `catalogue: ${catalogue.body.variants?.length ?? 0} variants, ` +
      `${price ?? 'no price stated'} per deploy, network ${catalogue.body.network}`,
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
    `no order was PAID. Paying quotes the catalogue price — ${price ?? 'which this catalogue does not state'} ` +
      '— into that asset at micro-pricing\'s rate and debits it from real ledger balance. The ' +
      'operator holds none, and crediting some to make the surface busier would be inventing ' +
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
