#!/usr/bin/env bash
# Copy the estate's databases from the compose host into the Kubernetes clusters.
#
#   ./scripts/k8s-db-import.sh --network mainnet --rehearse
#   ./scripts/k8s-db-import.sh --network mainnet --cutover
#
# RUN THIS ON THE k3s VM (cf-k8s / 192.168.1.171), not on a laptop. It needs
# kubectl against the local cluster and ssh to the compose host, and routing a
# 10 GB stream through a third machine would double the transfer for nothing.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE SAME COMMAND REHEARSES AND CUTS OVER, ON PURPOSE
# ══════════════════════════════════════════════════════════════════════════════
#
# `--rehearse` runs against the LIVE compose estate while it is still serving.
# `--cutover` runs after it has been stopped. Nothing else differs — same dump,
# same restore, same verification. The only thing `--cutover` adds is a refusal
# to proceed if the source is still accepting writes, because a dump taken from
# a live server is a snapshot of a moving target: consistent within each
# database (pg_dump uses one transaction) but NOT consistent ACROSS the 30, and
# this estate posts a ledger entry in one database for an event recorded in
# another.
#
# That is exactly why the rehearsal exists and why it is not a dry run. It
# produces a real, restorable copy AND a real number for how long the cutover
# takes, measured on this hardware with this data. A maintenance window
# estimated rather than measured is how a "ten minute" cutover becomes ninety.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY DUMP/RESTORE AND NOT STREAMING REPLICATION
# ══════════════════════════════════════════════════════════════════════════════
#
# `pg_basebackup` plus a replication slot would cut the window to a promotion.
# It also requires the source to be reachable on 5432, and the compose postgres
# publishes no port at all — deliberately. Getting there means a socat bridge or
# an ssh tunnel into a database holding every credential in the estate, standing
# for the length of the migration, on a host reached through Windows.
#
# The estate has no real users (see estate-has-no-real-users), so the thing that
# would justify that exposure — an unacceptable maintenance window — does not
# apply. A measured window of minutes is worth more than a shorter one bought
# with a temporary hole into the database.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE TRANSFER PATH, AND THE ONE MEASUREMENT IT RESTS ON
# ══════════════════════════════════════════════════════════════════════════════
#
#   VM  ──ssh──>  Windows  ──wsl──>  docker exec  ──>  pg_dump -Fc  ──stdout──┐
#   VM  <────────────────────── raw binary over ssh ─────────────────────────┘
#
# Raw binary, not base64. That was tested rather than assumed on 2026-08-19:
# 10 MB of /dev/urandom checksummed inside WSL, streamed back over this exact
# channel, sha256 identical on arrival and byte count exact. Base64 would have
# cost 33% on a 10 GB transfer to defend against a corruption that does not
# happen here.
#
# Two shell hazards this path is shaped around, both learned the hard way:
#
#   * A pipe written after `wsl -d Ubuntu-24.04 --` is interpreted by CMD.EXE,
#     not by WSL, and fails with "wc is not recognized". So nothing is piped on
#     the remote side; the stream is piped HERE, on the VM.
#   * `docker exec -i` consumes this script's stdin and silently eats the rest
#     of the loop. There is no `-i` below and every invocation ends in
#     `</dev/null`.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT IT REFUSES TO DO
# ══════════════════════════════════════════════════════════════════════════════
#
# It never DROPs a database and it never touches the source. `--clean
# --if-exists` drops and recreates objects INSIDE a target database, which is
# what makes a rehearsal repeatable, but the databases themselves are created by
# the `Database` CRD and outlive every run.
#
# It also refuses to start if the source holds a database Kubernetes does not
# know about. `compose/estate/initdb.sql` only runs on an empty data directory,
# so five of the estate's databases were created by hand against a running
# server — the file says so. If that happened once it can have happened again,
# and a database present on the source and absent from `21-databases-*.yaml`
# would be silently left behind by a migration that reported success.
set -euo pipefail

SOURCE_HOST="savva@192.168.1.129"     # Windows; WSL sits behind it
WSL_DISTRO="Ubuntu-24.04"
STAGE_ROOT="/var/tmp/cf-dumps"
JOBS=8                                 # parallel restore workers

# ssh from a Mac forwards LC_CTYPE="UTF-8", which is a macOS spelling no Linux
# has. Debian's `psql` is a perl wrapper, so every single invocation then prints
# eighteen lines of locale warning to stderr — enough to bury the actual output
# of a 30-database run. The VM's own LANG is already correct; drop the import.
unset LC_CTYPE || true

NETWORK=""
MODE=""
ONLY=""
KEEP_DUMPS=0
REUSE_DUMPS=0

usage() {
  cat >&2 <<'USAGE'
usage: k8s-db-import.sh --network {mainnet|testnet} {--rehearse|--cutover} [options]

  --only a,b,c    restrict to these databases (default: all of them)
  --reuse-dumps   restore from dumps already staged, do not re-transfer
  --keep-dumps    do not delete the staged dumps afterwards
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="${2:-}"; shift 2 ;;
    --rehearse) MODE="rehearse"; shift ;;
    --cutover)  MODE="cutover"; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --keep-dumps) KEEP_DUMPS=1; shift ;;
    --reuse-dumps) REUSE_DUMPS=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

case "$NETWORK" in
  mainnet) NAMESPACE="cloudsforge-estate"; SOURCE_CONTAINER="cloudsforge-estate-postgres-1" ;;
  testnet) NAMESPACE="cf-testnet";         SOURCE_CONTAINER="cf-testnet-postgres-1" ;;
  *) echo "--network must be mainnet or testnet" >&2; usage ;;
esac
[ -n "$MODE" ] || { echo "choose --rehearse or --cutover" >&2; usage; }

STAGE="$STAGE_ROOT/$NETWORK"
mkdir -p "$STAGE"
chmod 700 "$STAGE_ROOT" "$STAGE"   # dumps contain every row the estate holds

say() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# Run a command inside the source postgres container. No `-i`, stdin closed.
#
# stderr is discarded because every ssh to this host emits a three-line OpenSSH
# post-quantum warning on it, which would otherwise be indistinguishable from a
# real error. That makes an empty result the ONLY signal a query failed, so every
# caller below treats empty as fatal rather than as a value. See the cutover gate.
src_psql() {
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$SOURCE_HOST" \
    "wsl -d $WSL_DISTRO -- docker exec $SOURCE_CONTAINER psql -U cloudsforge -d ${1} -tAc \"${2}\"" \
    </dev/null 2>/dev/null | tr -d '\r'
}

# ── COUNTING ROWS EXACTLY, WHICH IS NOT WHAT THIS ORIGINALLY DID ─────────────
#
# The obvious verification is `sum(n_live_tup)` from `pg_stat_user_tables`, and
# it is worthless here. Measured on 2026-08-19, against the live estate:
#
#     mainnet identity   n_live_tup =  1,789      count(*) = 172,031
#     testnet identity   n_live_tup =      3      count(*) =  85,308
#     mainnet ledger     n_live_tup =  1,914      count(*) = 103,019
#
# Four orders of magnitude out. `n_live_tup` is a statistics-collector estimate
# that resets when the stats file is discarded — which these containers have done
# on restart — and only recovers as autovacuum gets round to each table. So the
# check would have compared one meaningless number against another and called any
# agreement success. It would have passed a restore that dropped every row of a
# table autovacuum had not visited on either side.
#
# So: an exact count of every user table, summed. It costs 4 seconds on `indexer`
# (12,467,789 rows across 15 tables, measured), and under a second everywhere
# else, which is nothing against a 10 GB transfer.
#
# Built with `||` rather than `format()` ON PURPOSE. `format()` needs `%I`, and
# this query crosses cmd.exe on the Windows host, which expands `%` even inside
# double quotes. `||`, `()`, `''` and `<>` were all tested across that path and
# survive; `%` is the one that would not.
ROWS_SQL="select coalesce(sum((xpath('/row/c/text()', query_to_xml('select count(*) as c from ' || quote_ident(schemaname) || '.' || quote_ident(relname), false, true, '')))[1]::text::bigint), 0) from pg_stat_user_tables"

# ── PREFLIGHT ────────────────────────────────────────────────────────────────
# Everything that can be known before a single byte moves is checked before a
# single byte moves. A migration that fails halfway leaves two half-populated
# databases and no clear statement of which.
say "preflight: $NETWORK ($MODE)"

command -v pg_restore >/dev/null || fail "pg_restore is not installed on this VM"
CLIENT_MAJOR="$(pg_restore --version | sed -E 's/.* ([0-9]+).*/\1/')"
[ "$CLIENT_MAJOR" -ge 17 ] || fail \
  "pg_restore is major $CLIENT_MAJOR but the servers are 17. An older pg_restore cannot read a
      newer dump, and the error it gives ('unsupported version in file header') reads like a
      corrupt transfer rather than a version problem."

kubectl get cluster postgres -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "no CNPG cluster 'postgres' in namespace $NAMESPACE — apply k8s/database first"
PHASE="$(kubectl get cluster postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
[ "$PHASE" = "Cluster in healthy state" ] || fail "target cluster is '$PHASE', not healthy"

ssh -o ConnectTimeout=15 -o BatchMode=yes "$SOURCE_HOST" \
  "wsl -d $WSL_DISTRO -- docker inspect -f '{{.State.Running}}' $SOURCE_CONTAINER" </dev/null 2>/dev/null \
  | grep -q true || fail "source container $SOURCE_CONTAINER is not running"

# ── THE DATABASE LIST, AND THE CROSS-CHECK THAT MATTERS ──────────────────────
# Kubernetes' list comes from the CRDs, which are generated from initdb.sql. The
# source's list is whatever is actually there. They are compared because they
# have been known to differ.
K8S_DBS="$(kubectl get database -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.spec.name}{"\n"}{end}' | sort)"
SRC_DBS="$(src_psql postgres "select datname from pg_database where not datistemplate and datname not in ('postgres','app') order by 1")"
[ -n "$SRC_DBS" ] || fail "could not list databases on the source"

ORPHANS="$(comm -13 <(echo "$K8S_DBS") <(echo "$SRC_DBS"))"
if [ -n "$ORPHANS" ]; then
  fail "the source has databases Kubernetes does not know about:
$(echo "$ORPHANS" | sed 's/^/        /')

      initdb.sql runs only on an empty data directory, so databases created by hand
      against a running server exist on the source and in no manifest. Migrating without
      them would silently leave their data behind on a host about to be decommissioned.
      Add the CREATE DATABASE to compose/estate/initdb.sql, regenerate, apply, re-run."
fi

MISSING="$(comm -23 <(echo "$K8S_DBS") <(echo "$SRC_DBS"))"
[ -n "$MISSING" ] && say "note: declared but absent on the source, will be left empty: $(echo "$MISSING" | tr '\n' ' ')"

if [ -n "$ONLY" ]; then
  DBS="$(echo "$ONLY" | tr ',' '\n' | sed '/^$/d' | sort)"
  UNKNOWN="$(comm -23 <(echo "$DBS") <(echo "$SRC_DBS"))"
  [ -n "$UNKNOWN" ] && fail "--only names databases not on the source: $(echo "$UNKNOWN" | tr '\n' ' ')"
else
  DBS="$(comm -12 <(echo "$K8S_DBS") <(echo "$SRC_DBS"))"
fi
DB_COUNT="$(echo "$DBS" | wc -l | tr -d ' ')"

# ── THE CUTOVER GATE ─────────────────────────────────────────────────────────
# In --cutover the source must be quiet. Measured as client backends other than
# this script's own connection: the estate runs one pool per service, so a
# stopped estate has none and a running one has dozens.
if [ "$MODE" = "cutover" ]; then
  BACKENDS="$(src_psql postgres "select count(*) from pg_stat_activity where backend_type='client backend' and pid<>pg_backend_pid()")"
  # Empty is NOT zero. src_psql discards stderr, so a query that failed for any
  # reason — container stopped mid-run, ssh refused, psql syntax — returns "".
  # Defaulting that to 0 would have read a broken probe as "the source is quiet"
  # and waved through the one gate protecting against a torn, cross-database
  # inconsistent dump. The check exists to be believed, so it fails closed.
  case "$BACKENDS" in
    ''|*[!0-9]*) fail "could not count client backends on the source (got: '${BACKENDS}').
      This gate is the only thing standing between --cutover and a dump taken from a
      live server. It will not assume quiet just because it could not ask." ;;
  esac
  if [ "$BACKENDS" -gt 0 ]; then
    fail "--cutover but the source still has $BACKENDS client backend(s) connected.

      A dump taken while the estate is writing is consistent within each database and NOT
      across them, and this estate posts a ledger entry in one database for an event
      recorded in another. Stop the estate first, then re-run. Use --rehearse to take a
      copy while it is live."
  fi
  say "source is quiet: 0 client backends"
fi

say "databases to migrate: $DB_COUNT"

# ── THE TARGET CONNECTION: STRAIGHT AT THE POD ───────────────────────────────
#
# This script runs ON the k3s node, so the pod network (10.42.0.0/24) is a local
# route. The primary's pod IP is therefore directly connectable and there is no
# reason to put a proxy in front of it.
#
# It was written with `kubectl port-forward` first, which is the reflexive
# answer, and that turned out to be actively wrong rather than merely redundant.
# Measured 2026-08-19: the forwarder served ONE connection, and when that client
# disconnected normally it died —
#
#     Handling connection for 55432
#     E0819 ... an error occurred forwarding 55432 -> 5432: ...
#         read tcp4 127.0.0.1:41152->127.0.0.1:5432: read: connection reset by peer
#     error: lost connection to pod
#
# — after which every later connection got "Connection refused". The failure
# surfaced as `port-forward ... never became usable`, blaming the setup for
# something that had worked and then collapsed, which is the kind of error
# message that sends you debugging the wrong end.
#
# Even had it been stable it would be the wrong shape: `pg_restore -j 8` opens
# eight concurrent connections, and port-forward would funnel all eight through
# one userspace proxy hop for a 10 GB restore.
#
# The cost of connecting directly is that a pod IP is not stable across a
# restart. It is resolved once, here, and if the pod moves mid-run the restore
# fails loudly on a refused connection rather than quietly writing somewhere
# else — which is the right failure.
POD_IP="$(kubectl get pod -n "$NAMESPACE" \
  -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].status.podIP}')"
[ -n "$POD_IP" ] || fail "could not find the primary pod's IP in namespace $NAMESPACE"

# The password comes out of the Secret into this process's environment. NOT onto
# a command line, where `ps` would show it to anything else on the box, and NOT
# into a file that an interrupted run could leave behind.
PGPASSWORD="$(kubectl get secret pg-cloudsforge -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
export PGPASSWORD
export PGHOST="$POD_IP" PGPORT=5432 PGUSER=cloudsforge

cleanup() { [ "$KEEP_DUMPS" = "1" ] || rm -rf "$STAGE"; }
trap cleanup EXIT

psql -d postgres -tAc 'select 1' >/dev/null 2>&1 \
  || fail "the target primary at $POD_IP:5432 did not answer"
say "connected to the target primary at $POD_IP:5432"

# ── THE LOOP ─────────────────────────────────────────────────────────────────
RUN_START=$(date +%s)
printf '\n%-16s %10s %8s %8s %10s %s\n' DATABASE DUMP_BYTES DUMP_S REST_S ROWS RESULT
FAILED=""
DRIFTED=""

for db in $DBS; do
  dump="$STAGE/$db.dump"

  # ── DUMP ──
  # -Fc (custom) rather than -Fd (directory): a single stream that crosses ssh
  # in one pass, and pg_restore can still parallelise reading it. -Fd would dump
  # in parallel but produces a directory, which cannot be streamed and would
  # need staging space inside the container.
  # -Z1: the link is gigabit LAN and the source CPU is shared with the live
  # estate, so light compression moves more bytes per second than heavy.
  d0=$(date +%s)
  if [ "$REUSE_DUMPS" = "1" ] && [ -s "$dump" ]; then
    dump_s="reused"
  else
    # stderr goes to a LOG, not to /dev/null. pg_dump's exit code does propagate
    # back through cmd.exe and wsl.exe (verified: a dump of a nonexistent database
    # returns 1, and psql returns 2), so a failure is caught either way — but the
    # code alone says "it failed" and the log says why, and this runs unattended
    # against 30 databases. The first three lines of each log are OpenSSH's
    # post-quantum warning, which is noise and not a problem.
    if ! ssh -o ConnectTimeout=15 -o BatchMode=yes "$SOURCE_HOST" \
        "wsl -d $WSL_DISTRO -- docker exec $SOURCE_CONTAINER pg_dump -U cloudsforge -Fc -Z1 -d $db" \
        </dev/null > "$dump.partial" 2>"$STAGE/$db.dump.log"; then
      rm -f "$dump.partial"; FAILED="$FAILED $db"
      printf '%-16s %10s %8s %8s %10s %s\n' "$db" - - - - "DUMP FAILED"; continue
    fi
    # Renamed only on success, so an interrupted run cannot leave a truncated
    # dump that --reuse-dumps would later restore as if it were complete.
    mv "$dump.partial" "$dump"
    dump_s=$(( $(date +%s) - d0 ))
  fi
  chmod 600 "$dump"
  bytes=$(stat -c%s "$dump")

  # ── RESTORE ──
  # --no-owner/--no-privileges: every object on the source is owned by
  # `cloudsforge` and there are no extra grants (measured across all 31
  # databases), so reproducing ownership adds nothing — and the target role is
  # deliberately not a superuser, which is what would be needed to assign
  # ownership to anyone else.
  # --clean --if-exists: makes a re-run replace rather than collide, which is
  # what lets the rehearsal be repeated and then repeated once more at cutover.
  r0=$(date +%s)
  if pg_restore --no-owner --no-privileges --clean --if-exists \
       -j "$JOBS" -d "$db" "$dump" >"$STAGE/$db.restore.log" 2>&1; then
    result="ok"
  else
    # pg_restore exits non-zero for warnings as well as errors. The log decides.
    if grep -qE '^pg_restore: error:' "$STAGE/$db.restore.log"; then
      result="RESTORE FAILED"; FAILED="$FAILED $db"
    else
      result="ok (warnings)"
    fi
  fi
  rest_s=$(( $(date +%s) - r0 ))

  # ── VERIFY ──
  # Not "did it exit zero" — an EXACT row count from each side. See ROWS_SQL
  # above for why the obvious `n_live_tup` version of this was worse than no
  # check at all.
  src_rows="$(src_psql "$db" "$ROWS_SQL" | tr -d ' ')"
  tgt_rows="$(psql -d "$db" -tAc "$ROWS_SQL" 2>/dev/null | tr -d ' ')"

  case "${src_rows}${tgt_rows}" in
    ''|*[!0-9]*)
      # One of the two counts did not come back. Never silently accepted: an
      # unanswerable question is not a passed check.
      result="$result / ROWS UNREADABLE ${src_rows:-?} vs ${tgt_rows:-?}"
      case "$FAILED" in *" $db"*) ;; *) FAILED="$FAILED $db" ;; esac ;;
    *)
      if [ "$src_rows" != "$tgt_rows" ]; then
        delta=$(( tgt_rows - src_rows ))
        # ── WHY A MISMATCH IS FATAL IN ONE MODE AND EXPECTED IN THE OTHER ────
        #
        # In --cutover the source is provably quiet (the gate above refuses
        # otherwise), so the two numbers describe the same fixed data and any
        # difference is data that did not arrive. Fatal.
        #
        # In --rehearse the source is LIVE and being written to throughout, so
        # the source is counted some minutes after its own dump was taken and is
        # legitimately ahead. Failing on that would make every rehearsal red and
        # teach the next person to ignore the result, which is worse than not
        # checking. It is reported as drift and summarised at the end.
        #
        # Except when the target is empty and the source is not. No amount of
        # live drift explains zero rows arriving, in either mode.
        if [ "$MODE" = "cutover" ] || { [ "$tgt_rows" = "0" ] && [ "$src_rows" != "0" ]; }; then
          result="$result / ROWS $src_rows vs $tgt_rows"
          case "$FAILED" in *" $db"*) ;; *) FAILED="$FAILED $db" ;; esac
        else
          result="$result / drift $(printf '%+d' "$delta")"
          DRIFTED="$DRIFTED $db"
        fi
      fi ;;
  esac

  printf '%-16s %10s %8s %8s %10s %s\n' "$db" "$bytes" "$dump_s" "$rest_s" "${tgt_rows:-?}" "$result"
done

RUN_S=$(( $(date +%s) - RUN_START ))
printf '\n'
say "$DB_COUNT database(s) in ${RUN_S}s"

if [ "$MODE" = "rehearse" ]; then
  cat <<EOF

  That ${RUN_S}s is the measured length of the $NETWORK cutover window on this
  hardware, with this data, plus however long stopping and starting the estate
  takes. It was taken against a LIVE source, so the copy is not
  cross-database consistent and must not be treated as the migration.
EOF
  if [ -n "$DRIFTED" ]; then
    cat <<EOF

  Row counts moved during the rehearsal on:$DRIFTED
  That is the estate still writing, not a bad restore — the source was counted
  after its own dump was taken. At --cutover the source is quiet and ANY
  difference is a failure.
EOF
  fi
fi

if [ -n "$FAILED" ]; then
  fail "these databases did not import cleanly:$FAILED
      Logs are in $STAGE/<db>.restore.log (re-run with --keep-dumps to retain them)."
fi

say "all clear"
