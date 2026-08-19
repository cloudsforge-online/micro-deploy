#!/usr/bin/env bash
#
# Apply the estate's telemetry plane to the cluster.
#
#   ./scripts/k8s-telemetry.sh --grafana-password-file /tmp/gf
#   ./scripts/k8s-telemetry.sh --dry-run
#   ./scripts/k8s-telemetry.sh --status
#   ./scripts/k8s-telemetry.sh --reload            # push configs, no restart
#
# One plane in `cf-telemetry` for BOTH networks, because that is what compose
# runs — see the header of k8s/telemetry/60-telemetry.yaml.
#
# ══════════════════════════════════════════════════════════════════════════════
# THE CONFIGS ARE NOT FORKED, THEY ARE REWRITTEN ON THE WAY IN
# ══════════════════════════════════════════════════════════════════════════════
#
# Every file this mounts is read from the SAME path compose reads it from —
# `prometheus/prometheus.yml`, `alertmanager/alertmanager.yml`, `otel/`,
# `tempo/`, `loki/`, `grafana/`. There is deliberately no `k8s/telemetry/config/`
# copy of any of them, because a second copy of a config is a config that will
# disagree with the first one, quietly, on the day it matters.
#
# Four of the six move untouched. The other two contain addresses that crossed a
# compose NETWORK and now cross a Kubernetes NAMESPACE, so they are rewritten
# here, in memory, on every apply:
#
#   prometheus.yml   `<project>-<service>-<n>:<port>`
#                    -> `<service>.<project>.svc.cluster.local:<port>`
#   alertmanager.yml `http://beacon:4000/`
#                    -> `http://beacon.cloudsforge-estate.svc.cluster.local:4000/`
#
# The Prometheus rule is mechanical rather than a lookup table, and it is
# mechanical because of a decision made earlier in this migration: the namespaces
# were named after the compose projects. `cloudsforge-estate` and `cf-testnet`
# are both, so `<project>` IS `<namespace>` and the rewrite needs no knowledge
# beyond the string.
#
# WHAT MAKES THAT SAFE IS THE GUARD, NOT THE REGEX. After rewriting, this script
# asserts that NO compose container name survives anywhere in the file. So a
# static target added to prometheus.yml next year in a form this rule does not
# recognise fails the apply loudly, instead of being mounted as an address that
# resolves to nothing and shows up as one more permanently-down target among
# fifty — which is precisely how micro-org#308 lasted from the plane's first
# deploy until 2026-08-09.
#
# ══════════════════════════════════════════════════════════════════════════════
# SECRETS
# ══════════════════════════════════════════════════════════════════════════════
#
# Read from the same gitignored directories `../up.sh` writes:
#
#   prometheus/secrets/    beacon_token, analytics_token, lantern_token
#   alertmanager/secrets/  beacon_token, page_webhook_url, ticket_webhook_url
#
# EMPTY is a supported mode for all six — Alertmanager's config documents why —
# but ABSENT is not, so every key is created unconditionally, empty if need be.
# No value is ever printed by this script, at any verbosity. The Grafana admin
# password is separate: it has no default anywhere by deliberate policy
# (micro-org#276), so it comes from `--grafana-password-file` on first apply and
# is REUSED from the existing Secret on every apply after that, which means the
# value never has to be produced twice.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

NAMESPACE=cf-telemetry
MANIFEST="$ROOT/k8s/telemetry/60-telemetry.yaml"
# The namespace whose services the `cf-services` file_sd job scrapes. Mainnet
# only, exactly as under compose: `targets/services.yaml` was rendered for the
# mainnet project and testnet had only the one credentialed `cf-indexer-testnet`
# job in prometheus.yml. Scraping testnet's fifty services too would be a new
# capability, not a migration.
TARGET_NAMESPACE=cloudsforge-estate

DRY_RUN=0
STATUS=0
RELOAD=0
GF_PASSWORD_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --status)  STATUS=1; shift ;;
    --reload)  RELOAD=1; shift ;;
    --grafana-password-file) GF_PASSWORD_FILE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "usage: $0 [--grafana-password-file FILE] [--dry-run] [--status] [--reload]" >&2; exit 2 ;;
  esac
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }

# ── the cluster is the cluster ────────────────────────────────────────────────
# The default kubectl context on at least one machine that can reach this repo
# is a live Azure work cluster. Applying an estate telemetry plane there would
# be somebody else's incident.
EXPECTED_NODE=${EXPECTED_NODE:-cf-k8s}
NODES="$(kubectl get nodes -o name 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
[ "$NODES" = "node/$EXPECTED_NODE" ] \
  || fail "this is not the CloudsForge cluster (expected node/$EXPECTED_NODE, got ${NODES:-<unreachable>})"

if [ "$STATUS" = 1 ]; then
  kubectl get deploy,pvc,svc -n "$NAMESPACE" 2>/dev/null || say "namespace $NAMESPACE does not exist yet"
  exit 0
fi

[ -f "$MANIFEST" ] || fail "missing $MANIFEST"

# ── rewrite the two cross-namespace configs ───────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" "$WORK" <<'PY' || fail "config rewrite failed (see above)"
import re, sys, pathlib

root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# `<project>-<service>-<ordinal>:<port>` -> `<service>.<project>.svc...:<port>`.
# `[a-z0-9-]+` is greedy and then backtracks over the ordinal, which is what
# makes `cloudsforge-estate-backup-runner-1:4130` split as backup-runner / 1
# rather than as `backup-runner-1` / nothing.
PROJECTS = ("cloudsforge-estate", "cf-testnet")
CONTAINER = re.compile(
    r"\b(" + "|".join(PROJECTS) + r")-([a-z0-9-]+)-(\d+):(\d+)\b"
)

prom_src = root / "prometheus" / "prometheus.yml"
text = prom_src.read_text()
seen = []


def swap(m):
    project, service, _ordinal, port = m.groups()
    seen.append(f"{m.group(0)} -> {service}.{project}.svc.cluster.local:{port}")
    return f"{service}.{project}.svc.cluster.local:{port}"


text = CONTAINER.sub(swap, text)

# ---------------------------------------------------------------------------
# THE GUARD, and it checks TARGETS rather than grepping for leftover container
# names. Two reasons. Prose: line 328 of prometheus.yml discusses
# `cf-testnet-indexer-1` by name in a comment, and a text search flags that
# forever. Coverage: a grep for the compose project prefix would not have caught
# a NEW target in some third form — `some-pinned-container:4000` — which is
# exactly the case worth catching.
#
# So every static target is enumerated and each one must be either an FQDN this
# script produced or a member of the telemetry plane itself, which resolves
# bare within its own namespace. Anything else fails the apply.
# ---------------------------------------------------------------------------
INTRA_PLANE = {
    "prometheus", "alertmanager", "tempo", "loki", "grafana", "otel-collector",
    "localhost", "127.0.0.1",
}
unresolvable = []
for group in re.findall(r"^\s*- targets:\s*\[(.*)\]\s*$", text, re.M):
    for quoted in re.findall(r"\"([^\"]+)\"|'([^']+)'", group):
        addr = quoted[0] or quoted[1]
        host = addr.rsplit(":", 1)[0]
        if host.endswith(".svc.cluster.local") or host in INTRA_PLANE:
            continue
        unresolvable.append(addr)
if unresolvable:
    print(
        "prometheus.yml has static targets that will not resolve in the cluster:\n       "
        + "\n       ".join(sorted(set(unresolvable)))
        + "\n\n       A target is expected to be either a Service FQDN this script rewrote, or\n"
        "       one of the telemetry plane's own members, which resolve bare inside\n"
        "       cf-telemetry. Anything else is mounted as an address pointing at nothing\n"
        "       and joins the target list as one more permanently-down service — which is\n"
        "       how micro-org#308 went unnoticed from the plane's first deploy until\n"
        "       2026-08-09. Teach the rule in scripts/k8s-telemetry.sh about the new form.",
        file=sys.stderr,
    )
    sys.exit(1)
if not seen:
    print(
        "prometheus.yml contained no `<project>-<service>-<n>:<port>` target at all.\n"
        "       It has had six since micro-org#437, so this is not a file this script\n"
        "       recognises and rewriting it silently would be a guess.",
        file=sys.stderr,
    )
    sys.exit(1)
(work / "prometheus.yml").write_text(text)

# Alertmanager: one address, anchored, and the count is asserted. Every alert in
# the estate routes through this receiver as well as its own, so a rewrite that
# silently matched zero times would take the whole incident path with it.
am_src = root / "alertmanager" / "alertmanager.yml"
am = am_src.read_text()
am, n = re.subn(
    r"url: http://beacon:4000/",
    "url: http://beacon.cloudsforge-estate.svc.cluster.local:4000/",
    am,
)
if n != 1:
    print(
        f"expected exactly one `url: http://beacon:4000/` in alertmanager.yml, found {n}.\n"
        "       That line is the estate's entire incident path (micro-org#308, #311);\n"
        "       it is not something to rewrite on a best-effort basis.",
        file=sys.stderr,
    )
    sys.exit(1)
(work / "alertmanager.yml").write_text(am)

print(f"  rewrote {len(seen)} Prometheus targets and 1 Alertmanager receiver")
for line in seen:
    print(f"    {line}")
PY

# ── render the scrape targets ─────────────────────────────────────────────────
# Same generator, same manifest, same skip rules as a compose deploy — only
# `--k8s-namespace` differs, which changes the address form and nothing else.
RELEASE_MANIFEST="$(ls -1 "$ROOT"/../org/releases/*.yaml 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$RELEASE_MANIFEST" ] \
  || fail "no release manifest found in ../org/releases/. The scrape list is rendered from
       the same document the deploy pins images from; without it this would be a
       hand-typed target list, which is the thing render-prometheus-targets.py exists
       to refuse."

mkdir -p "$WORK/targets"

# The compose model, WITHOUT Docker. Left to itself the renderer shells out to
# `docker compose config`, which is correct on the app host and impossible here
# — this VM has no Docker and removing that dependency is the migration. See
# `compose-model-no-docker.py` for what it does and does not promise; the short
# version is that it guards the five fields the renderer reads and refuses
# rather than guessing at any of them.
#
# Mainnet's env file, because `$TARGET_NAMESPACE` is mainnet's — the scrape
# list is generated for one network exactly as compose generates it, and the
# project name this resolves (`CF_PROJECT` unset -> `cloudsforge-estate`) is
# the same string as the namespace by construction.
python3 "$ROOT/scripts/compose-model-no-docker.py" \
  --env-file "$ROOT/compose/mainnet.env" \
  --out "$WORK/compose-model.json" \
  || fail "could not read the compose model (see above)"

python3 "$ROOT/scripts/render-prometheus-targets.py" \
  "$RELEASE_MANIFEST" \
  --compose-json "$WORK/compose-model.json" \
  --k8s-namespace "$TARGET_NAMESPACE" \
  --out "$WORK/targets/services.yaml" \
  || fail "rendering the scrape targets failed (see above)"

if [ "$DRY_RUN" = 1 ]; then
  say "--dry-run: rewrote configs and rendered $(grep -c '^- targets:' "$WORK/targets/services.yaml") targets. Nothing applied."
  exit 0
fi

kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: cloudsforge-estate
    online.cloudsforge.role: telemetry
YAML

cm() {  # cm <name> <kubectl --from-* args...>
  local name="$1"; shift
  kubectl create configmap "$name" --namespace "$NAMESPACE" "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# ── configs ───────────────────────────────────────────────────────────────────
cm otel-config          --from-file=collector.yaml="$ROOT/otel/collector.yaml"
cm tempo-config         --from-file=tempo.yaml="$ROOT/tempo/tempo.yaml"
cm loki-config          --from-file=loki.yaml="$ROOT/loki/loki.yaml"
cm prometheus-config    --from-file=prometheus.yml="$WORK/prometheus.yml"
cm alertmanager-config  --from-file=alertmanager.yml="$WORK/alertmanager.yml"
# `rules/` minus `*.test.yaml`. prometheus.yml names its three rule files
# explicitly rather than globbing, so a promtool unit-test file mounted beside
# them would never be loaded and is harmless — but it WOULD enter the config
# hash below, and restarting the estate's whole telemetry plane because somebody
# added a test case is a bad trade. Copied rather than excluded inline because
# `--from-file=<dir>` takes the whole directory or nothing.
mkdir -p "$WORK/rules"
for f in "$ROOT"/prometheus/rules/*.yaml; do
  case "$f" in *.test.yaml) continue ;; esac
  cp "$f" "$WORK/rules/"
done
[ -n "$(ls -A "$WORK/rules")" ] || fail "prometheus/rules/ contains no non-test rule file"
cm prometheus-rules     --from-file="$WORK/rules"
cm prometheus-targets   --from-file="$WORK/targets"
cm grafana-dashboards   --from-file="$ROOT/grafana/dashboards"
cm grafana-provisioning-datasources \
   --from-file=datasources.yaml="$ROOT/grafana/provisioning/datasources/datasources.yaml"
cm grafana-provisioning-dashboards \
   --from-file=dashboards.yaml="$ROOT/grafana/provisioning/dashboards/dashboards.yaml"

# ── env ───────────────────────────────────────────────────────────────────────
# ConfigMaps, not Secrets: these two files are committed and contain no
# credential. `compose/env/prometheus.env`, `tempo.env`, `loki.env` and
# `alertmanager.env` set only TZ and are not carried — a container's clock is
# UTC and the estate's timestamps are UTC, which is the same thing compose got.
cm env-otel-collector --from-env-file="$ROOT/compose/env/otel-collector.env"
cm env-grafana        --from-env-file="$ROOT/compose/env/grafana.env"

# ── secrets ───────────────────────────────────────────────────────────────────
# Every key created unconditionally; empty is supported, absent is not. Values
# are passed as FILE PATHS so none is ever an argv element or a shell variable.
secret_file() {  # secret_file <dir> <name> -> prints the path to use
  local path="$1/$2"
  [ -f "$path" ] || { : > "$WORK/empty-$2"; path="$WORK/empty-$2"; }
  printf '%s' "$path"
}

kubectl create secret generic prometheus-secrets --namespace "$NAMESPACE" \
  --from-file=beacon_token="$(secret_file "$ROOT/prometheus/secrets" beacon_token)" \
  --from-file=analytics_token="$(secret_file "$ROOT/prometheus/secrets" analytics_token)" \
  --from-file=lantern_token="$(secret_file "$ROOT/prometheus/secrets" lantern_token)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create secret generic alertmanager-secrets --namespace "$NAMESPACE" \
  --from-file=beacon_token="$(secret_file "$ROOT/alertmanager/secrets" beacon_token)" \
  --from-file=page_webhook_url="$(secret_file "$ROOT/alertmanager/secrets" page_webhook_url)" \
  --from-file=ticket_webhook_url="$(secret_file "$ROOT/alertmanager/secrets" ticket_webhook_url)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Grafana's password: supplied once, then reused from the cluster forever. The
# `:?`-with-no-default policy this inherits means there is nowhere else to read
# it from, and asking for it on every apply would be an invitation to put it in
# a shell history.
if kubectl get secret grafana-admin -n "$NAMESPACE" >/dev/null 2>&1; then
  [ -z "$GF_PASSWORD_FILE" ] || say "  grafana-admin already exists; --grafana-password-file ignored (delete the Secret to rotate)"
else
  [ -n "$GF_PASSWORD_FILE" ] \
    || fail "grafana-admin does not exist and no --grafana-password-file was given.
       There is deliberately no default for this password anywhere in the estate
       (see docker-compose.telemetry.yml, and micro-org#276 for why). Write it to a
       file and pass the path; the file is never read twice."
  [ -f "$GF_PASSWORD_FILE" ] || fail "no such file: $GF_PASSWORD_FILE"
  [ -s "$GF_PASSWORD_FILE" ] || fail "$GF_PASSWORD_FILE is empty. An empty admin password is
       not an unconfigured mode for Grafana; it is an open one."
  # Trimmed, because a trailing newline from `echo` would silently become part
  # of the password and the login that fails would be the operator's.
  tr -d '\r\n' < "$GF_PASSWORD_FILE" > "$WORK/gfpw"
  kubectl create secret generic grafana-admin --namespace "$NAMESPACE" \
    --from-file=password="$WORK/gfpw" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

if [ "$RELOAD" = 1 ]; then
  # Configs pushed, pods left alone. This is the path the compose plane could
  # not have: `/-/reload` there re-read a bind-mount SNAPSHOT and returned 200
  # having changed nothing. A ConfigMap directory really does update in place.
  say "--reload: ConfigMaps and Secrets updated; no pods restarted."
  kubectl exec -n "$NAMESPACE" deploy/prometheus -- \
    wget -qO- --post-data='' http://localhost:9090/-/reload >/dev/null 2>&1 </dev/null \
    && say "  prometheus reloaded" || say "  prometheus not running; nothing to reload"
  exit 0
fi

# ── apply, stamped ────────────────────────────────────────────────────────────
# The hash makes a changed config a new pod deterministically instead of after
# up to a minute of kubelet sync. `targets/` is excluded on purpose: it changes
# on every release and Prometheus re-reads it every 30s by `refresh_interval`,
# so including it would restart the whole plane for a routine deploy.
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum; }
else                                         sha256() { shasum -a 256; }; fi
HASH="$(cat "$WORK/prometheus.yml" "$WORK/alertmanager.yml" \
            "$ROOT/otel/collector.yaml" "$ROOT/tempo/tempo.yaml" "$ROOT/loki/loki.yaml" \
            "$WORK"/rules/* \
            "$ROOT"/grafana/provisioning/datasources/datasources.yaml \
            "$ROOT"/grafana/provisioning/dashboards/dashboards.yaml \
            "$ROOT"/grafana/dashboards/* | sha256 | cut -c1-16)"

sed "s|cloudsforge.online/config-hash: \"unset\"|cloudsforge.online/config-hash: \"$HASH\"|" \
  "$MANIFEST" | kubectl apply -f - >/dev/null

say "applied telemetry plane (config-hash $HASH)"

for d in otel-collector prometheus tempo loki alertmanager grafana; do
  kubectl rollout status "deployment/$d" -n "$NAMESPACE" --timeout=180s || {
    kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$d"
    fail "$d did not become ready"
  }
done

say
kubectl get deploy,pvc -n "$NAMESPACE"
