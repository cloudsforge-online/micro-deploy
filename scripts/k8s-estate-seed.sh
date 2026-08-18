#!/usr/bin/env bash
#
# Put content into the estate's PersistentVolumeClaims, and build the one
# ConfigMap that is a file rather than a setting.
#
#   ./scripts/k8s-estate-seed.sh --network mainnet
#   ./scripts/k8s-estate-seed.sh --network testnet --force
#
# ─── WHY THIS EXISTS AT ALL ──────────────────────────────────────────────────
#
# Under compose, three of these were bind mounts or named volumes that simply
# existed on the host. A manifest can declare a PVC but cannot fill it, and an
# empty PVC is not a visible failure: custody starts, reports ready, and holds
# no keys. So the filling is a step, it is written down, and it is checked.
#
# ─── WHY IT REFUSES A NON-EMPTY VOLUME ───────────────────────────────────────
#
# Before cutover these volumes are copies and overwriting one costs nothing.
# After cutover they are the originals — custody will have written keys here
# that exist nowhere else, and a re-run with a stale tarball would replace them
# with an older set. Since the two situations look identical from inside this
# script, it refuses to write into a volume that already has content and says
# what it found. `--force` is the operator asserting which situation it is.
set -Eeuo pipefail

NETWORK=""
FORCE=0
SEED_DIR="${SEED_DIR:-$HOME/seed}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="${2:-}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$NETWORK" in
  mainnet) NAMESPACE="cloudsforge-estate"; PROJECT="cloudsforge-estate" ;;
  testnet) NAMESPACE="cf-testnet";         PROJECT="cf-testnet" ;;
  *) echo "usage: $0 --network mainnet|testnet [--force]" >&2; exit 2 ;;
esac

# The busybox k3s already has, so seeding never waits on a registry — and never
# depends on the credential helper that makes pulls fail on the old host.
SEEDER_IMAGE="rancher/mirrored-library-busybox:1.37.0"

say() { printf '%s\n' "$*"; }

# ─── THE ONE CONFIGMAP ───────────────────────────────────────────────────────
#
# beacon's NODE_EXTRA_CA_CERTS. Public certificates only — the estate CA and the
# public roots — so a ConfigMap is the right object; a Secret would imply this
# is confidential and invite it being treated as one.
TRUST="$ROOT/gateway/certs/trust.crt"
if [ ! -f "$TRUST" ]; then
  say "FAIL: $TRUST is missing. beacon mounts it as its CA bundle and will not verify the estate's own TLS without it."
  exit 1
fi
kubectl create configmap gateway-trust -n "$NAMESPACE" \
  --from-file=trust.crt="$TRUST" --dry-run=client -o yaml | kubectl apply -n "$NAMESPACE" -f - >/dev/null
say "configmap/gateway-trust  <- gateway/certs/trust.crt  ($(grep -c 'BEGIN CERTIFICATE' "$TRUST") certificate(s))"

kubectl apply -n "$NAMESPACE" -f "$ROOT/k8s/estate/$NETWORK/20-pvc.yaml" >/dev/null
say "applied k8s/estate/$NETWORK/20-pvc.yaml"
say ""

# ─── THE VOLUMES ─────────────────────────────────────────────────────────────
#
# owner/mode mirror what `custody-keys-init` and `studio-assets-init` apply in
# the compose file, because those same Jobs run in deploy wave 30 and would
# otherwise be correcting this script's work on every deploy. Seeding as root
# and leaving it would be worse than wrong: custody starts as uid 1000, cannot
# read a root-owned keyring, and reports the vault as empty rather than as
# unreadable.
#
#   name            source                                       owner      mode
seed_one() {
  local claim="$1" kind="$2" source="$3" owner="$4" mode="$5"
  local pod="seed-$claim"

  kubectl delete pod "$pod" -n "$NAMESPACE" --ignore-not-found --wait=true >/dev/null 2>&1

  kubectl apply -n "$NAMESPACE" -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {app.kubernetes.io/name: estate-seed}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 0}
  containers:
  - name: seed
    image: $SEEDER_IMAGE
    command: ["sh", "-c", "sleep 900"]
    volumeMounts: [{name: target, mountPath: /dest}]
  volumes:
  - name: target
    persistentVolumeClaim: {claimName: $claim}
YAML

  if ! kubectl wait --for=condition=Ready "pod/$pod" -n "$NAMESPACE" --timeout=180s >/dev/null; then
    say "  FAIL: the seeder pod for $claim never became ready. The PVC is probably unbound:"
    kubectl get pvc "$claim" -n "$NAMESPACE" -o wide
    return 1
  fi

  local existing
  existing="$(kubectl exec "$pod" -n "$NAMESPACE" -- sh -c 'ls -A /dest 2>/dev/null | wc -l' </dev/null | tr -d '[:space:]')"
  if [ "$existing" != "0" ] && [ "$FORCE" -ne 1 ]; then
    say "  $claim: SKIPPED — already holds $existing entr(y|ies)."
    say "      Before cutover that means it was seeded already. After cutover it means the"
    say "      service has been writing here. Re-run with --force only if you know which."
    kubectl delete pod "$pod" -n "$NAMESPACE" --wait=false >/dev/null
    return 0
  fi

  # `kubectl exec -i` is fed from an explicit redirect on every call. Left to
  # inherit, it consumes the caller's stdin — which in a loop means the second
  # volume is seeded with whatever the first one did not read.
  if [ "$kind" = "tar" ]; then
    kubectl exec -i "$pod" -n "$NAMESPACE" -- tar xzf - -C /dest < "$source"
  else
    tar czf - -C "$source" . | kubectl exec -i "$pod" -n "$NAMESPACE" -- tar xzf - -C /dest
  fi

  kubectl exec "$pod" -n "$NAMESPACE" -- sh -c "chown -R $owner /dest && chmod $mode /dest" </dev/null
  local files
  files="$(kubectl exec "$pod" -n "$NAMESPACE" -- sh -c 'find /dest -type f | wc -l' </dev/null | tr -d '[:space:]')"
  say "  $claim: $files file(s), owner $owner, mode $mode"
  kubectl delete pod "$pod" -n "$NAMESPACE" --wait=false >/dev/null
}

status=0

# The keyring. `chmod 700` because the compose init sets 700 and custody checks
# it: a world-readable vault is refused at start rather than used.
seed_one custody-keys  tar "$SEED_DIR/${PROJECT}_custody-keys.tar.gz"  1000:1000 700 || status=1

# Generated studio artwork, served by the studio service itself.
seed_one studio-assets tar "$SEED_DIR/${PROJECT}_studio-assets.tar.gz" 1000:1000 755 || status=1

# The tessera world artwork, which was a bind mount of the checkout. Read from
# the checkout still — `CF_WORLD_ASSETS` in the network's env file selects which
# set, and the old one stays switchable exactly as it does under compose.
WORLD="$(grep -E '^CF_WORLD_ASSETS=' "$ROOT/compose/$NETWORK.env" | tail -1 | cut -d= -f2-)"
WORLD="${WORLD:-./estate/world-assets}"
WORLD_DIR="$ROOT/compose/${WORLD#./}"
if [ ! -d "$WORLD_DIR" ]; then
  say "  world-assets: FAIL — $WORLD_DIR does not exist. CF_WORLD_ASSETS names it; it is not in git."
  status=1
else
  # 0:0 and 755: mounted read-only by both consumers, so it needs to be readable
  # by whatever uid nginx runs as, and writable by nobody.
  seed_one world-assets dir "$WORLD_DIR" 0:0 755 || status=1
fi

say ""
if [ "$status" -eq 0 ]; then
  say "Seeded. Wave 30's custody-keys-init and studio-assets-init will re-assert the same"
  say "ownership on every deploy, so this and they agree by construction."
fi
exit "$status"
