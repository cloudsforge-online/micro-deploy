#!/usr/bin/env bash
# Put the EMBER chain's two read surfaces in the cluster: the index and the verifier.
#
#   ./scripts/k8s-hearth-devkit.sh --network testnet
#   ./scripts/k8s-hearth-devkit.sh --network testnet --dry-run
#   ./scripts/k8s-hearth-devkit.sh --network mainnet   # refuses; see below
#
# ── WHY A SCRIPT AND NOT A PLAIN `kubectl apply -f` ──────────────────────────
#
# `k8s/hearth-devkit/60-devkit.yaml` carries one value it cannot know and three
# claims nothing else checks. This is where both are settled, BEFORE the pods
# that would hide the difference start.
#
#   the chain id   `docker-compose.hearth-devkit.yml` writes it as `${CF_HEARTH_
#                  CHAIN_ID:?…}` — a hard failure, never a default, because the
#                  image defaults to mainnet's 7411 and an index quietly
#                  following the wrong chain is confidently wrong about every
#                  balance rather than visibly broken. A committed manifest
#                  cannot express `:?`, so the value is read here from
#                  `compose/<network>.env` — the same one statement per
#                  environment compose reads — and its absence is fatal here
#                  exactly as it is there.
#
#   the pin        The manifest and the compose file each name an image by SHA.
#                  Two files claiming which build answers "is this source
#                  verified" is one file too many unless something compares
#                  them; this does, byte for byte.
#
#   the upstreams  The gateway reaches these two through `CF_EXPLORER_INDEX_
#                  UPSTREAM` and `CF_VERIFY_UPSTREAM`. `k8s-gateway.sh` checks
#                  every router upstream against a real Service — but it reads
#                  `url: "http://name:port"` LITERALS, and these two are
#                  `{{ env … }}` templates, so they are the one pair its guard
#                  skips by design. Checked here instead, against the Services
#                  this file is about to create.
#
#   the env keys   Every `HEARTH_*` the compose file sets must appear in the
#                  manifest. A variable added there and forgotten here would
#                  otherwise ship as an image default nobody chose.
#
# ── WHY `--network mainnet` REFUSES ──────────────────────────────────────────
#
# `compose/mainnet.env` deliberately does not carry `CF_HEARTH_CHAIN_ID`, and
# `compose/testnet.env` says why above its own copy: the devkit reaching 7411 is
# a decision from phase F of `docs/ecosystem/39-forge-exchange.md` that somebody
# has to make, not a default that arrives with a copied file. So mainnet's five
# `rpc.<apex>` devkit routes — /api, /verify, /contracts, /compilers,
# /contract/* — answer 502 today on the LIVE COMPOSE ESTATE (measured against
# production, 2026-08-19: /api → 502, /verify → 502). This cluster reproduces
# that state rather than quietly inventing a chain id, so the migration
# regresses nothing and fixes nothing it was not asked to fix.
#
# To ship it on mainnet: add `CF_HEARTH_CHAIN_ID=7411` to `compose/mainnet.env`
# in a commit that says why, and re-run this with `--network mainnet`. Nothing
# else here needs changing — the manifest is already network-independent.
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

NETWORK=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$NETWORK" in
  mainnet) NAMESPACE="cloudsforge-estate" ;;
  testnet) NAMESPACE="cf-testnet" ;;
  *) echo "usage: $0 --network mainnet|testnet [--dry-run]" >&2; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

MANIFEST="$ROOT/k8s/hearth-devkit/60-devkit.yaml"
COMPOSE="$ROOT/compose/docker-compose.hearth-devkit.yml"
NETENV="$ROOT/compose/$NETWORK.env"
case "$NETWORK" in
  mainnet) TRAEFIK_ENV="$ROOT/compose/env/traefik.env" ;;
  testnet) TRAEFIK_ENV="$ROOT/compose/env/traefik.testnet.env" ;;
esac

for f in "$MANIFEST" "$COMPOSE" "$NETENV" "$TRAEFIK_ENV"; do
  [ -f "$f" ] || fail "$f is missing"
done

# Same guard as k8s-deploy.sh and k8s-gateway.sh, and for the same reason: on at
# least one machine that reaches this repository the default kubectl context is
# somebody else's live cluster. Node identity, not context name.
EXPECTED_NODE=${EXPECTED_NODE:-cf-k8s}
NODES="$(kubectl get nodes -o name 2>&1 | tr '\n' ' ' | sed 's/ *$//')"
[ "$NODES" = "node/$EXPECTED_NODE" ] || fail "this is not the CloudsForge cluster (expected node/$EXPECTED_NODE, got ${NODES:-<unreachable>})"

say "network:   $NETWORK"
say "namespace: $NAMESPACE"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fail "namespace $NAMESPACE does not exist"

# ── THE CHAIN ID ─────────────────────────────────────────────────────────────
#
# Whole lines, then the field before the first `=`. Never `grep -o`: it retries
# at successive offsets within a line, so `^` can match mid-value and a fragment
# of a credential comes back looking like a variable name.
CHAIN_LINE="$(grep -m1 '^CF_HEARTH_CHAIN_ID=' "$NETENV" || true)"
CHAIN_ID="${CHAIN_LINE#*=}"
if [ -z "$CHAIN_ID" ]; then
  say ""
  fail "compose/$NETWORK.env does not set CF_HEARTH_CHAIN_ID, so there is no chain id to give these two services.
      That absence is deliberate on mainnet — see the comment above CF_HEARTH_CHAIN_ID in compose/testnet.env,
      and phase F of docs/ecosystem/39-forge-exchange.md. \`docker compose\` refuses here for the same reason
      (\`\${CF_HEARTH_CHAIN_ID:?…}\`), and mainnet's rpc.<apex> devkit routes 502 on the live compose estate today.
      Nothing is applied. To ship it: add CF_HEARTH_CHAIN_ID=7411 to compose/mainnet.env in a commit that says why."
fi
case "$CHAIN_ID" in
  ''|*[!0-9]*) fail "CF_HEARTH_CHAIN_ID in compose/$NETWORK.env is not a number. The image wants the id EIP-155 binds signatures to, not a network name." ;;
esac
say "chain id:  $CHAIN_ID  (from compose/$NETWORK.env)"

# ── THE PIN ──────────────────────────────────────────────────────────────────
#
# Trimmed to the reference itself so indentation and the `image:` key cannot
# make two identical pins look different.
say ""
for svc in hearth-explorer-api hearth-verify; do
  C="$(grep -m1 "image: ghcr.io/cloudsforge-online/$svc:" "$COMPOSE" | sed 's/.*image: *//' | tr -d '\r')"
  M="$(grep -m1 "image: ghcr.io/cloudsforge-online/$svc:" "$MANIFEST" | sed 's/.*image: *//' | tr -d '\r')"
  [ -n "$C" ] || fail "$COMPOSE names no image for $svc"
  [ -n "$M" ] || fail "$MANIFEST names no image for $svc"
  [ "$C" = "$M" ] || fail "the pin for $svc differs between the compose file and the manifest.
      compose:  $C
      manifest: $M
      One of them is a claim about which build answered a verification request. They have to agree."
  say "pin:       $M"
done

# ── THE ENV KEYS ─────────────────────────────────────────────────────────────
#
# Every HEARTH_* the compose file sets must be set here too. The failure this
# prevents is silent: a new variable added to the compose file ships in this
# cluster as whatever the image defaults to, chosen by nobody.
say ""
COMPOSE_KEYS="$(grep -hE '^ +HEARTH_[A-Z0-9_]+:' "$COMPOSE" | sed 's/^ *//; s/:.*//' | sort -u)"
missing=""
for k in $COMPOSE_KEYS; do
  grep -q "^ *- name: $k\$" "$MANIFEST" || missing="$missing $k"
done
say "env keys:  $(printf '%s\n' "$COMPOSE_KEYS" | grep -c .) set by the compose file"
[ -z "$missing" ] || fail "the manifest does not set:$missing — each would fall back to an image default nobody chose."

# ── THE UPSTREAMS ────────────────────────────────────────────────────────────
#
# The gateway's two templated upstreams, compared against the Services this
# manifest declares. VALUES ARE NEVER PRINTED: the traefik env file is read into
# a variable, split, and only the derived name and port — which are also in the
# manifest, in the open — are ever shown.
say ""
check_upstream() {
  var="$1"; want_svc="$2"; want_port="$3"
  line="$(grep -m1 "^$var=" "$TRAEFIK_ENV" || true)"
  [ -n "$line" ] || fail "$TRAEFIK_ENV does not set $var. The router that reaches $want_svc is wrapped in {{ if env \"$var\" }}, so it would simply not exist and the path would fall through to the JSON-RPC node."
  val="${line#*=}"; val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  val="$(printf '%s' "$val" | tr -d '\r')"
  rest="${val#http://}"
  [ "$rest" != "$val" ] || fail "$var is not an http:// URL. Expected http://$want_svc:$want_port — the name a Service in $NAMESPACE resolves."
  rest="${rest%%/*}"
  got_svc="${rest%%:*}"; got_port="${rest##*:}"
  [ "$got_svc:$got_port" = "$want_svc:$want_port" ] || fail "$var does not name $want_svc:$want_port, which is what this manifest creates.
      Nothing else checks this pair — k8s-gateway.sh reads url: literals and skips {{ env }} templates — so a
      mismatch here is a 502 behind a gateway that reports healthy. Fix whichever of the two is wrong."
  grep -q "{name: p$want_port, port: $want_port, targetPort: $want_port}" "$MANIFEST" \
    || fail "the manifest declares no Service port $want_port, but $var addresses one."
  say "upstream:  $var -> $want_svc:$want_port  (env file and manifest agree)"
}
check_upstream CF_EXPLORER_INDEX_UPSTREAM hearth-explorer-api 9647
check_upstream CF_VERIFY_UPSTREAM         hearth-verify       9648

# The index calls the verifier directly, by a name that is a Service here too.
grep -q 'value: http://hearth-verify:9648' "$MANIFEST" \
  || fail "the manifest does not point HEARTH_VERIFY_URL at hearth-verify:9648. Without it getsourcecode answers \"not verified\" for every address, including the verified ones."

# ── THE CHAIN CREDENTIAL ─────────────────────────────────────────────────────
#
# KEY ONLY. EMBER_RPC_URL carries the chain host, which is itself a secret_vars
# entry, so the value is never read here — only its presence.
say ""
if kubectl get secret estate-tokens -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl get secret estate-tokens -n "$NAMESPACE" \
    -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' | grep -qx 'EMBER_RPC_URL' \
    || fail "secret/estate-tokens has no EMBER_RPC_URL key. Both pods reference it with optional: false and will not start. Re-run ./scripts/k8s-secrets.py --network $NETWORK --apply"
  say "secret:    estate-tokens/EMBER_RPC_URL present"
else
  fail "secret/estate-tokens does not exist. Run ./scripts/k8s-secrets.py --network $NETWORK --apply"
fi

if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "--dry-run: nothing applied."
  exit 0
fi

# ── APPLY ────────────────────────────────────────────────────────────────────
#
# Two substitutions, both of placeholders the committed manifest carries on
# purpose: the chain id (see the header) and the network label, which is
# descriptive — nothing selects on it — but wrong is worse than absent when an
# operator is filtering pods by network during an incident.
say ""
sed -e "s|value: 'CHAIN_ID_UNSET'|value: '$CHAIN_ID'|g" \
    -e "s|online.cloudsforge.network: unset|online.cloudsforge.network: $NETWORK|g" \
    "$MANIFEST" | kubectl apply -n "$NAMESPACE" -f -

say ""
for d in hearth-explorer-api hearth-verify; do
  kubectl rollout status "deployment/$d" -n "$NAMESPACE" --timeout=180s || {
    kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/name=$d" \
      -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .status.containerStatuses}}{{if .state.waiting}}  {{$p}}: {{.state.waiting.reason}} — {{.state.waiting.message}}{{"\n"}}{{end}}{{end}}{{end}}'
    fail "$d did not become ready"
  }
done

say ""
say "The dev kit is serving inside $NAMESPACE on chain $CHAIN_ID."
say "The gateway reaches it at hearth-explorer-api:9647 and hearth-verify:9648, which is"
say "rpc$( [ "$NETWORK" = mainnet ] && echo '.cloudsforge.online' || echo '.testnet.cloudsforge.online')/api, /verify, /contracts, /compilers and /contract/*."
say ""
say "The index walks the chain from genesis on a cold volume; /api answers before it"
say "has finished, with fewer transactions per address than it will have in a minute."
