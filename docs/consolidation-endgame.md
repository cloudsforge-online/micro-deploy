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

## 1. Repoint faucet at the consolidated Postgres — DONE 2026-08-26

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

### What actually happened, including the step this plan missed

The alias moved, the migrator ran, faucet came up on the consolidated cluster
and answers 200 through the testnet gateway; the old cluster shows zero
application connections. Five rows were carried and digest-verified
(`dispenses` 2, `faucet_address_grants` 2, `faucet_budget` 1;
`faucet_requester_grants` was empty on both sides). `jobs` and
`schema_migrations` were deliberately not copied — the runtime seeds its own
recurring jobs, and the migration ledger records what ran against THIS
database.

**The step this plan did not anticipate: the two clusters have different
`cloudsforge` passwords.** Repointing the alias without moving the credential
gives `password authentication failed for user "cloudsforge"`, three times,
and the deploy stops at wave 30 with nothing downstream applied — a good
failure, but a confusing one, because every symptom points at the database
rather than at the secret. `CF_POSTGRES_PASSWORD` in
`compose/estate/tokens.testnet.env` had to be set to the estate's value and
`k8s-secrets.py --network testnet --apply` re-run. **`--apply` is not the
default**: without it the script prints the names it would write and changes
nothing, which is exactly what happened on the first attempt and is why the
second deploy failed identically.

The plan's step ordering was otherwise right, and one thing it got right by
accident is worth keeping: retiring the testnet backup runner BEFORE the alias
moved. The runner reads `@postgres:5432` too, so had it still been running it
would have started dumping the consolidated cluster into the testnet rotation
the moment the alias changed.

Two defects were found while doing this, both pre-existing and both filed
rather than fixed here: the estate had taken no backup since 2026-08-20 and
had never backed up the adopted `*_testnet` databases at all (micro-org#511,
now fixed and verified), and the testnet faucet's funding address holds zero
EMBER with two drip requests queued since 2026-08-07 (micro-org#518).

## 2. Decommission the old cf-testnet Postgres — DONE 2026-08-26

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

### What actually happened

The archive was taken first and proven **completely**, not sampled: all 31
databases restored into scratch databases on the cluster being deleted, every
per-table row count matching, no scratch left behind. Sampling three would have
been the plan's letter; after the delete the archive is the only copy, so a
dump that turns out to be unreadable is unrecoverable rather than
inconvenient. The testnet custody vault (39 files) went into the same archive —
every slot in it has a counterpart in the estate vault, re-encrypted, but key
material is not something to delete on the strength of a counterpart.

Deleting the CNPG `Cluster` cascaded to its two PVCs, and the `cf-retain`
StorageClass left both PersistentVolumes `Released` with their data intact — a
second safety net that costs nothing and can be reclaimed later.

Beyond the plan's list, two things had to move that it did not name:

* **The three manifests describing the cluster** (`20-cluster-testnet`,
  `21-databases-testnet`, `22-bootstrap-testnet`) were deleted, and both
  renderers now REFUSE `--network testnet` by name rather than losing the
  choice — argparse's "invalid choice" tells someone following an old runbook
  nothing about where the databases went. A negative test in
  `check-k8s-databases-match-initdb.py` keeps the refusal from being tidied
  away as dead code, and was itself negative-tested.
* **`pg-cloudsforge` is no longer emitted into cf-testnet.** It exists in the
  shape CloudNativePG wants for `bootstrap.initdb` and nothing else reads it,
  so with no cluster there it was a live database password in a namespace with
  nothing to authenticate to — the kind of credential that outlives the
  rotation meant to retire it.

Verified after: 72 pods Running estate-wide, faucet 200 through the testnet
gateway with its rows intact, a consolidated testnet route 200, mainnet 200.

## 3. Retire backup-runner-testnet — DONE 2026-08-26, during phase 1

Its ordering turned out not to be free. The runner reads `@postgres:5432` like
everything else, so the moment phase 1 moved the alias it would have begun
dumping the CONSOLIDATED cluster into the testnet rotation — about 3 GB a day
of exact duplicate, in a tree labelled with the network it is not. It had to go
before the alias moved, not after, and `k8s-backup-runner.sh --network testnet`
now refuses with that reason.

The inventory below was the thing to get right, and it was measured rather than
assumed: all 22 adopted `*_testnet` databases are in the estate's backup set,
every vault slot has a counterpart in the estate vault, world-assets is
byte-identical, and the single studio asset that was not was carried across and
verified by content address.

With the old cluster gone it has nothing to dump. Delete the Deployment and
`backup-runner-env`, and remove whatever deploy path applies them. Before
deleting, read its config and confirm it includes nothing BUT the old cluster —
the miner-key lesson ([estate-miner-key-backup-covers-one-host]) is that backup
scope is always narrower or wider than assumed, never exactly as assumed.

## 4. The unread credentials — DONE 2026-08-26. The faucet move — a considered no

This phase had two halves, and they turned out to deserve opposite answers.

### The credentials: done

After phases 1–3 the testnet render emits one Deployment, yet **seven**
credential objects were still being applied into cf-testnet with no pod on
either side of them: the six per-service env-file Secrets (`secret-outbox`,
`secret-custody`, `secret-identity-key`, `secret-analytics-pepper`,
`secret-studio`, `secret-chainrpc`) and `estate-derived`, which carries a JSON
object of chain RPC endpoints, some of which carry basic-auth. `estate-derived`
was not on the original list here; it came from a `derived_vars` block in
`render-vars.testnet.yaml` naming consumers — settlement and
settlement-migrate — that the testnet render stopped emitting at the
consolidation.

The guard was what kept them alive. Section 2 of
`check-k8s-render-matches-compose.py` required every network to build every
Secret the renderer declares anywhere: right while both networks rendered the
same fifty services, wrong since. It now derives the requirement **per
namespace** from the rendered manifests. Per namespace and not per network,
because a `FILES` row does not necessarily land in its own network's namespace
— the testnet `env-chain` row is applied as `env-chain-testnet` into
cloudsforge-estate, so it is built under testnet and referenced by the mainnet
manifests, and a network-against-network comparison would call it missing on
one side and unused on the other. A pod can only mount a Secret beside it, so
the namespace is what both sides agree on.

cf-testnet now holds `estate-tokens` and `gateway-trust`, both of which faucet
reads, and the list cannot silently regrow: adding a row back without a pod to
read it fails CI.

### The faucet move: rejected, and this is the reason

Moving faucet's Deployment into cloudsforge-estate would buy the removal of one
reverse ExternalName (`TESTNET_ONLY_BRIDGED`) and one CI guard (7c). It would
cost a **second `estate-tokens` in cloudsforge-estate** — the name is taken
there by the mainnet set — because every value faucet reads is interpolated
from `tokens.testnet.env`: `FAUCET_DATABASE_URL`, `FAUCET_TOKEN`,
`FAUCET_REQUESTER_SALT`, `FAUCET_RPC_URL`, `CUSTODY_URL`, `CUSTODY_TOKEN`,
`FAUCET_FUNDING_ADDRESS` and four more.

That is the trade this very phase just argued against. The whole point of the
work above is that a credential should exist where something reads it and
nowhere else; the move would put a testnet credential set into the namespace
that holds the money core, to save one CNAME. Filtering it to the eleven keys
faucet needs is possible — the `only` mechanism exists — but that is a new
filtered credential object and a new renderer case ("a testnet-only service
rendered into the estate namespace") in exchange for deleting a Service and a
guard.

There is also a plainer argument. cf-testnet's remaining purpose is to be the
testnet bulkhead: the hearth devkit lives there precisely so the mainnet
gateway's `rpc.<apex>` upstream does NOT resolve (§5). faucet is a testnet-only
public giveaway endpoint, and it belongs on that side of the bulkhead rather
than beside custody and settlement.

So cf-testnet's end state is three pods — faucet and the two devkit services —
and that is the intended shape rather than a leftover. Like the two-gateway
decision in §6, this is written down as a decision so it is not rediscovered as
an oversight.

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
