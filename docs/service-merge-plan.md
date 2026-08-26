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

### `@cloudsforge/evm` — DONE 2026-08-26

Shipped as micro-runtime#8, consumed by all five services (faucet, mint,
foresight, settlement, wallet). No deployment change; every service's suite
green.

It carries `keccak256`, `keccak256Hex`, `sha3_256` and `toChecksumAddress`, and
nothing else. `evm.ts`, `chains.ts` and the contract bytecode deliberately stay
in the services that deploy and broadcast, because those differ per product in
ways that matter — gas floors, kill switches, mainnet allowlists. What moved is
only the part where differing at all is the defect.

The removal tool refused unless each service's `toChecksumAddress` body hashed
to the shared value first. That guard was the point: a service whose copy had
quietly diverged is the one case where the rewrite would be wrong, and it is
exactly what a regex would paper over. None refused.

### `@cloudsforge/clients` — NOT the same kind of job, and not yet scoped

The plan filed this beside the evm extraction as though they were the same
move. They are not, and the difference is the whole risk.

`keccak.ts` was **five byte-identical copies**: extracting it was a deletion.
`ledgerclient.ts` exists in eleven services at **187 to 871 lines each, all
different** — they are independent hand-rolled ports of one API, not copies of
one file. There is no shared implementation to lift out; there is a client to
*design*, and then eleven call sites to migrate onto it. That is a rewrite of
the path every service uses to move money, and it must not be smuggled in under
the heading that carried a mechanical deletion.

So this half needs its own investigation first, answering: which of the eleven
behaviours (retry, idempotency-key handling, circuit breaking, error mapping)
are genuinely common, which are deliberate per-service choices, and which are
accidents that would become bugs if unified. Until that exists, treat
`@cloudsforge/clients` as unscoped rather than pending.

Contracts note when it is scoped: publishing shapes moves into the frozen-tuple
regime — [contracts-compat-tuple-append-only] applies.

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

## What the design pass found, 2026-08-26 — four of this plan's claims are wrong

W and M1 were both designed in detail before any code moved. The investigations
corrected the plan rather than confirming it, which is the point of doing them
first. Read this section before starting either wave.

### M0 is further along than "no deployment changes" suggests

`@cloudsforge/evm` exists and `faucet` and `mint` consume it. The measurement
that justified it: `keccak.ts` existed five times (four byte-identical, wallet's
differing only in its comment header — strip comments and all five hash to
`0772cd9f`), and `toChecksumAddress` six times, five of those **function bodies**
byte-identical (`dd24e0e2`) inside three differently-named files. The files all
differ; only the function is the same, which is why it was easy to miss.

One claim made in that PR was wrong and is corrected on it: four of the five
services **do** pin the permutation against OpenSSL and the published vector.
Only `foresight` had no direct coverage. The real argument is not "the tests
were missing" but that **the same test was written four times**, and the one
service that skipped it was invisible because nothing compared them.

### M1: three statements in this plan cannot be executed as written

1. **"absorbs the smaller as a workspace package" is forbidden by CI.**
   `org/.github/workflows/service-ci.yml` pins an allow-list of importable
   `@cloudsforge/*` names, and it contains runtime packages only. Adding a
   SERVICE to it defeats the rule it enforces. The absorbed module must be
   plain directories under `src/`, imported by relative path.
2. **"The larger repo absorbs the smaller" points the wrong way here.**
   analytics is larger (5.1k vs 4.3k LOC), but **lantern must absorb**: it holds
   the public hostname, the gateway router and the OTLP endpoint every service
   pushes to. Absorb by blast radius, not by line count.
3. **The CI workflow is single-database by construction**, and this is the
   dangerous one. `database-env-var` is one name; the DSN export, Rule 1's
   `allow-match` and the skip-scan all derive from it. Merge into it as-is and
   the build is either red for a correct repo or — far worse — **green with all
   ten analytics database suites silently skipped**, because the skip-scan
   classifies a foreign variable name as "a cross-service tier stood down" and
   emits a notice. That is exactly the false green that block was written to
   end. **`org` must be fixed first**, and the skip of an own-prefix variable
   made fatal.

Two more findings that are not in this plan at all:

- **`PathPrefix('/ingest')` in the lantern router would publish analytics'
  event-bus ingest to the internet** the moment the merged process sits behind
  it. The MAC still gates it, so this is exposure rather than bypass — but the
  rule must narrow to `/ingest/client` in the same change, and that router's own
  comment claims its prefixes were read off `lantern/src/server.ts` route by
  route, which merging silently invalidates.
- **The job metrics collide.** Both services register `kind="rollup"` and
  `kind="retention"`, so `jobs_failed_total{kind="rollup"}` would sum two
  unrelated jobs; and both `sampleQueue`s write the **unlabelled** `jobs_pending`
  / `jobs_overdue`, so one queue's depth is erased every scrape. A `module`
  label in `@cloudsforge/telemetry` is the cheap fix and must land before the
  merge.

A live defect was found on the way and fixed separately: analytics'
`POST /ingest` wrote every delivery through the boot-time primary handle
instead of `ctx.sql`, so a testnet-stamped delivery landed in the mainnet
database. It had never fired — both `events` tables were empty — so it was a
one-line fix rather than a data repair.

### W: the hazard this plan warns about does not apply

**The base-path hazard is not in scope for wave W, and the wave should say so
plainly** so it is not re-litigated. Fourteen of the twenty-one bundles already
build for and serve from their apex subfolder: the prefix is in `vite.config.ts`,
in `src/lib/routes.ts`'s `BASE`, in every nginx `location`, **and in the
container filesystem** (`COPY --from=build /app/dist …/html/market`). Merging is
a union of document roots that are already disjoint, so no bundle's base path
changes. Both live checks confirm it today: `check-mounted-assets-compose.py`
and `check-base-paths-agree.py` pass on all fourteen.

It **would** apply if anyone proposed moving the seven root-served bundles into
subfolders to fit one `server` block. Use `server_name` instead.

Three corrections to how W should be built:

- **Do not build a composite from N build stages.** Twenty-one `pnpm install` +
  `vite build` runs in one context is a monorepo build in a repo that
  deliberately is not one. Assemble instead from the **already-published
  per-bundle images by digest**, with the Dockerfile generated from the release
  manifest. Per-bundle CI, `cfctl release` and rollback all stay untouched.
- **Pilot with `journal-web` + `exchange-web` + `agora-web`.** They are the only
  bundles with no backend of their own, and journal brings the two hardest nginx
  features in the estate (`sub_filter`, a real prerendered file tree). Three
  routers to re-point; the blast radius is an archive and two product pages.
- **`status-web` is never merged.** A status page that shares an origin with
  what it reports on cannot report the interesting outage, and sharing a
  *process* is strictly worse. Leave `hub-web` and `admin-web` alone too.

The deliverable of W is not the image; it is a **config matrix test**: for each
mount, assert four answers (root → 200 and that bundle's release tag, a deep
route → 200 shell, an unknown path → **404** with that bundle's shell, an asset
→ `immutable`). Every way fifteen nginx route tables can merge wrongly produces
a **200 with the wrong content**, which no health probe sees.

## What the pods actually cost — measured 2026-08-26, and it changes the plan

Wave W is done: twenty web Deployments became one, and the estate went from 72
running pods to 54. That was the whole of the over-engineering. The remaining
backend pods were then measured rather than assumed:

```
31 backend pods, 2410 Mi total, 77 Mi mean
cloudsforge-estate: 37 pods, 129 mCPU total
node cf-k8s: 341 mCPU (2%), 8520 Mi (56%)
```

**129 milli-cores. An eighth of one core, for the whole estate.** The mean
backend holds 77 MiB, which is a Node baseline heap rather than a workload —
most of these services are idle most of the time, because there are no users
yet ([estate-has-no-real-users]).

So the arithmetic for the remaining waves is:

| wave | pods saved | memory freed |
|---|--:|--:|
| M1 lantern + analytics | 1 | ~50 MiB |
| M2 activity + notify | 1 | ~50 MiB |
| M3 emberkin + aetherholm | 1 | ~50 MiB |
| deferred: agora+community, market+billing | 2 | ~100 MiB |

Merging two Node services saves **one baseline heap**, not two pods' worth of
memory — the merged process still carries both workloads. Five merges would
free roughly 250 MiB out of 8.5 GiB in use, and remove five pods from a node
running at 2% CPU.

### The recommendation this leads to

**Stop merging backend processes.** Not because it is hard, but because the
measurement says the split is not what it was accused of being. Twenty nginx
pods serving static files from twenty document roots was a process boundary
bought for nothing, and deleting it was worth a day. Thirty-one services with
thirty-one databases, thirty-one domains and thirty-one release cadences is an
architecture — a large one for a product with no users, but each boundary is
carrying something: its own schema, its own migrator, its own deploy blast
radius.

Trading that for 250 MiB would be the same mistake as the twenty nginx pods,
pointed the other way: doing work because the shape looks wrong rather than
because a measurement says it is.

**M1a is kept and was worth doing on its own merits.** The seam removed several
hundred lines of duplicated HTTP plumbing from each of lantern and analytics —
`compile`, `send`, `errorReply`, the request-id logic, the network resolution
and the metric block were the same code twice — and closing each handler over
its own deps is what would make any future merge safe rather than merely
possible. It also caught a live defect: `analytics/src/routeidempotency.test.ts`
derives its route list by reading the source, and moving the table made it find
**zero routes**, at which point three of its seven cases passed vacuously.

If the backends are ever merged, M1b onward is fully designed below and the CI
prerequisite is already shipped. The reason to do it then would be operational
— fewer things to release, fewer runbooks — and not this table.

## Two questions the pod list invites, answered

### "Why are there two frontend pods — didn't we merge mainnet and testnet?"

There is **one** frontend Deployment. `web` runs `replicas: 2`, and both pods
serve byte-identical content from the same ConfigMap and the same twenty
digest-pinned bundle images. It is not mainnet and testnet.

The testnet frontends were retired in wave 1 of the network consolidation and
`testnet.<apex>` 302-redirects into the apex combined view; there has been one
set of frontends since. The second replica exists because **one pod now carries
every public surface**: a node eviction, an OOM or a bad rollout would
otherwise take down the site, the account, every product page and the docs at
once. Twenty separate Deployments were accidentally providing that resilience,
and dropping to a single replica would quietly spend it.

If the estate ever wants the absolute floor, `replicas: 1` is a one-line change
in `scripts/k8s-render-web.py` — it buys one pod and costs the only redundancy
the public surfaces have.

### "And the two gateways?"

Those **are** mainnet and testnet, and they stay. This is a considered no, not
an oversight, and the cost is one pod.

`CF-Network` is stamped by a middleware on the **entrypoint**, before any router
is consulted, from that pod's `CF_EMBER_NETWORK`. So which estate's data a
request reaches is a property of **which pod received it** — a topology fact
that cannot be mismatched, and one a client cannot forge, because
`customRequestHeaders` overwrites rather than appends.

Merging into one Traefik would mean:

* **Every router rendered twice.** The two gateways are one template rendered
  with different `CF_WEB_SUFFIX` values — `agora.<apex>` and
  `agora-testnet.<apex>` are the same router definition. One gateway needs both
  hostname sets present simultaneously, so every one of ~115 router names has to
  be split and renamed per network.
* **The stamp moves from the entrypoint to each router.** That is the thing
  `policy.yml` argues against in its own comment: forty-odd places to remember,
  and the guarantee becomes a list that has to be kept right rather than a
  structure that cannot be got wrong. It fails closed — `requestNetwork()`
  refuses a request with no header — so a forgotten middleware is a 500 rather
  than a leak. But a 500 on a live surface is still an outage, and the current
  design makes it unreachable.

That is a restructure of the estate's most sensitive routing surface to save
one pod. The testnet gateway is also load-bearing rather than vestigial: the
combined view works by the mainnet frontend calling `api-testnet.<apex>`, which
is precisely what that pod exists to stamp.

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
