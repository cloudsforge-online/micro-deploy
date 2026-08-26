# Consolidation endgame — the last per-network duplicates

Status: **proposal, 2026-08-26.** Nothing in this document has been executed.
The network consolidation (`network-consolidation.md`) is complete: every
application service serves both networks from one pod in `cloudsforge-estate`,
the testnet gateway runs beside the mainnet one in the same namespace, and the
2026-08-26 cleanup deleted the 50 zero-replica Deployments, 20 endpoint-less
web Services and the orphaned `env-chain` Secret that `kubectl apply` had left
behind in `cf-testnet`.

What remains in `cf-testnet` after that cleanup, and this plan's disposition
for each:

| workload | why it is still separate | disposition |
|---|---|---|
| `postgres-1` (CNPG) | pre-consolidation data; faucet still writes to it | **decommission** (phase 2) |
| `faucet` | testnet-only service; its database lives on the old cluster | **repoint, then move** (phases 1, 4) |
| `backup-runner` | dumps the old cluster | **retire with the old cluster** (phase 3) |
| `hearth-explorer-api`, `hearth-verify` | devkit; deliberately outside the estate | **stays** (§5) |
| `gateway-testnet` (in cloudsforge-estate) | the second Traefik | **stays** (§6) |

Ordering matters: phase 1 unblocks phase 2, phase 2 makes phase 3 possible.
Phase 4 is independent polish and can happen any time after phase 1.

## 1. Repoint faucet at the consolidated Postgres

The old cluster's only application consumer is faucet (verified 2026-08-26 from
`pg_stat_activity`: the only non-backup connections are the faucet pod to
`faucet` and backup-runner mid-dump). The consolidated cluster already has an
empty `faucet` database from initdb.

Steps:

1. Announce a short testnet faucet pause (nobody real is waiting — the
   cold-start framing applies — but the status page should say it).
2. Scale `faucet` to 0 replicas by hand (temporary; the render restores it).
3. Copy the `faucet` database old → new with the proven stage-and-verify shape
   (5 tables, 4 migrations' worth of schema; dump/restore is fine at this size,
   then an md5-over-ordered-rows comparison per table, as the #516 copies did).
4. Change the interpolation that builds `FAUCET_DATABASE_URL` (it comes from
   the testnet `estate-tokens` interpolation set) to point at
   `postgres-rw.cloudsforge-estate.svc.cluster.local`, re-apply secrets,
   re-render, deploy.
5. Verify: `network-testnet.<apex>/v1/faucet` answers 200, a drip round-trips,
   and `pg_stat_activity` on the OLD cluster shows no faucet connection.

Note the rate-limit hazard recorded in
[faucet-token-rotation-resets-the-rate-limit]: the requester salt is derived
from `FAUCET_TOKEN` unless pinned. This plan does not rotate the token — only
the DSN moves — but check the pin before touching anything else in that file.

## 2. Decommission the old cf-testnet Postgres

Preconditions, all now true except (d):

- (a) #516 closed: every left-behind row is carried and digest-verified, and
  the one deliberately abandoned row (the `planned` mainnet-labelled withdrawal,
  id `54d19d19…`) has its disposition recorded on the issue — it dies here.
- (b) The 31 databases on the old cluster are otherwise pre-consolidation
  residue; the consolidated cluster is authoritative for all of them.
- (c) Backup coverage: the estate backup-runner dumps every database on the
  consolidated server, which now includes the adopted `*_testnet` set —
  verify the dump list actually names them before proceeding.
- (d) Faucet repointed (phase 1).

Steps:

1. Take one final full dump of the old cluster and **prove it restorable**
   (restore into a scratch server on the 55470+ port range, count rows in two
   tables). Keep it for 90 days.
2. Delete the CNPG `Cluster` in cf-testnet; after it is gone, delete the
   `postgres-1` / `postgres-1-wal` PVCs.
3. Delete the cluster's Secrets (`pg-cloudsforge`, `postgres-ca`,
   `postgres-server`, `postgres-replication`) and the `database-bootstrap` and
   `cnpg-default-monitoring` ConfigMaps.
4. Sweep the monitoring plane: the backup-age metric for the testnet runner,
   any Prometheus target or estate-verify section that reads the old cluster.
   `check-prometheus-target-ambiguity.py` gets simpler here, not more complex —
   backup-runner-testnet was the one legitimate cf-testnet target (#513).

## 3. Retire backup-runner-testnet

With the old cluster gone it has nothing to dump. Delete the Deployment and
`backup-runner-env`, and remove whatever deploy path applies them. Before
deleting, read its config and confirm it includes nothing BUT the old cluster —
the miner-key lesson ([estate-miner-key-backup-covers-one-host]) is that backup
scope is always narrower or wider than assumed, never exactly as assumed.

## 4. Move faucet's Deployment into cloudsforge-estate (optional polish)

After phase 1, faucet in cf-testnet works but is the namespace's last
render-managed object. Moving the Deployment+Service into the estate namespace
removes the `TESTNET_ONLY_BRIDGED` reverse-ExternalName mechanism and its CI
guard (7c in `check-k8s-gateway-matches-compose.py`), at the cost of teaching
`k8s-render.py` a "testnet-only service rendered into the estate namespace"
case. The router stays inside the `CF_EMBER_NETWORK == "testnet"` template
gate either way, so mainnet never grows a faucet route.

This phase also finally empties the testnet rows of `FILES` in
`k8s-secrets.py` down to what is real: today six Secrets (outbox, custody,
identity-key, analytics-pepper, studio, chainrpc) are still applied into
cf-testnet with zero consumers, because guard section 2 of
`check-k8s-render-matches-compose.py` requires every declared env-file Secret
to be built for every network. Rewriting that guard to derive per-namespace
requirements from the rendered manifests is part of THIS phase, not a separate
cleanup — doing it earlier means doing it twice.

## 5. The hearth devkit stays

`hearth-explorer-api` and `hearth-verify` (deployed by
`scripts/k8s-hearth-devkit.sh`, state on their own PVCs, no Postgres) stay in
cf-testnet on purpose: the mainnet gateway's `rpc.<apex>` routers name a hearth
upstream that must NOT resolve in the estate namespace — the refusal behaviour
depends on the lookup failing. The testnet gateway reaches them fully qualified
(`.cf-testnet.svc.cluster.local`, in `traefik.testnet.env`). cf-testnet's
endgame is therefore not an empty namespace; it is the devkit bulkhead plus
`estate-tokens` and `gateway-trust`, and that is the correct end state.

## 6. Keep two gateways — a considered no

The one remaining "duplicate" is the Traefik pair. Merging them into one
gateway is possible (a Host-to-network mapping instead of the entrypoint
middleware) and is rejected: today `CF-Network` is stamped from
`CF_EMBER_NETWORK` at the entrypoint, before any router is consulted, so a
request's network is a property of WHICH pod received it — a topology fact
that cannot be mis-matched. A single gateway would re-derive the network from
request attributes per route, and one bad rule writes one estate's data into
the other. That is precisely the failure class the consolidation spent six
waves making impossible. The second gateway costs one idle-ish pod; the
asymmetry is not close.

## Net effect when executed

cf-testnet: 5 pods today → 2 (the devkit). The estate loses backup-runner-
testnet and the old Postgres (and its two PVCs, ~the largest storage residue),
gains nothing. Pod total: 68 → 65. The bigger prize — fewer pods per estate —
is the subject of `service-merge-plan.md`.
