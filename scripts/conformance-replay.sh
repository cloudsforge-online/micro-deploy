#!/usr/bin/env bash
# Run ONE conformance replay by hand, through the same container the schedule uses.
#
# The schedule is `conformance-runner` in `compose/docker-compose.conformance.yml`, which runs
# `replay.sh loop` — immediately on start and daily thereafter. This runs `replay.sh once` in a
# throwaway container built from the identical service definition, so that "what a replay is" has
# exactly one definition and a hand run cannot drift from the scheduled one.
#
#   ./scripts/conformance-replay.sh                 # compare and publish to beacon
#   ./scripts/conformance-replay.sh --no-publish    # compare only; nothing reaches beacon
#
# See compose/docker-compose.conformance.yml for why this is a container and not a systemd timer,
# and micro-org#439 for why it exists at all.
set -euo pipefail

PUBLISH=1
[ "${1:-}" = "--no-publish" ] && PUBLISH=0

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_ROOT=$(cd -- "$HERE/.." && pwd)
cd "$DEPLOY_ROOT"

ENV_FILE=${CF_ENV_FILE:-compose/mainnet.env}
TOKENS_FILE=${CF_TOKENS_FILE:-compose/estate/tokens.env}
PROJECT=${COMPOSE_PROJECT_NAME:-cloudsforge-estate}

for f in "$ENV_FILE" "$TOKENS_FILE"; do
  [ -r "$f" ] || { echo "conformance-replay: cannot read $f" >&2; exit 1; }
done

# Docker on the app host is configured with a `credsStore` helper that is not on PATH in a
# non-interactive session, and every pull then fails with an error that says nothing about
# credentials. An empty config in a scratch directory is the whole fix.
DOCKER_CFG=$(mktemp -d)
printf '{}' > "$DOCKER_CFG/config.json"
export DOCKER_CONFIG=$DOCKER_CFG
trap 'rm -rf "$DOCKER_CFG"' EXIT

# BOTH `--env-file` flags. `--env-file` REPLACES the default rather than adding to it
# (micro-org#158), so dropping either one silently empties half the variables this service
# requires — and every one of them is `:?`, so it fails loudly rather than running degraded.
#
# `compare` exits non-zero ONLY on a breaking difference — a benign one is a difference the
# normaliser expected — and `--rm` plus no `-T` means that status comes straight back here.
exec docker compose -p "$PROJECT" \
  --env-file "$ENV_FILE" --env-file "$TOKENS_FILE" \
  -f compose/docker-compose.estate.yml \
  -f compose/docker-compose.conformance.yml \
  run --rm --no-deps \
  -e CF_CONFORMANCE_PUBLISH="$PUBLISH" \
  conformance-runner once
