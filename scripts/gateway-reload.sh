#!/usr/bin/env bash
# Make "the gateway is running configuration older than the file on disk" a state
# that ANNOUNCES ITSELF, instead of one that has to be suspected.
#
#   ./scripts/gateway-reload.sh              validate, reload, then prove it took
#   ./scripts/gateway-reload.sh --check      prove only; never touches the gateway
#   ./scripts/gateway-reload.sh --validate   render in a throwaway; never touches the gateway
#
# ── THE DEFECT, MEASURED ──────────────────────────────────────────────────────
#
# `compose/docker-compose.gateway.yml` passes `--providers.file.watch=true`, and
# on this host THE WATCH DOES NOT FIRE. Measured against the running estate:
# `gateway/dynamic/estate-web.yml` was edited at epoch 1785837810, and twenty
# seconds later the gateway still reported
#
#     traefik_config_last_reload_success 1.785836079e+09     (1731s earlier)
#     traefik_config_reloads_total 1
#
# and still routed the OLD table. The edited router only existed after a restart.
#
# WHY, AND IT IS NOT TRAEFIK'S FAULT. The dynamic directory is a bind mount from
# macOS into a Lima VM — `colima status` reports `mountType: virtiofs`, and
# `/proc/mounts` inside the gateway confirms `lima-… /etc/traefik/dynamic
# virtiofs ro`. virtiofs does not forward host-originated filesystem change
# notifications into the guest, so the inotify watch Traefik registers is on a
# filesystem that will never tell it anything. The write happens on macOS; the
# watcher is in Linux; nothing connects them. The flag is left ON because it is
# correct where this estate actually deploys — a Linux host, where the mount is a
# real bind mount and inotify works — and this script is what covers the gap on a
# developer machine without pretending the difference does not exist.
#
# ── WHY A CHECK AND NOT JUST A RESTART IN THE DEPLOY PATH ─────────────────────
#
# A restart in the deploy path only helps the person who runs the deploy path.
# The failure this closes is the one where somebody edits a router, reloads a
# browser, sees the old behaviour, and concludes the EDIT is wrong — or worse,
# sees the old behaviour still working and concludes the edit LANDED. Both cost
# hours and neither produces an error message.
#
# So `--check` is the primary mode and the restart is secondary. It compares two
# numbers that already exist and needs nothing new to be emitted:
#
#   * the newest mtime over `gateway/dynamic/*.yml` AND `gateway/certs/*.crt` —
#     the certificates were outside this set until 2026-08-04, which made the one
#     thing a TLS change changes invisible to the check that reports freshness;
#     see the note on `config_files` below, and
#   * `traefik_config_last_reload_success`, which Traefik has always exported on
#     its metrics entrypoint and which Prometheus is already scraping
#     (`prometheus/prometheus.yml`, job `traefik`).
#
# If the first is later than the second, the gateway is serving a file that no
# longer exists, and this says so with both timestamps and the gap between them.
#
# The two clocks are the macOS host's and the VM's, and they were measured
# identical (skew 0s) — virtiofs also passes the host mtime through unchanged, so
# the container's `stat` and the host's agree to the second. TOLERANCE_S exists
# for the drift a suspended VM accumulates, not because the comparison is fuzzy.
#
# ── AND IT VALIDATES BEFORE IT RELOADS, BECAUSE THIS HAS COST AN OUTAGE ───────
#
# A Go template action inside a YAML COMMENT is still an action, and a template
# failure REJECTS THE WHOLE DIRECTORY — not that file, everything, including
# policy.yml's /internal refusal. That took every surface in the estate down at
# once for about three minutes. Validation runs the SAME Traefik image the
# gateway runs, over a COPY of the directory, with the same env file, and refuses
# to touch the live gateway unless it renders clean.
#
# It asserts three things, and the second is the one nothing else here checks:
#
#   1. no ERR at startup            — template failure, unparseable YAML, missing cert
#   2. no "already configured"      — a duplicate name, which is a DROPPED router and
#                                     not an error (see surface-routes.py check 7)
#   3. a non-empty router table     — so a directory that renders to nothing cannot
#                                     pass by producing no complaints
#
# `scripts/surface-routes.py` check 7 catches a duplicate statically and in CI,
# which is the cheaper half. This catches it in the one place that knows for
# certain: the file provider itself, at the version the estate runs.
#
# ── THE SCRATCH DIRECTORY IS INSIDE THE REPOSITORY, AND THAT IS DELIBERATE ────
#
# It was `/tmp` first, and the probe reported a clean render of NOTHING: `/tmp`
# is not in the VM's shared set, so the bind mount appeared INSIDE the container
# as an existing, empty, readable directory. No error, no warning — `ls` showed
# two entries, `.` and `..`, and Traefik loaded two internal routers and declared
# itself happy. A validation that passes over an empty directory is worse than no
# validation, so the copy lives under the repository, which is shared by
# definition because the gateway is already mounting it.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

DYNAMIC="$ROOT/gateway/dynamic"
# Same variable as docker-compose.gateway.yml mounts, or `--check` would
# validate a configuration against a different certificate directory from the one
# the running gateway serves — a check that passes on the wrong evidence.
CERTS="${CF_CERT_DIR:-$ROOT/gateway/certs}"
SCRATCH="$ROOT/.gateway-validate"
ENV_FILE="$ROOT/compose/env/${CF_TRAEFIK_ENV:-traefik}.env"
# ── AND THE ENV FILE IS NOT SELF-CONTAINED, WHICH DEADLOCKED THIS SCRIPT ──────
#
# `compose/env/traefik.env` holds INTERPOLATIONS, not just literals:
#
#     CF_RPC_UPSTREAM=http://${CF_CHAIN_HOST:-host.docker.internal}:8545
#
# `CF_CHAIN_HOST` is defined in `compose/estate/tokens.env`, which is where it has
# lived since the chain nodes moved onto their own machine and the estate started
# reaching them over WireGuard at 10.10.0.1. Compose resolves that: it is passed
# BOTH files with `--env-file` (`release-deploy.sh`), and Compose v2 interpolates
# `env_file` values. Read from the running gateway, `CF_RPC_UPSTREAM` really is
# `http://10.10.0.1:8545`.
#
# `docker run --env-file` DOES NOT INTERPOLATE. It splits on the first `=` and
# passes the rest of the line verbatim, so the probe below received the literal
# string `http://${CF_CHAIN_HOST:-host.docker.internal}:8545` and Traefik answered
#
#     ERR error parsing server URL … invalid character "{" in host name
#
# on four routers — and assertion 1 counts any ERR as a directory that does not
# render. So `--validate` failed, `reload` refuses to touch the gateway when
# validation fails, and THE GATEWAY COULD NOT BE RELOADED AT ALL. Measured
# 2026-08-11: the live gateway was serving a router table 92,447 seconds — nearly
# 26 hours — older than the files on disk, and `estate-verify.sh` was telling the
# operator to fix it by running this script, which could not succeed. A check that
# reports a real defect and prescribes a remedy that cannot work is worse than
# either half alone.
#
# The fix asks COMPOSE what the environment resolves to rather than teaching this
# script the interpolation rules a second time — same two `--env-file` arguments
# the deploy uses, same defaults as `release-deploy.sh`, so a testnet validation
# is driven by the testnet tokens exactly as a testnet deploy is.
ESTATE_ENV=${ESTATE_ENV:-compose/mainnet.env}
TOKENS_FILE=${TOKENS_FILE:-compose/estate/tokens.env}
# The gateway moved to the estate's own compose project on 2026-08-10 so that
# `docker compose -p cloudsforge-estate ps` lists the container every public
# hostname depends on (micro-org#257). This default follows it.
GW_PROJECT=${CF_GW_PROJECT:-${CF_PROJECT:-cloudsforge-estate}}
PROBE=cf-gateway-validate
# Clock drift a suspended VM accumulates. Not a fudge factor for the comparison:
# the two clocks were measured identical, and a real staleness gap is minutes.
TOLERANCE_S=${CF_RELOAD_TOLERANCE_S:-5}

mode=reload
case "${1:-}" in
  --check)    mode=check ;;
  --validate) mode=validate ;;
  "")         mode=reload ;;
  *) echo "usage: $0 [--check|--validate]" >&2; exit 2 ;;
esac

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# ── WHICH RUNTIME, AND WHY THE QUESTION CHANGES SHAPE WITH IT ─────────────────
#
# Under compose the dynamic directory is BIND-MOUNTED: the files the gateway
# reads and the files in this checkout are the same inodes, so "is the gateway
# serving what is on disk" is entirely a question about TIME — did Traefik reload
# after the last write. There is nothing to compare, because there is only one
# copy.
#
# Under Kubernetes there are two copies. `gateway/dynamic/*.yml` is rendered into
# the `gateway-dynamic` ConfigMap and the pod mounts that, so the same sentence
# splits into two independent questions:
#
#   1. Does the ConfigMap still say what the repository says?  (a CONTENT
#      question — someone edited a `Host()` rule and never re-applied, and no
#      timestamp anywhere on the cluster would show it)
#   2. Has Traefik reloaded since the ConfigMap changed, and did that reload
#      SUCCEED?  (the time question, unchanged in meaning)
#
# Only 2 has a compose analogue. 1 is a failure mode this runtime adds, and it is
# the more likely of the two in practice: a kubelet syncs a changed ConfigMap into
# the mount within a minute and Traefik's watch fires on it, whereas a forgotten
# `kubectl apply` sits there indefinitely looking exactly like a healthy gateway.
CF_RUNTIME=${CF_RUNTIME:-compose}
CF_NAMESPACE=${CF_NAMESPACE:-${CF_PROJECT:-cloudsforge-estate}}
# Both gateways run in `cloudsforge-estate` (`docs/network-consolidation.md`
# §6.3), so the gateway's location is no longer `CF_NAMESPACE` and its name is
# no longer always `gateway`. A label selector that matches nothing returns
# empty, and every caller below reads that as "no gateway" — so a stale testnet
# router table would be reported as nothing to report.
CF_GATEWAY_NAMESPACE=${CF_GATEWAY_NAMESPACE:-cloudsforge-estate}
case "${CF_PROJECT:-}" in
  cf-testnet) CF_GATEWAY_SERVICE=${CF_GATEWAY_SERVICE:-gateway-testnet} ;;
  *)          CF_GATEWAY_SERVICE=${CF_GATEWAY_SERVICE:-gateway} ;;
esac
case "$CF_RUNTIME" in
  compose | k8s) ;;
  *) echo "gateway-reload: CF_RUNTIME='$CF_RUNTIME' is neither 'compose' nor 'k8s'." >&2; exit 2 ;;
esac

# ── the pieces this script must not carry a second copy of ────────────────────
#
# The image and the metrics port are READ from the compose file and from the
# running container. A validator that pins its own Traefik version proves the
# directory renders under a Traefik nobody runs, and a hardcoded 8082 goes stale
# the day the entrypoint moves — both are the class of second copy this
# repository keeps finding rotted.
image=$(awk '/^    image:/ { print $2; exit }' compose/docker-compose.gateway.yml)
if [ -z "$image" ]; then
  bad "no image: in compose/docker-compose.gateway.yml — cannot validate against the Traefik the gateway runs"
  exit 1
fi

# ── AND THE ENTRYPOINTS, FOR THE SAME REASON AND A SHARPER ONE ────────────────
#
# The probe below used to declare `--entrypoints.web.address=:80` and
# `--entrypoints.websecure.address=:443` and nothing else — a second copy of a
# list that lives in the compose file, of exactly the kind the note above rejects
# for the image and the metrics port.
#
# WHAT MAKES IT SHARPER THAN STALENESS: a router naming an entrypoint the probe
# does not define is not ignored. Traefik logs
#
#     ERR EntryPoint doesn't exist        entryPointName=tunnel routerName=…
#     ERR No valid entryPoint for this router  routerName=…
#
# and assertion 1 below counts any ERR as a directory that does not render. So on
# the day the `tunnel` entrypoint was added to this stack and to the 53 routers
# that answer on it, `--validate` would have failed — and `reload` calls
# `validate` first and refuses to touch the gateway when it fails. The check
# written to stop a bad configuration reaching the live gateway would instead have
# blocked a good one, and said "the dynamic directory does not render cleanly"
# about a directory that renders perfectly under the real gateway's flags.
# Measured on traefik:v3.2.3, not predicted.
#
# Read as ADDRESSES ONLY. The `http.tls` and `http.middlewares` flags are
# deliberately not mirrored: this probe is asserting that the directory renders,
# and TLS on the probe would make assertion 1 depend on the certificate directory
# in a way `--check` already covers.
ep_flags=$(grep -oE -- '--entrypoints\.[A-Za-z0-9_-]+\.address=:[0-9]+' compose/docker-compose.gateway.yml | sort -u)
if [ -z "$ep_flags" ]; then
  bad "no --entrypoints.<name>.address= in compose/docker-compose.gateway.yml — the probe would define none,"
  bad "and every router in the directory would fail to bind with 'EntryPoint doesn't exist'"
  exit 1
fi

[ -d "$DYNAMIC" ] || { bad "$DYNAMIC does not exist"; exit 1; }
[ -f "$ENV_FILE" ] || { bad "$ENV_FILE does not exist — the probe would render every Host() empty"; exit 1; }

# `stat` is BSD on the machine this runs on and GNU in CI, and the two spell the
# same field differently. Probed once rather than branched on `uname`, which is
# the same question asked less directly.
if stat -c %Y "$ENV_FILE" >/dev/null 2>&1; then STAT_MTIME='stat -c %Y'; else STAT_MTIME='stat -f %m'; fi
if command -v sha256sum >/dev/null 2>&1; then SHA='sha256sum'; else SHA='shasum -a 256'; fi

# ── WHY THERE IS A DIGEST AND NOT JUST A TIMESTAMP ────────────────────────────
#
# mtime alone reports a file that was TOUCHED as a file that was CHANGED, and
# this repository's own checks argue at length that a check firing on correct
# configuration is worse than no check, because it teaches the reader to ignore
# it. Restoring a file from a backup does exactly that: newer mtime, identical
# bytes, nothing stale about the gateway at all — it happened on the first run of
# this script.
#
# So the timestamp is the TRIGGER and the digest is the ANSWER. `.gateway-loaded`
# records `<reload-epoch> <digest>` at every moment freshness is CONFIRMED, which
# is a moment when no file has been written since the reload and the digest is
# therefore provably what the gateway loaded. A later write with a newer mtime is
# then checked against it: same reload, same digest, nothing to do.
#
# It is a cache and never an authority. A missing, stale or unreadable marker
# falls through to the conservative answer — stale — so deleting it can only
# cause an unnecessary reload, never a missed one. That asymmetry is the whole
# reason it is safe to keep a derived file around at all.
MARKER="$ROOT/.gateway-loaded"

# ── AND THE CERTIFICATES ARE IN IT, WHICH THEY WERE NOT ───────────────────────
#
# This hashed `gateway/dynamic/*.yml` and nothing else, so THE ONE THING A TLS
# CHANGE CHANGES WAS INVISIBLE TO THE CHECK THAT REPORTS FRESHNESS. Swap the pair
# `tls.yml` names and the gateway keeps terminating on the certificate it loaded
# at startup — Traefik reads a `certFile` when it builds the store, not per
# handshake — while this said "the gateway is serving what is on disk". A reload
# check blind to a certificate is worse than none: it is a check that answers the
# question confidently and about something else.
#
# Found while pointing the mainnet gateway at a Cloudflare Origin CA leaf
# (`gateway/dynamic/tls.yml`). `origin.crt` was installed at 22:45 and the gateway
# had last reloaded at 19:32, and `--check` was green.
#
# `.crt` ONLY, and `-maxdepth 1`. The keys are 0600 and hashing one would put a
# private key through `xargs` for no gain: a key never changes without its
# certificate changing, so the certificate is a complete trigger. `ca.srl` is a
# counter that moves when a leaf is signed and is deliberately out too — a digest
# that changes when nothing served changed is the false alarm this script's own
# header spends a paragraph arguing against.
config_files() {
  find "$DYNAMIC" -type f -name '*.yml'
  [ -d "$CERTS" ] && find "$CERTS" -maxdepth 1 -type f -name '*.crt'
}

config_digest() {
  # shellcheck disable=SC2086
  config_files | LC_ALL=C sort | xargs $SHA | $SHA | awk '{print $1}'
}

# The newest mtime, and the file that carries it, over EXACTLY the set above.
# They were two helpers over a directory each; making them one pass over one list
# is what keeps the trigger and the answer talking about the same files. Emits
# `<mtime> <path>`.
newest_config() {
  local t best=0 newest="" f
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC2086
    t=$($STAT_MTIME "$f" 2>/dev/null) || continue
    [ "$t" -gt "$best" ] && { best=$t; newest=$f; }
  done <<EOF
$(config_files)
EOF
  echo "$best $newest"
}

gateway_container() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$GW_PROJECT" \
    --filter "label=com.docker.compose.service=gateway" | head -1
}

# The pod behind the gateway Deployment. `app.kubernetes.io/name` and not `app`:
# that is the selector every Deployment in `k8s/estate` was written with, and a
# label that matches nothing returns an empty string, which every caller here
# treats as "no gateway" — the same conservative answer `gateway_container`
# gives.
gateway_pod() {
  kubectl get pod -n "$CF_GATEWAY_NAMESPACE" -l app.kubernetes.io/name="$CF_GATEWAY_SERVICE" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ── 1. THE CONFIGMAP AGAINST THE REPOSITORY ───────────────────────────────────
#
# Compared as CONTENT, key by key, and reported by NAME. A digest of the whole
# set would answer "something differs" for a check whose entire value is saying
# which file, and the repository has an essay two screens up about exactly that
# distinction for the mtime trigger.
#
# The certificates live in a SECRET rather than a ConfigMap, because the same
# volume carries the keys. Only entries ending `.crt` are read — a certificate is
# a public document and its bytes are what TLS staleness is about — and the
# private keys beside them are never fetched, never decoded and never named. The
# comparison prints file names and nothing else on either side of it.
k8s_config_matches_repo() {
  CF_NAMESPACE="$CF_NAMESPACE" DYNAMIC="$DYNAMIC" CERTS="$CERTS" python3 - <<'PY'
import base64, json, os, subprocess, sys

ns = os.environ["CF_NAMESPACE"]

def api(kind, name):
    p = subprocess.run(["kubectl", "get", kind, name, "-n", ns, "-o", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return json.loads(p.stdout)

def disk(directory, suffix):
    out = {}
    if not os.path.isdir(directory):
        return out
    for n in sorted(os.listdir(directory)):
        p = os.path.join(directory, n)
        if n.endswith(suffix) and os.path.isfile(p):
            out[n] = open(p, "rb").read()
    return out

# `both` says whether a file present in the repository and absent from the
# cluster is a failure.
#
# For the dynamic directory it is: a `*.yml` that was never applied is a router
# file the gateway has never seen, which is the whole drift this function exists
# to catch.
#
# For the certificates it is NOT, and `trust.crt` is why. That is the CA bundle
# CLIENTS verify against — `CF_ESTATE_CA`, what `estate-verify.sh` passes to
# `curl --cacert` — and the gateway has no use for its own issuer. It is in the
# directory, it is correctly not in the Secret, and demanding symmetry here would
# produce a permanent red about a file that is exactly where it belongs. What
# still holds in both directions is the assertion that matters: every certificate
# the gateway IS mounting is byte-identical to the one in this checkout.
problems, checked = [], 0
for kind, name, directory, suffix, both in (
    ("configmap", "gateway-dynamic", os.environ["DYNAMIC"], ".yml", True),
    ("secret", "gateway-certs", os.environ["CERTS"], ".crt", False),
):
    obj = api(kind, name)
    if obj is None:
        problems.append("%s/%s does not exist in namespace %s" % (kind, name, ns))
        continue
    # A ConfigMap may carry `data` (text) or `binaryData`; a Secret carries
    # base64 in `data`. Normalised to bytes so one comparison serves both.
    live = {}
    for k, v in (obj.get("data") or {}).items():
        live[k] = v.encode() if kind == "configmap" else base64.b64decode(v)
    for k, v in (obj.get("binaryData") or {}).items():
        live[k] = base64.b64decode(v)
    live = {k: v for k, v in live.items() if k.endswith(suffix)}
    repo = disk(directory, suffix)
    for k in sorted(set(repo) | set(live)):
        if k not in live and not both:
            continue
        checked += 1
        if k not in live:
            problems.append("%s is in %s and NOT in %s/%s" % (k, directory, kind, name))
        elif k not in repo:
            problems.append("%s is in %s/%s and NOT in %s" % (k, kind, name, directory))
        elif repo[k] != live[k]:
            problems.append("%s DIFFERS between %s and %s/%s" % (k, directory, kind, name))

if problems:
    for p in problems:
        print("FAIL " + p)
    sys.exit(1)
print("OK %d file(s) identical to the ConfigMap and the certificate Secret" % checked)
PY
}

# ── 2. THE TIME QUESTION, WITH THE CLUSTER AS THE CLOCK ───────────────────────
#
# `newest_config` reads mtimes off this checkout, which under Kubernetes is the
# wrong file set: the gateway does not read those files, and on a freshly cloned
# repository every one of them is newer than any reload that ever happened. The
# equivalent fact is when the CONFIGMAP was last written, and the API records it
# — `metadata.managedFields[*].time`, one entry per field manager, so the answer
# is the newest of them.
#
# Emits `<epoch> <what>`. An object that cannot be read emits `0`, and 0 makes
# the comparison below pass; that is deliberate and safe only because
# `k8s_config_matches_repo` has already failed loudly on a missing object.
k8s_config_changed_at() {
  CF_NAMESPACE="$CF_NAMESPACE" python3 - <<'PY'
import calendar, json, os, subprocess, time

ns = os.environ["CF_NAMESPACE"]
best, who = 0, ""
for kind, name in (("configmap", "gateway-dynamic"), ("secret", "gateway-certs")):
    p = subprocess.run(["kubectl", "get", kind, name, "-n", ns, "-o", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        continue
    meta = json.loads(p.stdout).get("metadata", {})
    stamps = [f["time"] for f in (meta.get("managedFields") or []) if f.get("time")]
    if meta.get("creationTimestamp"):
        stamps.append(meta["creationTimestamp"])
    for s in stamps:
        t = calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
        if t > best:
            best, who = t, "%s/%s" % (kind, name)
print("%d %s" % (best, who))
PY
}

# The metrics port, read from the RUNNING container's arguments for the same
# reason the compose branch reads it off `.Config.Cmd`: a hardcoded 8082 goes
# stale the day the entrypoint moves, and this file already refuses that trade
# for the image and the entrypoint list.
k8s_metrics_port() {
  kubectl get pod -n "$CF_NAMESPACE" "$1" \
    -o jsonpath='{.spec.containers[0].args[*]}' 2>/dev/null \
    | tr ' ' '\n' | awk -F: '/^--entrypoints\.metrics\.address=/ { print $NF; exit }'
}

# ── the probe's environment, resolved the way the deploy resolves it ──────────
#
# Writes an env file whose values are what the GATEWAY CONTAINER actually gets,
# and sets `PROBE_ENV` to its path. Compose does the interpolation; this reads the
# answer out of `config` rather than reimplementing `${VAR:-default}` in bash.
#
# It sets a variable instead of echoing the path because it also PRINTS — and a
# `$(…)` around a function that reports its own findings captures the findings
# and hides them, which is the failure this script exists to stop.
#
# It is written mode 600 and never printed. `traefik.env` holds no secrets today
# — hostnames and upstream host:port — but this file is now a projection of the
# TOKENS file, so it is treated as one whatever happens to be in it tomorrow.
#
# Any failure falls back to the raw env file, which is exactly the old behaviour:
# a machine without the tokens file can still validate, and the four chain routers
# are the only thing it gets wrong. Silent would be wrong, so it says which.
resolve_env_file() {
  local out="$SCRATCH/env.resolved" json=""
  if [ -f "$ESTATE_ENV" ] && [ -f "$TOKENS_FILE" ]; then
    json=$(docker compose --env-file "$ESTATE_ENV" --env-file "$TOKENS_FILE" \
             -f compose/docker-compose.gateway.yml config --format json 2>/dev/null)
  fi
  if [ -n "$json" ]; then
    if printf '%s' "$json" | (umask 077; python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"]["gateway"]["environment"]
out = open(sys.argv[1], "w")
n = 0
for k, v in svc.items():
    if v is None:
        continue
    v = str(v)
    # A newline would end the record early and docker would read the remainder as
    # a variable name. Nothing here is multi-line; if something becomes so, drop
    # it rather than corrupt every variable after it.
    if "\n" in v or "\r" in v:
        continue
    out.write(f"{k}={v}\n")
    n += 1
out.close()
print(n)
' "$out" >"$SCRATCH/.envcount" 2>/dev/null); then
      ok "probe environment resolved through compose ($(cat "$SCRATCH/.envcount") variables, from $ESTATE_ENV + $TOKENS_FILE)"
      PROBE_ENV="$out"
      return 0
    fi
  fi
  bad "could not resolve the environment through compose — falling back to $ENV_FILE verbatim."
  bad "Interpolated values (CF_*_UPSTREAM) will not render and their routers will report ERR."
  PROBE_ENV="$ENV_FILE"
}

# ── validate ──────────────────────────────────────────────────────────────────
validate() {
  echo "── validating $DYNAMIC in a throwaway $image ────────────────────────"
  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH/dynamic"
  cp "$DYNAMIC"/* "$SCRATCH/dynamic/" || { bad "could not copy the dynamic directory"; return 1; }
  PROBE_ENV="$ENV_FILE"
  resolve_env_file

  docker rm -f "$PROBE" >/dev/null 2>&1
  # No published ports: the probe's API is read with `docker exec`, so this can
  # never collide with the live gateway or with a second run of itself.
  # The certificate directory is mounted too — without it tls.yml logs a real ERR
  # about a store it cannot build, and assertion 1 would fire on every run until
  # somebody learned to ignore it.
  if ! docker run -d --rm --name "$PROBE" \
      --env-file "$PROBE_ENV" \
      -v "$SCRATCH/dynamic":/etc/traefik/dynamic:ro \
      -v "$CERTS":/etc/traefik/certs:ro \
      "$image" \
      --log.level=INFO \
      --providers.file.directory=/etc/traefik/dynamic \
      --providers.file.watch=false \
      $ep_flags \
      --api=true --api.insecure=true >/dev/null; then
    bad "the throwaway gateway would not start at all"
    rm -rf "$SCRATCH"
    return 1
  fi
  trap 'docker rm -f "$PROBE" >/dev/null 2>&1; rm -rf "$SCRATCH"' RETURN

  local routers="" i
  for i in $(seq 1 20); do
    routers=$(docker exec "$PROBE" wget -qO- http://127.0.0.1:8080/api/http/routers 2>/dev/null)
    [ -n "$routers" ] && break
    sleep 1
  done

  # ── THE ANSI STRIP IS NOT COSMETIC: WITHOUT IT ASSERTION 1 COULD NOT FIRE ────
  #
  # Traefik v3.2.3 colourises its console output whether or not it is attached to
  # a terminal, so every error line reaches `docker logs` as
  #
  #     ESC[90m<ts>ESC[0m ESC[1mESC[31mERRESC[0mESC[0m Error while …
  #
  # and the character immediately before `ERR` is the `m` that ends the colour
  # escape. `grep -E '\bERR\b'` therefore matches NOTHING, because `mERR` has no
  # word boundary in front of it.
  #
  # MEASURED, on this host, with the probe below: a `certFile` naming a file that
  # does not exist makes Traefik log
  # `ERR Error while creating certificate store … tlsStoreName=default` and serve
  # NO certificate at all — every handshake fails with `tlsv1 unrecognized name`
  # — and `grep -cE '\bERR\b'` over those logs returned `0` while `grep -cF ERR`
  # returned `1`.
  #
  # So the assertion this whole function exists for — the one that was supposed to
  # have caught the template-in-a-comment outage in the header — has been printing
  # "renders with no error" unconditionally. It is the defect class this
  # repository names most often, a check that cannot fail, inside the check
  # written to end another one.
  #
  # `$'\033'` rather than `\x1b`: BSD sed does not understand `\x1b` and would
  # have deleted the literal characters `x1b` instead, which is the quiet
  # half-fix. Bash resolves the escape before sed ever sees it.
  local rc=0 logs
  logs=$(docker logs "$PROBE" 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

  # 1. no ERR. A template failure, an unparseable file or a `certFile` that does
  #    not resolve — the first two reject the WHOLE directory, which is the
  #    three-minute outage this file's header records; the third leaves the
  #    gateway terminating on nothing, which is worse than the self-signed
  #    default `gateway/dynamic/tls.yml` was written to end.
  local errs
  errs=$(printf '%s\n' "$logs" | grep -E '\bERR\b' | grep -v 'use of closed network connection')
  if [ -n "$errs" ]; then
    bad "the dynamic directory does not render cleanly — the live gateway was NOT touched:"
    printf '%s\n' "$errs" | sed 's/^/       /'
    rc=1
  else
    ok "renders with no error under $image"
  fi

  # 2. no dropped definition. This is a WARN, not an ERR, and it is a route that
  #    silently does not exist. See surface-routes.py check 7.
  local dupes
  dupes=$(printf '%s\n' "$logs" | grep -F 'already configured')
  if [ -n "$dupes" ]; then
    bad "a name is defined twice, so one definition was DROPPED — the live gateway was NOT touched:"
    printf '%s\n' "$dupes" | sed 's/^/       /'
    rc=1
  else
    ok "no name is defined twice; every router in the directory loaded"
  fi

  # 3. a non-empty table. The `/tmp` case: an empty mount renders clean and
  #    proves nothing, so silence is not allowed to count as success.
  local count
  count=$(printf '%s' "$routers" | tr ',' '\n' | grep -c '"provider":"file"')
  if [ "${count:-0}" -lt 1 ]; then
    bad "the throwaway loaded NO file-provider router. An empty or unreadable mount renders clean"
    bad "and asserts nothing — check that $SCRATCH is under a path the VM shares"
    rc=1
  else
    ok "$count router(s) loaded from the file provider"
  fi
  return $rc
}

# ── the freshness assertion ───────────────────────────────────────────────────
freshness() {
  local cid mtime newest reload failure port gap
  cid=$(gateway_container)
  if [ -z "$cid" ]; then
    bad "no running gateway in compose project '$GW_PROJECT' — nothing to compare the files against"
    return 1
  fi

  # Derived from the container's own command line, so this does not become a
  # second copy of the entrypoint definition.
  port=$(docker inspect "$cid" --format '{{join .Config.Cmd " "}}' \
        | tr ' ' '\n' | awk -F: '/^--entrypoints\.metrics\.address=/ { print $NF; exit }')
  if [ -z "$port" ]; then
    bad "the gateway exposes no metrics entrypoint, so the reload timestamp cannot be read."
    bad "That is not a passing check — staleness would be invisible. Restore --entrypoints.metrics.address"
    return 1
  fi

  local metrics
  metrics=$(docker exec "$cid" wget -qO- "http://127.0.0.1:$port/metrics" 2>/dev/null)
  if [ -z "$metrics" ]; then
    bad "could not read the gateway's metrics on :$port — the reload timestamp is unknown, which is reported as a failure rather than a pass"
    return 1
  fi

  reload=$(printf '%s\n' "$metrics" | awk '/^traefik_config_last_reload_success/ { printf "%.0f", $2; exit }')
  failure=$(printf '%s\n' "$metrics" | awk '/^traefik_config_last_reload_failure/ { printf "%.0f", $2; exit }')
  read -r mtime newest <<EOF
$(newest_config)
EOF

  if [ -z "$reload" ] || [ "$reload" = "0" ]; then
    bad "the gateway has never successfully loaded a configuration (traefik_config_last_reload_success is unset)"
    return 1
  fi

  # A reload that FAILED leaves the success timestamp untouched, so the check
  # above would pass while the gateway serves the last good table. That is the
  # exact shape of "stale and looks fine", and it is the one the template-in-a-
  # comment outage produced.
  if [ -n "$failure" ] && [ "$failure" != "0" ] && [ "$failure" -gt "$reload" ]; then
    bad "the gateway's LAST reload FAILED ($(date -u -r "$failure" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$failure")) and it is still serving the table from before it."
    bad "Run '$0 --validate' — the directory does not render, and the running gateway is the only thing hiding it"
    return 1
  fi

  local digest
  digest=$(config_digest)
  gap=$((mtime - reload))

  if [ "$gap" -le "$TOLERANCE_S" ]; then
    # Nothing has been written since the reload, so what is on disk now IS what
    # the gateway loaded. This is the only moment that fact can be established,
    # and it is the only moment the marker is written.
    printf '%s %s\n' "$reload" "$digest" > "$MARKER" 2>/dev/null
    ok "the gateway is serving what is on disk (reloaded $((reload - mtime))s after the newest file)"
    return 0
  fi

  # Written since the reload — but the bytes may not have changed. Only a marker
  # taken against THIS SAME reload can settle that; one from an earlier reload
  # says nothing about what this gateway loaded, and is ignored.
  if [ -r "$MARKER" ]; then
    local m_reload m_digest
    read -r m_reload m_digest < "$MARKER"
    if [ "$m_reload" = "$reload" ] && [ "$m_digest" = "$digest" ]; then
      ok "the gateway is serving what is on disk (files touched since the reload, contents identical)"
      return 0
    fi
  fi

  bad "THE GATEWAY IS SERVING CONFIGURATION OLDER THAN THE FILES ON DISK, by ${gap}s."
  bad "  newest file : $(basename "$newest") at $(date -u -r "$mtime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$mtime")"
  bad "  last reload : $(date -u -r "$reload" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$reload")"
  bad "Every route decision the estate is making right now comes from the older one. The file"
  bad "provider's watch does not fire on this host's virtiofs mount (see this script's header)."
  bad "Fix it with:  $0"
  return 1
}

# ── the same assertion, against a cluster ─────────────────────────────────────
#
# Both halves run, and both are reported, even when the first fails. A ConfigMap
# that has drifted from the repository and a gateway that has not reloaded are
# different incidents with different fixes — `kubectl apply` versus `kubectl
# rollout restart` — and collapsing them into one early return would hand the
# reader whichever happened to be checked first.
k8s_freshness() {
  local rc=0 pod port metrics reload failure changed changed_by gap

  local content
  if content=$(k8s_config_matches_repo 2>&1); then
    ok "${content#OK }"
  else
    rc=1
    bad "THE DEPLOYED CONFIGURATION IS NOT WHAT THIS REPOSITORY SAYS."
    printf '%s\n' "$content" | sed 's/^FAIL /       /' | sed 's/^/    /'
    bad "Re-render and apply it: kubectl apply -k k8s/gateway (then $0)"
  fi

  pod=$(gateway_pod)
  if [ -z "$pod" ]; then
    bad "no running gateway pod in namespace '$CF_NAMESPACE' — nothing to compare the files against"
    return 1
  fi

  port=$(k8s_metrics_port "$pod")
  if [ -z "$port" ]; then
    bad "the gateway exposes no metrics entrypoint, so the reload timestamp cannot be read."
    bad "That is not a passing check — staleness would be invisible. Restore --entrypoints.metrics.address"
    return 1
  fi

  metrics=$(kubectl exec -n "$CF_NAMESPACE" "$pod" -c traefik -- \
    wget -qO- "http://127.0.0.1:$port/metrics" 2>/dev/null </dev/null)
  if [ -z "$metrics" ]; then
    bad "could not read the gateway's metrics on :$port in pod $pod — the reload timestamp is unknown, which is reported as a failure rather than a pass"
    return 1
  fi

  reload=$(printf '%s\n' "$metrics" | awk '/^traefik_config_last_reload_success/ { printf "%.0f", $2; exit }')
  failure=$(printf '%s\n' "$metrics" | awk '/^traefik_config_last_reload_failure/ { printf "%.0f", $2; exit }')
  read -r changed changed_by <<EOF
$(k8s_config_changed_at)
EOF

  if [ -z "$reload" ] || [ "$reload" = "0" ]; then
    bad "the gateway has never successfully loaded a configuration (traefik_config_last_reload_success is unset)"
    return 1
  fi

  # Identical in intent to the compose branch: a failed reload leaves the success
  # timestamp untouched, so a gateway serving the last good table looks fresh.
  if [ -n "$failure" ] && [ "$failure" != "0" ] && [ "$failure" -gt "$reload" ]; then
    bad "the gateway's LAST reload FAILED ($(date -u -r "$failure" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$failure")) and it is still serving the table from before it."
    bad "The mounted directory does not render. Read it: kubectl logs -n $CF_NAMESPACE $pod"
    return 1
  fi

  gap=$((changed - reload))
  if [ "$gap" -le "$TOLERANCE_S" ]; then
    ok "the gateway is serving the ConfigMap that is applied (reloaded $((reload - changed))s after it was written)"
    return $rc
  fi

  # No digest marker here, and none is needed. Under compose the trigger is an
  # mtime, which a `touch` or a restore moves without changing a byte; the
  # cluster's timestamp moves only when a write actually reached the API server,
  # so there is no false alarm to suppress and nothing derived to keep on disk.
  bad "THE GATEWAY IS SERVING CONFIGURATION OLDER THAN THE APPLIED ONE, by ${gap}s."
  bad "  written     : ${changed_by:-the ConfigMap} at $(date -u -r "$changed" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$changed")"
  bad "  last reload : $(date -u -r "$reload" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$reload")"
  bad "A kubelet syncs a changed ConfigMap into the mount within its sync period; if this"
  bad "persists the mount is stale. Force it:  kubectl rollout restart -n $CF_GATEWAY_NAMESPACE deploy/$CF_GATEWAY_SERVICE"
  return 1
}

# ── modes ─────────────────────────────────────────────────────────────────────
#
# `validate` and `reload` stay compose-only, and say so rather than degrading.
#
# `validate` runs a THROWAWAY TRAEFIK against the directory and counts the
# routers it builds, which is how a configuration that does not render is caught
# BEFORE it reaches the live gateway. The Kubernetes equivalent is a throwaway
# Pod mounting the same ConfigMap, and it is not written yet. `reload` refuses
# for the same reason it refuses when `validate` fails: restarting a gateway
# against a configuration nobody has rendered is how you turn a stale router
# table into no router table, and a rollout gives you a NEW pod with nothing.
# Until the probe Pod exists, that step is a person's to take deliberately.
if [ "$CF_RUNTIME" = k8s ] && [ "$mode" != check ]; then
  bad "'$mode' is not implemented for CF_RUNTIME=k8s — only --check is."
  bad "There is no probe-Pod validator yet, and a rollout without one replaces a stale"
  bad "router table with an empty one. Apply and restart deliberately:"
  bad "    kubectl apply -k k8s/gateway"
  bad "    kubectl rollout restart -n $CF_GATEWAY_NAMESPACE deploy/$CF_GATEWAY_SERVICE"
  bad "    $0 --check"
  exit 2
fi

case "$mode" in
  validate)
    validate || exit 1
    exit 0
    ;;
  check)
    echo "── is the gateway serving what is on disk? ──────────────────────────"
    case "$CF_RUNTIME" in
      compose) freshness || exit 1 ;;
      k8s) k8s_freshness || exit 1 ;;
    esac
    exit 0
    ;;
  reload)
    validate || exit 1
    cid=$(gateway_container)
    if [ -z "$cid" ]; then
      bad "no running gateway in compose project '$GW_PROJECT' — bring it up with scripts/estate-up.sh"
      exit 1
    fi
    echo
    echo "── reloading the gateway ────────────────────────────────────────────"
    # A restart, not a signal: Traefik has no SIGHUP reload for the file provider.
    # Its only reload path IS the watch, and the watch is what does not work here.
    if ! docker restart "$cid" >/dev/null; then
      bad "the gateway would not restart"
      exit 1
    fi
    for _ in $(seq 1 30); do
      docker exec "$cid" traefik healthcheck --ping >/dev/null 2>&1 && break
      sleep 1
    done
    ok "restarted"
    echo
    echo "── and proving it took, rather than assuming ────────────────────────"
    freshness || exit 1
    exit 0
    ;;
esac
