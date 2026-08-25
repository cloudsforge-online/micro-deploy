# Network consolidation — one set of pods for both networks

Written 2026-08-21, after the frontend combined view (micro-org#459) proved the
pattern this generalises.

## Status — 28 of 30 across; custody and settlement are blocked on a keyring

The cutover is done except for two services, and the two are blocked on the same
thing.

**Across and verified (28).** agora, community, analytics, policy, pricing,
devplatform, activity, studio, lantern, emberkin, worlds, nda, tessera, market,
mint, billing, hub-api, admin-api, aetherholm, foresight, trade, ledger, wallet,
identity, notify, beacon, indexer — each one pod, both estates, answering
`CF-Network: testnet` and `mainnet`. Twenty-two carry two database handles and
their migrators run against both; six keep one database with a `network` column
(§5.3, §5.4, §5.5).

**Blocked (2).** custody, and settlement behind it. The two custody databases
derive at different keyring versions — mainnet v4, testnet v2 — so the merged
pod would be handed 31 addresses it cannot sign for, and the per-user
`next_index` counters cannot be reconciled without knowing whether they advanced
over the same key material. micro-org#508. settlement's treasuries and sweep
sources name custody addresses, so it waits on the same answer.

**Paired on purpose (6).** The testnet gateway, `site` (the one web bundle
behind a live testnet router, kept by wave 1), `faucet` (a faucet has no mainnet
meaning), `hearth-explorer-api` and `hearth-verify` (chain-adjacent, and the
chains stay paired by definition), and `backup-runner`.

`cf-testnet` went from 51 Deployments to 4 running. It cannot be deleted while
custody's 31 v2 keys live in its database — which is also why nothing was
merged: the source is untouched and the deployment is scaled to zero, not
removed.

| item | state |
|---|---|
| `runtime` http / auth / db / telemetry (§4) | **merged** (micro-runtime#7). Not live: services still run images built before it, and nothing consumes it until wave 2. |
| gateway stamps `CF-Network` (§2.1) | **live on both networks** (micro-deploy#209). Middleware loaded, entrypoint args on the pod, Traefik clean. End-to-end proof waits for the first service that reads it. |
| `sslmode=require` on all 60 DSNs (§2.2.1) | **live on both networks** (micro-deploy#210). Verified before the change (`show ssl` = on, TCP probe from the ledger pod) and after: `ssl=true, TLSv1.3` on both. 53 mainnet + 55 testnet deployments available, 15/15 apex surfaces serving. |
| backend-agnostic DB bootstrap job (§2.2.1) | **merged, and run on both networks** (micro-deploy#212). Emits zero `CREATE DATABASE` — all thirty already exist — reasserts ownership, leaves 31 databases each. `cloudsforge` granted `CREATEDB`, which it lacked. |
| Prometheus/alert reshape to per-series `network` | **live** (micro-deploy#225). Twelve `by ()` clauses in `slo.yaml` gained `network`; three consuming alerts name the estate in their summary; both dashboards gained a `$network` selector defaulting to `mainnet`. The precondition was measured before the change rather than assumed — 116 mainnet and 20 testnet `http_requests_total` series live. Alert SEVERITY deliberately unchanged; see §9. |
| **wave 1** — retire the duplicate testnet bundles | **live** (micro-deploy#213). Testnet 51 → 31 rendered deployments; running pods 56 → 36. The twenty were measured unrouted (live router set read from the gateway's own metrics, not the configmap), unprobed by beacon, and serving zero requests. `site` kept — it is the one web bundle behind a live testnet router. They sit at zero replicas rather than deleted, which is the rollback. |
| **wave 2** — the six low-risk class B services | **merged** — agora, policy, analytics, pricing, community, devplatform. All behaviour-preserving: with one DSN configured `networkSql` holds one network and each is today's service. **Live on both networks at 2026.8.99.** |
| **wave 4** — the two class B′ singletons | **merged** — identity, notify. Both keep ONE database, as the class says. identity's `net`-claim fallback moves from `IDENTITY_NETWORK` to the request (§5.5); notify gains `deliveries.network` and keeps one pipeline and one SMTP allowance. |
| **wave 6** — the money core | **merged; live at 2026.8.99** — ledger, wallet. Both moved last, as the plan requires, and only after every caller already forwarded the header. wallet is the one with no bare `sql` at all: four domain bundles, and rebuilding some but not others is worse than rebuilding none (§5.6). |
| **wave 5** — the five class C workers | **merged** — beacon, indexer, custody, settlement, pool. Two surprises, both recorded: beacon is really class B′ (§5.3) and **indexer needed no code change at all** (§5.4). settlement is the real bulkhead — one queue and one runner per estate, because its jobs broadcast transactions. |
| **wave 3** — the fifteen product class B services | **merged** — activity, studio, lantern, emberkin, worlds, nda, tessera, market, mint, billing, hub-api, admin-api, aetherholm, foresight, trade. Same shape and the same behaviour-preserving property. **Live on both networks at 2026.8.99.** Four of them needed more than the recipe, and §5.2 records what and why; three more crash-looped on a second literal `mainnet` and §5.9 records that. |

Everything shipped so far is behaviour-preserving: every runtime parameter is
optional with a default that reproduces today, and the header is ignored by
services that have not been taught it.

The estate today runs twice: `cloudsforge-estate` (mainnet) and `cf-testnet`
are two namespaces with the same 51 Deployments, the same 30 databases in two
CloudNativePG clusters, two Traefik gateways and two cloudflared ingress
routes. Every service is a single-network process — the network is baked in at
boot through env, and nothing about a running pod can serve the other network.

This plan merges everything except the blockchains themselves into **one set
of pods that serves both networks**. The chains stay paired: the Hearth EMBER
nodes (mainnet and testnet), the UTXO daemons on the chain host, the miners
and the seeders are the networks — consolidating them would be a contradiction
in terms. Everything above them is infrastructure, and infrastructure that
exists twice to serve two names is the same waste the apex consolidation
removed one layer up.

---

## 1. What already points this way

Three prior decisions make this a completion rather than a new direction, and
the plan leans on each:

1. **The combined view (micro-org#459).** One frontend bundle serves both
   networks; the reader switches networks *in place* and the bundle re-points
   its reads at `https://testnet.<apex>` per request. The ~20 `*-web` pods in
   `cf-testnet` are already byte-identical duplicates whose public hostnames
   301 away. The frontends are consolidated in every sense except the pod
   count.

2. **One login (micro-org#459 stage 2, #472, #137).** Identity is already
   effectively shared: testnet's own login was retired in favour of the shared
   identity, testnet services verify against the shared JWKS
   (`CF_IDENTITY_JWKS_URL` is a testnet-only override pointing across), and
   accounts are one set. The testnet identity pod is a vestige.

3. **The `net` claim (runtime/packages/auth).** Tokens already carry a `net`
   claim and receivers already gate on it — but the gate compares against
   `#expectedNetwork`, *the network this deployment IS*. That boot-time
   constant is the one assumption every section below exists to remove.

## 2. The three design decisions

### 2.1 The network is a property of the REQUEST, never the deployment

One signal, carried three ways, one per layer:

| layer | carrier | set by |
|---|---|---|
| edge | the **hostname** (`testnet.<apex>` vs the apex) | the caller, as today — no public URL changes |
| inside the cluster | the **`CF-Network` header** (`mainnet` \| `testnet`) | the gateway, from the matched router; forwarded verbatim by every service-to-service call, exactly as trace context is |
| authorization | the **`net` claim** on the bearer | identity, at mint — already shipped |

The gateway is the only component allowed to *create* the header from a
hostname; a service receiving a request with no `CF-Network` treats it as a
routing fault (500, loudly), never as a default. Defaulting to mainnet is the
one silent failure mode this design refuses to have: a missing header on a
testnet write silently landing in mainnet data is strictly worse than an
outage.

The auth gate inverts: instead of "does the token's `net` match what I am",
it becomes "does the token's `net` match the request's `CF-Network`". A
testnet bearer presented against a mainnet-routed request is refused with the
same `wrong_network` error the deployment-scoped gate throws today. Tokens
with **no** `net` claim are accepted for a migration window and logged, then
refused — a `net`-less token is exactly the artifact this boundary exists to
keep out.

### 2.2 Isolation by database name: `<db>` and `<db>_testnet`, one cluster

Decided 2026-08-21: **one CloudNativePG cluster**, holding today's 30 mainnet
databases under their current names plus testnet's 30 imported as
`<name>_testnet`. No shared tables, no `network` column, no row-level
anything — the isolation boundary is the database name, which is the coarsest
boundary postgres offers and therefore the hardest to cross by accident.

Each dual-network service holds **two pools** and picks one per request from
`CF-Network`. The pick happens in one place — a `runtime/db` helper — not at
call sites, for the same reason the apex consolidation composed mounts at
accessors: a boundary enforced at every call site is a boundary with as many
holes as call sites.

Services that are conceptually *shared* rather than *per-network* (identity
first among them — one account set is the point of #459) end with **one**
database; their `_testnet` import is residue to reconcile and drop, not a
second pool. §5's table records the disposition per service.

The `cf-testnet` namespace is deleted at the end. Both backup targets
collapse to one; the shared-role rotation runbook (one `cloudsforge` role, 57
DSNs) loses its second cluster.

### 2.2.1 One postgres, and WHERE it runs is a config seam

Decided 2026-08-21, same conversation: all ~60 databases live in **one
postgres server**, and the estate must be able to run that server in either
of two places without code changes:

- **in-cluster** — the CloudNativePG cluster, as today; or
- **managed** — an Azure Database for PostgreSQL **Flexible Server**
  outside the cluster.

The seam already exists and is the reason this costs little: every DSN in
the estate spells `@postgres:5432`, and `postgres` is an **ExternalName
Service** (`k8s/database/29-service-alias.yaml`) — a pure DNS pointer. An
ExternalName can name anything resolvable, including
`<server>.postgres.database.azure.com`. Swapping the backend is repointing
one Service, not editing 57 DSNs. The render grows one knob:

```
database_backend: cnpg | external
database_external_host: <fqdn>        # required when external
```

Three things must be true for the swap to be *actually* one knob rather than
a knob plus a day of surprises, and each becomes part of wave 0:

1. **TLS in the DSN, always.** Flexible Server requires TLS; CNPG tolerates
   it. Every DSN carries `sslmode=require` from wave 0 onward so the
   in-cluster configuration is not quietly incompatible with the managed
   one. (Flexible Server takes plain usernames — no `user@server` suffix —
   so the one `cloudsforge` role name survives unchanged.)
2. **Provisioning that doesn't assume CNPG.** The 60 databases exist today
   as CNPG `Database` CRDs; those mean nothing to Azure. Provisioning moves
   to a plain SQL bootstrap job (the `initdb.sql` lineage) that runs against
   *whatever* `postgres` resolves to and is idempotent — CNPG keeps its CRDs
   as a convenience, but the bootstrap job is the source of truth
   `check-k8s-databases-match-initdb.py` verifies against, for both
   backends.
3. **A backup story per backend, named in the runbook.** CNPG: the existing
   runner and `estate-backup-restore.md`. Azure: PITR is the platform's, but
   `backup_last_verified_unixtime` must still be fed by a restore *drill*
   against a scratch server — a managed backup nobody has restored from is
   the same unproven backup the estate already refused to trust once.

Migration between backends, either direction, is the same operation as the
testnet import in §6 step 2: logical dump/restore per database via
`k8s-db-import.sh`, then repoint the alias. Nothing in a service knows it
happened.

What this deliberately does **not** promise: latency parity. In-cluster
postgres is a loopback-class hop; Azure is a WAN hop from a Hyper-V VM in a
home network. The knob makes the move *easy*, not *free* — before flipping
it for real, measure a read-heavy service (indexer, hub-api) against the
managed server, and recompute connection headroom against the chosen SKU's
`max_connections` (the estate's ~57 DSNs × pool sizes is the number to check,
and it is a *different* number per SKU tier).

### 2.3 Workers get per-network contexts, not per-network pods

Chain-facing services (indexer, settlement, pool, beacon, custody's
chain-watching side) have no request to read a network from. Each boots from
`CF_NETWORKS=mainnet,testnet` and constructs one **worker context per
network**: its own DB pool, its own chain-RPC set (`chain.mainnet.env` and
`chain.testnet.env` both mounted), its own interval loops, its own circuit
breakers. The contexts are bulkheaded: EMBER testnet wedging at its
difficulty floor (a known recurring state) must stall the testnet context's
loops and nothing else. A shared process is acceptable; shared backpressure
is not.

Per-network metrics move from *per-target* labels (Prometheus stamping the
scrape job) to *per-series* labels (the app stamping `network` on every
metric it emits). This is a prerequisite, not a nicety — after the merge, one
target serves both networks and the scrape job can no longer tell them apart.
The #398 incident (testnet scraped under mainnet labels) is the failure mode
this prevents from returning in a worse form.

### The SLO rules aggregate `network` away, and that BLOCKS wave 2

Measured 2026-08-21. Prometheus scrapes **mainnet only** today (the one
exception is `backup-runner-testnet`, labelled `estate: testnet`), so nothing
has ever needed to separate the two — and `prometheus/rules/slo.yaml`
accordingly aggregates without `network`:

```
sum by (service, route, status) (rate(http_requests_total[5m]))
sum by (service)               (rate(http_requests_total{status=~"5.."}[5m]))
histogram_quantile(0.95, sum by (service, le) (rate(http_request_duration_ms_bucket[5m])))
sum by (service, tier)         (rate(http_requests_total{status=~"5.."}[5m]))     # the burn rate
```

The moment one pod serves both networks, every one of those SUMS MAINNET AND
TESTNET INTO ONE NUMBER. A testnet error spike burns the mainnet error budget,
a testnet latency regression moves the mainnet p95, and the alert that fires
names a service and a tier with no way to say which network is broken. It is
#398 again, in the direction that pages somebody at night for the wrong estate.

**Why this is not fixed in wave 0.** Adding `network` to those `by ()` clauses
while no service emits the label produces series with `network=""` — a
DIFFERENT series identity from today's, which orphans every dashboard panel and
every alert built on them, in exchange for no new information. Expand/contract
applies to recording rules exactly as it does to schemas.

**So it is a wave 2 gate, and the order is fixed:** the first service to be
merged ships emitting `network` (it already can — `@cloudsforge/telemetry`
carries it on the standard specs), *then* the four rules above gain `network` in
their `by ()`, *then* the dashboards that read them are re-pointed. A merged
service deployed before that sequence is a service whose SLO silently blends two
networks, and nothing in the estate would say so.

## 3. What merges, what stays, what disappears

### Stays paired (out of scope, by definition)
- Hearth EMBER nodes, mainnet and testnet, and their seeders
- bitcoind / litecoind / dogecoind on the chain host
- The miners (both hosts) and their sealed coinbase keys

### Becomes one pod serving both networks
- All request-driven APIs (§5 class B)
- All chain-facing workers (§5 class C), as dual-context processes
- The gateway: **one Traefik** whose file provider carries both host sets —
  the apex routers as today plus the `testnet.<apex>` routers, each testnet
  router attaching `CF-Network: testnet` via a headers middleware
- cloudflared: one deployment, both hostname routes
- The backup runner, covering the one cluster

### Becomes one pod, single-network (nothing to merge)
- faucet — testnet-only today (the mainnet gateway holds it); stays
  testnet-only, just lives in the one namespace with `CF-Network: testnet`
  pinned at its router
- pool's stratum listeners — mainnet-only chain set today
  (`POOL_CHAINS`/`POOL_LTC_AUX_CHAINS` are mainnet-only env); the pool API
  is dual-network, the listeners keep their single network until testnet
  stratum is a product decision somebody actually makes

### Deleted outright
- The ~20 `cf-testnet` web-bundle Deployments (byte-identical duplicates)
- The testnet identity pod (already vestigial, #472)
- The `cf-testnet` gateway and its cloudflared route (end of wave 6)
- The `cf-testnet` CNPG cluster (after import + verified parity)
- The `cf-testnet` namespace itself — the last object deleted, and the
  definition of done

## 4. Runtime changes (shared packages, shipped before any service)

Every per-service change in §5 is mechanical *only if* the shared layer does
the heavy lifting first. Four packages, one PR each:

1. **`runtime/http`** — `CF-Network` joins trace context as a forwarded-
   verbatim header on `HttpClient`; the server side exposes
   `requestNetwork()` and refuses (500) when the header is absent on an
   inbound request. An env escape hatch (`CF_NETWORK_SINGLE=<net>`) lets a
   single-network service (faucet) and `pnpm dev` (no gateway to stamp the
   header) run unchanged.
2. **`runtime/db`** — `networkPools({ mainnet: DSN, testnet: DSN })` with
   `poolFor(net)`; a service that passes one DSN gets today's behaviour.
   Migrations run per pool: the migrate job executes once per configured
   network, so a schema change lands on `<db>` and `<db>_testnet` in the
   same job.
3. **`runtime/auth`** — `#expectedNetwork` (boot constant) becomes
   `expectedNetworkFor(request)` (the header). The `net`-less-token window:
   accept + count (`auth_netless_tokens_total{network=…}`), alert on it,
   refuse after the window closes.
4. **`runtime/telemetry`** — `network` becomes a first-class label on the
   default meters; the request middleware stamps it from the header so
   services get per-network RED metrics for free.

Outbox events grow a `network` field; consumers dispatch on it. The five
per-network secret families (`outbox`, `identity-key`, `custody`,
`analytics-pepper`, `studio`) are all mounted into merged pods under
suffixed names; the network context selects. Identity keeps **two signing
keys** (one per network, both published in the one JWKS) — the `net` claim
is the boundary, but key separation keeps a hypothetical key compromise
scoped to one network's tokens, which costs nothing to keep.

## 5. Per-service disposition

Class A — **static web bundles, delete the testnet copy** (network-agnostic
nginx since the combined view):

> site, hub-web, admin-web, mint-web, trade-web, worlds-web, explorer-web,
> network-site, market-web, devportal-web, status-web, emberkin-web,
> foresight-web, aetherholm-web, tessera-web, lantern-web, beacon-web,
> pool-web, exchange-web, journal-web, agora-web

Class B — **request-driven APIs, dual pools, header-routed**:

> ledger, wallet, activity, policy, pricing, billing, studio, mint, market,
> trade, worlds, nda, community, devplatform, analytics, admin-api, tessera,
> lantern, emberkin, aetherholm, foresight, agora, hub-api

Class B′ — **shared singletons, ONE database** (the `_testnet` import is
residue to reconcile and drop): **identity** (one account set, #459),
**notify** (one mail pipeline, one quota — deliveries gain a `network`
column instead, because "which network triggered this mail" is a fact about
the delivery, not a reason for two pipelines).

Class C — **chain-facing workers, dual contexts, bulkheaded**:

> indexer (scans both EMBER chains + UTXO set), settlement (both RPC sets;
> UTXO withdrawals stay mainnet-only as today), custody, beacon (one prober
> covering both networks — it half-does already), pool (API dual; stratum
> single per §3)

Class D — **single-network**: faucet (testnet).

Per-service unknowns get settled *in that service's wave*, not now — the
table above is a plan, and the rule from the apex consolidation stands: the
sweep that verifies a wave includes the service's own repo, every consumer's
dev path, and every consumer's tests.

### 5.0 Two things every class B service needs, learned from the first one

**`/livez`, `/readyz` and `/metrics` must be exempt from the network
requirement.** Kubelet probes the first two and Prometheus scrapes the third;
none arrives through the gateway, so none carries `CF-Network`. agora's first CI
build failed exactly here — every probe answered 500 `network_unknown`, the
container never became ready, and the image test reported "never answered
/livez". Every service has these three, so every service will fail this way
once, and the symptom looks like a boot error rather than a routing rule.

Write the exemption as a literal set of three paths, not a prefix and not an
opt-in flag: it is a hole in a data-isolation boundary, and widening it should
take a deliberate edit. All three answer without touching the database, which is
what makes them safe to exempt at all.

**The domain deps are rebuilt, not restructured.** See §5.1 — the estimate below
was written before the first service was actually done, and the work turned out
to be smaller than it looked.

### 5.1 A class B service is a REFACTOR, not a mechanical pass

Attempted on `agora` 2026-08-21 and stopped on purpose, with the work reverted.
The first two thirds went exactly as this plan assumed:

* `RequestContext` grows `network` (from `requestNetwork`, which refuses an
  unstamped request) and `sql` — the handle resolved ONCE at the edge, so the
  twenty-five `deps.sql` call sites become `ctx.sql` and `ServerDeps.sql`
  becomes a `NetworkSql` with no query methods, making the wrong thing
  unspellable rather than merely discouraged;
* `ServerDeps.singleNetwork` from `CF_NETWORK_SINGLE` for `pnpm dev`;
* two pools at the composition root, `AGORA_DATABASE_URL_TESTNET` unset meaning
  single-network;
* `network` on every http metric, including the refusal path.

That reached **five type errors**, all in composition. Then the real one:

**agora builds five DOMAIN DEP OBJECTS at boot — `posts`, `circles`,
`whispers`, `notifications`, `moderation` — and each closes over a database
handle. Thirty-two route sites read them.** A per-request network cannot flow
through an object constructed once at startup, so those five must either be
rebuilt per request or changed to take the handle as a parameter. That is a
restructuring of how the service composes its domain layer, not a rename.

**RESOLVED — the estimate above was wrong, and agora is done.** Those five
objects are PLAIN IMMUTABLE RECORDS, so they do not need restructuring at all:
one helper rebuilds them per request with the resolved handle, and all
thirty-two route sites are correct without being touched.

```ts
function forRequest(deps: ServerDeps, sql: Db): ServerDeps {
  return { ...deps, posts: { ...deps.posts, sql }, circles: { ...deps.circles, sql }, … }
}
```

Five shallow copies of small records, once per request, on a path about to do
IO. The whole service came to roughly 250 lines of diff including tests
(micro-agora#1), and the type system does the enforcement: `ServerDeps.sql` is a
`NetworkSql` with no query methods, so a route reaching for the process-wide
handle does not compile.

**So waves 2–5 are a repeatable pass after all**, and the recipe is:

1. `RequestContext` gains `network` and `sql`, resolved once at the edge;
2. `ServerDeps.sql` becomes `NetworkSql`, `singleNetwork` added for `pnpm dev`;
3. `deps.sql` → `ctx.sql` everywhere the compiler points;
4. `forRequest` for whatever dep objects the service builds at boot;
5. `network` on the http metrics, including the refusal path;
6. exempt the three operational routes (§5.0) — this is the one that fails CI
   if forgotten;
7. a `network.test.ts` pinning both refusals.

Steps 3 and 4 are found by the compiler rather than by reading, which is what
makes this safe to repeat: turning `ServerDeps.sql` into a type with no query
methods produces an exhaustive worklist.

**Confirmed across six services.** After agora, the recipe was applied to
policy, analytics, pricing, community and devplatform. Each ended at between one
and six compiler errors, all in composition, and each is behaviour-preserving.
Four more things worth knowing, each of which cost a CI round:

* **`.env.example` and the `optional()` idiom.** `env.test.ts` requires every
  variable `env.ts` reads to be declared, and extracts the read set by matching
  `source, 'NAME'`. The bare `source['NAME'] ?? ''` form therefore reads as
  UNDECLARED even though it plainly reads the variable. Use the service's own
  `optional(source, 'NAME', '')`.
* **The lockfile.** Adding `@cloudsforge/http` to a service that lacked it
  (policy, analytics) is `ERR_PNPM_OUTDATED_LOCKFILE` under `--frozen-lockfile`
  unless `pnpm-lock.yaml` is committed with it.
* **Helpers that take only `deps`.** Most services have two or three
  (`resolveVoice`, `authoriseProjectAs`, `roleInOrg`). They take the handle as a
  first parameter instead, so it reads as a property of the request.
* **Standalone functions with their OWN `{ sql }` record** — analytics's
  `scrapeRefresh` — must be left alone. They run off the scrape path, which has
  no request and therefore no network. A blanket rename breaks them.

And one variation worth naming: **policy's `decide` dep carries a snapshot
READER that also closes over the handle.** Rebuilding the object while leaving
the reader pointed at the other network would make every policy DECISION read
one estate while its writes went to the other — a divergence that presents as a
policy bug rather than a routing one. Look for a second closure whenever a dep
object holds more than data.

### 5.2 The four services wave 3 could not do mechanically, and what they taught

The recipe in §5.1 covered eleven of the fifteen. These four did not fit, and
each one names a different shape of hidden state. Read this before starting a
service whose deps look unusual.

**studio — the handle lives INSIDE a store.** `ServerDeps` never held a bare
`sql`: it holds `kits: BrandKitStore`, built once as
`postgresBrandKitStore(sql, SERVICE)`. Swapping a pool reference per request
would have left that closure bound to whichever network booted first, so every
request would read mainnet while the code above it read as network-aware. The
fix is to keep the FACTORY in deps and call it again per request — the same
shape as policy's snapshot reader, and the general rule is: *whatever captured
the handle is the thing that has to be rebuilt, not the field that names it.*

**mint and foresight — the network is not only which database, it is which
CHAIN.** `MINT_NETWORK` and `FORESIGHT_NETWORK` were the process's answer to
"which chain do I deploy to, and with which custody key". Getting that wrong is
not a mis-filed row: a testnet order served by a mainnet-configured pod deploys
a REAL contract, spends REAL gas, and records success. So `forRequest` moves
`deps.network` alongside the handle, and the deploy/resolve workers are built
one per network rather than once from env.

foresight adds a second edge: `resolutionLeaseKey(chain, network)` is the key
that stops two replicas posting the same resolution. One queue shared across
estates would make a mainnet resolution job and a testnet one collide on that
key, and `onConflict: 'earliest'` silently drops the second — a testnet market
that never resolves, with no error anywhere.

**hub-api and admin-api — no database, or not only a database.** hub-api holds
no store at all: its isolation is (a) the `CF-Network` it forwards to every
peer and (b) the CACHE KEY. Tile keys were per-user and some were global, so
one pod serving both estates would serve a mainnet portfolio to a testnet
viewer. The network is prefixed at the single site where the cache is read AND
written, never in the dozen `key:` literals the routes declare — there are a
dozen today and a thirteenth every few weeks, and one that forgot would be a
silent cross-estate leak.

admin-api is the sharper version of the same point: its own database holds
approvals and an audit trail, but what it DOES lives in the peers — it reverses
ledger entries, grants identity roles, delists listings. Narrowing only the
handle would leave an operator viewing testnet, approving a reversal recorded
against the testnet audit row, and having it carried out on MAINNET.

For both, the estate travels as a client-wide `CF-Network` header on one client
set per network rather than a per-call argument: these peer interfaces are
domain methods (`trialBalance()`, `reverseEntry(request)`) with nowhere to put
one, and threading an options bag through twenty of them leaves nineteen right
and one wrong. The `HttpClient`s themselves stay shared where a circuit breaker
is involved — a wallet that is down is down for both estates, and two breakers
over one process each see half the evidence and trip late.

**And the general lesson.** Six of the fifteen run a JOB PLANE in the same
process as the request plane. `deps.queue.enqueue` is a WRITE, so a queue that
is not per-network means a testnet request enqueues work that a runner holding
the mainnet handle then claims, applies to mainnet rows, and completes — with a
job row afterwards saying it went exactly as intended. One queue per database
and one runner per queue, and `jobs_pending`/`jobs_overdue` carry the network
label, because summed across two queues the gauge reads healthy while one
estate's backlog grows without limit.

### 5.3 beacon is class B′, not class C — a correction to §5's table

The class table above lists beacon under class C, "chain-facing workers, dual
contexts, bulkheaded". Doing it proved that wrong, and the correction is worth
recording because the reasoning generalises to any observability service.

**beacon keeps ONE database with a `network` column.** Two reasons:

1. Its rows are OBSERVATIONS, not an estate's user data. The isolation argument
   that justifies two pools everywhere else — a wrong handle is a query that
   succeeds against the other estate's rows and says nothing — does not apply,
   because nobody's money or identity is in `checks`. What is needed is
   attribution, and attribution is a column.

2. The public status page and the release gate want BOTH estates in one query.
   Two pools would make that a join across databases, which postgres cannot do,
   so the merged view would have to be assembled in application code from two
   round trips — more moving parts than the column, for no safety gained.

The one thing that genuinely had to be separated is **hysteresis**. `probe_state`
is keyed on `probes.name` and holds the consecutive-failure count that turns a
blip into an incident; two estates sharing a state row count each other's
failures and open an incident against the wrong one. That is why a CHECK
requires a testnet probe's name to end `-testnet`, and why the estate is DERIVED
from the name rather than read from the request body — one source cannot
disagree with itself.

**And a note on back-fills, because beacon's and notify's differ on purpose.**
`probes.network` defaults to `'mainnet'` NOT NULL; `deliveries.network` is
nullable and left empty. notify's history was written by a pod whose estate is
*inferable* from the deployment, and inferable is not recorded — stamping it
would turn an inference into an assertion. beacon's rows were written by a
mainnet prober watching URLs that ARE mainnet's: the estate is a property of
which database the migration runs against, not a guess from context. When in
doubt, prefer the null.

### 5.4 indexer needs NO code change, and that is a finding rather than an oversight

Checked before touching it, and the answer was already yes. indexer was built
multi-network from the start:

- `INDEXER_CHAINS` takes `<chain>:<network>` pairs, and the per-scope RPC URL
  and start height are named `INDEXER_RPC_<CHAIN>_<NETWORK>` — one process
  already follows `ember:mainnet` and `ember:testnet` side by side if both are
  listed, and `env.ts` REFUSES an RPC variable whose scope is not in the list.
- Every chain table carries `chain` and `network`, both inside the primary key,
  under a stated invariant at the top of `migrations.ts`: *"no query may span
  networks"*. A foreign key cannot reference the other network's row because the
  reference itself carries the network.
- Every metric already has `['chain', 'network']` among its labels.
- Every read route names the network in its PATH —
  `/chains/:chain/:network/status`, `/addresses/:chain/:network/:address/...` —
  so a caller has always had to say which estate it is asking about.

There is no process-wide `INDEXER_NETWORK` anywhere in the service.

**So the consolidation of indexer is a CONFIG change, not a code change:** point
one deployment's `INDEXER_CHAINS` at both scopes, give it both RPC URLs, and
delete the second deployment. That is deliberately left to the deploy step
rather than done here, because it is the same one-line-rollback cutover §6
describes for everything else.

Worth recording plainly, because "we looked and it was already right" is a
result that otherwise evaporates — the next person to read the class-C list
would spend the same afternoon proving it again.

### 5.5 identity's `net` fallback, and why the process could no longer answer

`net` names the estate a service token is FOR, and under a shared identity that
is not always the estate identity runs in. The credential ROW has carried it
since micro-org#459 stage 2; what wave 4 changed is the FALLBACK for credentials
minted before that.

It was `IDENTITY_NETWORK`, and it was correct while the pod served one estate —
its own network and the caller's were the same thing. One pod serving both makes
`IDENTITY_NETWORK` name whichever estate the deployment happens to be labelled
with, so a testnet service presenting a pre-#459 credential would be handed
`net=mainnet`: a token that FAILS at its own estate and PASSES at the other one.
Backwards twice, and precisely the crossing the claim exists to refuse.

The order is now **row → request → `IDENTITY_NETWORK`**. The row still wins, so
a caller cannot widen its own token by arriving through the other gateway, and
with nothing stamped the answer is unchanged — which is why this needed no
flag-day.

### 5.6 wallet: when a service has NO bare `sql` at all

wallet's deps hold four domain bundles — `deposits`, `withdrawals`, `money`,
`portfolio` — and every one closes over a pool reference. There is no single
field to swap.

Rebuilding some and not others is WORSE than rebuilding none, and that is worth
stating because a partial `forRequest` looks like progress. A deposit credited
in one estate and a balance read from the other means the two DISAGREE: the user
sees a deposit confirmed and a balance that never moved, and both services
insist they did their job. One wrong estate is a bug; two half-right ones is a
support case nobody can close.

`forRequest` rebuilds all four against the same handle, and the test pins the
COUNT so that a fifth bundle added later is a visible omission rather than a
silent one.

### 5.7 The refusal has to be LOUD, and for a while it was silent

The property everything above rests on is that `networkSql.for()` REFUSES a
network this deployment cannot serve, rather than substituting the handle it
does have. Every service was written that way and every test asserted it.

It still hung the connection.

The resolution sat on a bare line above the dispatch:

```ts
const sql = deps.sql.for(network) as unknown as Db
void handle(matched, { …, sql }, forRequest(deps, sql))
```

Both expressions are evaluated BEFORE `handle` returns a promise, so the throw
escaped the `void` expression — past a `.catch` that had not been attached yet —
and the request listener returned having sent nothing. The socket then stayed
open until the client gave up.

**A refusal nobody receives is worse than no refusal.** The caller cannot retry,
cannot report it, and cannot tell it apart from a slow query. Every unit test
passed throughout, because they assert that `for()` throws — which it does. What
nothing asserted was that the throw reaches the caller.

It surfaced by accident: a micro-trade fixture missing one dep made every request
in that suite hang, and CI ran for fifty minutes on a suite that finishes in
three seconds before anybody asked why.

Fixed in all twenty-one services by resolving inside a `try` that answers 500
`network_unavailable` before any route runs, so a refusal cannot leave a
half-finished write. `network.test.ts` now pins that an unservable network
ANSWERS, not merely that it throws.

**The general lesson, which is not about this estate.** A safety property proved
only at the point it is raised is proved halfway. The question a test has to ask
is not "does this refuse?" but "does the refusal arrive?" — and those had
different answers here for the length of six waves.

### 5.8 The gateway does not stamp every request — only the ones that reach it

§2.1 says the gateway stamps `CF-Network` on every request. That sentence is the
foundation of the whole design and it is **not true**, in a way that only a
deploy could show.

It is true of requests arriving through the gateway. It is false of every
service-to-service call, and the estate is full of them: an outbox relay POSTing
`/v1/events` to `admin-api:4014` goes container to container. Nothing stamps a
header on it, and nothing can — the gateway is not in that path and adding it
would route internal traffic through the edge.

So `requestNetwork` refused them, and mainnet's admin-api answered 500 on every
internal event delivery until it was rolled back.

**The companion defect, found in the same ten minutes.** The composition roots
registered their one DSN under a hardcoded `mainnet`. Same image, same code,
different env — so the testnet pod held its testnet DSN under the name `mainnet`
and refused every request the gateway had correctly stamped `testnet`. Five
testnet services crash-looped. The refusal was right; the registration was wrong.

**Both are the same missing fact:** a pod serving one estate has to KNOW which
estate it is. `CF_NETWORK_SINGLE` is that declaration, and it is now set by the
render for every deployment — not the `pnpm dev` convenience this document
called it, and not "never in production", which was wrong twice over.

The header still wins when present, so declaring the network cannot mask a
mis-stamped external request. It only answers the internal callers that never
had one.

**What this says about the plan.** Waves 2 through 6 were each verified by unit
tests, typechecks and CI, and all of it passed. What no test could see is that a
premise stated in §2 was false — and a premise is exactly the thing tests
inherit rather than check. The estate was rolled back in eleven minutes and
nothing was lost, which is what §6's one-line rollback is for; but the lesson is
that the verification gate for a wave has to include one real request on the
path the wave changes, and this one only ever exercised the path through the
gateway.


### 5.9 The literal `mainnet` has three hiding places, and a render variable that reaches nothing

The same defect has now been fixed three times, in three structures, across two
deploys. Each fix was correct and in place when the next one fired.

| Deploy | Structure | Symptom |
|---|---|---|
| 2026.8.97 | `networkSql({ mainnet: sql })` | 5 testnet pods refuse their own data |
| 2026.8.98 | `[{ network: 'mainnet' as const, queue }]` | 3 testnet pods **exit** on first request |
| 2026.8.98 | `for (const [network] of [['mainnet', sql]])` | testnet logs its schema checks as mainnet |

The shape is always the same: one image, one codebase, two deployments, and a
line that names an estate the pod might not be.

**The render was setting `CF_NETWORK_SINGLE` where nothing could read it.**
`config` in `k8s-render.py` is the compose *interpolation* environment — it
resolves `${VAR}` in compose files. No compose file references
`${CF_NETWORK_SINGLE}`, so the variable resolved nothing and reached no
container. Every testnet pod read it as absent and fell back to `mainnet`,
which meant the whole 2026.8.97 code fix could not have worked no matter how
correct it was. It is injected at the container-env site now, beside
`NODE_EXTRA_CA_CERTS`.

Worth stating plainly: for one deploy the fix and the defect were both present,
and the deploy still failed the same way. Nothing about the code was wrong.

#### The second fault was strictly worse than the first

`planeFor` throws a bare `Error`, and `forRequest(deps, …)` was evaluated on the
`void handle(…)` line — one line below the try §5.7 added, and still
synchronous. An uncaught throw in an HTTP request listener is an unhandled
exception, and node exits on those.

So the failure mode was not the 500 §5.7 built, nor even the hang §5.7 removed.
The pod **died**, and its replacement died on the next request:

```
ready → first request → exit → restart → ready → request → exit
```

That made it a remote crash reachable by anyone who can set a header. A
*mainnet* pod handed `CF-Network: testnet` would have gone down identically, and
mainnet pods sit behind a public gateway. Only the absence of such a request
kept mainnet up while testnet crash-looped.

`forRequest` is resolved inside the try in every service now. The rule is: **no
per-request dependency is resolved outside it**, because "which resolutions can
throw" is not a property worth tracking per service.

#### Why six waves of green tests never caught any of it

Every service has tests asserting that an unheld network is REFUSED, and they
passed on the broken code every time — because it *was* refused, correctly, for
data the pod was holding under the wrong name.

Nothing asserted **which networks a pod holds**. That is the assertion, and it
now lives in `src/ownnetwork.test.ts` in each consolidated service: no
per-network map names an estate directly, `ownNetwork` is declared from
`CF_NETWORK_SINGLE` above every use, and `forRequest` is inside the try. It is
per-repository rather than an estate sweep so it fails on the pull request that
introduces the defect rather than on the release that ships it.

#### The verification gate, restated

§5.8 said a wave's gate must include one real request on the path the wave
changes. That was right and still insufficient — 2026.8.98 was verified as
"51/51 and 31/31 available" and three pods were already dying, because
**readiness is not a request**. These pods boot, pass `/readyz`, report ready,
and die on the first real traffic.

So: for each network, one real request through the gateway, one internal
service-to-service request with no header, and one request stamped for the
*other* network — that last one must answer 500 and the pod must still be
running afterwards.


## 6. The cutover mechanism, and why rollback is one line

Both namespaces stay alive throughout. The unit of change is one service:

1. Ship the service network-aware (runtime upgrades + two DSNs + header
   handling). Deploy it to `cloudsforge-estate` as usual. Mainnet behaviour
   is unchanged — the header says `mainnet` on every request it was already
   getting.
2. Import that service's testnet database into the one cluster as
   `<db>_testnet` (`k8s-db-import.sh`; the source stays untouched in the
   old cluster). Point the service's testnet pool at it.
3. **Repoint one router**: the testnet gateway's `cf-svc-<service>` backend
   changes from `http://<service>:PORT` (namespace-local) to
   `http://<service>.cloudsforge-estate.svc.cluster.local:PORT`, and the
   router gains the `CF-Network: testnet` header middleware. Gateway config
   needs no release — `k8s-gateway.sh` reads the checkout.
4. Verify live (§7), then freeze writes to the old copy: scale the
   `cf-testnet` Deployment to zero. Delete it a wave later, not the same
   day — a scaled-to-zero Deployment is the rollback.

**Rollback** at any point before deletion is reverting the one router line
and scaling the old Deployment back up. The old database never moved, so
data rollback is "stop pointing at the import" — with the one caveat that
writes made to the import after cutover are lost to the old copy, which is
why the freeze in step 4 precedes the verify, not follows it.

### 6.1 What the first real cutover changed about §6 (agora, 2026-08-25)

Three of §6's four steps survived contact. The third did not.

**"Repoint one router" is wrong for half the estate.** Of wave 2's six services,
only agora, devplatform and pricing have a public router at all. community,
analytics and policy are reached ONLY service-to-service, by Service name inside
`cf-testnet` — so a plan step phrased entirely in terms of gateway backends had
nothing to say about them, and the first draft of the mechanism (drop the
service from the testnet render) would have taken their callers down with no
gateway edit able to bring them back.

What replaces it: the testnet render emits an **`ExternalName` Service** — a DNS
CNAME to `<svc>.cloudsforge-estate.svc.cluster.local`. Both kinds of caller keep
working with no edit anywhere, the gateway file is untouched, and the
`CF-Network: testnet` header the testnet gateway stamps on its own entrypoint
chain rides along unchanged. `ClusterIP` → `ExternalName` was checked against the
live API server before it was relied on; it is accepted as an update.

**The migrate Job is a separate compose service, and its exit code lies.** The
render matched `name in CONSOLIDATED_SERVICES`, so `agora` got the second DSN and
`agora-migrate` did not. The migrator loops over every configured DSN, found one,
logged `"network":"primary"`, and exited 0 — a green deploy that had silently
stopped maintaining half the schema. Nothing was wrong that day, because the
adopted database had been migrated by the testnet pod before the freeze; the
next release is where it would have refused testnet with the estate otherwise up.

Found by reading the migrator's LOG rather than its exit code. Both said the run
succeeded. Only one said what it had run against — and "what did it actually
touch" is the question a migration's exit code cannot answer.

**The freeze goes before the copy, not after.** §6 orders it import → repoint →
verify → freeze, and accepts that writes between import and repoint are lost.
`k8s-db-adopt-testnet.sh --adopt` inverts it and REFUSES unless the testnet
deployment is already at zero replicas. The estate has no real users, so the
seconds of testnet downtime cost nothing, and losing writes to a copy that is
about to become authoritative costs correctness. Measured: 1 second to copy
agora, 28 tables.

**What the verification actually proved.** Not "it returned 200" — the gate is
that one pod serves DIFFERENT data per estate. After a real database-reading
request with each header, `pg_stat_activity` on the mainnet cluster showed the
single agora pod holding open connections to `agora` AND `agora_testnet`. The
separation is visible at the connection, not inferred from a status code.

### 6.2 The last four need a decision, not a step (2026-08-25)

Twenty-four services are across. Four are not, and the reason is the same for
all of them: **each database's migration defaulted its own pre-existing rows to
`mainnet`, and in the testnet cluster that default is wrong.** It is the same
defect class as §5.9's literal — a value that was locally correct and globally
false — except that here it is in money records rather than in a key.

The plan assumed these four keep one database and therefore need no data step.
That was right about the schema and wrong about the rows: BOTH databases are
populated, with records that exist in only one of them.

| service | rows only in the testnet database | of which need a decision |
|---|---|---|
| custody | 31 keys, 0 overlapping mainnet's 293 | **1** |
| indexer | 7 watched addresses, 39,053 blocks | blocks: re-derivable |
| settlement | 1 confirmed tx, 1 treasury, 1 sweep source | **2** |
| beacon | 29 probes | **29** |

#### custody: the blocker is a UNIQUE constraint, not the keyring

This section said twice that the keyring was the blocker. It is not, and the
second attempt was as wrong as the first.

**`key_version` is the at-rest AES-GCM envelope version, not a derivation
version.** `hd.ts` derives from (mnemonic, family, network, index, chain) and
takes no version at all; signing decrypts the blob, whose own `v<n>:` prefix is
authoritative, and never reads the row's version. Re-encrypting a key changes no
address. The runtime says so, and the plural is the tell:

    cloudsforge-estate   "keyVersion":4,"readableKeyVersions":[4]
    cf-testnet           "keyVersion":2,"readableKeyVersions":[2]

`readableKeyVersions` is a LIST because a keyring is built to hold several at
once — that is how `runbook-custody-master-secret.md` rotates without any blob
ever becoming unreadable. Adding cf-testnet's V2 secret beside the estate's V4,
leaving `CUSTODY_KEY_VERSION=4`, makes all 39 testnet blobs readable and all 31
addresses signable; `reencrypt-cli.ts` then drains them to v4.

The `next_index` argument was wrong too. The two `foresight` counters index
different keyspaces — different mnemonic and different coin-type branch, since
every non-mainnet network takes coin type 1. Comparing them is a category error.

**The actual blocker (micro-org#510):**

    "custody_seeds_user_family_uniq" UNIQUE CONSTRAINT, btree (user_id, family)

Not keyed by network. **Six of the eight testnet seeds collide** with an estate
seed for the same (user, family), covering 28 of the 30 HD-derived keys. A merged
database holds one mnemonic per (user, family), so either six mnemonics are
abandoned or the constraint gains `network` — and repointing the rows at the
surviving seed is not an option, because `exports.ts` returns the SEED's phrase
and the stated `derivation_path` would then name a different address than the row.

Two more decisions ride along: **three** colliding key bindings rather than one —
and `custody_keys_binding_uniq` is PARTIAL, so the two treasuries insert
SILENTLY while only the deployer hard-fails — plus an `ember|testnet` treasury
pin the estate does not have, without which a merged testnet refuses every sweep.

micro-org#508 stays open for what is still true: the testnet keyring is two
envelope versions behind and was never rotated with the estate's, though
micro-org#339 recorded that rotation as done on both machines.

#### settlement is blocked BEHIND custody

Its `treasuries` and `sweep_sources` name custody addresses. Merging settlement
while custody's 31 addresses stay in the other cluster produces a treasury
pointing at an address the merged custody has never heard of.

#### What is NOT blocked

The mechanism is proven; only these rows need judgement. Each of the four can
cross the moment its rows are dispositioned, using exactly the path the other
twenty-four used — the render already knows how, `SINGLE_DATABASE_SERVICES`
already covers the no-second-handle case, and the freeze/adopt script already
refuses to copy from a database that is still being written to.

### 6.3 The gateway merge is not blocked by custody — and one Traefik is the wrong target

Assessed 2026-08-25 against the live gateways, whose `gateway-dynamic` ConfigMap
is byte-identical to the checkout in both namespaces.

**micro-org#508 and #510 do not block the gateway.** They are about database rows
and a UNIQUE constraint; the gateway cares only whether a router's upstream name
resolves. Of the services still in `cf-testnet`, `settlement` and `backup-runner`
have no router at all, and `custody`'s single router (`cf-web-vault`) answers 404
to everything — 1,548 GETs, all 404, and mainnet's equivalent answers 404 too.
Repointing it changes a 404 into a 404.

**`site` is retired** (done). Its two retirement routers sit at priority 550 with
`!PathPrefix('/v1')` and answer 34,184 requests with a 302 from middleware,
never reaching an upstream. `cf-web-site` sits at 500 and therefore only ever
matched `/v1`, which the bundle 404s: **41 requests in its entire life, every one
a 404.** Scaled to zero; the Service stays, because it is the declared `service:`
on three routers and `k8s-gateway.sh` refuses a router whose upstream has none.

**The real coupling is the hearth pair.** `hearth-explorer-api` and
`hearth-verify` exist ONLY in `cf-testnet` — mainnet's five `rpc.<apex>` devkit
routes 502 today, deliberately, because `compose/mainnet.env` has no
`CF_HEARTH_CHAIN_ID`. Move them under their current names and those five 502s
become 200s **serving testnet chain data on a mainnet hostname**, which is §6.1's
defect class exactly. They move as `*-testnet` with their own upstream variables,
or mainnet gets its own devkit. That is a decision, not a step.

#### Why one Traefik is the wrong target

The two gateways are the same Traefik reading the same 281 KB of files; the whole
difference is `env-traefik`. Rendering both:

    routers        90 mainnet, 79 testnet — 76 names in common, 0 sharing a rule
    middlewares    41 each, differing in exactly 2: cf-cors and cf-network

Collapsing to one costs 76 router duplications in a 3,404-line file whose value
is its comments, a second entrypoint chain, a doubled env Secret, a
re-specification of `surface-routes.py` checks 6 and 10, and the hearth rename —
to save one pod.

And two invariants are easy to lose in it. `CF-Network` is stamped **on the
entrypoint, not per router**, precisely so a forgotten router cannot deliver an
unstamped request; per-router stamping would restore that failure. And the CORS
asymmetry is a security property — `CF_VIEW_ORIGIN_SUFFIX` exists only in
`traefik.testnet.env`, so testnet accepts reads from mainnet frontends and
mainnet accepts nothing from testnet. One `cf-cors` on one entrypoint grants the
forbidden direction silently.

**So: two Traefik Deployments in `cloudsforge-estate`**, each with its own env
Secret, both mounting the same unchanged ConfigMap. That removes the
`cf-testnet` dependency with zero changes to `gateway/dynamic/*.yml` and
preserves every invariant by construction. If one Traefik is still wanted, it is
separate, later work — and it needs a second entrypoint (`tunnel-testnet`) with
its own `cf-network-testnet` and `cf-cors-testnet`, never per-router middleware.

**cloudflared is one line, and needs no dashboard.** It is already one connector
in `cf-edge` with two socat sidecars on 9081/9181; the 61 ingress rules are
token-delivered and stay untouched. Merging means repointing `origin-testnet`'s
socat target. `scripts/k8s-cloudflared.sh` hard-asserts `cf-testnet` has a ready
`gateway` Service, so it changes in the same commit or it refuses.

**What still blocks deleting the namespace** is `faucet`, which reaches custody
by bare name (`CUSTODY_URL=http://custody:4000`) — so faucet cannot move until
custody does. That is where micro-org#510 finally lands: on namespace deletion,
not on the gateway.

### The waves

| wave | contents | why this order |
|---|---|---|
| 0 | runtime packages, gateway header middleware, `network` metric labels, Prometheus/alert reshape; `sslmode=require` on every DSN and the backend-agnostic DB bootstrap job (§2.2.1) | everything else depends on it; deployable with zero behaviour change |
| 1 | class A web bundles | pure duplicates; deletes ~20 pods with no code change |
| 2 | low-risk class B: agora, community, analytics, policy, pricing, devplatform | real dual-pool services where a defect costs nobody money |
| 3 | product class B: market, trade, worlds, nda, tessera, lantern, emberkin, aetherholm, foresight, studio, mint, billing, hub-api, admin-api | the bulk; several small waves in practice, roughly this order |
| 4 | class B′ singletons: identity, notify | identity's testnet pod is vestigial — this wave is mostly deleting it and reconciling `identity_testnet` residue |
| 5 | class C workers: beacon, indexer, custody, settlement, pool | bulkheads verified per service; settlement last within the wave |
| 6 | money core: ledger, wallet; then gateway+cloudflared merge; then delete the `cf-testnet` cluster and namespace | ledger/wallet move only after every caller already forwards the header correctly in production |

Wave boundaries are verification gates, not dates. A wave that surfaces a
defect stops the train, fixes forward or rolls back the service, and the
next wave waits.

## 7. Verification, per wave

- `k8s-estate-verify.sh` **once** per deploy (it spends mail quota), plus a
  per-wave probe: for each moved service, the same request against the apex
  and against `testnet.<apex>` must answer from the *one* pod with
  *different* data (a marker row written to each network's DB pre-cutover
  proves the pools are not crossed — the check that matters most and greps
  can't do).
- A **wrong-network write probe**: a testnet bearer against a mainnet route
  must 403 `wrong_network`. This goes into estate-verify permanently, not
  just the migration.
- `check-k8s-databases-match-initdb.py` learns the `_testnet` set;
  `check-router-prefix-ordering.py` and `check-api-remount.py` re-run on the
  merged gateway file (the testnet host routers land in the same file the
  apex routers live in — same priority-band rules apply).
- Beacon keeps probing both networks throughout; its per-network journeys
  are the continuous version of the wave probe.

## 8. Risks, named

- **Cross-network data bleed** is the catastrophic one. Defences layered:
  header-or-500 (never default), pool selection in one runtime helper,
  `net`-claim-vs-header at auth, database-name isolation, marker-row probes,
  and the permanent wrong-network probe in estate-verify.
- **Shared-fate**: a testnet incident (EMBER testnet wedges regularly) now
  shares a process with mainnet. Bulkheaded worker contexts and per-network
  circuit breakers are the mitigation; the wave 5 verification includes
  deliberately stalling the testnet RPC and watching mainnet loops not care.
- **Pool arithmetic**: two pools per pod against one cluster roughly
  preserves today's total connection count (same 57 DSNs, half the pods),
  but the one cluster now carries both networks' connections — recompute
  `max_connections` headroom before wave 2, not after.
- **The k8s VM's memory** is the quiet beneficiary: ~51 fewer pods on a VM
  with a documented stall-without-OOM-kill failure mode. The consolidation
  is a stability fix wearing a tidiness costume.
- **Release flow**: `cfctl` and the 52-repo release are unchanged;
  `k8s-render.py --network` collapses to one render at the end of wave 6
  (mainnet.env and testnet.env fold into one estate env with per-network
  sub-keys). Until then both renders keep working — the render change is
  the last change, not the first.

## 9. Explicitly deferred

### Should a testnet fault page somebody at night?

Raised by the wave-2 telemetry gate (micro-deploy#225) and deliberately NOT
decided there. The SLO rules now group by `network`, so `SLOErrorBudgetBurnFast`,
`SLOErrorBudgetBurnSlow` and `GatewayErrorRatioHigh` fire per estate — and their
severity is unchanged, which means a testnet burn pages at the same tier a
mainnet one does.

That is the honest translation of today's behaviour: before the change, a
testnet fault was blended into the mainnet number and could page just the same,
only anonymously. Naming the estate does not make it noisier; it makes what was
already happening legible.

Whether it *should* page is a policy question — testnet has no users
([[estate-has-no-real-users]] applies), so the argument for routing it to
`severity: ticket` is strong. It is left open rather than folded into a
telemetry change, because changing what wakes somebody up should be a decision
somebody made rather than a side effect.

- Testnet stratum (pool listeners stay mainnet-only).
- Any schema-level merge (`network` columns, shared tables) — the database-
  name boundary is the design, not a stepping stone to something cleverer.
- `network.<apex>`'s apex-mount question (open from the apex consolidation,
  unrelated to this plan).
- Hearth-devkit and conformance tooling — dev-only, follows whenever
  convenient.

---

*Prior art this plan leans on: [`apex-consolidation.md`](apex-consolidation.md)
(the wave/verify/rollback discipline), [`kubernetes-migration.md`](kubernetes-migration.md)
(why the estate is shaped the way it is), micro-org#459 (the combined view
and the `net` claim), micro-org#472/#137 (one login).*
