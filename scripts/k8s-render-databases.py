#!/usr/bin/env python3
"""Turn `compose/estate/initdb.sql` into CloudNativePG `Database` resources.

    ./scripts/k8s-render-databases.py --network mainnet --out k8s/database/21-databases-mainnet.yaml
    ./scripts/k8s-render-databases.py --network testnet --out k8s/database/21-databases-testnet.yaml

WHY THIS EXISTS
---------------
`compose/estate/initdb.sql` is the estate's list of databases and it is more than
a list: it carries, per database, why that service owns its own and what would
break if it did not. "Whispers are the reason this is its own database rather
than a schema inside `community`" is a design decision recorded at the only
place it can be enforced.

Kubernetes needs the same list in a different shape. Hand-copying it would make
two lists, and two lists diverge — the file itself says how: it runs ONLY on an
empty data directory, so five of the databases in it were also created by hand
against a running server, and the file records that rather than pretending
otherwise. A second hand-maintained copy would repeat that story with no note.

So the SQL stays the source of truth and this generates from it. Adding a
database means one `CREATE DATABASE` in the SQL, exactly as today, and
`check-k8s-databases-match-initdb.py` fails the build if the generated files
were not regenerated.

WHY THE `Database` CRD RATHER THAN RUNNING THE SQL
--------------------------------------------------
CNPG can run arbitrary SQL once, at bootstrap, via `postInitSQL`. That would be
the literal translation and it has the same defect as the compose file: it
happens only when the data directory is empty, so every database added later is
a manual step on every existing cluster, and the manifest stops describing the
system.

A `Database` resource is reconciled instead of executed. It exists as an object
`kubectl get database` can list, it is created against a cluster that is already
running, and its `.status` says whether it actually exists — which is the
question "did somebody remember to create it on this estate" and which the SQL
file could only answer with a comment.

`metadata.name` IS NOT `spec.name`, AND THAT IS NOT PEDANTRY
------------------------------------------------------------
PostgreSQL identifiers allow underscores. Kubernetes object names are RFC 1123
subdomains and do not. The estate has exactly one database where those two rules
disagree — `admin_api` — and applying it produced:

    The Database "admin_api" is invalid: metadata.name: Invalid value:
    "admin_api": a lowercase RFC 1123 subdomain must consist of lower case
    alphanumeric characters, '-' or '.'

Worth being precise about what that failure looked like, because it is the
argument for generating this file rather than writing it: 29 of the 30 applied
cleanly. The estate would have come up with 29 databases, `admin-api` the
service would have failed to connect to a database nobody had noticed was
missing, and the manifest that was supposed to guarantee the set would have been
the thing that quietly dropped one.

So the object name is sanitised (`_` → `-`) and `spec.name` carries the real
PostgreSQL name unchanged. The two fields exist separately in the CRD precisely
for this. Sanitising is not allowed to be lossy, so a collision — an estate with
both `admin_api` and `admin-api`, which would map to one object and silently
create one database — is a hard failure below rather than a last-write-wins.

`databaseReclaimPolicy: retain` IS THE LOAD-BEARING FIELD
---------------------------------------------------------
The default is `delete`, which means `kubectl delete database indexer` runs
`DROP DATABASE indexer` — 9.4 GB, no confirmation, no undo. `retain` makes
deleting the Kubernetes object orphan the real database instead, which is the
same choice, for the same reason, as `reclaimPolicy: Retain` on the StorageClass
holding it.
"""
import argparse
import importlib
import pathlib
import re
import sys

NETWORKS = {
    # network → (namespace, cluster name)
    #
    # The cluster is called `postgres` in both, matching the compose service
    # name so the 57 DSNs need no rewriting; see the header of
    # k8s/database/20-cluster-mainnet.yaml. The namespaces are the two compose
    # PROJECT names, unchanged, so every runbook and dashboard that names one
    # goes on being right.
    "mainnet": ("cloudsforge-estate", "postgres"),
    "testnet": ("cf-testnet", "postgres"),
}

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--network", required=True, choices=sorted(NETWORKS), help="which network's namespace to emit for")
parser.add_argument("--sql", default="compose/estate/initdb.sql", help="the source of truth")
parser.add_argument("--owner", default="cloudsforge", help="the role that owns every database (there is only one)")
parser.add_argument("--out", help="write here instead of stdout")
args = parser.parse_args()

namespace, cluster = NETWORKS[args.network]

sql_path = pathlib.Path(args.sql)
if not sql_path.exists():
    sys.exit(f"FAIL: no SQL at {sql_path}. Refusing to emit a database list from nothing.")

# ── THE HEADER MUST NOT DEPEND ON HOW THIS WAS INVOKED ───────────────────────
#
# The generated file names its source. If that name were `args.sql` verbatim,
# running this by hand from the repo root (`compose/estate/initdb.sql`) and
# running it from CI with an absolute path would produce DIFFERENT BYTES for the
# same databases — and `check-k8s-databases-match-initdb.py` compares bytes, so
# it would fail on a file nobody had touched. A guard that fails when nothing is
# wrong gets switched off, and then it is not guarding anything.
try:
    sql_label = sql_path.resolve().relative_to(pathlib.Path(__file__).resolve().parent.parent).as_posix()
except ValueError:
    # A source outside the repository — only ever a test or a one-off. Name it
    # as given rather than inventing a relative path that would not resolve.
    sql_label = str(sql_path)

# ── PARSED, NOT GUESSED AT ───────────────────────────────────────────────────
#
# Line-anchored and comment-stripped rather than a bare substring search,
# because `initdb.sql` is two thirds prose and the word "CREATE DATABASE"
# appears inside its comments — "a database for it would be an empty one that
# nothing ever opens", and the paragraph explaining why `hub-api` deliberately
# has none. A tolerant match would create `hub-api` because the file explains
# why it must not exist, which is a very funny bug to have in production.
statements = []
for raw in sql_path.read_text().split("\n"):
    line = raw.split("--", 1)[0].strip()
    if not line:
        continue
    match = re.match(r"^CREATE\s+DATABASE\s+([A-Za-z_][A-Za-z0-9_]*)\s*;$", line, re.IGNORECASE)
    if match:
        # ── FOLDED TO LOWERCASE, BECAUSE POSTGRESQL DOES ────────────────────
        #
        # An UNQUOTED identifier is case-folded to lowercase by the server, so
        # `CREATE DATABASE Foo;` creates a database called `foo`. `spec.name` on
        # the CRD is not SQL — CNPG quotes it — so emitting `Foo` verbatim would
        # ask for `"Foo"`, which is a DIFFERENT database from the `foo` compose
        # would have made. Both would then exist, one empty, and the service
        # would connect to whichever its DSN happened to spell.
        #
        # Every name in initdb.sql is already lowercase, so this changes nothing
        # today. It is here so that the day one is not, the two systems still
        # mean the same database. Folding before the duplicate check below is
        # also what makes `Foo` and `foo` collide loudly instead of silently.
        statements.append(match.group(1).lower())
    elif re.search(r"\bCREATE\s+DATABASE\b", line, re.IGNORECASE):
        # Not survivable-by-skipping. A CREATE DATABASE this cannot parse is
        # either a quoted identifier, a `WITH` clause carrying an encoding or a
        # template, or a typo — and each of those is a database that would exist
        # under compose and silently not exist here. Better to stop.
        sys.exit(
            f"FAIL: {sql_path} has a CREATE DATABASE this cannot parse:\n"
            f"       {line}\n"
            f"       Expected `CREATE DATABASE <unquoted_identifier>;` and nothing else. If the estate\n"
            f"       now needs a WITH clause, teach this script about it rather than letting the\n"
            f"       database quietly not exist on Kubernetes."
        )

if not statements:
    sys.exit(f"FAIL: {sql_path} creates no databases. That is not a parse result worth trusting.")

duplicates = sorted({name for name in statements if statements.count(name) > 1})
if duplicates:
    sys.exit(f"FAIL: {sql_path} creates these more than once: {', '.join(duplicates)}")

# ── THE ADOPTED TESTNET DATABASES ────────────────────────────────────────────
#
# `docs/network-consolidation.md` §6. A consolidated service serves both estates
# from one pod and holds a SECOND database, `<db>_testnet`, in the mainnet
# cluster. Those were created by `scripts/k8s-db-adopt-testnet.sh` with a plain
# `CREATE DATABASE`, which is how the cutover had to work — but it left them
# outside CloudNativePG entirely.
#
# That is the exact rot this file's own header warns about, one level up. Before
# this, `kubectl get database` reported 30 of 30 healthy while TWENTY-TWO
# databases the estate depends on were declared by nothing: a cluster rebuilt
# from these manifests would have come up without them, and twenty-two services
# would have refused every testnet request on an estate that looked fine.
#
# The list is imported from `k8s-render.py` rather than restated here. Two lists
# of which services are consolidated would drift, and drift between two lists
# that are each individually correct is the defect this whole plan kept
# producing.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
_render = importlib.import_module("k8s_render_shim")
adopted: list[str] = []
if args.network == "mainnet":
    declared = set(statements)
    for svc in sorted(_render.CONSOLIDATED_SERVICES - _render.SINGLE_DATABASE_SERVICES):
        db = svc.replace("-", "_")
        if db in declared:
            adopted.append(f"{db}_testnet")

names = sorted(statements + adopted)

# ── THE POSTGRES NAME AND THE KUBERNETES NAME ────────────────────────────────
#
# See the header. `_` is legal in one and not the other, so the object gets a
# sanitised name and `spec.name` keeps the real one. Collisions are fatal: two
# databases mapping to one object would create one database and report success.
k8s_names = {}
for name in names:
    k8s_name = name.replace("_", "-")
    if not re.match(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", k8s_name):
        sys.exit(
            f"FAIL: database `{name}` does not survive sanitisation — `{k8s_name}` is still not a\n"
            f"      valid Kubernetes object name (lowercase alphanumeric and '-', starting and\n"
            f"      ending alphanumeric). Rename the database or teach this script the mapping;\n"
            f"      do NOT let it be skipped, because a skipped database is a service that cannot\n"
            f"      connect and a manifest that claims otherwise."
        )
    if k8s_name in k8s_names:
        sys.exit(
            f"FAIL: `{name}` and `{k8s_names[k8s_name]}` both sanitise to the Kubernetes object\n"
            f"      name `{k8s_name}`. Applying both would create ONE object and therefore ONE\n"
            f"      database, with the second silently overwriting the first and `kubectl apply`\n"
            f"      reporting success. Rename one of them in {sql_path}."
        )
    k8s_names[k8s_name] = name

lines = [
    f"# GENERATED by scripts/k8s-render-databases.py from {sql_label} — do not hand-edit.",
    "#",
    f"# Network:   {args.network}",
    f"# Namespace: {namespace}",
    f"# Cluster:   {cluster}",
    f"# Databases: {len(names)}",
    "#",
    "# Regenerate with:",
    f"#   ./scripts/k8s-render-databases.py --network {args.network} --out k8s/database/21-databases-{args.network}.yaml",
    "#",
    "# `initdb.sql` remains the source of truth and carries the reasoning for each",
    "# database — read it, not this file, to find out why a service has its own.",
    "#",
    "# Every entry is `databaseReclaimPolicy: retain`, so deleting one of these objects",
    "# ORPHANS the database rather than dropping it. The default is `delete`, and on",
    "# `indexer` that default is a 9.4 GB `DROP DATABASE` with no confirmation.",
]

renamed = sorted((k, v) for k, v in k8s_names.items() if k != v)
if renamed:
    lines += [
        "#",
        "# NOTE: `metadata.name` is NOT the database name for every entry below. Kubernetes",
        "# object names are RFC 1123 subdomains and cannot contain `_`, which PostgreSQL",
        "# allows. `spec.name` is always the real database. Affected here:",
    ] + [f"#   object {k}  ->  database {v}" for k, v in renamed]

for name in names:
    k8s_name = name.replace("_", "-")
    lines += [
        "---",
        "apiVersion: postgresql.cnpg.io/v1",
        "kind: Database",
        "metadata:",
        # The KUBERNETES object name — sanitised, and not necessarily the
        # database's name. `spec.name` below is the one PostgreSQL sees.
        f"  name: {k8s_name}",
        f"  namespace: {namespace}",
        "  labels:",
        f"    online.cloudsforge.network: {args.network}",
        "spec:",
        # The real PostgreSQL database name, verbatim from initdb.sql.
        f"  name: {name}",
        f"  owner: {args.owner}",
        "  cluster:",
        f"    name: {cluster}",
        "  ensure: present",
        "  databaseReclaimPolicy: retain",
    ]

out = "\n".join(lines) + "\n"
if args.out:
    pathlib.Path(args.out).write_text(out)
    print(f"wrote {args.out}: {len(names)} database(s) for {args.network}", file=sys.stderr)
else:
    sys.stdout.write(out)
