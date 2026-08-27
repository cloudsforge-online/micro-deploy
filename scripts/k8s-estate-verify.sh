#!/usr/bin/env bash
# Run `scripts/estate-verify.sh` against the KUBERNETES estate.
#
#   ./scripts/k8s-estate-verify.sh              # mainnet  → cloudsforge-estate
#   ./scripts/k8s-estate-verify.sh testnet      # testnet  → cf-testnet
#
# Everything after the network name is passed through untouched.
#
# ── WHAT THIS ADDS, AND WHY IT IS A WRAPPER AND NOT A SECOND VERIFIER ─────────
#
# `estate-verify.sh` is 4,000 lines of assertions about an estate, and almost
# none of them care what runs it. The parts that did — forty-one `docker compose`
# shell-outs, sixteen surface base URLs, eleven `--resolve` targets — are now
# behind `CF_RUNTIME`, which this script sets to `k8s`. A SECOND verifier would
# have been a second list of what "correct" means, and this repository has paid
# four times for the second list of anything.
#
# What is left is addresses. Compose publishes forty-six host ports on
# 127.0.0.1; Kubernetes publishes none. So the twenty-six service URLs the
# verifier reads from its own environment are exported here as ClusterIPs — and
# ClusterIPs are enough, with no `kubectl port-forward` anywhere, because
# kube-proxy's rules live on the NODE: from this VM, `curl http://10.43.x.y:4000`
# reaches the pod. (Cluster DNS does not resolve from the node. Only the IPs.)
#
# ── THE MAPPING IS DERIVED FROM BOTH FILES, NEVER TYPED HERE ─────────────────
#
# `IDENTITY` is not `identity` by uppercasing: `HUB` is `hub-api` and `ADMIN` is
# `admin-api`, and a hand-written table would be right today and wrong at the
# next service. So the join is computed:
#
#   estate-verify.sh   VAR=${VAR:-http://127.0.0.1:${PB}NNN}   → VAR, NNN
#   docker-compose     "127.0.0.1:${CF_PORT_BASE:-4}NNN:PPPP"  → NNN, service
#
# giving VAR → service → the Service's own ClusterIP and port. A variable that
# joins to nothing is REPORTED AND FATAL rather than silently left at its
# loopback default, because a loopback default on this VM is a connection
# refused, and this file's entire subject is checks that fail for the wrong
# reason.
set -uo pipefail
cd "$(dirname "$0")/.."

NET=${1:-mainnet}
case "$NET" in
  mainnet | testnet) shift || true ;;
  -*) NET=mainnet ;;
  *)
    echo "k8s-estate-verify: '$NET' is neither 'mainnet' nor 'testnet'." >&2
    exit 2
    ;;
esac

# ── REFUSE TO RUN AGAINST ANYTHING THAT IS NOT THIS k3s ──────────────────────
#
# The default kubectl context on the author's laptop is a live Azure cluster
# belonging to a different employer. This script writes to databases and
# registers accounts. There is no version of that mistake worth being one flag
# away from, so the API server is asserted rather than trusted: k3s serves on
# loopback, and a cluster reached over the network is not this one.
command -v kubectl >/dev/null 2>&1 || {
  echo "k8s-estate-verify: no kubectl on PATH. This runs ON the VM (cf-k8s), not from the Mac." >&2
  exit 2
}
api=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
case "$api" in
  https://127.0.0.1:* | https://localhost:*) ;;
  *)
    echo "k8s-estate-verify: refusing to run. The current context's API server is" >&2
    echo "                   '$api', which is not this node's k3s (https://127.0.0.1:6443)." >&2
    exit 2
    ;;
esac

ESTATE_ENV=compose/$NET.env
[ -f "$ESTATE_ENV" ] || {
  echo "k8s-estate-verify: $ESTATE_ENV does not exist on this host." >&2
  exit 2
}
# Anchored `sed`, not `source`: these are compose env files, and a value holding
# a space or a backtick is legal there and is code here.
envget() { sed -n "s/^$1=//p" "$ESTATE_ENV" | tail -1 | tr -d '\r'; }
CF_PROJECT=$(envget CF_PROJECT)
CF_PROJECT=${CF_PROJECT:-cloudsforge-estate}
CF_NAMESPACE=${CF_NAMESPACE:-$CF_PROJECT}

# ── THE GATEWAY IS NOT IN `CF_NAMESPACE` FOR TESTNET ─────────────────────────
#
# `CF_NAMESPACE` still means "where this network's own objects live", and for
# testnet that is `cf-testnet`: the database, the Hearth devkit, the backup
# runner and the thirty ExternalName CNAMEs the service-URL join reads. But the
# gateway moved to `cloudsforge-estate` (`docs/network-consolidation.md` §6.3),
# so it needs its own pair — a namespace AND a name, because the namespace alone
# no longer picks one out.
#
# Getting this wrong is not a loud failure. The lookup returns empty, `GW_ADDR`
# falls back to 127.0.0.1, and every one of the ~30 gateway assertions spends a
# full connect timeout before failing — the "eight minutes, two hostnames in"
# run that estate-verify.sh's own comment describes.
CF_GATEWAY_NAMESPACE=${CF_GATEWAY_NAMESPACE:-cloudsforge-estate}
case "$CF_PROJECT" in
  cf-testnet) CF_GATEWAY_SERVICE=${CF_GATEWAY_SERVICE:-gateway-testnet} ;;
  *)          CF_GATEWAY_SERVICE=${CF_GATEWAY_SERVICE:-gateway} ;;
esac

kubectl get namespace "$CF_NAMESPACE" >/dev/null 2>&1 || {
  echo "k8s-estate-verify: namespace '$CF_NAMESPACE' does not exist." >&2
  exit 2
}

# ── THE JOIN ─────────────────────────────────────────────────────────────────
# Emits `export VAR=http://ip:port` lines on stdout and complaints on stderr.
# NAMES ONLY reach this shell's environment as addresses; nothing here reads a
# value out of a secret, a ConfigMap or a container.
plan=$(
  CF_NAMESPACE="$CF_NAMESPACE" python3 - <<'PY'
import io, os, re, subprocess, sys

ns = os.environ["CF_NAMESPACE"]
ev = io.open("scripts/estate-verify.sh", encoding="utf-8").read()
variables = {
    m.group(1): m.group(2)
    for m in re.finditer(
        r"^([A-Z][A-Z0-9_]*)=\$\{\1:-http://127\.0\.0\.1:\$\{PB\}(\d{3})\}$", ev, re.M
    )
}
if not variables:
    sys.exit("estate-verify.sh published no ${PB}NNN service URLs — the pattern moved")

# host port -> (compose service, container port)
published, service = {}, None
for line in io.open("compose/docker-compose.estate.yml", encoding="utf-8"):
    top = re.match(r"^  ([a-z0-9][a-z0-9-]*):\s*$", line)
    if top:
        service = top.group(1)
    pub = re.search(r'"127\.0\.0\.1:\$\{CF_PORT_BASE:-4\}(\d{3}):(\d+)"', line)
    if pub and service:
        published[pub.group(1)] = service

# One kubectl call, not twenty-six.
out = subprocess.run(
    ["kubectl", "get", "svc", "-n", ns, "-o",
     "jsonpath={range .items[*]}{.metadata.name} {.spec.clusterIP} {.spec.ports[0].port}\n{end}"],
    capture_output=True, text=True,
)
addr = {}
for row in out.stdout.split("\n"):
    parts = row.split()
    if len(parts) == 3 and parts[1] not in ("", "None"):
        addr[parts[0]] = parts[1] + ":" + parts[2]

# ── A MERGED SERVICE HAS NO COMPOSE ENTRY, AND A MERGED BUNDLE HAS NO SERVICE ──
#
# Two different holes, both opened by consolidation, both of which used to end
# this script with "published by no compose service" on a perfectly healthy
# estate:
#
#   * An ABSORBED service (wave M) is deleted from the compose file entirely —
#     its code runs inside the absorber's image — so the host-port lookup finds
#     nothing. Read the absorber out of k8s-render.py's MERGED_INTO.
#   * A WEB BUNDLE (wave W) keeps its compose service but is rendered into the
#     one `web` pod, so the port resolves to a name with no Service. Read that
#     set out of the same file.
#
# Parsed textually rather than imported, because importing k8s-render.py drags
# in its argument parser and its render-vars read for two dict literals.
render_py = io.open("scripts/k8s-render.py", encoding="utf-8").read()

def _literal(block: str) -> str:
    m = re.search(block + r"\s*[:=][^{]*\{(.*?)\n\}", render_py, re.S)
    return m.group(1) if m else ""

merged_into = dict(re.findall(r'"([a-z0-9-]+)":\s*"([a-z0-9-]+)"', _literal("MERGED_INTO")))
in_web_pod = set(re.findall(r'"([a-z0-9-]+)"', _literal("MERGED_INTO_WEB_POD")))
if not merged_into and not in_web_pod:
    sys.exit("k8s-render.py published neither MERGED_INTO nor MERGED_INTO_WEB_POD — the pattern moved")

def resolve(svc: str) -> str:
    """Follow merges to the service that actually answers."""
    seen = [svc]
    while svc in merged_into or svc in in_web_pod:
        svc = merged_into.get(svc, "web")
        if svc in seen:
            break
        seen.append(svc)
    return svc

unmapped = []
for name, port in sorted(variables.items(), key=lambda kv: kv[1]):
    svc = published.get(port)
    if svc is None:
        # No compose entry: the variable name IS the service name for every
        # absorbed service, which is what makes this recoverable.
        guess = name.lower().replace("_", "-")
        svc = guess if guess in merged_into else None
    if svc is None:
        unmapped.append(f"{name} (host port {port} is published by no compose service)")
        continue
    target = resolve(svc)
    if target not in addr:
        unmapped.append(f"{name} -> {svc}"
                        + (f" -> {target}" if target != svc else "")
                        + f" (no Service '{target}' in namespace {ns})")
    else:
        note = "" if target == svc else f"   # {svc} is merged into {target}"
        print(f"export {name}=http://{addr[target]}{note}")

if unmapped:
    sys.stderr.write(
        "k8s-estate-verify: %d service URL(s) could not be resolved to a ClusterIP.\n"
        "                   Left at their loopback defaults they would each report a\n"
        "                   dead service on a healthy estate, so this is fatal:\n%s\n"
        % (len(unmapped), "\n".join("                     - " + u for u in unmapped))
    )
    sys.exit(1)

print("export CF_VERIFY_SERVICE_URLS=%d" % len(variables))
PY
) || exit 1
eval "$plan"

# ── THE TWO CREDENTIALS THE DRILL CANNOT BE RUN WITHOUT ──────────────────────
#
# `estate-verify.sh` refuses to start without `ESTATE_ADMIN_PASSWORD`, and
# without `BEACON_IDENTITY_CREDENTIAL` it cannot mint the service token that
# passes the registration challenge — it says so itself, and then reports five
# consecutive failures that are all about the missing variable rather than about
# the estate. Under compose the operator supplies both with
# `set -a; . compose/estate/tokens.env; set +a`.
#
# Here they come from the CLUSTER'S OWN Secret rather than from that file, and
# the difference matters: the Secret is what the pods are actually running with.
# Sourcing the file would verify the estate against the credentials someone meant
# to deploy, which is the same class of mistake as reading a version out of a
# manifest instead of out of the running container.
#
# COMMAND SUBSTITUTION, DELIBERATELY. The value goes from kubectl into a shell
# variable and stops. There is no intermediate file, no `eval` of a generated
# line, and nothing here echoes, logs or lengths either variable — only the two
# NAMES appear below, and only to say whether each was found. This repository has
# leaked a live credential twice through code that meant to be careful about
# exactly this, so the rule is not "redact it", it is "never let it reach a
# stream anything reads".
export ESTATE_ADMIN_PASSWORD=${ESTATE_ADMIN_PASSWORD:-$(
  kubectl get secret estate-tokens -n "$CF_NAMESPACE" \
    -o jsonpath='{.data.ESTATE_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null
)}
export BEACON_IDENTITY_CREDENTIAL=${BEACON_IDENTITY_CREDENTIAL:-$(
  kubectl get secret estate-tokens -n "$CF_NAMESPACE" \
    -o jsonpath='{.data.BEACON_IDENTITY_CREDENTIAL}' 2>/dev/null | base64 -d 2>/dev/null
)}
creds=""
for n in ESTATE_ADMIN_PASSWORD BEACON_IDENTITY_CREDENTIAL; do
  eval "v=\${$n:-}"
  [ -n "$v" ] || creds="$creds $n"
done
unset v
if [ -n "$creds" ]; then
  echo "k8s-estate-verify: secret/estate-tokens in $CF_NAMESPACE carries no value for:$creds" >&2
  echo "                   Every check that needs one would then report on the variable" >&2
  echo "                   and not on the estate, so this stops here." >&2
  exit 2
fi

# ── THE FIVE ADDRESSES THAT LEAVE THIS PROCESS ───────────────────────────────
#
# "THE PAGES HAVE SOMETHING ON THEM" does not curl anything itself. It shells out
# to `scripts/estate-seed.mjs --check`, deliberately — `scripts/seed/lib.mjs`
# already holds the map of where each surface is, and restating it in bash would
# be the second copy of it. That map is therefore a SECOND reader of the estate's
# addresses, in a different language, in a different process, and it does not see
# the twenty-six exports above.
#
# Eleven of its entries are https hostnames and survive the runtime change
# untouched. Five are published host ports, which is a docker fact and not an
# estate one, so on k3s they resolve to a closed port and `--check` reports three
# live services as unreadable. `lib.mjs` takes `CF_<SERVICE>_URL` for each of the
# five; the ClusterIPs the join already computed are exactly what they want.
#
# Assigned from the joined variables rather than re-derived, so there is still
# one mapping in this file and not two — and left empty if a name somehow did not
# join, because `lib.mjs` falls back to the loopback default and an empty
# override must not become the string "http://:".
for cf_seed_pair in CF_LEDGER_URL:LEDGER CF_BILLING_URL:BILLING CF_NDA_URL:NDA \
  CF_COMMUNITY_URL:COMMUNITY CF_STUDIO_URL:STUDIO; do
  cf_seed_dst=${cf_seed_pair%%:*}
  eval "cf_seed_val=\${${cf_seed_pair#*:}:-}"
  [ -n "$cf_seed_val" ] && eval "export $cf_seed_dst=\"\$cf_seed_val\""
done
unset cf_seed_pair cf_seed_dst cf_seed_val

export CF_RUNTIME=k8s
export CF_NAMESPACE
export CF_GATEWAY_NAMESPACE
export CF_GATEWAY_SERVICE
export ESTATE_ENV
echo "runtime: k8s  namespace: $CF_NAMESPACE  service URLs: $CF_VERIFY_SERVICE_URLS ClusterIPs  gateway: $CF_GATEWAY_SERVICE in $CF_GATEWAY_NAMESPACE at $(kubectl get svc -n "$CF_GATEWAY_NAMESPACE" "$CF_GATEWAY_SERVICE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
exec ./scripts/estate-verify.sh "$@"
