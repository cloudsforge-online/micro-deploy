/**
 * Seed micro-worlds' TITLE REGISTER: one row per game the estate actually runs.
 *
 * ══════════════════════════════════════════════════════════════════════════════
 * WHY THIS FILE EXISTS — THE REGISTER WAS THE ONLY HAND-MAINTAINED TABLE LEFT
 *
 * Every other domain in `estate-seed.mjs` is seeded through its own API and is
 * therefore reproducible: destroy the volume, run the seeder, get the same
 * estate back. The title register was not in that list, so the three rows in it
 * were typed by hand — once, months ago, by whoever last touched the service —
 * and then drifted, silently, with nothing in the estate able to notice.
 *
 * Measured on mainnet on 2026-08-14, `GET /v1/titles` on `api.cloudsforge.online`:
 *
 *   emberkin           draft   capabilities []              assetScopes []
 *   ninety-days-after  beta    capabilities []              assetScopes []
 *   aetherholm         live    capabilities [private_world] assetScopes [aetherholm]
 *
 * **Emberkin is a finished client**, built, deployed and serving at
 * `emberkin.cloudsforge.online`. `draft` is the one status that is not open to
 * play (`worlds/src/titles.ts`), so `worlds-web` rendered the game with no way
 * in and a sentence saying the register has it as draft. Nobody could reach a
 * game that was running the whole time, because a row said otherwise.
 *
 * ── WHAT THIS SEEDER WILL AND WILL NOT CLAIM ────────────────────────────────
 *
 * `POST /v1/titles` is an UPSERT ON SLUG (`worlds/src/titles.ts`: `on conflict
 * (slug) do update set name, status, service_url, capabilities, asset_scopes`).
 * There is no PATCH, so this is both the create and the correct — running it
 * twice is the same estate, and running it after somebody has edited a row by
 * hand puts the row back to what this file says. That is the point: the file is
 * the register's source, and a drift is a diff here rather than a mystery.
 *
 * **A capability declared here is a promise the title service has to keep.** The
 * provisioning bridge reads them to decide whether a purchase can be delivered
 * (`worlds/src/provisioning.ts`), and it only reaches the title's own
 * `POST /v1/provision` for `private_world` and `seasons`. So:
 *
 *   - `private_world` is declared ONLY for aetherholm, which is the only service
 *     in this estate that implements the title contract — `/livez`,
 *     `GET /v1/title`, `POST /v1/provision`. Grepping micro-emberkin and
 *     micro-nda for those routes returns nothing, and declaring the capability
 *     for them would turn "cannot be bought" into "bought, accepted, never
 *     delivered", which is strictly worse for the person paying.
 *   - `achievements` is declared for all three, and it is the one capability
 *     that costs nothing to be wrong about: it is not read by the bridge at all
 *     (`provisioning.ts` checks only `private_world` and `seasons`), and it is
 *     the truthful description of what the platform holds for these games —
 *     `PUT /v1/titles/:id/achievements` is open to any principal holding
 *     `worlds:title`, which all three have.
 *
 * `seasons`, `cosmetics` and `inventory` are declared by NOBODY here, and each
 * absence is a fact rather than an oversight. `seasons` reaches the bridge and
 * no title implements it. `cosmetics` and `inventory` are delivered LOCALLY by
 * `grantLocally()` with no capability check at all, so declaring them would
 * change nothing about what works and would add three claims this estate cannot
 * demonstrate.
 *
 * ── STATUSES, AND WHY EMBERKIN IS `beta` AND NOT `live` ─────────────────────
 *
 * `beta` and `live` are equal in the service today — both are open to play and
 * both are sellable (`worlds/src/titles.ts`) — so the choice between them is
 * about what a reader is told, and the estate should not tell somebody a game is
 * finished when it has never had a player. Aetherholm keeps `live` because that
 * is what it was already registered as and it is the one game whose title
 * contract is complete. Emberkin and *Ninety Days After* are `beta`: open,
 * honest about being new.
 *
 * ── serviceUrl IS AN IN-CLUSTER ADDRESS AND NEVER A PUBLIC ONE ──────────────
 *
 * It is the address the provisioning bridge POSTs to, on the compose network,
 * with a service credential. `GET /v1/titles` does not put it on the wire and no
 * browser ever sees it. The three values below were read out of
 * `compose/docker-compose.estate.yml` — every one of these services listens on
 * 4000 inside its container.
 *
 * ── THE TESTNET COPY IS A DIFFERENT REGISTER, AND THAT IS HANDLED ───────────
 *
 * `lib.mjs` resolves `API_HOST` per environment, so a testnet run addresses
 * `api-testnet.cloudsforge.online` and writes testnet's register. The in-cluster
 * service names are the same in both compose projects, so the `serviceUrl`
 * values need no environment switch — `http://emberkin:4000` means the testnet
 * project's emberkin when resolved from inside the testnet project.
 * ══════════════════════════════════════════════════════════════════════════════
 */

import { api, ok, bad, note, head } from './lib.mjs'

/**
 * The register, as it should be. One entry per game the estate runs.
 *
 * `slug` is the key — it is what the upsert conflicts on, what every entitlement
 * is scoped by, and what `worlds-web`'s catalogue joins its cover and its one
 * line of copy on. Changing one would orphan both, so they do not change.
 */
const TITLES = [
  {
    slug: 'emberkin',
    name: 'Emberkin',
    // Was `draft` on the live register, which is why nothing could reach a game
    // that has been serving at its own host since it was built.
    status: 'beta',
    serviceUrl: 'http://emberkin:4000',
    capabilities: ['achievements'],
    assetScopes: ['urn:cf:emberkin'],
  },
  {
    slug: 'aetherholm',
    name: 'Aetherholm',
    status: 'live',
    serviceUrl: 'http://emberkin:4000',
    // The only truthful `private_world` in the estate: aetherholm is the only
    // service implementing `POST /v1/provision`.
    capabilities: ['private_world', 'achievements'],
    assetScopes: ['urn:cf:aetherholm'],
  },
  {
    slug: 'ninety-days-after',
    name: 'Ninety Days After',
    status: 'beta',
    serviceUrl: 'http://nda:4000',
    capabilities: ['achievements'],
    assetScopes: ['urn:cf:nda'],
  },
]

/** Whether a live row already says exactly what the register above says. */
function matches(row, want) {
  const same = (a, b) => [...a].sort().join(',') === [...b].sort().join(',')
  return (
    row.name === want.name &&
    row.status === want.status &&
    same(row.capabilities ?? [], want.capabilities) &&
    same(row.assetScopes ?? [], want.assetScopes)
  )
}

export async function seedWorlds(token) {
  head('worlds — the title register, one row per game the estate runs')

  /*
   * READ FIRST, AND `includeRetired` IS ON.
   *
   * Not to decide whether to write — the upsert is idempotent and this seeder
   * writes every row unconditionally, so a hand-edit is corrected rather than
   * preserved. It is to say WHAT CHANGED, which is the whole value of running a
   * seeder against an estate somebody has been editing: "already correct" and
   * "was draft, now beta" are different lines and an operator needs the second
   * one. A retired row that is about to be revived is invisible without the
   * flag, and would be reported as a create.
   */
  const before = await api('worlds', '/v1/titles?includeRetired=true', { token })
  if (before.status !== 200) {
    bad(`read the register → ${before.status}: ${JSON.stringify(before.body).slice(0, 160)}`)
    return
  }
  const existing = new Map((before.body.titles ?? []).map((row) => [row.slug, row]))

  for (const want of TITLES) {
    const row = existing.get(want.slug) ?? null
    if (row && matches(row, want)) {
      ok(`${want.slug} — already ${want.status}, ${want.capabilities.join('+')} — not rewritten`)
      continue
    }

    const res = await api('worlds', '/v1/titles', {
      method: 'POST',
      token,
      body: want,
    })
    if (res.status !== 201 && res.status !== 200) {
      bad(`${want.slug} → ${res.status}: ${JSON.stringify(res.body).slice(0, 200)}`)
      continue
    }
    if (row === null) {
      ok(`${want.slug} registered — ${want.status}, ${want.capabilities.join('+') || 'no capabilities'}`)
    } else {
      // The DIFF, in the operator's terms. A row that silently changed status is
      // how the estate ended up with an unreachable game in the first place.
      const changes = []
      if (row.status !== want.status) changes.push(`status ${row.status} → ${want.status}`)
      if (row.name !== want.name) changes.push(`name "${row.name}" → "${want.name}"`)
      const was = (row.capabilities ?? []).join('+') || 'none'
      const now = want.capabilities.join('+') || 'none'
      if (was !== now) changes.push(`capabilities ${was} → ${now}`)
      const wasScopes = (row.assetScopes ?? []).join('+') || 'none'
      const nowScopes = want.assetScopes.join('+') || 'none'
      if (wasScopes !== nowScopes) changes.push(`assetScopes ${wasScopes} → ${nowScopes}`)
      ok(`${want.slug} corrected — ${changes.join(', ')}`)
    }
  }

  note(
    'a capability here is a promise the title service keeps: only aetherholm implements ' +
      'POST /v1/provision, so only aetherholm declares private_world.',
  )
}
