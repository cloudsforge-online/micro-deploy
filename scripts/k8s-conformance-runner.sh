#!/usr/bin/env bash
# Put the conformance replay in the cluster, pinned to a digest — micro-org#537.
#
#   ./scripts/k8s-conformance-runner.sh
#   ./scripts/k8s-conformance-runner.sh --tag main --dry-run
#   ./scripts/k8s-conformance-runner.sh --now        # apply, then fire one replay
#
# ── WHY THIS IS A SCRIPT AND NOT `kubectl apply -f` ─────────────────────────
#
# Two of this deployable's inputs fail QUIETLY when they are wrong, and both are
# the reason the corpus went unreplayed for a fortnight without anybody noticing:
#
#   the image        a tag that resolves to nothing is an ImagePullBackOff that
#                    arrives as a pod event long after an apply printed
#                    `configured` — and a CronJob's pod events are read by
#                    nobody until somebody asks why a gate has no input.
#
#   the account      `CF_CONFORMANCE_ACCOUNT` in `estate-tokens`. Without it,
#                    five of the eight suites SKIP. The run still publishes and
#                    still clears every alert, having compared almost nothing,
#                    which is micro-org#439 restated one level down. The
#                    manifest's `optional: false` makes the pod fail rather than
#                    skip, but a pod that will not start is again a pod event.
#
# So both are checked HERE, by name, before anything is applied — and the image
# is pinned to a DIGEST, so what runs tomorrow is what was verified today.
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

NAMESPACE="cloudsforge-estate"
IMAGE="ghcr.io/cloudsforge-online/micro-conformance"
TAG="main"
DRY_RUN=0
RUN_NOW=0
MANIFEST="$ROOT/k8s/conformance/60-conformance-runner.yaml"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)     TAG="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --now)     RUN_NOW=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '  %-46s %s\n' "$1" "$2"; }

# ── MAINNET ONLY, and it is not a flag ──────────────────────────────────────
#
# There is one corpus and it was recorded against mainnet. Chain id is contract
# rather than gauge in it, so a testnet replay of THIS corpus reports a breaking
# difference that means "wrong estate" and nothing else. A `--network` argument
# here would be an invitation to produce that and read it as a defect.
echo "conformance runner -> ${NAMESPACE} (mainnet corpus; testnet needs its own)"

# ── 1. THE ACCOUNT ──────────────────────────────────────────────────────────
#
# The KEY only. Never the value, and never a length — a length narrows a guess,
# and this file is read in terminals that scroll into logs.
if ! kubectl get secret estate-tokens -n "$NAMESPACE" \
      -o jsonpath='{.data.CF_CONFORMANCE_ACCOUNT}' 2>/dev/null | grep -q .; then
  echo "::error::estate-tokens has no CF_CONFORMANCE_ACCOUNT in ${NAMESPACE}" >&2
  echo "Five of the eight suites sign in. Without an account they SKIP, the run publishes" >&2
  echo "having compared almost nothing, and every conformance alert goes green on it." >&2
  exit 1
fi
say "CF_CONFORMANCE_ACCOUNT" "present in estate-tokens"

if ! kubectl get secret estate-tokens -n "$NAMESPACE" \
      -o jsonpath='{.data.BEACON_TOKEN}' 2>/dev/null | grep -q .; then
  echo "::error::estate-tokens has no BEACON_TOKEN in ${NAMESPACE}" >&2
  echo "The runner cannot publish without it, and a replay nobody records is the defect" >&2
  echo "this deployable exists to fix (micro-org#439)." >&2
  exit 1
fi
say "BEACON_TOKEN" "present in estate-tokens"

# ── 2. beacon, WHICH IS WHERE THE ANSWER GOES ───────────────────────────────
if ! kubectl get service beacon -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "::error::no beacon Service in ${NAMESPACE} — the replay would compare and publish nowhere" >&2
  exit 1
fi
say "beacon Service" "resolvable at http://beacon:4000"

# ── 3. THE IMAGE, RESOLVED TO A DIGEST ──────────────────────────────────────
#
# curl AND NOT `docker manifest inspect`, WHICH THIS SCRIPT TRIED FIRST AND
# WHICH DOES NOT WORK WHERE IT HAS TO RUN. **The k3s VM has no docker.** k3s
# drives containerd directly, and the only Docker on the estate is the BuildKit
# host used to build the backup runner. A script whose one job is to make a
# deploy safe, that cannot run on the node it deploys to, is not a check — it is
# a step somebody skips.
#
# The registry's own HTTP API needs no daemon and no credential: every package in
# the organisation is public, which `publish-image.yml` re-checks on every
# publish. The Accept headers matter — without them the registry answers with a
# v1 manifest whose digest is NOT the one Kubernetes will pull, so the pin would
# be to something real and wrong.
registry_token="$(curl -fsSL \
  "https://ghcr.io/token?scope=repository:${IMAGE#ghcr.io/}:pull&service=ghcr.io" 2>/dev/null \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)"
digest=""
if [ -n "$registry_token" ]; then
  digest="$(curl -fsSI \
    -H "Authorization: Bearer ${registry_token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${IMAGE#ghcr.io/}/manifests/${TAG}" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p' | head -1 || true)"
fi
if [ -z "$digest" ]; then
  echo "::error::cannot resolve ${IMAGE}:${TAG} to a digest" >&2
  echo "The image is published by micro-conformance's own CI on a green push to main." >&2
  echo "Applying a floating tag instead would mean the replay that certifies a release" >&2
  echo "is not the one anybody verified." >&2
  exit 1
fi
say "image" "${TAG} -> ${digest}"

pinned="${IMAGE}@${digest}"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "--dry-run: would apply ${MANIFEST} with image ${pinned}"
  exit 0
fi

# The manifest carries the TAG so a human reading it sees a name; the digest is
# substituted here so what runs is what was resolved above. Substituted on the
# way in rather than committed, because a digest in a tracked file is a digest
# somebody has to remember to bump.
sed "s|image: ${IMAGE}:${TAG}$|image: ${pinned}|" "$MANIFEST" \
  | kubectl apply -n "$NAMESPACE" -f -

echo
kubectl get cronjob conformance-runner -n "$NAMESPACE"

if [ "$RUN_NOW" = 1 ]; then
  # Named for the operator who fired it rather than a timestamp: `--now` runs are
  # rare and always deliberate, and `kubectl get jobs` should say which were.
  job="conformance-runner-manual-$$"
  echo
  echo "firing one replay as ${job}"
  kubectl create job "$job" -n "$NAMESPACE" --from=cronjob/conformance-runner
  echo "follow it with: kubectl logs -n ${NAMESPACE} -f job/${job}"
fi
