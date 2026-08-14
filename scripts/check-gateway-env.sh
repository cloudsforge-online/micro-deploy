#!/usr/bin/env bash
# Does the RUNNING gateway carry every variable its env file sets?
#
#   ./scripts/check-gateway-env.sh mainnet
#   ./scripts/check-gateway-env.sh testnet [--quiet]
#
# ── THE FAILURE THIS EXISTS FOR ───────────────────────────────────────────────
#
# `gateway/dynamic/*.yml` are Go templates, and Traefik's file provider renders
# them from the GATEWAY CONTAINER'S OWN ENVIRONMENT. `env "CF_ANYTHING"` on an
# unset name renders the empty string — silently, successfully, with no warning
# in any log. A block guarded by `{{ if env "X" }}` simply is not there.
#
# On 2026-08-14 (micro-org#459 / the reader-reported "cannot reach the server"):
# `compose/env/traefik.testnet.env` set `CF_VIEW_ORIGIN_SUFFIX`, `policy.yml`
# rendered the combined view's three allowed origins inside
# `{{ if env "CF_VIEW_ORIGIN_SUFFIX" }}`, the file was on the host, the release
# was deployed, and the testnet API answered every preflight
#
#   HTTP/1.1 200 OK
#   Access-Control-Allow-Credentials: true
#   Access-Control-Allow-Headers: ...
#   Access-Control-Allow-Methods: ...
#
# with NO `Access-Control-Allow-Origin` — a refusal, to a browser. The variable
# was in the file and not in the container, because release-deploy.sh CYCLES the
# gateway (`docker restart`) and A RESTART DOES NOT RE-READ `env_file`. Only
# recreating the container does. The fix had been merged, released and deployed,
# and the bug was still live, which is the worst shape a fix can take.
#
# ── WHY A NAME-ONLY COMPARISON IS THE WHOLE CHECK ─────────────────────────────
#
# Every failure in this family is a MISSING NAME. A wrong value renders as the
# wrong hostname and is caught by check-tunnel-origin.sh, estate-verify.sh, or a
# reader; an absent name renders as nothing at all and is caught by no one,
# because the resulting config is valid YAML describing a smaller estate.
#
# So this compares two sets of variable NAMES and never reads, prints, compares
# or otherwise touches a single VALUE. The gateway's env file holds no secret
# today, and this script must not become the reason that matters.
#
# ── WHAT IT DOES NOT ASSERT ──────────────────────────────────────────────────
#
# Not that the values agree — `docker inspect` would have to be read for that,
# and see above. Not that the templates reference only variables that are set: a
# template may legitimately test a name no file sets (`CF_WEB_RETIRED` is unset
# on mainnet by design and `{{ if eq (env "CF_WEB_RETIRED") "true" }}` is exactly
# how that is meant to read). One direction, one class of failure, no false
# alarms.
#
# Prints variable NAMES, a container name and a command. No value of any kind.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

env_name="${1:-mainnet}"
quiet=""
[ "${2:-}" = "--quiet" ] && quiet=1

case "$env_name" in
  mainnet) env_file=compose/env/traefik.env
           default_container=cloudsforge-estate-gateway-1
           recreate="make estate-gateway" ;;
  testnet) env_file=compose/env/traefik.testnet.env
           default_container=cf-testnet-gateway-1
           recreate="make estate-gateway-testnet" ;;
  *) echo "usage: check-gateway-env.sh [mainnet|testnet] [--quiet]" >&2; exit 2 ;;
esac
container="${GATEWAY_CONTAINER:-$default_container}"

if [ ! -f "$env_file" ]; then
  echo "FATAL: $env_file does not exist, so there is nothing to compare against." >&2
  exit 1
fi

if ! docker inspect "$container" >/dev/null 2>&1; then
  # Same reasoning as the other post-deploy checks: a developer's laptop
  # legitimately runs no gateway, and an absent gateway is already reported —
  # loudly, with the command to fix it — by check-tunnel-origin.sh.
  [ -z "$quiet" ] && echo "no $container on this host; gateway environment not compared"
  exit 0
fi

# `substr($0,1,1) != "#"` rather than a `^` anchor on purpose: this file is read
# over `ssh <windows-host> 'wsl.exe -- bash -lc "..."'` often enough that it is
# worth not depending on a character Windows cmd eats as its escape.
want=$(awk -F= 'substr($0,1,1) != "#" && NF > 1 && $1 ~ /[A-Za-z_][A-Za-z0-9_]*/ {print $1}' "$env_file" | sort -u)
have=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1 | sort -u)

if [ -z "$want" ]; then
  echo "FATAL: $env_file sets no variables at all, so this check would pass against" >&2
  echo "       any container. Refusing to give a verdict." >&2
  exit 1
fi

missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))

if [ -n "$missing" ]; then
  echo "FATAL: $container IS MISSING VARIABLES ITS ENV FILE SETS." >&2
  echo "       Set in $env_file, absent from the running container:" >&2
  printf '         %s\n' $missing >&2
  echo >&2
  echo "       Every one of those renders as the empty string in gateway/dynamic/*.yml," >&2
  echo "       so any block guarded by one of them is not in the served config — with no" >&2
  echo "       error anywhere, because a template that drops a section is still valid." >&2
  echo >&2
  echo "       A RESTART CANNOT FIX THIS. \`docker restart\` keeps the environment the" >&2
  echo "       container was created with; only recreating it re-reads env_file:" >&2
  echo "         $recreate" >&2
  exit 1
fi

count=$(printf '%s\n' "$want" | wc -l | tr -d ' ')
[ -z "$quiet" ] && echo "ok: $container carries all $count variables set in $env_file"
exit 0
