#!/usr/bin/env bash
# Make the estate's PUBLIC hostnames resolve to the estate's OWN gateway, from
# inside the cluster.
#
#   ./scripts/k8s-cluster-dns.sh            # derive, apply, restart CoreDNS
#   ./scripts/k8s-cluster-dns.sh --check    # derive and compare; change nothing
#   ./scripts/k8s-cluster-dns.sh --print    # derive and print the zone; touch nothing
#
# ── WHAT THIS REPLACES, AND WHY IT IS NOT OPTIONAL ───────────────────────────
#
# Under compose the gateway container carried a list of network `aliases`, and
# `docker-compose.gateway.yml` explains at length what they are for: `beacon`
# probes the surfaces at the addresses a person uses — `https://hub.<apex>/` —
# because a probe that skips the gateway reports healthy while the gateway is
# broken. Docker's embedded DNS answered those names with the gateway's address
# on the estate's own network.
#
# Kubernetes has no such thing. CoreDNS answers `*.cluster.local` and forwards
# everything else to the node's resolver, so inside the cluster
# `hub.cloudsforge.online` resolves on the PUBLIC internet — which, while the
# compose estate is still serving traffic, means a pod in this cluster asking for
# a CloudsForge surface is answered by THE OTHER ESTATE. Not an outage: something
# worse, a probe that passes about a machine it never touched.
#
# ── WHY THE LIST IS DERIVED FROM THE ROUTERS ─────────────────────────────────
#
# The compose list was static, and its own comment records that it had already
# drifted: `lantern` and `beacon` became browser surfaces and neither hostname
# was ever added, so beacon could not resolve the two operator consoles it is
# supposed to probe. The comment also claimed a script checked the list for
# drift. No such check existed.
#
# So nothing is typed here. Every `Host(...)` in `gateway/dynamic/*.yml` is read,
# its `{{ env "..." }}` placeholders are filled from the same env file Traefik
# fills them from, and the result IS the list — a hostname the gateway routes
# cannot be missing from it, and a hostname it does not route cannot appear.
#
# ── WHY THE CONDITIONALS ARE EVALUATED AND NOT SKIPPED ───────────────────────
#
# `estate-web.yml` is one file serving two estates, and which routers it contains
# depends on the reading gateway's own environment — `{{ if eq (env
# "CF_WEB_RETIRED") "true" }}` is `true` in `traefik.testnet.env` and `false` in
# `traefik.env`. Reading the file blind therefore attributes TESTNET's routers to
# mainnet, and the biggest guarded block is the retirement:
#
#     Host(`testnet.cloudsforge.online`) && !PathPrefix(`/v1`)  →  302 to the apex
#
# The public internet shows what that name owes an answer. Measured 2026-08-19:
#
#     curl -o /dev/null -w '%{http_code} %{redirect_url}' https://testnet.cloudsforge.online/
#     302 https://cloudsforge.online/
#
# and the gateway that serves that 302 is TESTNET's, because testnet's is the one
# whose environment renders the router. Point the name at mainnet's — which the
# first version of this script did, mainnet being applied first — and a pod gets
# the one gateway in the cluster with no router for it at all. So `condition()`
# below evaluates the two template forms this config uses, and the collision that
# used to be printed here is gone: nothing claims the name twice. Collisions are
# still reported, because the next one may not have an obvious answer.
set -Eeuo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=apply
case "${1:-}" in
  --check) MODE=check ;;
  --print) MODE=print ;;
  -h | --help) sed -n '2,8p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

# ── REFUSE TO RUN AGAINST ANYTHING THAT IS NOT THIS k3s ──────────────────────
# The same guard `k8s-estate-verify.sh` carries, for the same reason: the default
# context on the author's laptop is a live cluster belonging to someone else, and
# this one writes to kube-system and restarts CoreDNS.
command -v kubectl >/dev/null 2>&1 || {
  echo "k8s-cluster-dns: no kubectl on PATH. This runs ON the VM (cf-k8s)." >&2
  exit 2
}
api=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
case "$api" in
  https://127.0.0.1:* | https://localhost:*) ;;
  *)
    echo "k8s-cluster-dns: refusing to run. The current context's API server is" >&2
    echo "                 '$api', which is not this node's k3s." >&2
    exit 2
    ;;
esac

# The renderer writes to a file rather than into `$(...)`, deliberately: bash
# parses a command substitution by tokenising what is inside it, and the Python
# below is full of backticks — `Host(`…`)` is Traefik's own syntax — which inside
# `$( )` are read as an old-style command substitution and end the script at
# "unexpected EOF while looking for matching `". A quoted heredoc protects the
# body from EXPANSION, not from that. So: redirect, then read the file back.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 - > "$TMP/zone" <<'PY'
import io, os, re, subprocess, sys

# network -> (namespace, the env file Traefik renders its templates from)
NETWORKS = [
    ("mainnet", "cloudsforge-estate", "compose/env/traefik.env"),
    ("testnet", "cf-testnet", "compose/env/traefik.testnet.env"),
]

def envfile(path):
    """Anchored reads, never `source`: these are compose env files and a value
    holding a backtick is legal there and is code in a shell."""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in io.open(path, encoding="utf-8"):
        line = line.strip().replace("\r", "")
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
            out[k] = v
    return out

IF_RE    = re.compile(r"^\{\{\s*if\s+(.*?)\s*\}\}\s*$")
ELSE_RE  = re.compile(r"^\{\{\s*else\s*\}\}\s*$")
END_RE   = re.compile(r"^\{\{\s*end\s*\}\}\s*$")
COND_ENV = re.compile(r'^env\s+"([A-Z_][A-Z0-9_]*)"$')
COND_EQ  = re.compile(r'^eq\s+\(\s*env\s+"([A-Z_][A-Z0-9_]*)"\s*\)\s+"([^"]*)"$')


def condition(expr, env, unknown):
    """The two forms this config actually uses, and nothing else.

    Traefik renders these files with Go's text/template, so a router inside a
    false branch DOES NOT EXIST in the gateway that read the file. Ignoring the
    conditionals — which the first version of this script did — gets the one
    question here materially wrong, because the biggest guarded block in
    `estate-web.yml` is the testnet RETIREMENT, and it is rendered by exactly one
    of the two estates:

        {{ if eq (env "CF_WEB_RETIRED") "true" }}   # traefik.testnet.env says true
          cf-retired-web-apex:  Host(`testnet.cloudsforge.online`) && !PathPrefix(`/v1`)

    Read blind, that `Host()` is found while scanning MAINNET (the files are one
    shared directory), mainnet is applied first, and the name gets pointed at a
    gateway whose own environment says `CF_WEB_RETIRED=false` — i.e. at the one
    gateway in the cluster with no router for it at all. The live 302 in the
    header is served by TESTNET's gateway; this is what makes the zone say so.

    An expression in neither form is reported and treated as rendered, because a
    missing name is a silent wrong answer and an extra one shows up as a printed
    collision."""
    m = COND_ENV.match(expr)
    if m:
        return bool(env.get(m.group(1), ""))
    m = COND_EQ.match(expr)
    if m:
        return env.get(m.group(1), "") == m.group(2)
    unknown.add(expr)
    return True


def hostnames(env):
    """Every Host(`...`) in the RENDERED dynamic config, with `{{ env "X" }}`
    filled in. A rule that still holds template syntax after substitution is
    reported and skipped rather than guessed at."""
    found, unresolved = set(), set()
    unknown = set()
    for name in sorted(os.listdir("gateway/dynamic")):
        if not name.endswith(".yml"):
            continue
        # `{{ if }}` blocks nest here — the whole of estate-web.yml sits inside
        # one — so this is a stack, not a flag.
        stack = []
        for line in io.open(os.path.join("gateway/dynamic", name), encoding="utf-8"):
            bare = line.strip()
            m = IF_RE.match(bare)
            if m:
                stack.append(condition(m.group(1), env, unknown))
                continue
            if ELSE_RE.match(bare) and stack:
                stack[-1] = not stack[-1]
                continue
            if END_RE.match(bare) and stack:
                stack.pop()
                continue
            if not all(stack):                   # inside a branch that renders to nothing
                continue
            if re.match(r"\s*#", line):          # a Host() inside a comment is prose
                continue
            for raw in re.findall(r"Host\(`([^`]*)`\)", line):
                h = re.sub(
                    r"\{\{\s*env\s+\"([A-Z_][A-Z0-9_]*)\"\s*\}\}",
                    lambda m: env.get(m.group(1), "\x00" + m.group(1) + "\x00"),
                    raw,
                )
                if "{{" in h or "\x00" in h or not h or h.startswith("."):
                    unresolved.add(raw)
                else:
                    found.add(h)
    return found, unresolved, unknown

def gateway_ip(ns):
    p = subprocess.run(
        ["kubectl", "get", "svc", "-n", ns, "gateway", "-o", "jsonpath={.spec.clusterIP}"],
        capture_output=True, text=True,
    )
    ip = p.stdout.strip()
    return ip if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", ip) else ""

rows, notes, fatal = [], [], []
claimed = {}
for network, ns, path in NETWORKS:
    env = envfile(path)
    if not env:
        fatal.append("%s: %s does not exist on this host" % (network, path))
        continue
    ip = gateway_ip(ns)
    if not ip:
        fatal.append("%s: no gateway Service with a ClusterIP in namespace %s" % (network, ns))
        continue
    names, unresolved, unknown = hostnames(env)
    for raw in sorted(unresolved):
        notes.append("%s: skipped an unresolved rule Host(`%s`)" % (network, raw))
    for expr in sorted(unknown):
        notes.append(
            "%s: treated `{{ if %s }}` as rendered — this script knows only "
            "`env \"X\"` and `eq (env \"X\") \"lit\"`" % (network, expr)
        )
    if not names:
        fatal.append("%s: gateway/dynamic/*.yml yielded no hostnames — the pattern moved" % network)
        continue
    mine = []
    for h in sorted(names):
        if h in claimed:
            notes.append(
                "COLLISION %s is claimed by %s and by %s; %s wins (see the header)"
                % (h, claimed[h], network, claimed[h])
            )
            continue
        claimed[h] = network
        mine.append(h)
    rows.append((network, ns, ip, mine))

if fatal:
    sys.stderr.write("k8s-cluster-dns: cannot build the zone:\n")
    for f in fatal:
        sys.stderr.write("  - %s\n" % f)
    sys.exit(1)

for n in notes:
    sys.stderr.write("k8s-cluster-dns: %s\n" % n)

apex = "cloudsforge.online"
out = []
out.append("# Generated by scripts/k8s-cluster-dns.sh — do not edit by hand.")
out.append("# The names below are the Host() rules in gateway/dynamic/*.yml, pointed at")
out.append("# the gateway Service of the namespace that routes them. fallthrough sends")
out.append("# every OTHER name in the zone (_dmarc, MX, anything unrouted) to the node's")
out.append("# resolver, so this adds addresses and takes none away.")
out.append("%s:53 {" % apex)
out.append("    errors")
out.append("    hosts {")
for network, ns, ip, names in rows:
    out.append("        # %s — %s (%d name%s)" % (network, ns, len(names), "" if len(names) == 1 else "s"))
    for h in names:
        out.append("        %s %s" % (ip, h))
out.append("        fallthrough")
out.append("    }")
out.append("    cache 30")
out.append("    forward . /etc/resolv.conf")
out.append("}")
sys.stderr.write(
    "k8s-cluster-dns: %s\n"
    % ", ".join("%s %d name(s) -> %s" % (n, len(h), ip) for n, _, ip, h in rows)
)
print("\n".join(out))
PY

ZONE=$(<"$TMP/zone")

if [ "$MODE" = print ]; then
  printf '%s\n' "$ZONE"
  exit 0
fi

# ── ONE FILE, NAMED `.server`, IN THE ConfigMap k3s ALREADY IMPORTS ──────────
#
# k3s's Corefile ends with `import /etc/coredns/custom/*.server`, and the CoreDNS
# Deployment already mounts `configmap/coredns-custom` there with
# `optional: true` — so this is the supported seam, not a patch of a file k3s
# owns and will rewrite on upgrade.
#
# `*.server` files are imported OUTSIDE the `.:53` block, which is what makes a
# second server block for this zone legal. The `*.override` seam imports INSIDE
# it, and a second `hosts` plugin there would be fighting the NodeHosts one.
if [ "$MODE" = check ]; then
  live=$(kubectl get configmap coredns-custom -n kube-system \
    -o jsonpath='{.data.cloudsforge\.server}' 2>/dev/null || true)
  if [ -z "$live" ]; then
    echo "k8s-cluster-dns: configmap/coredns-custom carries no cloudsforge.server — the estate's" >&2
    echo "                 hostnames resolve on the public internet from inside this cluster." >&2
    exit 1
  fi
  if [ "$live" = "$ZONE" ]; then
    echo "k8s-cluster-dns: the applied zone is identical to the one derived from the routers"
    exit 0
  fi
  echo "k8s-cluster-dns: the applied zone DIFFERS from the routers. Re-apply." >&2
  diff <(printf '%s\n' "$live") <(printf '%s\n' "$ZONE") >&2 || true
  exit 1
fi

printf '%s\n' "$ZONE" > "$TMP/cloudsforge.server"
kubectl create configmap coredns-custom -n kube-system \
  --from-file="$TMP/cloudsforge.server" --dry-run=client -o yaml | kubectl apply -f -

# A kubelet propagates a changed ConfigMap into a mounted volume on its own sync
# period, and CoreDNS's `reload` plugin then has to notice. Restarting is the
# deterministic version of both: the new pod mounts the current ConfigMap, and
# the rollout finishes when it is actually answering with it.
kubectl rollout restart -n kube-system deploy/coredns
kubectl rollout status -n kube-system deploy/coredns --timeout=120s

echo "k8s-cluster-dns: applied. Prove it from a pod, not from the node — the node's"
echo "                 resolver is not CoreDNS:"
echo "    kubectl run dnscheck --rm -it --restart=Never --image=busybox:1.36 -- \\"
echo "      nslookup hub.cloudsforge.online"
