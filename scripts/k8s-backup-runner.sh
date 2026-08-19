#!/usr/bin/env bash
# Put the backup runner in the cluster — and prove its three host inputs are real first.
#
#   ./scripts/k8s-backup-runner.sh --network mainnet
#   ./scripts/k8s-backup-runner.sh --network testnet --dry-run
#   ./scripts/k8s-backup-runner.sh --build              # rebuild the image, then stop
#
# ── WHY THIS IS A SCRIPT AND NOT `kubectl apply -f` ──────────────────────────
#
# Three of this deployable's inputs live on the NODE rather than in the cluster,
# and all three fail quietly when they are wrong:
#
#   /srv/cloudsforge-backups            the estate's only recovery point
#   ~/dev/cloudsforge/miner-keys        sealed coinbase keystores + passphrase
#   the image, in containerd's k8s.io namespace, since nothing publishes it
#
# `type: Directory` and `imagePullPolicy: Never` do make each of them a hard
# failure — but the failure arrives as a pod event several seconds after an
# apply that printed `configured`, which is exactly the shape of deploy that
# gets walked away from. This checks them first, by name, and says which one.
#
# The mode and ownership checks are not decoration either. The container runs as
# uid 1000 with no capabilities; a destination owned by root is a pod that starts
# and then fails its canary write, which reads as a backup fault rather than a
# permissions one.
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

NETWORK=""
DRY_RUN=0
BUILD_ONLY=0

# The host paths the manifest names. Kept here as constants rather than
# arguments: a backup destination passed on a command line is a backup
# destination somebody can typo, and micro-org#434 is what one wrong path cost.
DESTINATION="/srv/cloudsforge-backups"
MINER_KEYS="$ROOT/../miner-keys"
MANIFEST="$ROOT/k8s/backup/60-backup-runner.yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --build)   BUILD_ONLY=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "$MANIFEST" ] || fail "$MANIFEST is missing"

# ── THE IMAGE TAG COMES OUT OF THE MANIFEST, NOT OUT OF THIS SCRIPT ──────────
#
# One source of truth. If the tag lived here too, a rebuild could bump this copy
# and leave the manifest pointing at an image that still exists — so the pod
# would keep running yesterday's code with today's commit in the log, which is
# the failure nobody catches because everything is green.
IMAGE="$(sed -n 's/^ *image: \(cloudsforge\.local\/backup-runner:.*\)$/\1/p' "$MANIFEST" | head -1)"
[ -n "$IMAGE" ] || fail "could not read the image tag out of $MANIFEST"

# ── BUILD ────────────────────────────────────────────────────────────────────
#
# BuildKit, driving k3s's own containerd, so the result is already in the store
# kubelet reads from: no registry, no push, no pull to fail. See
# /etc/buildkit/buildkitd.toml on the VM, and the manifest header for why this
# deployable has no published image at all.
build_image() {
  local rt="$ROOT/../runtime"
  [ -d "$ROOT/backup" ] || fail "$ROOT/backup is missing, so there is nothing to build"
  [ -d "$rt/packages" ] || fail "$rt is missing; the Dockerfile needs it as the named context runtimepkgs"
  command -v buildctl >/dev/null 2>&1 || [ -x /usr/local/bin/buildctl ] \
    || fail "buildctl is not installed. See the migration runbook: BuildKit is VM host state, not a repo artefact."
  systemctl is-active --quiet buildkit.service \
    || fail "buildkit.service is not running (sudo systemctl start buildkit)"

  # The tag the CURRENT sources would produce. Compared against the manifest so
  # that a source change which nobody re-pinned is loud rather than silent.
  local dsha rsha expected
  dsha="$(git -C "$ROOT" log -1 --format=%h -- backup 2>/dev/null || echo unknown)"
  rsha="$(git -C "$rt" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  expected="cloudsforge.local/backup-runner:${dsha}-${rsha}"

  say "building $IMAGE"
  say "  context      $ROOT/backup"
  say "  runtimepkgs  $rt"
  sudo /usr/local/bin/buildctl build \
    --frontend dockerfile.v0 \
    --local context="$ROOT/backup" \
    --local dockerfile="$ROOT/backup" \
    --local runtimepkgs="$rt" \
    --opt context:runtimepkgs=local:runtimepkgs \
    --output "type=image,name=${IMAGE}" \
    || fail "the build failed (see above)"

  if [ "$expected" != "$IMAGE" ] && [ "$dsha" != "unknown" ] && [ "$rsha" != "unknown" ]; then
    say ""
    say "NOTE: the sources now hash to a different tag than the manifest pins."
    say "        manifest  $IMAGE"
    say "        sources   $expected"
    say "      The image was built under the MANIFEST's tag, so this deploy is"
    say "      self-consistent — but update $MANIFEST to $expected and rebuild,"
    say "      or the tag stops describing what is inside it."
  fi
}

if [ "$BUILD_ONLY" = 1 ]; then
  build_image
  exit 0
fi

case "$NETWORK" in
  mainnet) NAMESPACE="cloudsforge-estate" ;;
  testnet) NAMESPACE="cf-testnet" ;;
  *) echo "usage: $0 --network mainnet|testnet [--dry-run] | --build" >&2; exit 2 ;;
esac

# Same guard as every other k8s script here, and for the same reason: on at
# least one machine that reaches this repository the default kubectl context is
# somebody else's live cluster. Node identity, not context name.
EXPECTED_NODE=${EXPECTED_NODE:-cf-k8s}
NODES="$(kubectl get nodes -o name 2>&1 | tr '\n' ' ' | sed 's/ *$//')"
[ "$NODES" = "node/$EXPECTED_NODE" ] || fail "this is not the CloudsForge cluster (expected node/$EXPECTED_NODE, got ${NODES:-<unreachable>})"

say "network:   $NETWORK"
say "namespace: $NAMESPACE"
say "image:     $IMAGE"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fail "namespace $NAMESPACE does not exist"

# ── THE THREE HOST INPUTS ────────────────────────────────────────────────────

# 1. The destination. `type: Directory` already refuses an absent one; this says
#    so in a sentence instead of a pod event, and additionally checks the two
#    things Kubernetes will not: who owns it, and whether the filesystem clears
#    the floor `src/disk.ts` enforces.
say ""
say "destination: $DESTINATION"
[ -d "$DESTINATION" ] || fail "$DESTINATION does not exist. Create it as uid 1000, mode 0700 — and see micro-org#434 before choosing a different path."
owner="$(stat -c '%u:%g' "$DESTINATION")"
[ "$owner" = "1000:1000" ] || fail "$DESTINATION is owned by $owner, but the container runs as 1000:1000 with no capabilities. Its canary write would fail."
mode="$(stat -c '%a' "$DESTINATION")"
[ "$mode" = "700" ] || say "  NOTE: mode is $mode, not 700. The estate's backup sets are readable by more than their owner."

# 100 GiB is `src/disk.ts`'s floor — "a destination that reports less than a
# floor no real backup disk would be under is a destination that is not the
# backup disk". Checked here so a too-small filesystem is a refusal to deploy
# rather than a refusal to run.
total_kib="$(df -Pk "$DESTINATION" | awk 'NR==2 {print $2}')"
free_kib="$(df -Pk "$DESTINATION" | awk 'NR==2 {print $4}')"
[ "$total_kib" -ge 104857600 ] || fail "$DESTINATION is on a filesystem of ${total_kib} KiB, under the 100 GiB floor src/disk.ts enforces. The mount is not what it should be."
say "  filesystem: $((total_kib / 1048576)) GiB total, $((free_kib / 1048576)) GiB free"
# min_free_bytes is 100 GiB in the catalogue. Below it the runner refuses to
# START A RUN, which is a healthy pod that never backs anything up — the exact
# shape of failure micro-org#434 was about. Warn while it is still a warning.
if [ "$free_kib" -lt 104857600 ]; then
  say "  WARNING: free space is under the catalogue's min_free_bytes (100 GiB)."
  say "           The pod will be Ready and every run will refuse. Prune, or give"
  say "           the destination its own disk — see the migration runbook."
fi

# 2. The miner keys. Read-only, and read at all only when BACKUP_AGE_RECIPIENT
#    is set. The runner prefers `<env>/coinbase-keystore.json` over the
#    plaintext `coinbase-key.json` the seal of micro-org#206 replaced.
say ""
say "miner keys:  $MINER_KEYS"
[ -d "$MINER_KEYS" ] || fail "$MINER_KEYS does not exist. The sealed coinbase keystores live there; without it the miner key is silently left out of every set."
keystore="$MINER_KEYS/$NETWORK/coinbase-keystore.json"
[ -f "$keystore" ] || say "  NOTE: $keystore is absent — this network's coinbase key will NOT be in the set."
[ -f "$MINER_KEYS/secrets/coinbase-passphrase" ] || say "  NOTE: no secrets/coinbase-passphrase — a keystore without one recovers nothing."

# 3. The image. `imagePullPolicy: Never` means a missing image is
#    ErrImageNeverPull with no explanation of where it should have come from.
say ""
if sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -qx "$IMAGE"; then
  say "image:       present in containerd (namespace k8s.io)"
else
  fail "$IMAGE is not in the node's image store, and imagePullPolicy is Never so nothing will fetch it.
       Build it:  $0 --build"
fi

# ── THE ONE THING THAT DIFFERS BETWEEN THE NETWORKS ──────────────────────────
#
# BACKUP_ENVIRONMENT is half of the cross-environment restore refusal: the other
# half is written inside each artefact, and `src/manifest.ts` compares them. It
# is not a parameter anywhere in the runner because on 2026-08-05 the thing that
# failed — twice — was a parameter that was ignored.
#
# Keeping it (and INSTANCE_ID, which only labels metrics) in a ConfigMap is what
# lets one manifest serve both namespaces. BACKUP_COMPOSE_PROJECT is not here:
# it is the namespace, read through the downward API.
say ""
say "ConfigMap backup-runner-env:"
say "  BACKUP_ENVIRONMENT=$NETWORK"
say "  INSTANCE_ID=backup-runner-$NETWORK"

if [ "$DRY_RUN" = 1 ]; then
  say ""
  say "--dry-run: stopping before any change. Server-side validation of the manifest:"
  kubectl apply -n "$NAMESPACE" -f "$MANIFEST" --dry-run=server
  exit 0
fi

kubectl create configmap backup-runner-env -n "$NAMESPACE" \
  --from-literal="BACKUP_ENVIRONMENT=$NETWORK" \
  --from-literal="INSTANCE_ID=backup-runner-$NETWORK" \
  --dry-run=client -o yaml | kubectl apply -n "$NAMESPACE" -f -

kubectl apply -n "$NAMESPACE" -f "$MANIFEST"

say ""
say "waiting for the rollout..."
# Generous, because the startup probe covers `src/disk.ts` proving the
# destination is real: a canary write, a read-back and a statfs floor, before
# /readyz answers at all.
kubectl rollout status -n "$NAMESPACE" deploy/backup-runner --timeout=180s \
  || fail "the rollout did not complete. kubectl -n $NAMESPACE describe pod -l app.kubernetes.io/name=backup-runner"

say ""
kubectl get -n "$NAMESPACE" deploy/backup-runner svc/backup-runner

# The reason the Service name and port are load-bearing: Prometheus already has
# a target pointing at them, generated from the compose host `backup-runner:4130`.
say ""
say "Prometheus scrapes backup-runner.$NAMESPACE.svc.cluster.local:4130/metrics"
say "Check it turned up:"
say "  kubectl get --raw \"/api/v1/namespaces/cf-telemetry/services/prometheus:9090/proxy/api/v1/targets?state=any\""
