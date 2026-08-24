#!/usr/bin/env bash
# Copy one testnet database into the mainnet cluster as `<db>_testnet`.
#
#   ./scripts/k8s-db-adopt-testnet.sh --db agora --rehearse
#   ./scripts/k8s-db-adopt-testnet.sh --db agora --adopt
#   ./scripts/k8s-db-adopt-testnet.sh --db agora --drop      # undo a rehearsal
#
# RUN THIS ON THE k3s VM (192.168.1.171). Both clusters are pods in the local
# cluster; routing the stream through a laptop would cross the network twice
# for nothing.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHAT THIS IS FOR
# ══════════════════════════════════════════════════════════════════════════════
#
# `docs/network-consolidation.md` §6 step 2. One pod is going to serve both
# estates, and §2.2 says the two are kept apart by DATABASE NAME inside one
# cluster: `agora` and `agora_testnet`, same postgres, same role, different
# `datname`. This moves the second one into place.
#
# It does NOT touch the source. `cf-testnet`'s cluster keeps its copy, still
# served by its own pod, until the router is repointed and the deployment is
# scaled to zero — which is the rollback, and which is why the source must not
# be a moved thing but a copied one.
#
# ══════════════════════════════════════════════════════════════════════════════
# REHEARSE FIRST, AND THE DIFFERENCE IS ONE REFUSAL
# ══════════════════════════════════════════════════════════════════════════════
#
# `--rehearse` copies from the LIVE testnet database while it is still serving.
# `--adopt` refuses unless the testnet deployment for that service is already at
# zero replicas, because a dump of a database still taking writes is a snapshot
# of a moving target — and the writes that land after the snapshot are lost to
# the copy that is about to become authoritative.
#
# Everything else is identical: same dump, same restore, same verification. The
# rehearsal produces a real, queryable copy and a real number for how long the
# freeze has to last. A window estimated rather than measured is how a "two
# minute" cutover becomes twenty.
#
# ══════════════════════════════════════════════════════════════════════════════
# WHY `--role` AND NOT `--no-owner` ALONE
# ══════════════════════════════════════════════════════════════════════════════
#
# Both clusters use the one estate role (`cloudsforge`, see
# [[estate-one-postgres-role]]). Restoring as `postgres` with `--no-owner`
# leaves every table owned by `postgres`, and the service — which connects as
# `cloudsforge` — then reads fine and cannot ALTER anything, so the failure
# arrives at the next migration rather than at the restore. `--role=cloudsforge`
# makes pg_restore `SET ROLE` before it creates anything, so ownership is right
# at the moment it is written.
#
# ══════════════════════════════════════════════════════════════════════════════
# `kubectl exec -i` ON THE RESTORE SIDE IS DELIBERATE
# ══════════════════════════════════════════════════════════════════════════════
#
# The house rule is to drop `-i` and append `</dev/null`, because an exec that
# inherits the caller's stdin silently eats it. Here the pipe INTO the pod is
# the whole point, so `-i` stays on the restore and the dump side gets the
# `</dev/null` instead.
set -euo pipefail

MAIN_NS=cloudsforge-estate
TEST_NS=cf-testnet
PG=postgres-1
ROLE=cloudsforge

db=""; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --db)       db="$2"; shift 2 ;;
    --rehearse) mode=rehearse; shift ;;
    --adopt)    mode=adopt; shift ;;
    --drop)     mode=drop; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$db" ]   || { echo "--db is required" >&2; exit 2; }
[ -n "$mode" ] || { echo "one of --rehearse / --adopt / --drop is required" >&2; exit 2; }

target="${db}_testnet"

say() { printf '  %s\n' "$*"; }

# ── The service whose deployment must be frozen for --adopt ───────────────────
# The database name and the deployment name differ in exactly one way across the
# estate: underscores for hyphens (`admin_api` is `admin-api`).
svc="${db//_/-}"

if [ "$mode" = drop ]; then
  echo "dropping ${target} from ${MAIN_NS} — this destroys the COPY, never the source"
  kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${target}\" WITH (FORCE)" </dev/null
  say "gone. ${TEST_NS}/${db} is untouched, as it was throughout."
  exit 0
fi

echo "adopting ${TEST_NS}/${db}  →  ${MAIN_NS}/${target}   (${mode})"

# ── The freeze, checked rather than assumed ───────────────────────────────────
if [ "$mode" = adopt ]; then
  replicas=$(kubectl get deploy "$svc" -n "$TEST_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "absent")
  if [ "$replicas" = "absent" ]; then
    say "no ${svc} deployment in ${TEST_NS} — nothing is writing to it"
  elif [ "$replicas" != "0" ]; then
    echo "REFUSED: ${TEST_NS}/${svc} still has ${replicas} replica(s)." >&2
    echo "  A dump taken while it writes loses every write after the snapshot, to a copy" >&2
    echo "  that is about to become the authoritative one. Scale it to zero first:" >&2
    echo "    kubectl scale deploy/${svc} -n ${TEST_NS} --replicas=0" >&2
    exit 1
  else
    say "${TEST_NS}/${svc} is at zero replicas — the source is frozen"
  fi
fi

# ── Source facts, recorded BEFORE the copy so the comparison means something ──
# `n_live_tup` is an ESTIMATE maintained by the stats collector, and a database
# that has not been written to since its last vacuum reports whatever it last
# saw — which for these is often the value from before the rows arrived. Both
# sides get ANALYZE, so the two numbers are the same KIND of number.
kubectl exec -n "$TEST_NS" "$PG" -c postgres -- psql -U postgres -d "$db" -c "ANALYZE" </dev/null >/dev/null
src_tables=$(kubectl exec -n "$TEST_NS" "$PG" -c postgres -- psql -U postgres -d "$db" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" </dev/null | tr -d '[:space:]')
src_rows=$(kubectl exec -n "$TEST_NS" "$PG" -c postgres -- psql -U postgres -d "$db" -tAc \
  "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables" </dev/null | tr -d '[:space:]')
src_size=$(kubectl exec -n "$TEST_NS" "$PG" -c postgres -- psql -U postgres -tAc \
  "select pg_size_pretty(pg_database_size('${db}'))" </dev/null | tr -d '[:space:]')
say "source: ${src_tables} tables, ~${src_rows} live rows, ${src_size}"

# ── A fresh target every time. A restore over a half-populated one is the ─────
#    worst outcome available: it succeeds, and the extra rows are invisible.
kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 \
  -c "DROP DATABASE IF EXISTS \"${target}\" WITH (FORCE)" </dev/null >/dev/null
kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE \"${target}\" OWNER ${ROLE}" </dev/null >/dev/null
say "created ${target}, owned by ${ROLE}"

started=$(date +%s)
# `-i` on the restore because the pipe into the pod IS the intent; `</dev/null`
# on the dump because it must not inherit this script's stdin.
kubectl exec -n "$TEST_NS" "$PG" -c postgres -- pg_dump -U postgres -Fc --no-acl "$db" </dev/null \
  | kubectl exec -i -n "$MAIN_NS" "$PG" -c postgres -- \
      pg_restore -U postgres -d "$target" --no-owner --role="$ROLE" --no-acl --exit-on-error
elapsed=$(( $(date +%s) - started ))
say "restored in ${elapsed}s"

# ── Verify against the numbers taken before, not against "it did not error" ───
dst_tables=$(kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -d "$target" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'" </dev/null | tr -d '[:space:]')
kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -d "$target" -c "ANALYZE" </dev/null >/dev/null
dst_rows=$(kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -d "$target" -tAc \
  "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables" </dev/null | tr -d '[:space:]')
notmine=$(kubectl exec -n "$MAIN_NS" "$PG" -c postgres -- psql -U postgres -d "$target" -tAc \
  "select count(*) from pg_tables where schemaname='public' and tableowner<>'${ROLE}'" </dev/null | tr -d '[:space:]')

say "target: ${dst_tables} tables, ~${dst_rows} live rows, ${notmine} not owned by ${ROLE}"

fail=0
[ "$src_tables" = "$dst_tables" ] || { echo "MISMATCH: ${src_tables} tables in, ${dst_tables} out" >&2; fail=1; }
[ "$notmine" = "0" ] || { echo "MISMATCH: ${notmine} table(s) not owned by ${ROLE}" >&2; fail=1; }
# Live-tuple counts are estimates on both sides; a gap wider than 1% is a real
# difference rather than statistics drift.
if [ "$src_rows" -gt 0 ]; then
  delta=$(( src_rows > dst_rows ? src_rows - dst_rows : dst_rows - src_rows ))
  if [ $(( delta * 100 )) -gt "$src_rows" ]; then
    echo "MISMATCH: ~${src_rows} rows in, ~${dst_rows} out" >&2; fail=1
  fi
fi
[ "$fail" = 0 ] || exit 1

say "verified"
if [ "$mode" = rehearse ]; then
  echo
  echo "REHEARSAL ONLY. ${target} exists and matches, and nothing points at it yet."
  echo "The freeze for the real run has to cover ${elapsed}s of copy plus the rollout."
  echo "Undo with:  $0 --db ${db} --drop"
fi
