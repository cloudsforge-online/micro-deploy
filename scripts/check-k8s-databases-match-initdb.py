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
GENERATOR = ROOT / "scripts" / "k8s-render-databases.py"
SQL = ROOT / "compose" / "estate" / "initdb.sql"
TARGETS = {
    "mainnet": ROOT / "k8s" / "database" / "21-databases-mainnet.yaml",
    "testnet": ROOT / "k8s" / "database" / "21-databases-testnet.yaml",
}

failures = []

for missing in [p for p in (GENERATOR, SQL, *TARGETS.values()) if not p.exists()]:
    failures.append(f"{missing.relative_to(ROOT)} does not exist")

if not failures:
    for network, target in TARGETS.items():
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "--network", network, "--sql", str(SQL)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            # The generator fails closed on an unparseable CREATE DATABASE, a
            # duplicate, or a name that cannot become a Kubernetes object. Its
            # message says which; pass it through rather than paraphrasing.
            failures.append(f"the generator refused to run for {network}:\n{result.stdout}{result.stderr}")
            continue
        if result.stdout != target.read_text():
            failures.append(
                f"{target.relative_to(ROOT)} is not what the generator produces from "
                f"{SQL.relative_to(ROOT)}.\n"
                f"       Regenerate it:\n"
                f"         ./scripts/k8s-render-databases.py --network {network} "
                f"--out k8s/database/21-databases-{network}.yaml"
            )

if failures:
    print("FAIL: check-k8s-databases-match-initdb")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print(f"ok: both k8s/database/21-databases-*.yaml match {SQL.relative_to(ROOT)}")
