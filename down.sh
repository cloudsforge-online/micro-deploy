#!/usr/bin/env bash
# Stop the telemetry plane. The existing estate is untouched — this project owns
# nothing it did not create.
#
#   ./down.sh             stop, keep 15d of metrics and 30d of logs
#   ./down.sh --volumes   stop and DELETE all telemetry history

set -euo pipefail
cd "$(dirname "$0")"

PROJECT="${COMPOSE_PROJECT_NAME:-cfmicro}"
# The gateway is in the ESTATE's project now (micro-org#257), so it is a second
# `down` rather than a second `-f`. It is also the reason `--remove-orphans`
# below is safe again: it applies to `$PROJECT`, which after the split contains
# the telemetry plane and nothing else.
GW_PROJECT="${CF_GW_PROJECT:-${CF_PROJECT:-cloudsforge-estate}}"
ARGS=(-p "$PROJECT"
      -f compose/docker-compose.telemetry.yml
      down --remove-orphans)

# Volumes are kept by default. Losing a week of traces is not a business event
# (13-operational-model.md §14), but losing them because somebody typed `down`
# during an incident is an avoidable one.
[[ "${1:-}" == "--volumes" ]] && ARGS+=(--volumes)

# The gateway first: it attaches to the three networks the telemetry file owns,
# and `docker network rm` below refuses a network that still has an endpoint.
#
# `stop` + `rm`, and NOT `down`, for the one reason that matters here: `down` on
# `$GW_PROJECT` with only the gateway file would be a `down` OF THE ESTATE's
# project. Compose scopes `down` to the project, not to the services in the
# files, so it would stop and remove the ~50 estate containers as well. This
# names the one container it is allowed to remove.
docker compose -p "$GW_PROJECT" -f compose/docker-compose.gateway.yml \
  rm -sf gateway 2>/dev/null || true

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
