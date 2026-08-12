#!/usr/bin/env bash
# Is the Prometheus that is RUNNING reading the prometheus.yml in this checkout?
#
# ── WHY THIS CANNOT BE ANSWERED BY LOOKING AT THE FILE (micro-org#438) ────────
#
# `prometheus.yml` reaches the container as a SINGLE-FILE bind mount:
#
#     ../prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
#
# and on this host that is a SNAPSHOT TAKEN WHEN THE CONTAINER WAS CREATED, not
# a live view of the file. Nothing done to the file afterwards reaches the
# container — not a rewrite, not a rename, not an in-place append.
#
# That is stronger than the usual story, which is worth saying because the usual
# story is what a person will reach for and it is not what happens here. On
# native Linux a single-file bind is pinned to the INODE, so `git checkout` —
# which replaces a tracked file by rename — breaks it, while an in-place write
# still shows through. Under Docker Desktop's WSL2 indirection the mount source
# is not the checkout at all:
#
#     /run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/Ubuntu-24.04/273b9437...
#
# so neither propagates. Measured on the app host on 2026-08-12:
#
#   A  single file, in-place append, SAME inode (verified 41304 -> 41304)
#      container sees it .................................................. NO
#   B  directory mount, in-place append to a file inside it
#      container sees it ................................................. YES
#   C  directory mount, brand new file created inside it
#      container sees it ................................................. YES
#   D  this file mid-deploy of micro-org#437, checkout correct on disk:
#      grep -c 'cloudsforge-estate-'   checkout 5,  container 0
#
# A is the probe that settles it: same inode, still invisible. So this is not the
# inode hazard wearing a different hat, and a fix that only avoided renames would
# not have worked.
#
# ── AND WHY NEITHER OF THE TWO OBVIOUS CHECKS CATCHES IT ─────────────────────
#
# `POST /-/reload` re-reads `--config.file`, which resolves to the snapshot. It
# parses fine and returns 200 — measured, on this host, against a file the
# checkout had already changed. A reload is not a no-op that fails loudly; it is
# a no-op that SUCCEEDS, and a deploy that ends in a green reload has proved
# nothing at all about prometheus.yml.
#
# `promtool check config prometheus/prometheus.yml` reads the host's file, which
# is the correct one. It is green for the same reason it is useless here.
#
# Both of the things a person reaches for confirm the wrong file. That is why
# this compares the two sides directly, and why it is worth a script.
#
# ── THE THREE CASES, WHICH ARE NOT TWO ───────────────────────────────────────
#
#   prometheus/targets/     directory mount   file_sd, re-read every 30s
#   prometheus/rules/       directory mount   needs POST /-/reload
#   prometheus/prometheus.yml   SINGLE FILE   needs a container RECREATE
#
# Directory mounts are live in both directions — probes B and C above — so only
# the single file has the problem, and it is the one file nothing re-reads on a
# timer.
#
# `docker compose up -d` does NOT fix it either. Compose recreates on a change
# to the service's config hash or image, and neither moves when only the CONTENT
# behind an unchanged mount spec has changed. So the ordinary deploy path leaves
# it exactly as it was — which is why --fix exists and why estate-up.sh passes it.
#
# Usage:
#   check-prometheus-config-live.sh          report, exit 1 on drift
#   check-prometheus-config-live.sh --fix    report and recreate the container
set -u

cd "$(dirname "$0")/.." || exit 2

CONTAINER=${CF_PROMETHEUS_CONTAINER:-cfmicro-prometheus-1}
PROJECT=${COMPOSE_PROJECT_NAME:-cfmicro}
HOST_FILE=prometheus/prometheus.yml
fix=0
[ "${1:-}" = "--fix" ] && fix=1

if [ ! -f "$HOST_FILE" ]; then
  echo "no $HOST_FILE in this checkout; nothing to compare" >&2
  exit 2
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  # Not an error. On a host that has never brought telemetry up there is no
  # running config to disagree with the checkout, and saying so beats failing a
  # deploy over a container that is legitimately absent.
  echo "  $CONTAINER is not running — no live config to compare"
  exit 0
fi

# sha256 both sides. Comparing digests rather than diffing keeps this quiet
# about a config that legitimately contains scrape credentials' FILE PATHS and
# keeps the output free of anything worth redacting.
host_sum=$(sha256sum "$HOST_FILE" | cut -d' ' -f1)
live_sum=$(docker exec "$CONTAINER" sha256sum /etc/prometheus/prometheus.yml 2>/dev/null | cut -d' ' -f1)

if [ -z "$live_sum" ]; then
  echo "could not read /etc/prometheus/prometheus.yml inside $CONTAINER" >&2
  exit 2
fi

if [ "$host_sum" = "$live_sum" ]; then
  echo "  ok — $CONTAINER is reading this checkout's prometheus.yml (${host_sum:0:12})"
  exit 0
fi

echo
echo "PROMETHEUS IS RUNNING A DIFFERENT prometheus.yml FROM THIS CHECKOUT (micro-org#438)"
echo
echo "    checkout   ${host_sum:0:12}  $HOST_FILE"
echo "    container  ${live_sum:0:12}  $CONTAINER:/etc/prometheus/prometheus.yml"
echo
echo "  A single-file bind mount is a snapshot taken when the container was"
echo "  created, so editing the file changes nothing here. A reload will re-read"
echo "  the snapshot and return 200. The container has to be recreated."

if [ "$fix" -eq 0 ]; then
  echo
  echo "  Recreate it with:"
  echo "    docker compose -p $PROJECT --env-file .env \\"
  echo "      -f compose/docker-compose.telemetry.yml \\"
  echo "      up -d --no-deps --force-recreate prometheus"
  echo
  echo "  or re-run this with --fix."
  exit 1
fi

echo
echo "  --fix: recreating $CONTAINER ─────────────────────────────────────────"
# --env-file .env explicitly: compose loads a default `.env` from the PROJECT
# directory, which is `compose/` here because that is where the first -f lives,
# and the file is at the deploy root. Without it every service in the telemetry
# file fails interpolation on CF_GRAFANA_ADMIN_PASSWORD before anything runs —
# which is a confusing way to be told the env file was not found.
#
# --no-deps so a sibling that happens to be unhealthy does not take the whole
# command down, and --force-recreate because that is the entire point: compose
# would otherwise decide nothing had changed, which is the bug.
if ! docker compose -p "$PROJECT" --env-file .env \
  -f compose/docker-compose.telemetry.yml \
  up -d --no-deps --force-recreate prometheus; then
  echo "the recreate failed; Prometheus is still reading the stale config" >&2
  exit 1
fi

# Prove it rather than assume it. A recreate that came back up on the same stale
# inode — which is what would happen if the mount spec itself were wrong — looks
# identical from the outside to one that worked.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  live_sum=$(docker exec "$CONTAINER" sha256sum /etc/prometheus/prometheus.yml 2>/dev/null | cut -d' ' -f1)
  [ -n "$live_sum" ] && break
done

if [ "$host_sum" != "$live_sum" ]; then
  echo >&2
  echo "RECREATED AND STILL DIFFERENT (${live_sum:0:12} != ${host_sum:0:12})." >&2
  echo "A recreate takes a fresh snapshot, so this is not the mount hazard —" >&2
  echo "check the volume line in" >&2
  echo "compose/docker-compose.telemetry.yml actually points at this checkout." >&2
  exit 1
fi

echo "  ok — $CONTAINER now reads this checkout's prometheus.yml (${host_sum:0:12})"
