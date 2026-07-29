#!/usr/bin/env bash
# Stop the telemetry plane. The existing estate is untouched — this project owns
# nothing it did not create.
#
#   ./down.sh             stop, keep 15d of metrics and 30d of logs
#   ./down.sh --volumes   stop and DELETE all telemetry history

set -euo pipefail
cd "$(dirname "$0")"

PROJECT="${COMPOSE_PROJECT_NAME:-cfmicro}"
ARGS=(-p "$PROJECT"
      -f compose/docker-compose.telemetry.yml
      -f compose/docker-compose.gateway.yml
      down --remove-orphans)

# Volumes are kept by default. Losing a week of traces is not a business event
# (13-operational-model.md §14), but losing them because somebody typed `down`
# during an incident is an avoidable one.
[[ "${1:-}" == "--volumes" ]] && ARGS+=(--volumes)

docker compose "${ARGS[@]}"

# The gateway overlay declares the three networks `external`, so compose will not
# remove them even though the telemetry file created them — from its point of
# view they belong to somebody else. Remove them here, ignoring failure, so a
# teardown leaves the host as it found it. `docker network rm` refuses a network
# that still has an endpoint, which is the safety we want: if something else is
# attached, it stays.
#
# `stack_default` is deliberately absent from this list. It is the existing
# estate's network and this project does not own it.
for net in cf-micro-edge cf-micro-app cf-micro-vault; do
  docker network rm "$net" >/dev/null 2>&1 || true
done

echo
echo "Existing estate, still running:"
docker ps --filter name=cloudsforge- --format '{{.Names}}\t{{.Status}}' | sort
