# Service-merge plan — un-splitting the over-split estate

Status: **proposal, 2026-08-26.** Nothing in this document has been executed,
and no merge starts without an explicit go decision per wave.

## Why

The estate runs 31 backend services plus ~20 static web bundles as separate
Deployments — 54 application pods for a product with no real users yet
([estate-has-no-real-users]). Measured across the repos (survey 2026-08-26):
every backend is the same stack (TypeScript strict ESM, Node ≥22, plain
`node:http`, the `postgres` driver, built from `service-template`, sharing the
seven `@cloudsforge/*` runtime packages), ~295k LOC of non-test source total.
The separation buys isolation in a handful of places and pays overhead
everywhere: per-pod memory and connection pools, a migrate Job per service per
deploy, a repo/CI/release pipeline per service, and hand-rolled duplication —
`ledgerclient.ts` exists in 11 services, `keccak.ts` is byte-identical in 4
and near-identical in 2 more, and mint/foresight/settlement/indexer each carry
their own `evm.ts`/`chains.ts`.

Some separations are load-bearing. The plan below merges only where they are
not.

## Hard exclusions — never merged into anything

- **custody** — HD seeds and encrypted keys on the filesystem (0700/0600 under
  `CUSTODY_DATA_DIR`, never in the DB), eight chain-crypto libraries,
  documented in its own source as permanently single-host. Anything merged in
  inherits full key-compromise blast radius from an RCE.
- **settlement** — builds, signs and broadcasts fund-moving transactions on
  seven chains. Merging widens the set of code paths that can reach a
  broadcast.
- **ledger** — the financial source of truth, called by 11 services. Small
  (8k LOC), stays alone for blast radius, not size.
- **identity** — root of trust; its JWKS is referenced by effectively every
  service. Same reasoning.
- **pool** — owns a second listener (raw TCP Stratum v1) and a mining workload
  profile nothing else shares.
- **beacon** — ships headless Chromium and holds real journey-account
  credentials; its resource profile is nothing like an API service.
- **trade** — the CLOB matching engine is latency-sensitive; it should not
  share a process with anyone's batch sweeps.
- **hub-api** — the read-aggregation BFF over 8 upstreams with per-peer
  circuit breakers; folding it into any upstream makes that upstream a
  dependency of the whole dashboard. Already stateless and DB-less.
- **indexer** — the chain follower (raw Bitcoin P2P wire code, compact-filter
  client); restart cost and scaling profile are its own.

## Wave W — one static server for the web bundles (largest pod win)

The ~20 `*-web` Deployments are nginx containers each serving one Vite build.
One web-server Deployment serving every bundle (each build mounted at its
routed path, one nginx config generated from the same registry the gateway
routes from) replaces ~20 pods with ~2 replicas of one. This aligns with the
apex-subfolder consolidation already in flight (`apex-consolidation.md`); the
per-bundle images become build stages of one composite image in the release
pipeline. Router side nothing changes: upstream Services become CNAMEs to the
merged Service, exactly the mechanism the network consolidation proved.
Hazard to carry: [vite-base-never-rewrites-string-literals] — bundle asset
paths must be re-proven per bundle with the accessor test, not grep.

## Wave M0 — extract shared packages (enabler, no process change)

- `@cloudsforge/clients`: typed clients for ledger, indexer, pricing, custody,
  policy, billing, worlds. Replaces 30+ hand-rolled per-service client files.
- `@cloudsforge/evm`: `keccak.ts`, `evm.ts`, `chains.ts` from
  mint/foresight/settlement/faucet (+ wallet/beacon variants where they
  converge).

No deployment changes at all, big review-surface shrink, and a prerequisite
for every later wave (a merged process should not carry two hand-rolled
copies of the same client). Contracts note: publishing shapes moves into the
frozen-tuple regime — [contracts-compat-tuple-append-only] applies.

## Wave M1 — `lantern` + `analytics` → one telemetry service

Same shape on both sides: signed/OTLP ingest → rollup job → retention prune →
read API; no outbound calls, no outbox; 4.3k + 5.1k LOC, 4 + 8 tables.
**Both databases are kept** — the merged process reads both `*_DATABASE_URL`s
and the pseudonymisation pepper (`ANALYTICS_PSEUDONYM_KEY`, k-anonymity floor)
stays scoped to the analytics routes, so the privacy boundary survives as a
module boundary instead of a process boundary. Lowest risk: no service calls
either of them on a hot path.

## Wave M2 — `activity` + `notify` → one bus-tail service

Both are pure consumers with an inbox and no outbox; their consumed-topic sets
are near-identical (~84 vs ~86 topics). One process consumes the bus once and
fans to two sinks (record, deliver). Both already serve both networks
post-consolidation, so the compose-era single/dual mismatch is gone. Two
conditions make it safe: the SMTP delivery worker keeps its own job lease so a
wedged mail host cannot stall the activity record, and the mail-quota
protections stay exactly as they are ([estate-mail-quota] — beacon's synthetic
registrations already spend the whole Mailtrap allowance).

## Wave M3 — `emberkin` + `aetherholm` → one titles service

Two game backends, 6.9k + 7.6k LOC, template CRUD plus a deterministic engine
each; aetherholm calls nothing at all, emberkin only billing/worlds/identity.
Both databases kept; tick jobs already serialize through leased jobs, so the
different cadences coexist. `nda` can join later as a third module once the
pattern is proven; **`worlds` stays out** — it is the registry and entitlement
bridge the titles depend on, and folding a title into it inverts the
dependency.

## Deferred, with reasons — not in this plan's scope

- `market` + `billing`: a real candidate, but `billing.entitlement.*` is the
  widest-consumed event in the estate (9 consumers); touch the entitlement
  authority only after M1–M3 prove the pattern.
- `agora` + `community`: agora is under active build-out as the social product
  and community writes treasury spends to ledger; merging a fast-moving
  surface into a money-path service is the wrong direction today.
- `faucet` → anything: a public unauthenticated giveaway endpoint stays out of
  services that deploy paid mainnet tokens. Its estate placement is handled in
  `consolidation-endgame.md`.
- `mint` + `foresight`: duplicated code, different products — the duplication
  is solved by M0's `@cloudsforge/evm`, not by a process merge.

## Merge mechanics (the template every M-wave follows)

1. The larger repo absorbs the smaller as a workspace package; the smaller
   repo is archived after cutover. One image, one `server.ts` mounting both
   route sets on one port, both env prefixes read unchanged.
2. Both migrators run sequentially in the one migrate Job; both databases
   remain, named by their existing `*_DATABASE_URL` variables — no schema
   merge, no network-column work (that is done).
3. The retired service's ClusterIP Service becomes a CNAME to the merged
   Service (the proven consolidation mechanism), so no caller changes on
   cutover day; callers migrate to the merged name at leisure.
4. Jobs and topic subscriptions are unioned; inbox tables stay per-database.
5. Rollback is the old image plus flipping the CNAME back — both stay
   deployable until the wave is declared done.
6. One wave at a time, and never while `cfctl bump` is pending —
   [release-bump-blocks-on-any-dirty-checkout] applies to every repo an agent
   touches.

## Net effect if W + M0–M3 all execute

Application pods: 54 → ~32 (web bundles ~20→2, three process merges −3).
Backend repos actively deployed: 31 → 28, with two shared packages absorbing
the worst duplication. Isolation properties of the money core, key custody,
identity and the chain plane: unchanged by construction.
