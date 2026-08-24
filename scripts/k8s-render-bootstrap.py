#!/usr/bin/env python3
"""Turn `compose/estate/initdb.sql` into a backend-agnostic bootstrap Job.

    ./scripts/k8s-render-bootstrap.py --network mainnet --out k8s/database/22-bootstrap-mainnet.yaml
    ./scripts/k8s-render-bootstrap.py --network testnet --out k8s/database/22-bootstrap-testnet.yaml

WHY THIS EXISTS ALONGSIDE k8s-render-databases.py
--------------------------------------------------
`k8s-render-databases.py` emits CloudNativePG `Database` resources. Those are
excellent and they are also **CNPG-only**: a `postgresql.cnpg.io/v1` object means
nothing to a PostgreSQL server that is not managed by CNPG, and the network
consolidation (`docs/network-consolidation.md` §2.2.1) commits the estate to
being able to run its one postgres EITHER in-cluster on CNPG OR on an Azure
Database for PostgreSQL Flexible Server, chosen by repointing the `postgres`
ExternalName alias.

Under that second backend nothing would create the thirty databases. The alias
would resolve, every service would start, and every one of them would fail on
`database "ledger" does not exist` — a total outage whose cause is thirty
objects that were never ported.

So this emits the SAME LIST as plain SQL, run by a Job against whatever
`postgres` resolves to. It works on both backends because it uses nothing but
libpq and the SQL standard: no operator, no CRD, no cluster reference.

WHY BOTH, RATHER THAN REPLACING THE CRDs
-----------------------------------------
The CRDs stay because under CNPG they are better: the operator reconciles them
continuously, so a database dropped by hand comes back, and `databaseReclaimPolicy:
retain` is a guarantee this Job cannot make. The Job is the PORTABLE floor, not a
replacement — it is idempotent, so running it against a CNPG cluster that already
has all thirty is a no-op that proves they are all there.

IDEMPOTENT, AND NOT BY `IF NOT EXISTS`
---------------------------------------
PostgreSQL has no `CREATE DATABASE IF NOT EXISTS`. The portable idiom is to
SELECT the statements that are needed and let psql execute its own output with
`\\gexec` — which is why the generated SQL looks like a query rather than a
script. `CREATE DATABASE` also cannot run inside a transaction block, so the
generated file must not be wrapped in BEGIN/COMMIT; psql's default autocommit is
what makes each statement stand alone.

THE ROLE THIS RUNS AS NEEDS `CREATEDB`, AND ONLY THAT
------------------------------------------------------
Not superuser. `CREATE DATABASE` is the one privilege beyond ordinary use that
this Job requires, and the estate's single `cloudsforge` role was created
without it — measured, not assumed: `rolsuper=f, rolcreatedb=f` on 2026-08-21.
Granting `CREATEDB` is one statement, reversible with one, and it does not let
the role read anything it could not read before. Azure Flexible Server's
administrative role has it already, so the same credential works on both
backends, which is the property this file exists to preserve.

THE OWNER IS GRANTED, NOT ASSUMED
----------------------------------
`ALTER DATABASE ... OWNER TO` is emitted for every database, every run. On a
fresh Azure server the databases would otherwise be owned by the administrative
role the Job connected as, and the estate's one `cloudsforge` role would be able
to connect and not to create a table. That failure appears at the first
migration, long after the Job reported success.
"""

import argparse
import pathlib
import re
import sys

NETWORKS = {
    "mainnet": "cloudsforge-estate",
    "testnet": "cf-testnet",
}

# Kept identical to k8s-render-databases.py ON PURPOSE. Two parsers over one
# file that disagree would produce two different database lists and each would
# look right on its own; `check-k8s-databases-match-initdb.py` compares both
# generated artefacts against the SQL, so a divergence fails rather than ships.
CREATE_RE = re.compile(r"^CREATE\s+DATABASE\s+([A-Za-z_][A-Za-z0-9_]*)\s*;$", re.IGNORECASE)


def databases(sql_text: str) -> list[str]:
    """Every `CREATE DATABASE` at the start of a line, lower-cased as PostgreSQL would."""
    names: list[str] = []
    for raw in sql_text.splitlines():
        line = raw.split("--", 1)[0].strip()
        m = CREATE_RE.match(line)
        if m:
            # `CREATE DATABASE Foo;` creates `foo`. Emitting `Foo` verbatim into a
            # quoted identifier would ask for a DIFFERENT database.
            names.append(m.group(1).lower())
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--network", required=True, choices=sorted(NETWORKS))
    parser.add_argument("--sql", default="compose/estate/initdb.sql")
    parser.add_argument("--owner", default="cloudsforge")
    parser.add_argument("--image", default="postgres:17-alpine", help="anything carrying psql")
    parser.add_argument(
        "--credential-secret",
        default="pg-cloudsforge",
        help="a Secret with `username` and `password`, for a role that HAS CREATEDB",
    )
    parser.add_argument("--out")
    args = parser.parse_args()

    namespace = NETWORKS[args.network]
    sql_path = pathlib.Path(args.sql)
    if not sql_path.exists():
        return fail(f"no SQL at {sql_path}. Refusing to emit a bootstrap from nothing.")

    names = databases(sql_path.read_text(encoding="utf8"))
    if not names:
        return fail(f"{sql_path} yielded no CREATE DATABASE lines. A bootstrap that creates nothing would report success and leave the estate with no databases.")

    try:
        sql_label = sql_path.resolve().relative_to(pathlib.Path(__file__).resolve().parent.parent).as_posix()
    except ValueError:
        sql_label = str(sql_path)

    values = ",\n      ".join(f"({quote_literal(n)})" for n in names)
    owner = quote_ident(args.owner)
    grants = "\n".join(
        f"ALTER DATABASE {quote_ident(n)} OWNER TO {owner};\nGRANT ALL PRIVILEGES ON DATABASE {quote_ident(n)} TO {owner};"
        for n in names
    )

    bootstrap_sql = f"""\
-- GENERATED by scripts/k8s-render-bootstrap.py from {sql_label}. Do not edit.
--
-- Runs against ANY PostgreSQL — CloudNativePG in-cluster, or an Azure Database
-- for PostgreSQL Flexible Server — because it uses nothing but libpq and
-- standard SQL. See the script's docstring for why that portability is the
-- whole point.
--
-- NOT WRAPPED IN A TRANSACTION: `CREATE DATABASE` cannot run inside one, and
-- psql's default autocommit is what lets each statement stand alone.
\\set ON_ERROR_STOP on

-- Every database that does not exist yet, as statements, executed by \\gexec.
-- PostgreSQL has no `CREATE DATABASE IF NOT EXISTS`; this is the portable idiom.
SELECT format('CREATE DATABASE %I', d)
FROM (VALUES
      {values}
     ) AS t(d)
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = t.d)
\\gexec

-- OWNERSHIP EVERY RUN, not only on creation. On a fresh managed server the
-- databases above are owned by whichever administrative role this Job connected
-- as, and `{args.owner}` would be able to connect and unable to create a table —
-- a failure that first appears at the migration, long after this reported
-- success.
{grants}
"""

    lines = [
        "# GENERATED by scripts/k8s-render-bootstrap.py. Do not edit.",
        f"# Source of truth: {sql_label} ({len(names)} databases)",
        f"# Regenerate: ./scripts/k8s-render-bootstrap.py --network {args.network} --out <this file>",
        "#",
        "# The PORTABLE half of database provisioning. `21-databases-*.yaml` carries",
        "# CloudNativePG `Database` resources, which are better under CNPG — the operator",
        "# reconciles them, and `databaseReclaimPolicy: retain` is a guarantee a Job cannot",
        "# make. They are also meaningless to a PostgreSQL that CNPG does not manage.",
        "#",
        "# This Job creates the same list with plain SQL against whatever the `postgres`",
        "# Service resolves to, so the estate can move to an Azure Flexible Server by",
        "# repointing one ExternalName instead of porting thirty CRDs. Idempotent: run",
        "# against a CNPG cluster that already has all thirty and it is a no-op that",
        "# proves they are there.",
        "---",
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        "  name: database-bootstrap",
        f"  namespace: {namespace}",
        "  labels:",
        f"    online.cloudsforge.network: {args.network}",
        "data:",
        "  bootstrap.sql: |",
    ]
    lines += [f"    {ln}" if ln else "" for ln in bootstrap_sql.splitlines()]
    lines += [
        "---",
        "apiVersion: batch/v1",
        "kind: Job",
        "metadata:",
        # NAME CARRIES NO HASH, so re-applying replaces rather than accumulating.
        # A Job's pod template is immutable; `k8s-database.sh` deletes before
        # applying, which is the documented way to re-run one.
        "  name: database-bootstrap",
        f"  namespace: {namespace}",
        "  labels:",
        f"    online.cloudsforge.network: {args.network}",
        "spec:",
        # Bounded. A bootstrap that retries forever against a server that will
        # never answer hides the outage behind a pod that looks busy.
        "  backoffLimit: 3",
        "  ttlSecondsAfterFinished: 3600",
        "  template:",
        "    metadata:",
        "      labels:",
        "        app: database-bootstrap",
        f"        online.cloudsforge.network: {args.network}",
        "    spec:",
        "      restartPolicy: Never",
        "      containers:",
        "        - name: psql",
        f"          image: {args.image}",
        "          command: ['psql']",
        # `-v ON_ERROR_STOP=1` is also set inside the SQL. Both, deliberately: the
        # file is run by hand during a migration too, and a hand run that ignores
        # errors would report a bootstrap that half happened.
        "          args: ['-v', 'ON_ERROR_STOP=1', '-f', '/sql/bootstrap.sql']",
        "          env:",
        # PGHOST is the alias, never a cluster-specific name — that indirection IS
        # the portability. PGSSLMODE matches what every service DSN now carries;
        # Azure Flexible Server refuses a plaintext connection outright.
        "            - name: PGHOST",
        "              value: postgres",
        "            - name: PGPORT",
        "              value: '5432'",
        "            - name: PGDATABASE",
        "              value: postgres",
        "            - name: PGSSLMODE",
        "              value: require",
        "            - name: PGUSER",
        "              valueFrom:",
        "                secretKeyRef:",
        f"                  name: {args.credential_secret}",
        "                  key: username",
        "            - name: PGPASSWORD",
        "              valueFrom:",
        "                secretKeyRef:",
        f"                  name: {args.credential_secret}",
        "                  key: password",
        "          volumeMounts:",
        "            - name: sql",
        "              mountPath: /sql",
        "              readOnly: true",
        "      volumes:",
        "        - name: sql",
        "          configMap:",
        "            name: database-bootstrap",
    ]

    out = "\n".join(lines) + "\n"
    if args.out:
        pathlib.Path(args.out).write_text(out)
        print(f"wrote {args.out}: bootstrap for {len(names)} database(s) on {args.network}", file=sys.stderr)
    else:
        sys.stdout.write(out)
    return 0


def quote_ident(name: str) -> str:
    """Double-quote an identifier, doubling any embedded quote. Belt and braces —
    every name here matches `[A-Za-z_][A-Za-z0-9_]*`, but the quoting is what makes
    that a property of the OUTPUT rather than of the input regex."""
    return '"' + name.replace('"', '""') + '"'


def quote_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def fail(message: str) -> int:
    print(f"FAIL: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
