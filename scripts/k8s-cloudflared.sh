#!/usr/bin/env bash
# Apply the Cloudflare tunnel connector — THE ESTATE'S LIVE FRONT DOOR.
#
#   ./scripts/k8s-cloudflared.sh --token-file /run/cfd-token   # first time
#   ./scripts/k8s-cloudflared.sh                               # Secret exists
#   ./scripts/k8s-cloudflared.sh --dry-run
#   ./scripts/k8s-cloudflared.sh --status
#
# ── THIS SCRIPT'S DANGEROUS DIRECTION REVERSED AT THE CUTOVER ────────────────
#
# Until 2026-08-19 07:44 UTC the manifest carried `replicas: 0` and this script
# refused to run unless it still did, because scaling UP would have registered a
# second connector on a tunnel the compose estate was still serving — and a
# tunnel load-balances, so Cloudflare would have split live traffic across two
# estates with two different databases.
#
# The cutover happened. The app host's `Cloudflared` service is Stopped and
# Disabled; this pod is the only connector on the tunnel. So the manifest now
# carries `replicas: 1` and the assertion is inverted: this script refuses to
# apply a file that would scale the LIVE connector down, and refuses to finish
# if the result is not 1. The same guard, aimed the other way — because the
# thing worth preventing is no longer "going live by accident", it is "going
# dark by accident", and an apply of a stale checkout is exactly how that
# happens.
#
# Rolling back to compose is still two commands on two machines, but the order
# now matters more than the commands: bring the compose estate up FIRST, then
#
#   app host:  powershell -Command "Start-Service Cloudflared"
#   cluster:   kubectl -n cf-edge scale deploy/cloudflared --replicas=0
#
# Both are local and take seconds, which is the whole reason the 61 dashboard
# ingress rules are left unedited — see the manifest's section on the loopback
# forwarders.
#
# ── WHAT IT CHECKS BEFORE APPLYING ───────────────────────────────────────────
#
#   both gateways   The pod's two socat sidecars forward to
#                   `gateway.cloudsforge-estate:81` and `gateway-testnet.cloudsforge-estate:81`.
#                   A Service that does not exist, or does not carry port 81,
#                   fails at cutover as a 502 on every public hostname at once.
#                   Checked here, while nothing is at stake.
#
#   the ports       9081 and 9181 are not this script's invention: they are
#                   `${CF_GW_PORT_BASE:-90}81` from `compose/docker-compose.yml`
#                   with mainnet's unset base and testnet's `CF_GW_PORT_BASE=91`
#                   from `compose/testnet.env`. Re-derived from those files, so
#                   changing the compose port without changing the forwarders
#                   fails here rather than at 3am.
#
#   the token       Present, non-empty, and shaped like a tunnel token. Never
#                   printed, never passed in argv, never written by this script
#                   anywhere but the Secret.
#
# ── HOW THE TOKEN GETS HERE ──────────────────────────────────────────────────
#
# On the app host it lives in `C:\ProgramData\cloudflared\token` (184 bytes),
# referenced by the `Cloudflared` service as `--token-file`. It is a bearer
# credential for the estate's ENTIRE public surface: whoever holds it can
# register a connector and be handed a share of production traffic. So it moves
# host-to-host over a pipe that never renders it and never lands on a laptop:
#
#   ssh <app-host> "powershell -NoProfile -EncodedCommand <read+trim+base64>" \
#     | ssh <this-vm> 'umask 077 && base64 -d > /run/cfd-token'
#   ./scripts/k8s-cloudflared.sh --token-file /run/cfd-token
#   shred -u /run/cfd-token     # the script also does this with --consume
#
# `--token-file` and not `--token`, because an argument is visible in `ps` to
# every user on the box for as long as the script runs.
set -Eeuo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"

TOKEN_FILE=""
CONSUME=0
DRY_RUN=0
STATUS_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
    --consume)    CONSUME=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --status)     STATUS_ONLY=1; shift ;;
    -h|--help)    sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

NAMESPACE="cf-edge"
MANIFEST="$ROOT/k8s/cloudflared/60-cloudflared.yaml"
GW_COMPOSE="$ROOT/compose/docker-compose.gateway.yml"
TESTNET_ENV="$ROOT/compose/testnet.env"

for f in "$MANIFEST" "$GW_COMPOSE" "$TESTNET_ENV"; do
  [ -f "$f" ] || fail "$f is missing"
done

# Same guard as k8s-deploy.sh, k8s-gateway.sh and k8s-hearth-devkit.sh, and for
# the same reason: on at least one machine that reaches this repository the
# default kubectl context is somebody else's live cluster. Node identity, not
# context name — a context can be renamed, a node cannot be renamed into being
# the wrong cluster.
EXPECTED_NODE=${EXPECTED_NODE:-cf-k8s}
NODES="$(kubectl get nodes -o name 2>&1 | tr '\n' ' ' | sed 's/ *$//')"
[ "$NODES" = "node/$EXPECTED_NODE" ] || fail "this is not the CloudsForge cluster (expected node/$EXPECTED_NODE, got ${NODES:-<unreachable>})"

# ── --status: what is live right now, before anything is touched ─────────────
if [ "$STATUS_ONLY" = 1 ]; then
  say "namespace $NAMESPACE:"
  kubectl get deploy,pod -n "$NAMESPACE" 2>&1 | sed 's/^/  /'
  say ""
  say "Since the 2026-08-19 cutover this deployment IS the estate's front door."
  say "1/1 Ready is the healthy state. Anything less is a public outage, not a"
  say "fallback: the app host's Windows service is Stopped and Disabled."
  exit 0
fi

# ── THE TWO GATEWAY SERVICES ─────────────────────────────────────────────────
#
# Checked before the Secret, because a missing gateway is the failure that would
# survive every other check and only appear as a total public outage.
# ── BOTH GATEWAYS ARE IN `cloudsforge-estate` NOW ────────────────────────────
# `docs/network-consolidation.md` §6.3. The triple is namespace:network:service
# rather than namespace:network, because the two no longer determine the third.
for pair in "cloudsforge-estate:mainnet:gateway" "cloudsforge-estate:testnet:gateway-testnet"; do
  ns="${pair%%:*}"; rest="${pair#*:}"; net="${rest%%:*}"; gw="${rest##*:}"
  kubectl get namespace "$ns" >/dev/null 2>&1 || fail "namespace $ns does not exist, so the $net forwarder would have nothing to reach"
  port="$(kubectl get svc "$gw" -n "$ns" -o jsonpath='{.spec.ports[?(@.name=="tunnel")].port}' 2>/dev/null || true)"
  [ "$port" = "81" ] || fail "service $gw in $ns has no 'tunnel' port 81 (got '${port:-<none>}'); run ./scripts/k8s-gateway.sh --network $net first"
  eps="$(kubectl get endpoints "$gw" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [ -n "$eps" ] || fail "service $gw in $ns has no ready endpoints, so the $net forwarder would 502 the moment the tunnel moved"

  # THE ONE CHECK THAT SURVIVES BOTH GATEWAYS SHARING A NAMESPACE. Two Services
  # in one namespace can select the same pods, and a `gateway-testnet` whose
  # selector still said `gateway` would pass every check above while forwarding
  # testnet hostnames to the MAINNET Traefik — which would answer them, from
  # mainnet rows, with a 200. Endpoints existing is not evidence they are the
  # right ones; the two Services must not resolve to the same address.
  eval "eps_$net=\"\$eps\""
  say "$gw in $ns: tunnel/81 with ready endpoints"
done

# ── THE TWO LOOPBACK PORTS, RE-DERIVED FROM COMPOSE ──────────────────────────
#
# Whole lines, then the field after the first `=`. Never `grep -o`: it retries
# at successive offsets within a line, so `^` can match mid-value and a fragment
# of a credential comes back looking like a variable name.
grep -q 'CF_GW_PORT_BASE:-90}81:81' "$GW_COMPOSE" \
  || fail "compose/docker-compose.gateway.yml no longer publishes the tunnel entrypoint at \${CF_GW_PORT_BASE:-90}81 — the forwarder ports in the manifest were derived from that line and must be re-derived"
BASE_LINE="$(grep -m1 '^CF_GW_PORT_BASE=' "$TESTNET_ENV" || true)"
TESTNET_BASE="${BASE_LINE#*=}"
[ "$TESTNET_BASE" = "91" ] || fail "compose/testnet.env sets CF_GW_PORT_BASE=${TESTNET_BASE:-<unset>}, so testnet's tunnel port is ${TESTNET_BASE:-??}81 and not 9181 as the manifest's forwarder assumes"

for want in \
  "TCP-LISTEN:9081,bind=127.0.0.1,fork,reuseaddr" \
  "TCP:gateway.cloudsforge-estate.svc.cluster.local:81" \
  "TCP-LISTEN:9181,bind=127.0.0.1,fork,reuseaddr" \
  "TCP:gateway-testnet.cloudsforge-estate.svc.cluster.local:81" ; do
  grep -qF -- "- $want" "$MANIFEST" || fail "the manifest does not carry the forwarder argument '$want'"
done

[ "$eps_mainnet" != "$eps_testnet" ] || fail \
  "service gateway and service gateway-testnet in cloudsforge-estate resolve to the SAME pod
      address. They are two Deployments sharing one namespace, so a selector copied from one
      to the other is silent: both forwarders reach the mainnet Traefik, and every testnet
      hostname answers 200 with mainnet data. Check the selector on service/gateway-testnet.
      (This guard re-uses the endpoint addresses collected above.)"

say "forwarders: 127.0.0.1:9081 -> mainnet gateway, 127.0.0.1:9181 -> testnet gateway (both derived from compose)"

# ── replicas: 1 IS AN INVARIANT OF THE FILE, NOT A DEFAULT ───────────────────
#
# This assertion used to demand 0, when the compose estate was serving and going
# live by accident was the hazard. The cutover inverted it. Now this pod IS the
# public estate, the manifest is the thing `kubectl apply` writes over the live
# spec, and a checkout carrying the old value would scale the only connector on
# the tunnel to zero — every hostname 502 at once, from an apply that looked
# routine.
grep -q '^  replicas: 1$' "$MANIFEST" \
  || fail "the manifest does not declare 'replicas: 1'. Since the 2026-08-19 cutover this deployment is the estate's ONLY Cloudflare connector, so applying a file that says anything else takes every public hostname down at once. Refusing."

# ── THE NAMESPACE AND THE TOKEN ──────────────────────────────────────────────
#
# The namespace is created from the manifest, but the Secret has to exist before
# the Deployment references it, and `kubectl apply -f` gives no ordering. So the
# namespace is applied on its own first.
if [ "$DRY_RUN" = 1 ]; then
  say ""
  say "--dry-run: server-side validating, nothing is written"
  kubectl apply --dry-run=server -f "$MANIFEST" 2>&1 | sed 's/^/  /'
  say ""
  say "Secret cloudflared-token is NOT validated by --dry-run; run without it to create the Secret."
  exit 0
fi

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  say "creating namespace $NAMESPACE"
  kubectl create namespace "$NAMESPACE" >/dev/null
}

if [ -n "$TOKEN_FILE" ]; then
  [ -f "$TOKEN_FILE" ] || fail "--token-file $TOKEN_FILE does not exist"

  # Trim, into a file, never into a variable and never into argv. A variable
  # would reach `ps` through any child process's environment; an argument
  # reaches `ps` directly.
  TRIMMED="$(mktemp)"
  chmod 600 "$TRIMMED"
  # shellcheck disable=SC2064
  trap "rm -f '$TRIMMED'" EXIT
  tr -d ' \t\r\n' < "$TOKEN_FILE" > "$TRIMMED"

  BYTES="$(wc -c < "$TRIMMED" | tr -d ' ')"
  [ "$BYTES" -gt 0 ] || fail "--token-file $TOKEN_FILE is empty after trimming whitespace"
  # A tunnel token is base64 of a small JSON object holding the account tag,
  # the tunnel id and the connector secret. The app host's is 184 bytes. This
  # is a shape check, not a value check: it catches an HTML error page, a
  # truncated pipe or somebody's password, and it prints only the verdict.
  [ "$BYTES" -ge 120 ] || fail "the token is only $BYTES bytes after trimming; a Cloudflare tunnel token is ~180. Refusing to install a truncated credential."
  LC_ALL=C grep -qE '^[A-Za-z0-9+/=_-]+$' "$TRIMMED" \
    || fail "the token contains characters outside the base64 alphabet, so it is not a tunnel token (a stray shell prompt or an error page in the pipe would look like this). Refusing."
  say "token: $BYTES bytes, base64 alphabet, shape OK"

  # --from-file, so the value never appears in this process's arguments.
  # dry-run|apply, so re-running replaces rather than erroring on conflict.
  kubectl create secret generic cloudflared-token \
    --namespace "$NAMESPACE" \
    --from-file=token="$TRIMMED" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  say "secret cloudflared-token: installed in $NAMESPACE"

  rm -f "$TRIMMED"
  if [ "$CONSUME" = 1 ]; then
    shred -u "$TOKEN_FILE" 2>/dev/null || rm -f "$TOKEN_FILE"
    say "consumed: $TOKEN_FILE removed"
  else
    say "NOTE: $TOKEN_FILE still holds the token in plaintext. Remove it: shred -u $TOKEN_FILE"
  fi
else
  kubectl get secret cloudflared-token -n "$NAMESPACE" >/dev/null 2>&1 \
    || fail "secret cloudflared-token does not exist in $NAMESPACE and no --token-file was given. See the header for the host-to-host pipe that installs it without rendering it."
  # Length only. Never the value.
  KEYS="$(kubectl get secret cloudflared-token -n "$NAMESPACE" -o jsonpath='{range .data.*}{"x"}{end}' 2>/dev/null || true)"
  [ -n "$KEYS" ] || fail "secret cloudflared-token exists but carries no data"
  kubectl get secret cloudflared-token -n "$NAMESPACE" -o jsonpath='{.data.token}' >/dev/null 2>&1 \
    || fail "secret cloudflared-token has no key 'token', which is the key the Deployment reads"
  say "secret cloudflared-token: present with key 'token'"
fi

# ── APPLY ────────────────────────────────────────────────────────────────────
say ""
kubectl apply -f "$MANIFEST"

# ── AND PROVE THE FRONT DOOR IS STILL OPEN ───────────────────────────────────
#
# The field is in the manifest, so apply DOES set it — but this asserts the
# outcome rather than trusting the mechanism, and it is the last chance to catch
# a spec that reached the cluster saying zero.
REPLICAS="$(kubectl get deploy cloudflared -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
[ "$REPLICAS" = "1" ] || fail "deployment cloudflared is at replicas=$REPLICAS after apply, and it is the estate's only connector. THE PUBLIC SITE IS DOWN RIGHT NOW. Fix it with: kubectl -n $NAMESPACE scale deploy/cloudflared --replicas=1"

# Ready, not merely scheduled. `/ready` answers 200 only with an established
# edge connection, so this is the difference between "a pod exists" and "the
# estate is reachable" — and if the apply rolled the pod, that gap is real.
say ""
say "waiting for the connector to register with Cloudflare's edge"
kubectl rollout status deploy/cloudflared -n "$NAMESPACE" --timeout=120s \
  || fail "the connector did not become Ready within 120s. Public traffic is not being served. Check: kubectl -n $NAMESPACE logs deploy/cloudflared -c cloudflared"

say ""
say "cloudflared is live in $NAMESPACE at replicas=1, Ready, serving both"
say "networks through the loopback forwarders."
say ""
say "This is the estate's front door. To roll back to the compose estate, bring"
say "that estate UP FIRST, then:"
say ""
say "  1. app host:  powershell -Command \"Start-Service Cloudflared\""
say "  2. cluster:   kubectl -n $NAMESPACE scale deploy/cloudflared --replicas=0"
say ""
say "The 61 Cloudflare ingress rules are not touched by either direction, which"
say "is why rollback needs no dashboard."
