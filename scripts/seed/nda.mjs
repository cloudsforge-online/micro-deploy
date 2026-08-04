/**
 * Seed micro-nda (Ninety Days After): one world, started, populated and ticked.
 *
 * ── WHY THE BOTS ARE NOT THE THING §2 REFUSES ───────────────────────────────
 *
 * This is the one domain where seeding creates something that looks like other
 * participants, so it is worth being precise about why it is allowed.
 *
 * `PUT /v1/worlds/:id/bots` is a FEATURE OF THE GAME, not a trick played on a
 * reader. `worlds.ts:575-578` inserts each one with `is_bot = true`, `user_id =
 * null`, and a handle of the literal form `bot-<personality>-<n>`. The roster
 * route returns `isBot` on every row (`worlds.ts:603`). A bot is therefore
 * labelled as a bot in the schema, on the wire and in its own name — there is no
 * position from which one could be mistaken for a person.
 *
 * That is the whole distinction `docs/ecosystem/21-engagement-treasury.md` §2
 * draws. What it refuses is "synthetic bids, ghost bettors, invisible house
 * positions" — value-bearing acts by parties that do not exist, presented as
 * organic demand. A survival game's NPC settlers bear no value, take no money
 * from anyone, and are disclosed. Refusing them would not be principle; it would
 * be refusing to turn on a documented feature.
 *
 * **No user account is registered by this file.** The only human in the world is
 * the estate's own operator, who joins with their own token.
 *
 * ── WHY IT IS TICKED, AND ONLY TWICE ────────────────────────────────────────
 *
 * A world in `lobby` with nobody in it renders as empty as no world. Starting it
 * and resolving two days produces `world_events`, `reports`, `player_progress`
 * and `objectives` — the tables a reader would actually look at. Two rather than
 * twenty because the point is a legible surface, not a simulated season, and
 * every tick is real work the resolution engine does.
 *
 * ── IDEMPOTENCY, AND A TRAP SPECIFIC TO THIS SERVICE ────────────────────────
 *
 * `worlds.name` has NO unique constraint (`migrations.ts:123-152`), so the check
 * is a list-and-match on the name and the create is guarded by it.
 *
 * The trap: nda namespaces its idempotency key by ROUTE ONLY, not by principal —
 * `namespacedKey` is `` `${route}:${clientKey}` `` (`nda/src/idempotency.ts:82-84`).
 * Two different callers sending the same key to the same route collide, and the
 * loser can be served the winner's response. Every key below is therefore
 * prefixed with `estate-seed.` so it cannot collide with a real player's, and is
 * otherwise fixed so that a retry inside one run replays.
 *
 * ── ONE FINDING ─────────────────────────────────────────────────────────────
 *
 * There is no `nda-web`, and no web application in the estate calls this service
 * — `worlds-web` renders micro-WORLDS, which is a different service with
 * different routes. nda is also absent from both gateway configs. Seeding it
 * makes its API and its metrics legible and lights up no page, exactly as with
 * community.
 */

import { api, ok, bad, skip, note, head, sleep } from './lib.mjs'

/** `name` is trimmed and must be 3-40 characters (`rules.ts:423-424`). */
const WORLD = {
  name: 'Emberfall Commons',
  width: 24,
  height: 24,
  seasonLength: 90,
  tickIntervalMinutes: 1440,
  seed: 'cloudsforge-estate-emberfall-commons',
}

/** 12 settlers. `bot_count` is capped at 200 by the schema; 12 fills a roster without theatre. */
const BOT_COUNT = 12

/** Ticks to resolve, so reports and events exist for a reader to look at. */
const TICKS = 2

const key = (...parts) => ['estate-seed', ...parts].join('.').slice(0, 200)

async function findWorld(token) {
  const res = await api('nda', '/v1/worlds?status=lobby,active,archived', { token })
  if (res.status !== 200) {
    bad(`list worlds → ${res.status}: ${JSON.stringify(res.body).slice(0, 160)}`)
    return null
  }
  return (res.body.worlds ?? []).find((w) => w.name === WORLD.name) ?? null
}

export async function seedNda(token) {
  head('nda — one world, the game\'s own labelled bots, and two real ticks')

  let world = await findWorld(token)
  if (world) {
    ok(`world "${WORLD.name}" already exists (${world.id.slice(0, 8)}, ${world.status}) — not re-created`)
  } else {
    const res = await api('nda', '/v1/worlds', {
      method: 'POST',
      token,
      body: WORLD,
      idempotencyKey: key('nda', 'world', WORLD.seed),
    })
    if (res.status !== 201 && res.status !== 200) {
      bad(`create world → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
      return
    }
    world = res.body.world
    ok(`world ${world.id.slice(0, 8)} "${WORLD.name}" created — ${WORLD.width}x${WORLD.height} tiles, in lobby`)
  }

  // ── the roster ─────────────────────────────────────────────────────────────
  // Idempotent by construction: `syncBots` brings the roster IN LINE WITH a
  // target rather than adding to it (`worlds.ts:547-596`), so sending the same
  // count twice is a no-op in the service and not merely in this script.
  const bots = await api('nda', `/v1/worlds/${world.id}/bots`, {
    method: 'PUT',
    token,
    body: { enabled: true, count: BOT_COUNT },
    idempotencyKey: key('nda', 'bots', world.id, String(BOT_COUNT)),
  })
  if (bots.status === 200 || bots.status === 201) {
    ok(`roster brought in line with ${BOT_COUNT} bots — every one is is_bot=true, user_id=null, handle bot-*`)
  } else {
    bad(`bots → ${bots.status}: ${JSON.stringify(bots.body).slice(0, 160)}`)
  }

  // ── the one human ──────────────────────────────────────────────────────────
  // Naturally idempotent: an existing player comes back `created: false`
  // (`worlds.ts:401-402`). Joining is allowed while the world is in lobby.
  const joined = await api('nda', `/v1/worlds/${world.id}/join`, {
    method: 'POST',
    token,
    body: {},
    idempotencyKey: key('nda', 'join', world.id),
  })
  if (joined.status === 200 || joined.status === 201) {
    ok('the estate operator settled in the world — the only account here that is a person')
  } else {
    bad(`join → ${joined.status}: ${JSON.stringify(joined.body).slice(0, 160)}`)
  }

  // ── start ──────────────────────────────────────────────────────────────────
  if (world.status === 'lobby') {
    const started = await api('nda', `/v1/worlds/${world.id}/start`, {
      method: 'POST',
      token,
      body: {},
      idempotencyKey: key('nda', 'start', world.id),
    })
    if (started.status === 200 || started.status === 201) {
      ok('world started — lobby → active')
      world.status = 'active'
    } else {
      bad(`start → ${started.status}: ${JSON.stringify(started.body).slice(0, 160)}`)
    }
  } else {
    ok(`world is already ${world.status} — not restarted`)
  }

  // ── the operator's own queued actions ──────────────────────────────────────
  // Replacing a queue rather than appending to one, so this is idempotent in the
  // service: `PUT` sets the queue to exactly what is sent.
  const actions = await api('nda', `/v1/worlds/${world.id}/actions`, {
    method: 'PUT',
    token,
    body: { actions: [{ type: 'work' }, { type: 'fortify' }, { type: 'rest' }] },
    idempotencyKey: key('nda', 'actions', world.id),
  })
  if (actions.status === 200 || actions.status === 201) ok('the operator queued three actions for the next day')
  else bad(`actions → ${actions.status}: ${JSON.stringify(actions.body).slice(0, 160)}`)

  // ── resolve some days ──────────────────────────────────────────────────────
  //
  // NOT idempotent, and it must not pretend to be: a tick is the resolution
  // engine doing real work and advancing the world's clock. So the guard is the
  // world's OWN DAY COUNTER — this brings the world up to TICKS days and stops.
  // A second seeding run finds it already there and ticks nothing, which is why
  // the counts do not move on a re-run.
  const state = await api('nda', `/v1/worlds/${world.id}`, { token })
  const day = state.status === 200 ? (state.body.world?.day ?? 0) : 0
  if (day >= TICKS) {
    ok(`world is on day ${day} — already at or past day ${TICKS}, so nothing is ticked`)
  } else {
    for (let d = day; d < TICKS; d++) {
      const tick = await api('nda', `/v1/worlds/${world.id}/tick`, {
        method: 'POST',
        token,
        body: {},
        idempotencyKey: key('nda', 'tick', world.id, String(d)),
      })
      if (tick.status !== 202 && tick.status !== 200) {
        bad(`tick ${d} → ${tick.status}: ${JSON.stringify(tick.body).slice(0, 160)}`)
        break
      }
      // 202: the resolution runs in a leased job, not in the request.
      ok(`tick for day ${d} accepted (202) — the engine resolves it in a leased job`)
      for (let i = 0; i < 30; i++) {
        await sleep(1_000)
        const now = await api('nda', `/v1/worlds/${world.id}`, { token })
        if (now.status === 200 && (now.body.world?.day ?? 0) > d) break
      }
    }
    const final = await api('nda', `/v1/worlds/${world.id}`, { token })
    note(`world is on day ${final.status === 200 ? final.body.world?.day : '?'}`)
  }

  skip(
    'no player account was registered. The world holds one person — the estate operator — and ' +
      `${BOT_COUNT} bots that the schema, the wire and their own handles all label as bots.`,
  )
  skip(
    'nothing in this estate RENDERS this: there is no nda-web, no web app calls the service, and ' +
      'it has no gateway route. worlds-web renders micro-worlds, which is a different service.',
  )
}
