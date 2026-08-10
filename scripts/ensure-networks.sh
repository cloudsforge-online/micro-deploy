#!/usr/bin/env bash
# Create the three `cf-micro-*` networks if they are missing. Idempotent.
#
#   ./scripts/ensure-networks.sh
#
# ── WHY THIS IS NOT A COMPOSE FILE'S JOB ANY MORE ─────────────────────────────
#
# `docker-compose.telemetry.yml` used to declare these three as networks it
# creates, while `docker-compose.gateway.yml` and
# `docker-compose.estate-gateway.yml` declare the same three as `external: true`.
# Compose merges the top-level `networks:` map across `-f` files LAST-WINS, so
# which file "owns" a network depended on the order of the `-f` flags — pass the
# gateway file second and the creator becomes an attacher. Three file headers in
# this repository carried a paragraph explaining the resulting discipline.
#
# On 2026-08-10 that model was checked against the host. All three networks exist
# with no labels whatsoever, so nothing in compose created them and compose will
# not adopt them:
#
#   network cf-micro-app was found but has incorrect label
#   com.docker.compose.network set to "" (expected: "app")
#
# and that is fatal. Every "telemetry on its own" invocation the repository
# documents had therefore been broken for as long as those networks had existed.
# It went unnoticed because the merged invocations — the ones that actually got
# run — attached rather than created, so they never hit the check.
#
# One shell script owning them makes the ownership explicit, matches what is
# already true on the host, and lets every compose file declare `external: true`,
# which removes the ordering hazard entirely rather than documenting it.
#
# ── WHY IT NEVER MODIFIES ONE THAT EXISTS ─────────────────────────────────────
#
# Because the only way to change a network's attributes is to delete and recreate
# it, and both `cf-micro-edge` and `cf-micro-app` have the live gateway attached.
# Deleting one is a public outage. So this creates what is absent, reports what is
# present and wrong, and leaves the decision to a human with a maintenance window.
#
# It reports rather than fixes exactly one known drift today: `cf-micro-vault` is
# live with `Internal=false` while every declaration of it said `internal: true`.
# Nothing is attached to it, so that one is cheap to correct — `docker network rm
# cf-micro-vault` and re-run this — but it is still a delete, and a script that
# deletes networks is a script that will one day delete the wrong one.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f .env ]] && set -a && . ./.env && set +a

prefix="${CF_NET_PREFIX:-cf-micro}"

# name → extra `docker network create` flags. `vault` is internal — no route to
# the outside world — because it is the network custody would join, and the
# guarantee wanted there is that the gateway cannot reach it at all.
declare -A want=(
  ["${prefix}-edge"]=""
  ["${prefix}-app"]=""
  ["${prefix}-vault"]="--internal"
)

# Exit status means "the networks this stack needs exist", and nothing else. The
# drift below is reported loudly and does NOT fail the run: both callers have
# `set -e`, and refusing to bring the telemetry plane up over a network property
# that no running container uses would be trading an alerting plane for a lint.
for net in "${!want[@]}"; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    internal=$(docker network inspect "$net" --format '{{.Internal}}')
    if [[ "${want[$net]}" == *--internal* && "$internal" != "true" ]]; then
      echo "DRIFT: $net exists but is NOT internal, and every declaration of it says it is."
      echo "       Nothing is attached to it today, so the correction is cheap:"
      echo "         docker network rm $net && ./scripts/ensure-networks.sh"
      echo "       Check the attachment count first; this script will not delete it for you."
    else
      echo "ok: $net exists"
    fi
    continue
  fi
  # shellcheck disable=SC2086 # the flags are a deliberate word-split
  docker network create ${want[$net]} \
    --label com.cloudsforge.owner=deploy/scripts/ensure-networks.sh \
    "$net" >/dev/null
  echo "created: $net ${want[$net]}"
done
