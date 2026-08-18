#!/usr/bin/env bash
# Apply the rendered estate to the cluster, in the order the estate needs.
#
#   ./scripts/k8s-deploy.sh --network mainnet
#   ./scripts/k8s-deploy.sh --network testnet --dry-run
#   ./scripts/k8s-deploy.sh --network mainnet --rerun-migrations
#   ./scripts/k8s-deploy.sh --network mainnet --wave 50
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
JOB_TIMEOUT=${JOB_TIMEOUT:-900}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-900}

while [ $# -gt 0 ]; do
  case "$1" in
    --network)           NETWORK="${2:-}"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --rerun-migrations)  RERUN_MIGRATIONS=1; shift ;;
    --wave)              ONLY_WAVE="${2:-}"; shift 2 ;;
    -h|--help)           sed -n '2,12p' "$0"; exit 0 ;;
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
  DEPLOYS="$(names_in "$DIR/50-deployments.yaml" | tr '\n' ' ')"
  DEPLOY_COUNT="$(printf '%s' "$DEPLOYS" | wc -w | tr -d ' ')"
  kubectl apply -n "$NAMESPACE" -f "$DIR/50-deployments.yaml" >/dev/null || fail "wave 50 apply failed"
  say "  applied $DEPLOY_COUNT Deployment(s)"

  # `readyReplicas` alone is a trap during a rolling update: it counts the OLD
  # ReplicaSet's pods, so a Deployment reads fully ready one second after being
  # given an image that cannot start. observedGeneration and updatedReplicas are
  # what make the answer about THIS revision.
  deploy_states() {
    kubectl get deployment -n "$NAMESPACE" $DEPLOYS -o go-template='{{range .items}}{{.metadata.name}} {{.metadata.generation}} {{if .status}}{{or .status.observedGeneration 0}} {{or .status.updatedReplicas 0}} {{or .status.readyReplicas 0}}{{else}}0 0 0{{end}} {{or .spec.replicas 1}}{{"\n"}}{{end}}' 2>/dev/null
  }

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
say ""
say "This brings up the services. It does NOT route traffic to them — that is the"
say "gateway's IngressRoutes, applied separately. Until those exist the estate is"
say "reachable only from inside the cluster."
