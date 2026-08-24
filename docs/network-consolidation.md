# Network consolidation — one set of pods for both networks

**Status: PLAN. Nothing below is implemented.** Written 2026-08-21, after the
frontend combined view (micro-org#459) proved the pattern this generalises.

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
