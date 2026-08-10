/**
 * Seed micro-community: one real community, its treasury declarations, and two
 * proposals actually open for discussion.
 *
 * ── THE HONESTY PROBLEM THIS DOMAIN POSES, AND HOW IT IS ANSWERED ────────────
 *
 * A governance surface looks alive when several members are arguing and voting.
 * Producing that here would mean registering accounts that are not people and
 * casting votes nobody cast — which is the "ghost bettors" of
 * `docs/ecosystem/21-engagement-treasury.md` §2 wearing a committee's clothes.
 * A fabricated quorum is worse than a fabricated bid, because a governance
 * system MOVES MONEY BY VOTE (`community/README.md`) and a reader who
 * believes the votes are real is being misled about who decided.
 *
 * So nothing here invents a member. **Every act below is performed by the
 * estate's own operator account, and the community has exactly one member,
 * which is the truth.** No vote is cast: a founder voting alone on their own
 * charter would be honest but would render as a tally, and a tally of one that
 * looks like consensus is the thing worth avoiding. The proposals are OPENED for
 * discussion, which is the state that actually invites the first real member to
 * do something.
 *
 * ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
 *
 * Two layers, because the service has two.
 *
 *   * Every mutating route requires an `Idempotency-Key` of 8-200 characters
 *     matching `[A-Za-z0-9._:-]` (`community/src/server.ts, 1209-1214`),
 *     and the key is namespaced by principal, so a fixed key per artefact is
 *     safe and makes a retry inside one run a replay rather than a duplicate.
 *
 *   * That is not enough on its own, because a replay is only recognised while
 *     the claim row survives. So each artefact is also CHECKED FOR FIRST, on the
 *     field the schema makes unique: `slug` for a community, `assetCode` for a
 *     treasury account, `name` for a role. Proposals have no unique field at
 *     all, so they are matched on `title`, which is stated here rather than
 *     implied because it is the weakest of the four.
 *
 * ── A TRAP WORTH WRITING DOWN ───────────────────────────────────────────────
 *
 * A duplicate `slug` does NOT come back as a 409. `community/src/server.ts`
 * has no `23505` branch, so the Postgres unique violation surfaces as a **500
 * `internal`**. A seeder that treated "not 409" as "created" would report success
 * on a failed run. Hence the list-first, always.
 *
 * ── AND ONE FINDING, REPORTED RATHER THAN PAPERED OVER ──────────────────────
 *
 * **Nothing in this estate renders any of this.** There is no `community-web`
 * repository, and the only consumer is micro-tessera, which creates one
 * community per ward and explicitly does not read proposals, votes or tallies
 * (`tessera/src/communityclient.ts`). micro-community is also absent from both
 * `public-api.yml` and `estate-web.yml`, so it has no gateway route and a
 * browser cannot reach it at all. Seeding it makes its API and `estate-verify`
 * legible; it lights up no page. That is a gap in the estate, not in this file.
 */

import { api, ok, bad, skip, head } from './lib.mjs'

/** The one community. Slug shape is `^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$` (`migrations.ts`). */
const COMMUNITY = {
  slug: 'forge-council',
  name: 'The Forge Council',
  kind: 'public',
  joinPolicy: 'open',
  governanceModel: 'one_member_one_vote',
}

/**
 * Treasury accounts are DECLARATIONS, not balances.
 *
 * `community` holds no money: an account here names a `(subject, asset,
 * purpose=treasury)` triple in micro-ledger and `treasury_subject` is a
 * generated column pinned to `'community:' || id` (`community/README.md`).
 * Declaring one moves nothing and claims nothing about a balance, which is
 * exactly why it is safe to seed and a purchase is not.
 *
 * ── THIS WAS `['SHARD', 'EMBER']` UNTIL 2026-08-10. micro-org#226 ────────────
 *
 * SHARD is retired: `RETIRED_ASSETS` freezes it and `assertIssuable('SHARD')`
 * throws "SHARD is retired and may not denominate anything new"
 * (`contracts/packages/chain`). A treasury account IS something new — it is a
 * `(subject, asset, purpose)` triple that did not exist before this script asks
 * for it — so seeding one in SHARD is the retirement being ignored by a
 * hand-typed string, which is the exact failure `mint.mjs` already names in this
 * directory: "a hand-typed asset code in a seeder is precisely how SHARD
 * outlived its own retirement".
 *
 * Dropped rather than converted, because a declaration has no amount to convert
 * and no history to preserve. A community created by this script today can
 * never hold a Shard: none can be issued, and the 26,000 that survive on mainnet
 * (14 accounts, measured 2026-08-10 — 13,000 in `custody`, 13 x 1,000 in user
 * liability accounts) are pre-retirement residue belonging to individual users,
 * with no path from there to a community treasury.
 *
 * EMBER alone is also what the treasury this council proposes to spend from is
 * denominated in, since admin-api's migration 13 (`engagement-in-ember-wei`,
 * 2026-08-10). Two declared assets, one of which nothing can ever put money
 * into, is a treasury page with a permanently empty row on it.
 *
 * The estate's existing council already has both accounts declared — the seed
 * ran on 2026-08-04 — and this change does NOT remove the SHARD one. Removing a
 * declaration is not seeding's job and it names an account holding nothing.
 * A fresh estate gets EMBER only.
 */
const TREASURY_ASSETS = ['EMBER']

/** Asset shape is `^[A-Z][A-Z0-9:_-]{0,120}$` (`migrations.ts`). */
const ROLES = [
  {
    name: 'steward',
    capabilities: ['proposal.review', 'discussion.moderate'],
  },
]

/** ISO, `n` days from now, on the minute. */
const inDays = (n) => new Date(Date.now() + n * 86_400_000).toISOString()

/**
 * Two proposals, both genuinely about this estate.
 *
 * The treasury one is a real shape the service enforces: `treasury_spend`
 * requires the `spend` bag, a recipient matching
 * `^(user|community|organisation):[A-Za-z0-9._-]{1,128}$` (`migrations.ts`),
 * and a timelock at least fifteen minutes after close (`proposals.ts`).
 * It PROPOSES a spend; it does not make one. Nothing moves unless a real
 * membership votes it through and the execution job runs.
 */
function proposals(communityId) {
  return [
    {
      kind: 'text',
      title: 'Charter: what the Forge Council decides, and what it does not',
      body:
        'This council governs the shared surfaces of the CloudsForge estate: which questions ' +
        'Foresight opens, which listings the platform itself puts on Market, and how the ' +
        'engagement treasury is spent. It does not govern user funds, which live in micro-ledger ' +
        'and move only by their owner\'s instruction, and it does not govern consensus, which ' +
        'belongs to whoever mines Hearth.\n\n' +
        'Proposed at the opening of the estate by its operator, who is at the time of writing its ' +
        'only member. This proposal is open for discussion rather than put to a vote, because a ' +
        'tally of one is not a mandate.',
      quorum: '1',
      thresholdBps: 5000,
      opensAt: inDays(1),
      closesAt: inDays(15),
      timelockUntil: inDays(16),
    },
    {
      kind: 'treasury_spend',
      title: 'Fund the first Foresight house seed from the council treasury',
      body:
        'Foresight can seed a new market symmetrically across both outcomes, at open only, ' +
        'disclosed on the page as the platform\'s — the one form of platform money in a market ' +
        'that docs/ecosystem/21-engagement-treasury.md permits. The estate cannot do it today: ' +
        'FORESIGHT_HOUSE_ADDRESS is unset and the engagement treasury holds nothing, because it is ' +
        'funded by mined EMBER arriving through the front door as an ordinary deposit and no ' +
        'deposit has been made.\n\n' +
        'This proposes the first transfer, so that the seed is authorised by a vote rather than by ' +
        'whoever holds a database connection. The amount is deliberately small: the point is to ' +
        'establish the path, not to fund a programme.',
      quorum: '1',
      thresholdBps: 6600,
      opensAt: inDays(1),
      closesAt: inDays(15),
      timelockUntil: inDays(16),
      // ── EMBER wei, and this was `SHARD` / `'100000'` until 2026-08-10 ───────
      //
      // micro-org#226: this proposal IS the issue, reproduced in seeded content.
      // It proposed spending a retired asset (`RETIRED_ASSETS`,
      // contracts/packages/chain) to fund a house seed that is EMBER wei — the
      // two legs of one programme in two assets, one of which may not denominate
      // anything new. Nothing refuses it on the way in: `spend_asset_code` is
      // free text on `proposals` (community/migrations.ts), and had it ever
      // executed, micro-ledger's retired-asset gate is scoped to
      // ACQUISITION_KINDS and leaves `transfer` legal on purpose, so it would
      // have POSTED rather than raised.
      //
      // CONVERTED, NOT RELABELLED, which is the whole point. SHARD has 0
      // decimals and EMBER has 18, so carrying '100000' across to EMBER would
      // have proposed 1e5 wei — 0.0000000000001 EMBER, four billionths of a US
      // cent — a rounding error wearing the same digits. At the frozen rate
      // 1 Shard = 4e16 wei (1 Shard = 1 US cent, `SHARDS_PER_USD`; 1 EMBER =
      // the administered 0.25 USD, `pricing.administered_prices` `usd_scaled`
      // 250000 against `RATE_SCALE` 1e6, read on mainnet 2026-08-10 and
      // unchanged since 2026-08-04), 100,000 Shards is 4e21 wei = 4,000 EMBER.
      // The value the proposal asks for is identical either way: USD 1,000.
      // Converting keeps the ask the council already made; picking a new figure
      // would be this script inventing a number, which it refuses to do
      // elsewhere for the same reason.
      //
      // 4,000 EMBER is far more than the estate holds — 50.200042 EMBER across
      // 31 ledger accounts, measured 2026-08-10 — and that is not a defect in
      // this seed. A `treasury_spend` PROPOSES; nothing moves without a real
      // membership voting it through and the execution job running, and the body
      // above already says the treasury holds nothing. It was equally
      // unaffordable as USD 1,000 of Shards.
      spend: {
        assetCode: 'EMBER',
        amount: '4000000000000000000000',
        recipient: `community:${communityId}`,
      },
    },
  ]
}

/** Fixed keys: a retry inside one run replays rather than duplicating. */
const key = (...parts) => ['estate-seed', ...parts].join('.').slice(0, 200)

async function ensureCommunity(token) {
  const list = await api('community', '/v1/communities?limit=200', { expect: 200 })
  const found = (list.body.communities ?? []).find((c) => c.slug === COMMUNITY.slug)
  if (found) {
    ok(`community ${COMMUNITY.slug} already exists (${found.id.slice(0, 8)}) — not re-created`)
    return found
  }
  const res = await api('community', '/v1/communities', {
    method: 'POST',
    token,
    body: COMMUNITY,
    idempotencyKey: key('community', COMMUNITY.slug),
  })
  if (res.status !== 201 && res.status !== 200) {
    // A 500 here is very likely the unmapped 23505 described in the header.
    bad(`create community → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
    return null
  }
  ok(`community ${COMMUNITY.slug} created — the caller became its owner in the same transaction`)
  return res.body.community
}

async function ensureTreasuryAccounts(token, communityId) {
  const list = await api('community', `/v1/communities/${communityId}/treasury-accounts`, {
    token,
    expect: 200,
  })
  const have = new Set((list.body.accounts ?? list.body.treasuryAccounts ?? []).map((a) => a.assetCode))
  for (const assetCode of TREASURY_ASSETS) {
    if (have.has(assetCode)) {
      ok(`treasury account ${assetCode} already declared`)
      continue
    }
    const res = await api('community', `/v1/communities/${communityId}/treasury-accounts`, {
      method: 'POST',
      token,
      body: { assetCode },
      idempotencyKey: key('treasury', communityId, assetCode),
    })
    if (res.status === 201 || res.status === 200) {
      ok(`treasury account ${assetCode} declared — a name for a ledger triple, holding nothing`)
    } else {
      bad(`treasury ${assetCode} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    }
  }
}

async function ensureRoles(token, communityId) {
  const list = await api('community', `/v1/communities/${communityId}/roles`, {
    token,
    expect: 200,
  })
  const have = new Set((list.body.roles ?? []).map((r) => r.name))
  for (const role of ROLES) {
    if (have.has(role.name)) {
      ok(`role ${role.name} already exists`)
      continue
    }
    const res = await api('community', `/v1/communities/${communityId}/roles`, {
      method: 'POST',
      token,
      body: role,
      idempotencyKey: key('role', communityId, role.name),
    })
    if (res.status === 201 || res.status === 200) ok(`role ${role.name} created`)
    else bad(`role ${role.name} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
  }
}

async function ensureProposals(token, communityId) {
  const list = await api('community', `/v1/communities/${communityId}/proposals?limit=200`, {
    token,
    expect: 200,
  })
  const byTitle = new Map((list.body.proposals ?? []).map((p) => [p.title, p]))

  for (const spec of proposals(communityId)) {
    let proposal = byTitle.get(spec.title)
    if (proposal) {
      ok(`proposal "${spec.title.slice(0, 44)}…" already exists (${proposal.status})`)
    } else {
      const res = await api('community', `/v1/communities/${communityId}/proposals`, {
        method: 'POST',
        token,
        body: spec,
        idempotencyKey: key('proposal', communityId, spec.kind),
      })
      if (res.status !== 201 && res.status !== 200) {
        bad(`proposal "${spec.title.slice(0, 40)}…" → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
        continue
      }
      proposal = res.body.proposal
      ok(`proposal ${proposal.id.slice(0, 8)} [${spec.kind}] "${spec.title.slice(0, 44)}…"`)
    }

    // A proposal left in `draft` accepts no discussion and no vote, and renders
    // as empty as no proposal at all. `open` is the state that invites the first
    // real member to do something. No Idempotency-Key on this route by design
    // (`routeidempotency.test.ts`): a second open is a state conflict.
    if (proposal.status === 'draft') {
      const opened = await api('community', `/v1/proposals/${proposal.id}/open`, {
        method: 'POST',
        token,
        body: {},
      })
      if (opened.status === 200) ok(`  opened ${proposal.id.slice(0, 8)} for discussion`)
      else bad(`  open ${proposal.id.slice(0, 8)} → ${opened.status}: ${JSON.stringify(opened.body).slice(0, 160)}`)
    }

    // One post, by the operator, saying what the proposal is for. Not a
    // conversation — a conversation would need people.
    const posts = await api('community', `/v1/proposals/${proposal.id}/posts?limit=50`, {
      token,
    })
    if (posts.status === 200 && (posts.body.posts ?? []).length > 0) {
      ok(`  discussion already opened on ${proposal.id.slice(0, 8)}`)
      continue
    }
    const body =
      spec.kind === 'treasury_spend'
        ? 'Posted by the estate operator. This is the authorisation path for a disclosed, symmetric ' +
          'house seed, not the seed itself — nothing moves until a real membership votes it through ' +
          'and the timelock expires.'
        : 'Posted by the estate operator at the opening of the council. The council has one member ' +
          'today. This proposal is open for discussion rather than put to a vote, because a tally ' +
          'of one is a signature, not a mandate.'
    const res = await api('community', `/v1/proposals/${proposal.id}/posts`, {
      method: 'POST',
      token,
      body: { body },
      idempotencyKey: key('post', proposal.id),
    })
    if (res.status === 201 || res.status === 200) ok(`  discussion opened on ${proposal.id.slice(0, 8)}`)
    else bad(`  post on ${proposal.id.slice(0, 8)} → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
  }
}

export async function seedCommunity(token) {
  head('community — one real council, one real member, and no invented quorum')

  const community = await ensureCommunity(token)
  if (!community) return

  await ensureTreasuryAccounts(token, community.id)
  await ensureRoles(token, community.id)
  await ensureProposals(token, community.id)

  skip(
    'no votes were cast and no members were invented. The council has one member — its operator — ' +
      'and that is what the API reports. A seeded electorate would be the ghost bettors of ' +
      '21-engagement-treasury.md §2 in a committee\'s clothes.',
  )
  skip(
    'nothing in this estate RENDERS any of the above: there is no community-web, micro-community ' +
      'has no gateway route in public-api.yml or estate-web.yml, and tessera — its only consumer — ' +
      'creates a community per ward and reads no proposal. Seeded for the API, not for a page.',
  )
}
