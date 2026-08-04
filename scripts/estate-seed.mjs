#!/usr/bin/env node
/**
 * Give the estate's product surfaces something to show.
 *
 *   cd deploy
 *   ./scripts/estate-seed.mjs                 # everything
 *   ./scripts/estate-seed.mjs --only foresight
 *   ./scripts/estate-seed.mjs --counts        # just the row counts, change nothing
 *
 * `scripts/estate-bootstrap.sh` calls this as its last step. It is a separate
 * file rather than another section of that script because it will grow: every
 * service the estate gains that has a surface will want a few honest rows here,
 * and bootstrap is already nine hundred lines of credential machinery that
 * nobody should have to scroll past to find a seeded market.
 *
 * ── THE THREE PROPERTIES THIS HAS TO HAVE ────────────────────────────────────
 *
 * **1. Idempotent.** Bootstrap is re-run several times an hour. A second run
 * must not double the content, and the proof is not this sentence — it is the
 * counts printed before, after one run and after two. Where a service offers an
 * idempotency key this uses it; where it does not, this lists and matches first.
 * Each domain file names its own discriminator and why that one.
 *
 * **2. Through the real APIs.** There is not one INSERT in this tree. A row
 * conjured into Postgres proves nothing and skips every invariant the service
 * exists to enforce — the ledger's balancing trigger, the outbox, the policy
 * call, the escrow that makes a listing real. Going through the front door also
 * means the seeding itself exercises the estate, which is how three of the
 * findings in this file's own reporting were discovered. The single exception is
 * `select count(*)`, which only reads, and only so that the idempotency claim
 * above can be checked rather than asserted.
 *
 * **3. Labelled as the platform's.** `docs/ecosystem/21-engagement-treasury.md`
 * §2 refuses synthetic demand in terms: "synthetic bids, ghost bettors,
 * invisible house positions… It is the one form of this that costs nothing and
 * it is fraud." So: no user is registered by this seeder, no bid is placed, no
 * bet is staked, and no vote is cast by an invented member. Everything created
 * here is created by the estate's own named operator account and is visible on
 * the surface as the platform's. Where a surface would only look alive with a
 * crowd, it is left looking honestly quiet and the reason is printed.
 *
 * ── WHAT A FAILURE HERE MEANS ────────────────────────────────────────────────
 *
 * Seeding is additive and must never be able to break a bootstrap. A service
 * that refuses is reported and the run continues to the next domain; the exit
 * code is non-zero only if something genuinely went wrong, and never merely
 * because a surface could not be filled. `skip` lines are deliberate omissions
 * with reasons attached and are not failures — the difference matters, because a
 * run that cried failure over an empty engagement treasury would train an
 * operator to stop reading.
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..')
const CA = process.env.CF_ESTATE_CA || path.join(ROOT, 'gateway/certs/ca.crt')

/* ── the CA, before anything can make a request ────────────────────────────────
 *
 * Node reads NODE_EXTRA_CA_CERTS once, at startup, and there is no API to add a
 * root afterwards. Re-execing is the only way to have it apply. If the CA is
 * missing this FAILS rather than falling back to an unverified request — 183
 * uses of `curl -k` hid a certificate every browser refused, and that was the
 * estate's worst defect of the night.
 */
if (!fs.existsSync(CA)) {
  console.error(`FAIL: no estate CA at ${CA} — run ./scripts/gateway-cert.sh first.`)
  console.error('      This seeder will not fall back to an unverified request.')
  process.exit(1)
}
if (process.env.NODE_EXTRA_CA_CERTS !== CA) {
  const { spawnSync } = await import('node:child_process')
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), ...process.argv.slice(2)], {
    stdio: 'inherit',
    env: { ...process.env, NODE_EXTRA_CA_CERTS: CA },
  })
  process.exit(r.status ?? 1)
}

const { login, counts, printCounts, tally, head, bad, note } = await import('./seed/lib.mjs')

const args = process.argv.slice(2)
const only = args.includes('--only') ? args[args.indexOf('--only') + 1] : null
const countsOnly = args.includes('--counts')

/**
 * The domains, in the order a reader would want them.
 *
 * Each is loaded lazily so that `--only foresight` does not pay for, or fail on,
 * a module it is not going to run.
 */
const DOMAINS = [
  { name: 'foresight', load: () => import('./seed/foresight.mjs').then((m) => m.seedForesight) },
  { name: 'community', load: () => import('./seed/community.mjs').then((m) => m.seedCommunity) },
  { name: 'mint', load: () => import('./seed/mint.mjs').then((m) => m.seedMint) },
  { name: 'nda', load: () => import('./seed/nda.mjs').then((m) => m.seedNda) },
  { name: 'billing', load: () => import('./seed/billing.mjs').then((m) => m.seedBilling) },
]

async function main() {
  if (countsOnly) {
    printCounts('row counts', counts())
    return 0
  }

  console.log('seeding the estate — everything below goes through the real APIs\n')
  const before = counts()
  printCounts('BEFORE', before)

  let token
  try {
    token = await login()
  } catch (err) {
    console.error(`\nFAIL: could not sign in as the operator — ${err.message}`)
    console.error('      run ./scripts/estate-bootstrap.sh first; it creates and promotes the account.')
    return 1
  }

  for (const domain of DOMAINS) {
    if (only && only !== domain.name) continue
    try {
      const seed = await domain.load()
      await seed(token)
    } catch (err) {
      // One domain refusing must not cost the others. The surface it would have
      // filled stays empty, which is visible, and the reason is printed here.
      head(`${domain.name} — did not complete`)
      bad(`${domain.name}: ${err.message}`)
      if (process.env.CF_SEED_TRACE) console.error(err)
    }
  }

  const after = counts()
  printCounts('AFTER', after)

  console.log(
    `\n  ${tally.ok} ok, ${tally.skipped} deliberately skipped, ${tally.bad} failed.`,
  )
  if (tally.skipped > 0) {
    note('a "skip" is something this seeder chose not to do, with the reason above it.')
  }
  return tally.bad === 0 ? 0 : 1
}

process.exit(await main())
