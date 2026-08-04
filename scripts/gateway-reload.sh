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
#   * the newest mtime under `gateway/dynamic/`, and
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
CERTS="$ROOT/gateway/certs"
SCRATCH="$ROOT/.gateway-validate"
ENV_FILE="$ROOT/compose/env/${CF_TRAEFIK_ENV:-traefik}.env"
GW_PROJECT=${CF_GW_PROJECT:-cfmicro}
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

dynamic_digest() {
  # shellcheck disable=SC2086
  find "$DYNAMIC" -type f -name '*.yml' | LC_ALL=C sort | xargs $SHA | $SHA | awk '{print $1}'
}

newest_mtime() {
  # shellcheck disable=SC2086
  find "$1" -type f -exec $STAT_MTIME {} + 2>/dev/null | sort -rn | head -1
}

newest_file() {
  local newest="" t best=0 f
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC2086
    t=$($STAT_MTIME "$f")
    [ "$t" -gt "$best" ] && { best=$t; newest=$f; }
  done
  echo "$newest"
}

gateway_container() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$GW_PROJECT" \
    --filter "label=com.docker.compose.service=gateway" | head -1
}

# ── validate ──────────────────────────────────────────────────────────────────
validate() {
  echo "── validating $DYNAMIC in a throwaway $image ────────────────────────"
  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH/dynamic"
  cp "$DYNAMIC"/* "$SCRATCH/dynamic/" || { bad "could not copy the dynamic directory"; return 1; }

  docker rm -f "$PROBE" >/dev/null 2>&1
  # No published ports: the probe's API is read with `docker exec`, so this can
  # never collide with the live gateway or with a second run of itself.
  # The certificate directory is mounted too — without it tls.yml logs a real ERR
  # about a store it cannot build, and assertion 1 would fire on every run until
  # somebody learned to ignore it.
  if ! docker run -d --rm --name "$PROBE" \
      --env-file "$ENV_FILE" \
      -v "$SCRATCH/dynamic":/etc/traefik/dynamic:ro \
      -v "$CERTS":/etc/traefik/certs:ro \
      "$image" \
      --log.level=INFO \
      --providers.file.directory=/etc/traefik/dynamic \
      --providers.file.watch=false \
      --entrypoints.web.address=:80 \
      --entrypoints.websecure.address=:443 \
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

  local rc=0 logs
  logs=$(docker logs "$PROBE" 2>&1)

  # 1. no ERR. A template failure or an unparseable file rejects the WHOLE
  #    directory, which is the three-minute outage this file's header records.
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
  mtime=$(newest_mtime "$DYNAMIC")
  newest=$(newest_file "$DYNAMIC")

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
  digest=$(dynamic_digest)
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

# ── modes ─────────────────────────────────────────────────────────────────────
case "$mode" in
  validate)
    validate || exit 1
    exit 0
    ;;
  check)
    echo "── is the gateway serving what is on disk? ──────────────────────────"
    freshness || exit 1
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
