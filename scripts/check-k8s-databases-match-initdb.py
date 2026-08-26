#!/usr/bin/env python3
"""The generated Kubernetes `Database` manifests still match `initdb.sql`.

THE DEFECT THIS PREVENTS
------------------------
`compose/estate/initdb.sql` is where a database is declared, and it will stay
that way — adding one is a `CREATE DATABASE` there, exactly as it has always
been. Kubernetes needs the same list as `Database` objects, so
`k8s/database/21-databases-{mainnet,testnet}.yaml` are generated from it.

Generated files rot the moment somebody edits the source and does not
regenerate, and this particular rot is silent in the worst way. Add
`CREATE DATABASE whispers;` to the SQL, deploy, and:

  * under compose nothing happens either, because initdb.sql runs ONLY on an
    empty data directory — so the author creates it by hand, it works, and the
    estate is fine;
  * under Kubernetes the `Database` object is simply absent, the database is
    never created, and the service that needs it fails to connect on a cluster
    that `kubectl get database` will happily report as 30/30 applied.

Both halves look healthy. The manifest that exists to guarantee the set is the
thing that dropped one. That is what this refuses to let merge.

WHY IT REGENERATES RATHER THAN COMPARING NAMES
----------------------------------------------
Comparing the set of database names would catch an addition and miss everything
else the generator decides: the owner, the cluster it binds to, the namespace,
and `databaseReclaimPolicy: retain` — which is the field standing between
`kubectl delete database indexer` and a 9.4 GB `DROP DATABASE`. A check that
only compares names would pass a file in which every `retain` had become
`delete`.

So it runs the generator and compares bytes. Anything the generator would emit
differently, for any reason, fails here.

THE ONE THING IT CANNOT CHECK
-----------------------------
It compares the repository to the repository. It does NOT know what is on a
cluster; a database created by hand against a live server, or an object deleted
from one, is invisible to it. That gap is real and is covered elsewhere:
`.status.applied` on each object is what says the cluster agrees, and
`scripts/k8s-db-import.sh` compares the two servers' actual `pg_database`
during the migration.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL = ROOT / "compose" / "estate" / "initdb.sql"

# TWO GENERATORS, ONE SOURCE, AND BOTH ARE CHECKED.
#
# `k8s-render-databases.py` emits CloudNativePG `Database` CRDs; `k8s-render-bootstrap.py`
# emits the portable psql Job that does the same work against any PostgreSQL, which is what
# lets the estate move to an Azure Flexible Server by repointing one Service
# (`docs/network-consolidation.md` §2.2.1).
#
# Checking only one of them would be worse than checking neither: the two would drift, each
# would look right on its own, and the failure would be a managed server missing exactly the
# databases somebody added after the split — discovered when every service reports
# `database "x" does not exist` at once.
#
# ── ONE NETWORK, SINCE 2026-08-26 ────────────────────────────────────────────
#
# There used to be a testnet column here. `docs/consolidation-endgame.md` phase
# 2 decommissioned the cf-testnet CloudNativePG cluster: that namespace's
# `postgres` Service is an ExternalName into cloudsforge-estate, and the
# estate's cluster holds both networks' databases — the testnet ones under
# their `_testnet` names, which `21-databases-mainnet.yaml` already declares.
#
# So this is not a narrowing of the check. The same 52 databases are still
# checked against the same initdb.sql; what is gone is a second rendering of a
# subset of them for a server that no longer exists.
GENERATORS = {
    ROOT / "scripts" / "k8s-render-databases.py": {
        "mainnet": ROOT / "k8s" / "database" / "21-databases-mainnet.yaml",
    },
    ROOT / "scripts" / "k8s-render-bootstrap.py": {
        "mainnet": ROOT / "k8s" / "database" / "22-bootstrap-mainnet.yaml",
    },
}

# Both renderers must still REFUSE the retired network by name rather than
# emitting for it, because the failure this prevents is a second cluster being
# built from a runbook nobody updated. Asserted here so the refusal is covered
# by CI and cannot be dropped as dead code.
RETIRED = "testnet"

failures = []

expected = [SQL, *GENERATORS.keys(), *(t for m in GENERATORS.values() for t in m.values())]
for missing in [p for p in expected if not p.exists()]:
    failures.append(f"{missing.relative_to(ROOT)} does not exist")

if not failures:
    for generator, targets in GENERATORS.items():
        for network, target in targets.items():
            result = subprocess.run(
                [sys.executable, str(generator), "--network", network, "--sql", str(SQL)],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                # The generator fails closed on an unparseable CREATE DATABASE, a
                # duplicate, or a name that cannot become a Kubernetes object. Its
                # message says which; pass it through rather than paraphrasing.
                failures.append(
                    f"{generator.name} refused to run for {network}:\n{result.stdout}{result.stderr}"
                )
                continue
            if result.stdout != target.read_text():
                failures.append(
                    f"{target.relative_to(ROOT)} is not what {generator.name} produces from "
                    f"{SQL.relative_to(ROOT)}.\n"
                    f"       Regenerate it:\n"
                    f"         ./scripts/{generator.name} --network {network} "
                    f"--out {target.relative_to(ROOT)}"
                )

# ── THE RETIRED NETWORK STAYS REFUSED ────────────────────────────────────────
#
# Negative test, because the positive one above cannot see this. If a later
# edit "tidies up" the RETIRED_NETWORKS branch as dead code, both renderers go
# back to emitting a cluster and a database list for a namespace that has no
# database server — and the first person to follow an old runbook builds a
# second Postgres beside the consolidated one, with the same 22 databases under
# their plain names. Nothing would report that as wrong.
if not failures:
    for generator in GENERATORS:
        result = subprocess.run(
            [sys.executable, str(generator), "--network", RETIRED, "--sql", str(SQL)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            failures.append(
                f"{generator.name} --network {RETIRED} SUCCEEDED, and must not. The\n"
                f"       {RETIRED} database cluster was decommissioned; emitting for it would\n"
                "       describe a server that does not exist. Keep the RETIRED_NETWORKS\n"
                "       refusal. See docs/consolidation-endgame.md phase 2."
            )
        elif RETIRED not in (result.stdout + result.stderr):
            failures.append(
                f"{generator.name} --network {RETIRED} failed without naming the network.\n"
                "       The refusal has to say which cluster is gone and where its databases\n"
                "       went, or it is just an error message."
            )

if failures:
    print("FAIL: check-k8s-databases-match-initdb")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print(
    f"ok: both generated database artefacts match {SQL.relative_to(ROOT)}, and both\n"
    f"    generators refuse --network {RETIRED} by name"
)
