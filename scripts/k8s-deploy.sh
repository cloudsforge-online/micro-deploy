#!/usr/bin/env bash
# Apply the rendered estate to the cluster, in the order the estate needs.
#
#   ./scripts/k8s-deploy.sh --network mainnet
#   ./scripts/k8s-deploy.sh --network testnet --dry-run
#   ./scripts/k8s-deploy.sh --network mainnet --rerun-migrations
#   ./scripts/k8s-deploy.sh --network mainnet --wave 50
#   ./scripts/k8s-deploy.sh --network mainnet --batch 0     # all at once
#   ./scripts/k8s-deploy.sh --network mainnet --no-hold     # cutover: start everything
#
# Before the cutover `settlement` and `beacon` are HELD BACK AUTOMATICALLY —
# see THE HOLD IS NOT OPT-IN. `--no-hold` is what starts them, and it is a
# cutover step, not a convenience.
#
# ── WHY WAVES, WHEN KUBERNETES IS SUPPOSED TO SELF-ORDER ─────────────────────
#
# Kubernetes converges: apply everything at once and it eventually sorts itself
# out. That is true and it is not enough here, for two reasons the compose file
# already knew about.
#
# The migrators. 33 services carry `restart: no` and run a schema migration,
# and 31 services declare `depends_on: … condition: service_completed_successfully`
# against one. Kubernetes has no equivalent — a Deployment cannot wait for a Job.
# Applied together, every service starts against a schema that is not there yet,
# crash-loops, and the deploy "succeeds" while the estate serves 500s. So the
# Jobs are a wave, and the wave is waited on.
#
# The volumes. A Deployment whose PVC does not exist stays Pending with an event
# nobody reads. Applying the claims first turns that into a Bound check here.
#
# ── AND WHY THE MIGRATOR WAVE IS ONE WAVE, NOT THIRTY-THREE ──────────────────
#
# Measured, not assumed: no migrator declares a dependency on anything but
# postgres. There is no migrator that needs another migrator's tables, so there
# is no ordering to preserve inside wave 30 and all 32 Jobs are applied at once.
# If that ever stops being true the symptom is a Job failing on a missing table,
# which this script prints in full rather than summarising.
#
# ── AND WHY WAVE 50 IS APPLIED IN BATCHES ────────────────────────────────────
#
# Every service here is Node, and the most expensive twenty seconds of a Node
# container's life are its first: module graph, JIT warm-up, a TLS handshake to
# postgres, a schema check. Applying 49 Deployments at once is not 49 services'
# worth of load, it is 49 cold starts' worth arriving together.
#
# Measured on this node with both estates present — 99 services starting at once
# drove load average to 155 on 8 vCPU. Nothing was short of memory (5.6Gi free);
# the run queue was simply longer than the scheduler could clear, and the first
# things to lose were the pods with the least CPU to spare: CoreDNS, whose
# timeouts made migrators fail on `getaddrinfo EAI_AGAIN postgres`, the CNPG
# controller, and k3s's own Traefik. A starved control plane then keeps the
# estate from converging, so the overload is self-sustaining rather than a spike
# that passes.
#
# The same 49, applied eight at a time, converged in seven minutes at a peak
# load of 2.6. The batching is not a capacity workaround — it is the difference
# between a queue the node drains and a herd it cannot.
#
# A batch that does not converge is REPORTED AND LEFT RUNNING, not waited on
# forever: a service that is slow to start is usually waiting for one that has
# not been applied yet, so blocking the batches behind it is how a soluble wait
# becomes a deadlock. The whole-wave check at the end is what decides success.
#
# ── THE ORDER IS THE FILENAMES ───────────────────────────────────────────────
#
# 20-pvc → 30-migrate-jobs → 40-services → 50-deployments. `k8s-render.py` names
# them so that sorted order IS apply order, so this script does not carry a
# second copy of the ordering that could disagree with the renderer's.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

NETWORK=""
DRY_RUN=0
RERUN_MIGRATIONS=0
ONLY_WAVE=""
# Unset rather than empty: empty is a legitimate value meaning "hold nothing",
# and it has to be distinguishable from "the operator said nothing", which is
# what selects the default below. See THE HOLD IS NOT OPT-IN.
HOLD=
HOLD_SET=0
HOLD_DEFAULT="settlement,beacon"
JOB_TIMEOUT=${JOB_TIMEOUT:-900}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-900}
# Deployments per batch in wave 50, and how long one batch is waited on before
# the next is applied. `--batch 0` restores the old all-at-once behaviour, which
# is right on a node with cores to spare and wrong on this one.
BATCH=${BATCH:-8}
BATCH_WAIT=${BATCH_WAIT:-240}

while [ $# -gt 0 ]; do
  case "$1" in
    --network)           NETWORK="${2:-}"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --rerun-migrations)  RERUN_MIGRATIONS=1; shift ;;
    --wave)              ONLY_WAVE="${2:-}"; shift 2 ;;
    --hold)              HOLD="${2:-}"; HOLD_SET=1; shift 2 ;;
    --no-hold)           HOLD=""; HOLD_SET=1; shift ;;
    --batch)             BATCH="${2:-}"; shift 2 ;;
    -h|--help)           sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$NETWORK" in
  mainnet) NAMESPACE="cloudsforge-estate" ;;
  testnet) NAMESPACE="cf-testnet" ;;
  *) echo "usage: $0 --network mainnet|testnet [--dry-run] [--rerun-migrations] [--wave N]" >&2; exit 2 ;;
esac

DIR="k8s/estate/$NETWORK"
say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ── THE GUARD THAT COMES BEFORE EVERYTHING ───────────────────────────────────
#
# `kubectl` obeys whatever kubeconfig it finds, and on at least one machine that
# reaches this repository the default context is a live Azure cluster belonging
# to somebody else's product. Every command below is an `apply` or a `delete`;
# aimed at the wrong cluster they are not recoverable by re-running with the
# right one.
#
# Context NAMES are not identity — k3s calls its context `default`, and so does
# half the world. The node name is. One node called `cf-k8s` is this cluster and
# nothing else is, so that is what gets checked.
EXPECTED_NODE=${EXPECTED_NODE:-cf-k8s}
NODES="$(kubectl get nodes -o name 2>&1 | tr '\n' ' ' | sed 's/ *$//')"
if [ "$NODES" != "node/$EXPECTED_NODE" ]; then
  say "FAIL: this is not the CloudsForge cluster."
  say "      expected exactly: node/$EXPECTED_NODE"
  say "      got:              ${NODES:-<no nodes; kubectl could not reach a cluster>}"
  say ""
  say "      Refusing to apply. Set EXPECTED_NODE if the cluster has genuinely been"
  say "      rebuilt under a new node name — never to silence this on a machine whose"
  say "      kubeconfig points somewhere else."
  exit 1
fi

say "cluster:   $(kubectl config current-context)  (node/$EXPECTED_NODE)"
say "network:   $NETWORK"
say "namespace: $NAMESPACE"

# ── THE HOLD IS NOT OPT-IN ───────────────────────────────────────────────────
#
# `--hold settlement,beacon` used to be something the operator remembered. On
# 2026-08-19 the operator did not, and both ran for 22 minutes beside the live
# compose estate — the exact scenario the `--hold` comment below describes as a
# double-spend race. It did not fire (`outbound_transactions` newest was two
# weeks old, 0 rows created; beacon registered 2 synthetic accounts), so the
# cost was a few messages of shared Mailtrap quota. It was luck, not design: a
# safety property that depends on remembering a flag is not a safety property.
#
# So the DEFAULT is now derived from the one fact that says whether a second
# estate is live: `cf-edge/cloudflared`'s replica count, which is 0 until the
# cutover and 1 after it, and which `scripts/k8s-cloudflared.sh` already treats
# as the whole interlock. Before the cutover the hold applies by itself; after
# it, this deploy IS the estate and holding would be the wrong default.
#
# An explicit `--hold` or `--no-hold` always wins, so the deliberate case is
# still one flag away — it is only the SILENT case that changed sides.
if [ "$HOLD_SET" = 0 ]; then
  CONNECTORS="$(kubectl -n cf-edge get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  case "$CONNECTORS" in
    ""|0)
      HOLD="$HOLD_DEFAULT"
      say "hold:      $HOLD  (cf-edge/cloudflared replicas=${CONNECTORS:-<absent>} — not cut over)"
      ;;
    *)
      say "hold:      none  (cf-edge/cloudflared replicas=$CONNECTORS — this estate is live)"
      ;;
  esac
elif [ -n "$HOLD" ]; then
  say "hold:      $HOLD  (explicit)"
else
  say "hold:      none  (explicit --no-hold)"
fi

# ── PREFLIGHT ────────────────────────────────────────────────────────────────

for f in 20-pvc.yaml 30-migrate-jobs.yaml 40-services.yaml 50-deployments.yaml; do
  [ -f "$DIR/$f" ] || fail "$DIR/$f is missing. Run scripts/k8s-render.py for $NETWORK first."
done

# Every file records the release it was rendered from. They are written in one
# pass, so disagreement means a partial re-render — half the estate on one
# release and half on another, which is precisely the state a release manifest
# exists to make impossible.
RELEASES_SEEN="$(awk '/^# Release:/{print $3}' "$DIR"/*.yaml | sort -u)"
[ "$(printf '%s\n' "$RELEASES_SEEN" | wc -l | tr -d ' ')" = "1" ] || {
  say "FAIL: $DIR was rendered in more than one pass. Releases found:"
  printf '        %s\n' $RELEASES_SEEN
  fail "re-render the whole directory"
}
RELEASE="$RELEASES_SEEN"
say "release:   $RELEASE"
say ""

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fail "namespace $NAMESPACE does not exist. Apply k8s/base/00-namespaces.yaml."

# The required Secrets and ConfigMaps are READ OUT OF THE MANIFESTS rather than
# listed here, so this check cannot drift from what the pods actually reference.
# A missing one is worth catching now: `optional: false` means the pod is never
# scheduled and the only evidence is a CreateContainerConfigError on an object
# whose Deployment reports itself as merely progressing.
NEED_SECRETS="$(grep -h -A1 'secretRef:\|secretKeyRef:' "$DIR"/*.yaml | awk '/name:/{print $2}' | sort -u)"
NEED_CONFIGMAPS="$(grep -h -A1 'configMap:\|configMapRef:\|configMapKeyRef:' "$DIR"/*.yaml | awk '/name:/{print $2}' | sort -u)"

missing=""
for s in $NEED_SECRETS; do
  if kubectl get secret "$s" -n "$NAMESPACE" >/dev/null 2>&1; then
    # KEY COUNT ONLY. Never the keys, and never — under any circumstance a future
    # edit might invent — the values.
    n="$(kubectl get secret "$s" -n "$NAMESPACE" -o go-template='{{len .data}}' 2>/dev/null)"
    [ "${n:-0}" -gt 0 ] 2>/dev/null || missing="$missing secret/$s(empty)"
  else
    missing="$missing secret/$s"
  fi
done
for c in $NEED_CONFIGMAPS; do
  kubectl get configmap "$c" -n "$NAMESPACE" >/dev/null 2>&1 || missing="$missing configmap/$c"
done
if [ -n "$missing" ]; then
  say "FAIL: the manifests reference objects that do not exist:"
  for m in $missing; do say "        $m"; done
  say ""
  say "      Secrets come from scripts/k8s-secrets.py --network $NETWORK."
  say "      gateway-trust comes from scripts/k8s-estate-seed.sh --network $NETWORK."
  exit 1
fi
say "preflight: $(printf '%s\n' "$NEED_SECRETS" | wc -l | tr -d ' ') secret(s), $(printf '%s\n' "$NEED_CONFIGMAPS" | wc -l | tr -d ' ') configmap(s) present"

# Postgres. `postgres:5432` in every DATABASE_URL is the ExternalName alias in
# k8s/database/29-service-alias.yaml, not a CNPG service — CNPG names its own
# `postgres-rw`. Without the alias every migrator fails DNS at once, which reads
# like a database outage rather than a missing Service.
kubectl get service postgres -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "service/postgres (the ExternalName alias) is missing. Apply k8s/database/29-service-alias.yaml."
PHASE="$(kubectl get cluster.postgresql.cnpg.io postgres -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
case "$PHASE" in
  "Cluster in healthy state") say "preflight: postgres — $PHASE" ;;
  "") fail "no CNPG Cluster/postgres in $NAMESPACE. Apply k8s/database/20-cluster-$NETWORK.yaml." ;;
  *)  say "preflight: postgres — $PHASE"
      say "           Not healthy. The migrators will fail against it, so this stops here."
      exit 1 ;;
esac
say ""

# ── DRY RUN ──────────────────────────────────────────────────────────────────
#
# `--validate=strict` on purpose. kubectl's default mode DROPS fields the schema
# does not know instead of refusing them, which is how a malformed volume source
# survives review: it applies cleanly and mounts nothing.
if [ "$DRY_RUN" -eq 1 ]; then
  say "── dry run (server-side, strict) ────────────────────────────────────────"
  rc=0
  for f in "$DIR"/*.yaml; do
    out="$(kubectl apply -n "$NAMESPACE" -f "$f" --dry-run=server --validate=strict 2>&1)"
    if [ $? -ne 0 ]; then rc=1; say "  $(basename "$f"): REJECTED"; printf '%s\n' "$out" | sed 's/^/      /'; continue; fi
    say "  $(basename "$f"): $(printf '%s\n' "$out" | wc -l | tr -d ' ') object(s) accepted"
  done
  say ""
  [ $rc -eq 0 ] && say "Dry run clean. Nothing was changed." || say "Dry run found rejections above. Nothing was changed."
  exit $rc
fi

want_wave() { [ -z "$ONLY_WAVE" ] || [ "$ONLY_WAVE" = "$1" ]; }
# Object names sit at exactly two spaces of indent — `metadata.name` and nothing
# else in these files, because container and template names are nested deeper.
names_in() { awk '/^  name: /{print $2}' "$1"; }

# ── `--hold`, AND WHY A SECOND ESTATE IS NOT A HARMLESS COPY ─────────────────
#
# During migration this cluster runs a SECOND mainnet estate beside the live
# compose one. Its databases are copies, so most services are inert towards the
# original: they read and write their own snapshot and nothing outside notices.
#
# Two are not, because their state is not in the database at all:
#
#   settlement  — `chain.sweep`, `chain.outbound` and `treasury.watch` poll the
#                 SAME chain host and sign with the SAME custody keys. Two
#                 estates sweeping the same addresses build conflicting spends:
#                 a double-spend race on the UTXO chains, a nonce collision on
#                 EMBER. Its queue is empty today, which makes this a race that
#                 has not fired yet rather than one that cannot.
#
#   beacon      — its synthetic journeys register real accounts, and each one
#                 sends real mail through the shared Mailtrap tenant. That tier
#                 allows 150 messages a day and beacon alone already spends it,
#                 so a second copy does not degrade the estate's mail — it
#                 removes it.
#
# `--hold` leaves those Deployments UNAPPLIED rather than applied-then-scaled:
# an image pull is slower than a `kubectl scale`, so scaling afterwards would
# almost always win, and "almost always" is not a property to give a money path.
# Their Services still apply, so a caller gets a refused connection with a name
# that resolves rather than an NXDOMAIN it will cache.
#
# At cutover the live estate is stopped, the databases are re-synced, and the
# same command runs WITHOUT `--hold`. Nothing here is permanent.
held() { case ",$HOLD," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Documents are split on a bare `---`, which the renderer emits as a separator
# and never inside content — block scalars are indented, so they cannot produce
# one at column zero. A document with no `metadata.name` is the header comment
# block; it is dropped because kubectl reads a comment-only document as null.
drop_held_docs() {
  awk -v hold=",$HOLD," '
    function flush() {
      if (name != "" && index(hold, "," name ",") == 0) printf "---\n%s", buf
      buf = ""; name = ""
    }
    /^---$/ { flush(); next }
    { buf = buf $0 "\n"; if ($0 ~ /^  name: / && name == "") name = $2 }
    END { flush() }
  ' "$1"
}

# The same split, keeping a named subset instead of dropping one. Used to apply
# wave 50 a batch at a time from the one rendered file, so a batch is a slice of
# what would have been applied anyway and never a differently-rendered thing.
select_docs() {
  awk -v want=" $2 " '
    function flush() {
      if (name != "" && index(want, " " name " ")) printf "---\n%s", buf
      buf = ""; name = ""
    }
    /^---$/ { flush(); next }
    { buf = buf $0 "\n"; if ($0 ~ /^  name: / && name == "") name = $2 }
    END { flush() }
  ' "$1"
}

# ── WAVE 20: THE CLAIMS ──────────────────────────────────────────────────────
if want_wave 20; then
  say "── wave 20: volumes ─────────────────────────────────────────────────────"
  kubectl apply -n "$NAMESPACE" -f "$DIR/20-pvc.yaml" || fail "wave 20 apply failed"
  for pvc in $(names_in "$DIR/20-pvc.yaml"); do
    phase="$(kubectl get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
    say "  $pvc: $phase"
    [ "$phase" = "Bound" ] || fail "$pvc is $phase. A Deployment mounting it will sit Pending forever."
  done
  # Bound is not full. Seeding is a separate step precisely because a manifest
  # cannot express it, and an empty custody-keys is a service that starts,
  # reports ready, and holds no keys.
  say "  (content comes from scripts/k8s-estate-seed.sh — Bound does not mean seeded)"
  say ""
fi

# ── WAVE 30: THE MIGRATORS ───────────────────────────────────────────────────
#
# Job specs are immutable, so the names carry the release and a re-deploy of the
# same release re-applies an already-Complete Job as a no-op. That is the
# idempotent path and it is the common one.
#
# The two paths that are NOT no-ops need handling, because `apply` cannot fix
# either: a FAILED Job of the same name stays failed forever under apply, and a
# deliberate re-run needs the old object gone. Both are deletions, and both are
# announced.
job_states() {
  kubectl get job -n "$NAMESPACE" $1 -o go-template='{{range .items}}{{$s := "running"}}{{if .status}}{{range .status.conditions}}{{if eq .status "True"}}{{if eq .type "Complete"}}{{$s = "complete"}}{{end}}{{if eq .type "Failed"}}{{$s = "failed"}}{{end}}{{end}}{{end}}{{end}}{{.metadata.name}} {{$s}}{{"\n"}}{{end}}' 2>/dev/null
}

report_failed_job() {
  local job="$1"
  say ""
  say "  ── $job ───────────────────────────────────────────────"
  kubectl get job "$job" -n "$NAMESPACE" -o jsonpath='{range .status.conditions[*]}    {.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null
  local pods
  pods="$(kubectl get pod -n "$NAMESPACE" -l "job-name=$job" -o name 2>/dev/null)"
  for p in $pods; do
    say "    $p:"
    # A container that never started has no logs at all, and the whole reason
    # lives in the waiting state instead — so print that first, or an
    # ImagePullBackOff reads as a migrator that produced no output.
    kubectl get "$p" -n "$NAMESPACE" -o go-template='{{range .status.containerStatuses}}{{if .state.waiting}}      waiting: {{.state.waiting.reason}} — {{.state.waiting.message}}{{"\n"}}{{end}}{{if .state.terminated}}      terminated: {{.state.terminated.reason}} (exit {{.state.terminated.exitCode}}){{"\n"}}{{end}}{{end}}' 2>/dev/null
    kubectl logs "$p" -n "$NAMESPACE" --tail=40 2>&1 | sed 's/^/      /'
  done
}

if want_wave 30; then
  say "── wave 30: migrations ──────────────────────────────────────────────────"
  JOBS="$(names_in "$DIR/30-migrate-jobs.yaml" | tr '\n' ' ')"
  JOB_COUNT="$(printf '%s' "$JOBS" | wc -w | tr -d ' ')"

  if [ "$RERUN_MIGRATIONS" -eq 1 ]; then
    say "  --rerun-migrations: deleting $JOB_COUNT existing Job(s) so they run again"
    kubectl delete job -n "$NAMESPACE" $JOBS --ignore-not-found --wait=true >/dev/null 2>&1
  else
    stale="$(job_states "$JOBS" | awk '$2=="failed"{print $1}')"
    if [ -n "$stale" ]; then
      say "  these Jobs are in a Failed state from an earlier attempt; deleting so apply re-creates them:"
      for j in $stale; do say "    $j"; done
      kubectl delete job -n "$NAMESPACE" $stale --ignore-not-found --wait=true >/dev/null 2>&1
    fi
  fi

  kubectl apply -n "$NAMESPACE" -f "$DIR/30-migrate-jobs.yaml" >/dev/null || fail "wave 30 apply failed"
  say "  applied $JOB_COUNT Job(s), all in parallel — no migrator depends on another"

  started=$SECONDS
  while :; do
    states="$(job_states "$JOBS")"
    complete="$(printf '%s\n' "$states" | awk '$2=="complete"' | wc -l | tr -d ' ')"
    failed="$(printf '%s\n' "$states" | awk '$2=="failed"{print $1}')"
    elapsed=$((SECONDS - started))

    if [ -n "$failed" ]; then
      say ""
      say "  FAILED after ${elapsed}s: $(printf '%s\n' "$failed" | wc -l | tr -d ' ') of $JOB_COUNT"
      for j in $failed; do report_failed_job "$j"; done
      say ""
      fail "wave 30 did not complete. Nothing downstream was applied, so the estate is unchanged."
    fi

    [ "$complete" = "$JOB_COUNT" ] && { say "  $complete/$JOB_COUNT complete in ${elapsed}s"; break; }

    if [ "$elapsed" -ge "$JOB_TIMEOUT" ]; then
      say ""
      say "  TIMEOUT after ${elapsed}s — $complete/$JOB_COUNT complete. Still running:"
      printf '%s\n' "$states" | awk '$2!="complete"{print "    " $1}'
      fail "wave 30 timed out (JOB_TIMEOUT=${JOB_TIMEOUT}s)"
    fi

    [ $((elapsed % 15)) -lt 5 ] && say "  $complete/$JOB_COUNT complete (${elapsed}s)"
    sleep 5
  done
  say ""
fi

# ── WAVE 40: THE NAMES ───────────────────────────────────────────────────────
#
# Services before Deployments so that a pod which resolves a sibling on its very
# first request finds a name rather than an NXDOMAIN it caches.
if want_wave 40; then
  say "── wave 40: services ────────────────────────────────────────────────────"
  kubectl apply -n "$NAMESPACE" -f "$DIR/40-services.yaml" >/dev/null || fail "wave 40 apply failed"
  say "  applied $(names_in "$DIR/40-services.yaml" | wc -l | tr -d ' ') Service(s)"
  say ""
fi

# ── WAVE 50: THE ESTATE ──────────────────────────────────────────────────────
if want_wave 50; then
  say "── wave 50: deployments ─────────────────────────────────────────────────"
  ALL_DEPLOYS="$(names_in "$DIR/50-deployments.yaml")"
  DEPLOYS=""
  for d in $ALL_DEPLOYS; do held "$d" || DEPLOYS="$DEPLOYS $d"; done
  DEPLOY_COUNT="$(printf '%s' "$DEPLOYS" | wc -w | tr -d ' ')"

  if [ -n "$HOLD" ]; then
    for d in $(printf '%s\n' "$ALL_DEPLOYS"); do
      held "$d" || continue
      say "  HELD: $d — not applied"
      # A hold added between deploys has to take effect on what is already
      # running, or the flag protects only a cluster that never ran without it.
      if kubectl get deployment "$d" -n "$NAMESPACE" >/dev/null 2>&1; then
        kubectl scale deployment "$d" -n "$NAMESPACE" --replicas=0 >/dev/null 2>&1
        say "        (it existed and was running; scaled to 0)"
      fi
    done
  fi

  # `readyReplicas` alone is a trap during a rolling update: it counts the OLD
  # ReplicaSet's pods, so a Deployment reads fully ready one second after being
  # given an image that cannot start. observedGeneration and updatedReplicas are
  # what make the answer about THIS revision.
  deploy_states() {
    kubectl get deployment -n "$NAMESPACE" ${1:-$DEPLOYS} -o go-template='{{range .items}}{{.metadata.name}} {{.metadata.generation}} {{if .status}}{{or .status.observedGeneration 0}} {{or .status.updatedReplicas 0}} {{or .status.readyReplicas 0}}{{else}}0 0 0{{end}} {{or .spec.replicas 1}}{{"\n"}}{{end}}' 2>/dev/null
  }
  ready_in() { printf '%s\n' "$(deploy_states "$1")" | awk '$2==$3 && $4==$6 && $5==$6' | wc -l | tr -d ' '; }

  if [ "${BATCH:-0}" -gt 0 ] 2>/dev/null && [ "$DEPLOY_COUNT" -gt "$BATCH" ]; then
    n=0; batch=0; slice=""
    for d in $DEPLOYS; do
      slice="$slice $d"; n=$((n + 1))
      [ "$n" -lt "$BATCH" ] && continue

      batch=$((batch + 1))
      select_docs "$DIR/50-deployments.yaml" "$slice" | kubectl apply -n "$NAMESPACE" -f - >/dev/null || fail "wave 50 apply failed (batch $batch)"
      b_started=$SECONDS
      b_count="$(printf '%s' "$slice" | wc -w | tr -d ' ')"
      while [ "$(ready_in "$slice")" != "$b_count" ] && [ $((SECONDS - b_started)) -lt "$BATCH_WAIT" ]; do sleep 5; done
      say "  batch $batch: $(ready_in "$slice")/$b_count ready in $((SECONDS - b_started))s — load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
      n=0; slice=""
    done
    if [ -n "$slice" ]; then
      batch=$((batch + 1))
      select_docs "$DIR/50-deployments.yaml" "$slice" | kubectl apply -n "$NAMESPACE" -f - >/dev/null || fail "wave 50 apply failed (batch $batch)"
      say "  batch $batch: applied $(printf '%s' "$slice" | wc -w | tr -d ' ')"
    fi
    say "  applied $DEPLOY_COUNT Deployment(s) in $batch batch(es) of $BATCH"
  else
    drop_held_docs "$DIR/50-deployments.yaml" | kubectl apply -n "$NAMESPACE" -f - >/dev/null || fail "wave 50 apply failed"
    say "  applied $DEPLOY_COUNT Deployment(s)"
  fi

  started=$SECONDS
  while :; do
    states="$(deploy_states)"
    ready="$(printf '%s\n' "$states" | awk '$2==$3 && $4==$6 && $5==$6' | wc -l | tr -d ' ')"
    elapsed=$((SECONDS - started))

    [ "$ready" = "$DEPLOY_COUNT" ] && { say "  $ready/$DEPLOY_COUNT available in ${elapsed}s"; break; }

    if [ "$elapsed" -ge "$ROLLOUT_TIMEOUT" ]; then
      say ""
      say "  TIMEOUT after ${elapsed}s — $ready/$DEPLOY_COUNT available. Not ready:"
      for d in $(printf '%s\n' "$states" | awk '!($2==$3 && $4==$6 && $5==$6){print $1}'); do
        say "    $d"
        # The reason a pod is not running is almost never in the Deployment. It
        # is a waiting-state reason on the container — ImagePullBackOff,
        # CreateContainerConfigError, CrashLoopBackOff — so print that.
        kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=$d" \
          -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .status.containerStatuses}}{{if .state.waiting}}      {{$p}}: {{.state.waiting.reason}} — {{.state.waiting.message}}{{"\n"}}{{end}}{{if .state.terminated}}      {{$p}}: terminated {{.state.terminated.reason}} (exit {{.state.terminated.exitCode}}){{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null
      done
      say ""
      fail "wave 50 timed out (ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT}s). The applied Deployments are still converging; re-run --wave 50 to keep waiting."
    fi

    [ $((elapsed % 15)) -lt 5 ] && say "  $ready/$DEPLOY_COUNT available (${elapsed}s)"
    sleep 5
  done
  say ""
fi

say "Deployed $NETWORK at release $RELEASE."
if [ -n "$HOLD" ]; then
  say ""
  say "HELD BACK, and therefore NOT RUNNING: $HOLD"
  say "  This estate is incomplete until the same command runs without --hold,"
  say "  which is a cutover step: stop the compose estate, re-sync the databases,"
  say "  then deploy again with no hold."
fi
say ""
say "This brings up the services. It does NOT route traffic to them — that is the"
say "estate's own Traefik, applied separately by ./scripts/k8s-gateway.sh --network"
say "$NETWORK, which reads gateway/dynamic/ rather than any IngressRoute CRD. Until"
say "it runs, the estate is reachable only by Service name from inside the cluster."
