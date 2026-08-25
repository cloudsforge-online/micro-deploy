#!/usr/bin/env bash
# Put the estate's gateway in the cluster: its files, its certificate, its pod.
#
#   ./scripts/k8s-gateway.sh --network mainnet
#   ./scripts/k8s-gateway.sh --network testnet --dry-run
#   ./scripts/k8s-gateway.sh --network mainnet --hold pool   # pool is not deployed yet
#
# ── WHAT THIS BUILDS, AND WHY IT IS A SCRIPT AND NOT FOUR MORE MANIFESTS ─────
#
# Three of the gateway's four inputs are FILES that already exist in this
# repository and on this host, and the fourth is a Secret the estate's own
# secrets loader already knows how to build:
#
#   configmap/gateway-dynamic   <- gateway/dynamic/*.yml   (208KB, tracked)
#   secret/gateway-certs        <- gateway/certs/estate.{crt,key}  (untracked)
#   secret/env-traefik          <- scripts/k8s-secrets.py, from env/traefik*.env
#   k8s/gateway/60-gateway.yaml <- the Deployment and Service
#
# Committing a second copy of the dynamic files as a rendered ConfigMap would
# create two sources of truth for 67 routers, and the copy would be the one
# nobody edits and everybody deploys. So they are read from where they live,
# every time.
#
# ── THE HASH ANNOTATION IS THE POINT OF THIS SCRIPT ──────────────────────────
#
# Traefik's file provider watches its directory, so in principle editing a route
# and re-applying the ConfigMap is enough. In practice the kubelet propagates a
# ConfigMap change to a mounted volume on its own sync period — up to a minute,
# unbounded if the kubelet is busy — so a deploy that applies and returns has
# not deployed anything yet, and the operator who curls the new route gets the
# old answer and concludes the route is wrong.
#
# Hashing the content into a pod annotation makes changed files a new pod. The
# rollout then finishes when the gateway is actually serving them.
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

NETWORK=""
DRY_RUN=0
HOLD=""
CERT_DIR="${CF_CERT_DIR:-$ROOT/gateway/certs}"

while [ $# -gt 0 ]; do
  case "$1" in
    --network)  NETWORK="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --cert-dir) CERT_DIR="${2:-}"; shift 2 ;;
    --hold)     HOLD="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
    -h|--help)  sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ── BOTH GATEWAYS LIVE IN cloudsforge-estate ─────────────────────────────────
#
# `docs/network-consolidation.md` §6.3. The thirty application services now
# serve both estates from one pod each, and a Traefik that must reach them has
# to be able to say `http://worlds:4000` and get one — which, in Kubernetes,
# means being in their namespace. The testnet gateway therefore moves here and
# is renamed, rather than staying in `cf-testnet` behind thirty CNAMEs.
#
# WHAT MAKES THIS SAFE IS THE ENTRYPOINT MIDDLEWARE, NOT THIS SCRIPT. `cf-network`
# is attached to the entrypoint (`--entrypoints.websecure.http.middlewares=`),
# so every request through this gateway is stamped `CF-Network` from its own
# `CF_EMBER_NETWORK` before any router is consulted. Two Deployments with two
# env Secrets are therefore two networks, and no router can be added that
# forgets to say which.
#
# THE DYNAMIC CONFIG AND THE CERTIFICATE ARE NOT COPIED — they are now literally
# one object each, shared by both Deployments. That was already true in content:
# measured 2026-08-25, `gateway-dynamic` and `gateway-certs` hashed identically
# in the two namespaces. Everything that differs between the estates was already
# in the env Secret, which is why this merge needs no edit to gateway/dynamic/.
case "$NETWORK" in
  mainnet) NAMESPACE="cloudsforge-estate"; GW_NAME="gateway";         GW_SECRET="env-traefik" ;;
  testnet) NAMESPACE="cloudsforge-estate"; GW_NAME="gateway-testnet"; GW_SECRET="env-traefik-testnet" ;;
  *) echo "usage: $0 --network mainnet|testnet [--dry-run]" >&2; exit 2 ;;
esac

say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Same guard as k8s-deploy.sh, and for the same reason: on at least one machine
# that reaches this repository the default kubectl context is somebody else's
# live cluster. Node identity, not context name.
EXPECTED_NODE=${EXPECTED_NODE:-cf-k8s}
NODES="$(kubectl get nodes -o name 2>&1 | tr '\n' ' ' | sed 's/ *$//')"
[ "$NODES" = "node/$EXPECTED_NODE" ] || fail "this is not the CloudsForge cluster (expected node/$EXPECTED_NODE, got ${NODES:-<unreachable>})"

say "namespace: $NAMESPACE   deployment: $GW_NAME   env: $GW_SECRET"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fail "namespace $NAMESPACE does not exist"

# ── THE DYNAMIC FILES ────────────────────────────────────────────────────────
DYN="$ROOT/gateway/dynamic"
FILES="$(find "$DYN" -maxdepth 1 -name '*.yml' | sort)"
[ -n "$FILES" ] || fail "$DYN holds no *.yml. The gateway would start, listen, and 404 every request."

# Counted, not assumed. A ConfigMap silently truncated to a subset of the files
# is a gateway that serves some surfaces and 404s the rest, which reads as an
# application fault rather than a deploy fault.
say ""
say "dynamic files:"
for f in $FILES; do
  say "  $(basename "$f")  $(wc -c <"$f" | tr -d ' ') bytes, $(grep -c '^      rule:' "$f" || true) router rule(s)"
done

# 1MiB is the etcd object ceiling and applies to the whole ConfigMap. The files
# are ~208KB today; this fails loudly at 900KB rather than letting an apply that
# has grown past the limit fail with an error about request size.
TOTAL="$(cat $FILES | wc -c | tr -d ' ')"
[ "$TOTAL" -lt 900000 ] || fail "the dynamic files total ${TOTAL} bytes, which is close to the 1MiB ConfigMap ceiling. Split them across two ConfigMaps and mount both."

# ── THE CERTIFICATE ──────────────────────────────────────────────────────────
#
# `tls.yml` names exactly these two paths, so exactly these two are mounted. The
# CA's PRIVATE key (`ca.key`) is deliberately NOT here: it signs certificates
# and the gateway only serves one. Putting it in the cluster would mean any
# future pod that can read Secrets in this namespace can mint a certificate the
# estate's own trust bundle accepts.
for n in estate.crt estate.key; do
  [ -f "$CERT_DIR/$n" ] || fail "$CERT_DIR/$n is missing. gateway/dynamic/tls.yml names it as certFile/keyFile; without it every TLS handshake fails."
done
say ""
say "certificate: $CERT_DIR/estate.crt"
# Subject and dates only. Never the key, and never the key's length — this
# prints what an unauthenticated client already sees in the handshake.
openssl x509 -in "$CERT_DIR/estate.crt" -noout -subject -enddate 2>/dev/null | sed 's/^/  /' || say "  (openssl unavailable; not verified here)"

# ── THE ENV SECRET, WHICH IS THE ONE THAT FAILS SILENTLY ─────────────────────
#
# The dynamic files are Go templates over `env`. An absent name does not error:
# `Host(``)` is a valid rule that matches no request ever sent, Traefik logs
# nothing, and the surface is simply dead behind a 404 from the catch-all. So
# the names are checked here, by name, before the pod that would hide it starts.
# CF_EMBER_NETWORK is required because `cf-network` interpolates it into the
# `CF-Network` header on EVERY request, from the entrypoint chain. Unset, the
# template renders an empty value, every request arrives at every service with
# `CF-Network: ` — and `requestNetwork()` refuses each one. That is the correct
# failure and a total outage, so it is worth catching before the pod starts
# rather than in the first request after it.
NEED="CF_API_HOST CF_WEB_SUFFIX CF_SITE_HOST CF_RPC_UPSTREAM CF_EXPLORER_INDEX_UPSTREAM CF_VERIFY_UPSTREAM CF_EMBER_NETWORK"
if kubectl get secret "$GW_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  # KEYS ONLY. The values are hostnames and upstream URLs and one of them is
  # interpolated from a `secret_vars` entry, so none of them is printed here.
  HAVE="$(kubectl get secret "$GW_SECRET" -n "$NAMESPACE" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
  missing=""
  for n in $NEED; do case " $HAVE " in *" $n "*) ;; *) missing="$missing $n" ;; esac; done
  say ""
  say "secret/$GW_SECRET: $(printf '%s' "$HAVE" | wc -w | tr -d ' ') key(s)"
  [ -z "$missing" ] || fail "secret/$GW_SECRET is missing:$missing — re-run ./scripts/k8s-secrets.py --network $NETWORK --apply"
else
  fail "secret/$GW_SECRET does not exist. Run ./scripts/k8s-secrets.py --network $NETWORK --apply"
fi

# ── EVERY UPSTREAM MUST RESOLVE, AND NOTHING ELSE CHECKS THIS ────────────────
#
# Under compose an upstream resolved because the container was ON the network:
# `ports:` only ever governed reaching it from the HOST, so six frontends that
# publish nothing — the compose file argues each case — were reachable anyway.
# Kubernetes gives a Pod no DNS name at all. Only a Service has one.
#
# That difference is invisible from every direction an operator normally looks:
# the Deployment reads 1/1, the readiness probe passes (it talks to localhost
# INSIDE the pod, so it never crosses the network that is missing), the gateway
# is healthy, and the surface answers 502. Measured on this cluster: 6 of 67
# routers were dead that way while everything reported green.
#
# So the router table is compared against the Services that actually exist,
# before the gateway that would hide the difference is applied. Deliberately
# withheld services are named with --hold, exactly as in k8s-deploy.sh; anything
# missing that was not named is a fault and stops the deploy.
say ""
UPSTREAMS="$(grep -ohE 'url: *"http://[a-z][a-z0-9-]*:[0-9]+"' $FILES \
             | sed -E 's/.*http:\/\/([a-z0-9-]+):([0-9]+)".*/\1 \2/' | sort -u)"
HAVE_SVC="$(kubectl get svc -n "$NAMESPACE" \
            -o go-template='{{range .items}}{{$n := .metadata.name}}{{range .spec.ports}}{{$n}} {{.port}}{{"\n"}}{{end}}{{end}}')"

missing=""; held=""
while read -r svc port; do
  [ -n "$svc" ] || continue
  if printf '%s\n' "$HAVE_SVC" | grep -qx "$svc $port"; then continue; fi
  case " $HOLD " in *" $svc "*) held="$held $svc:$port"; continue ;; esac
  missing="$missing $svc:$port"
done <<UPSTREAM_LIST
$UPSTREAMS
UPSTREAM_LIST

say "upstreams: $(printf '%s\n' "$UPSTREAMS" | grep -c . ) named by the router table"
[ -z "$held" ] || say "  held (--hold), will 502 until deployed: $held"
if [ -n "$missing" ]; then
  say ""
  say "  These upstreams have no Service on the port the router uses:"
  for m in $missing; do say "    $m"; done
  fail "$(printf '%s' "$missing" | wc -w | tr -d ' ') upstream(s) would 502 behind a gateway that reports healthy.
      A Deployment is not addressable in Kubernetes — only a Service is. If the compose
      service publishes no port, scripts/k8s-render.py takes the port from its healthcheck;
      re-render and re-apply wave 40. If the absence is deliberate, name it with --hold."
fi

# The hash covers everything the pod mounts, so a certificate renewal restarts
# the gateway too — Traefik reloads dynamic files on its own but not the file a
# TLS store already read.
# This script runs from the deploy host (Linux) and from a workstation (macOS,
# no `sha256sum`). The hash only has to be stable within one machine's deploys,
# but resolving the tool once is cheaper than discovering the difference as an
# unexplained gateway restart on somebody else's laptop.
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum; }
else                                         sha256() { shasum -a 256; }; fi
HASH="$(cat $FILES "$CERT_DIR/estate.crt" | sha256 | cut -c1-16)"
say ""
say "content hash: $HASH"

if [ "$DRY_RUN" = "1" ]; then
  say ""
  say "--dry-run: nothing applied."
  exit 0
fi

# ── APPLY ────────────────────────────────────────────────────────────────────
say ""
# ── SERVER-SIDE, BECAUSE THIS CONFIGMAP OUTGREW A kubectl LIMIT ──────────────
#
# `kubectl apply` writes the ENTIRE object into a
# `kubectl.kubernetes.io/last-applied-configuration` ANNOTATION so the next
# apply can diff against it. Annotations are capped at 256 KiB across all of
# them, and this ConfigMap is the whole of `gateway/dynamic/` — five files that
# have grown with every wave of the apex consolidation. Wave 3f crossed the
# line:
#
#   The ConfigMap "gateway-dynamic" is invalid: metadata.annotations:
#   Too long: may not be more than 262144 bytes
#
# The failure is EXACTLY the shape that is worst to hit here. `k8s-deploy.sh`
# had already rolled 51 deployments, so the estate was running new images
# behind the OLD routing table — every surface up, and the release's whole
# point unapplied. Nothing was down, and nothing said so either.
#
# `--server-side` stores the diff base in `metadata.managedFields` instead,
# which has no such cap: the apiserver tracks ownership per field rather than
# keeping a serialised copy of the object inside the object. `--force-conflicts`
# because the resource already carries fields owned by the client-side manager
# from every previous deploy, and this script is their sole author.
#
# Nothing else about the apply changes — same ConfigMap, same keys, same
# content hash printed above, and Traefik's file provider reloads on the same
# mount it always did.
kubectl create configmap gateway-dynamic -n "$NAMESPACE" \
  $(for f in $FILES; do printf ' --from-file=%s=%s' "$(basename "$f")" "$f"; done) \
  --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -n "$NAMESPACE" -f - >/dev/null
say "configmap/gateway-dynamic applied"

# `kubectl create secret --from-file` reads the file bytes verbatim, so the
# quoting hazard that `k8s-secrets.py` exists to solve does not apply: a PEM is
# not an env file. The value never passes through a shell variable here.
kubectl create secret generic gateway-certs -n "$NAMESPACE" \
  --from-file=estate.crt="$CERT_DIR/estate.crt" \
  --from-file=estate.key="$CERT_DIR/estate.key" \
  --dry-run=client -o yaml | kubectl apply -n "$NAMESPACE" -f - >/dev/null
say "secret/gateway-certs applied  (2 keys)"

# ── THE RENAME IS BY FIELD, NEVER BY `sed s/gateway/` ────────────────────────
#
# A textual substitution would also rewrite `gateway-dynamic` and
# `gateway-certs`, which are the two objects that must stay SHARED between the
# two Deployments. The pod would then mount a ConfigMap that does not exist,
# which Kubernetes reports as a pod stuck in ContainerCreating — but only after
# the apply has already reported success. So only the fields that name the
# workload are touched, and the volume sources are not among them.
sed "s|cloudsforge.online/dynamic-hash: \"unset\"|cloudsforge.online/dynamic-hash: \"$HASH\"|" \
  "$ROOT/k8s/gateway/60-gateway.yaml" \
  | GW_NAME="$GW_NAME" GW_SECRET="$GW_SECRET" python3 -c '
import os, sys, yaml
name, secret = os.environ["GW_NAME"], os.environ["GW_SECRET"]
docs = list(yaml.safe_load_all(sys.stdin))
for d in docs:
    d["metadata"]["name"] = name
    d["metadata"].setdefault("labels", {})["app.kubernetes.io/name"] = name
    if d["kind"] == "Deployment":
        d["spec"]["selector"]["matchLabels"]["app.kubernetes.io/name"] = name
        d["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = name
        for c in d["spec"]["template"]["spec"]["containers"]:
            for e in c.get("envFrom", []):
                if "secretRef" in e and e["secretRef"]["name"] == "env-traefik":
                    e["secretRef"]["name"] = secret
    else:
        d["spec"]["selector"]["app.kubernetes.io/name"] = name
yaml.safe_dump_all(docs, sys.stdout)
' | kubectl apply -n "$NAMESPACE" -f - >/dev/null
say "deployment/$GW_NAME and service/$GW_NAME applied"

say ""
kubectl rollout status deployment/"$GW_NAME" -n "$NAMESPACE" --timeout=180s || {
  say ""
  kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name="$GW_NAME" \
    -o go-template='{{range .items}}{{$p := .metadata.name}}{{range .status.containerStatuses}}{{if .state.waiting}}  {{$p}}: {{.state.waiting.reason}} — {{.state.waiting.message}}{{"\n"}}{{end}}{{end}}{{end}}'
  fail "the gateway did not become ready"
}

say ""
say "The $NETWORK gateway is serving inside $NAMESPACE at $GW_NAME:443 (TLS) and $GW_NAME:81 (tunnel)."
say "It publishes NO host port: public traffic arrives through cloudflared, which"
say "reaches $GW_NAME:81 as a pod-to-pod hop."
