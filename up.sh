#!/usr/bin/env bash
# Bring the CloudsForge telemetry plane up beside the existing estate.
#
#   ./up.sh              telemetry only
#   ./up.sh --gateway    telemetry + Traefik
#   ./down.sh            stop it again
#
# Idempotent. Running it twice is a no-op plus a reload.

set -euo pipefail
cd "$(dirname "$0")"

PROJECT="${COMPOSE_PROJECT_NAME:-cfmicro}"
TELEMETRY=(-f compose/docker-compose.telemetry.yml)
FILES=("${TELEMETRY[@]}")
[[ "${1:-}" == "--gateway" ]] && FILES+=(-f compose/docker-compose.gateway.yml)

# ---------------------------------------------------------------- secrets ---
# Written, never committed. `.gitignore` in each directory refuses them, so a
# credential cannot be added to the repository by accident — which is a stronger
# guarantee than remembering not to.
mkdir -p prometheus/secrets alertmanager/secrets

# Load ../.env if the operator made one. Absent is a supported mode: every
# value below has a default that works on loopback, and the stack comes up
# degraded-but-honest rather than refusing to start.
[[ -f .env ]] && set -a && . ./.env && set +a

# ── WRITING A SECRET MUST NOT BE A WAY OF DESTROYING ONE (micro-org#321) ──────
#
# Every line below used to be a bare `printf '%s' "${VAR:-}" > file`, which turns
# an unset variable into an ERASED credential. That is not hypothetical and it
# was not the token this script was written for: measured on the mainnet host on
# 2026-08-10, `.env` sets CF_BEACON_TOKEN and does NOT set CF_ANALYTICS_TOKEN or
# CF_LANTERN_TOKEN, while `prometheus/secrets/analytics_token` and
# `lantern_token` both held a real 44-byte value that an operator had put there
# by hand, exactly as README §Secrets tells them to. The next run of this
# idempotent, safe-to-repeat script would have emptied both and taken two scrapes
# down — and the failure would have looked like Prometheus's fault.
#
# So: a value in the environment wins, absence keeps what is already there, and
# a missing file is always created. The last part matters as much as the first —
# Prometheus refuses to start when a `files:` path is absent and Alertmanager
# fails its `credentials_file` the same way, so "create it empty" is what keeps
# unconfigured a supported mode rather than a plane that will not come up.
#
# 0644 and not 0600 for the reason spelled out at the Beacon token below.
write_secret() {
  local path="$1" value="${2:-}"
  if [[ -z "$value" && -s "$path" ]]; then
    echo "up.sh: keeping the existing $(basename "$path") — nothing in .env to replace it with" >&2
  else
    printf '%s' "$value" > "$path"
  fi
  chmod 644 "$path"
}

# Beacon gates /metrics behind auth, deliberately — an open /metrics publishes
# the shape of the estate to anyone who can reach the port. Prometheus reads the
# token from this file via `http_headers: files:` rather than from its config,
# because a token in a config file is a token in a backup and in a screenshot.
#
# An EMPTY file is the honest default: the scrape then 401s and
# `BeaconScrapeFailing` fires, which is a visible, actionable state. Writing a
# guessed token would produce the same 401 with no explanation.
#
# ── 0644 AND NOT 0600, WHICH IS NOT A RELAXATION (micro-org#308) ──────────────
#
# This was `chmod 600`, and 0600 is unreadable by the process that has to read
# it. Prometheus and Alertmanager both run as the image default `nobody`
# (uid 65534, verified with `docker exec … id` on 2026-08-09); these files are
# written by the operator (uid 1000) and mounted read-only, so owner-only means
# owner-only for a user that is not in the container. Setting the token then
# produced the SAME dead scrape as not setting it, with a different message:
#
#   unable to read headers file /etc/prometheus/secrets/beacon_token
#
# Measured here on 2026-08-09 while fixing the Beacon target: the token was
# written, and the scrape stayed down until the mode changed. A permission that
# silently converts a configured credential into an unconfigured one is worse
# than a mode that a second Unix account on a single-operator deploy host could
# read — and no such account exists. The real containment is that none of these
# files is ever committed, which `.gitignore` enforces.
#
# Prometheus cannot be told to run as another uid without also owning
# `/prometheus`, and chown to 65534 needs root the deploy does not have.
write_secret prometheus/secrets/beacon_token "${CF_BEACON_TOKEN:-}"

# The SAME token, in a second file, for Alertmanager (micro-org#311). Beacon's
# `/api/alerts/webhook` is gated exactly like its `/metrics`, and every alert in
# alertmanager.yml routes to it, so an alert that cannot authenticate is an
# incident that is never opened — the alerting plane wired end to end and silent.
#
# Alertmanager cannot send `x-beacon-token`: its `http_config` offers
# `basic_auth`, `authorization` and `oauth2` and no arbitrary header. Beacon
# therefore accepts the same credential as `Authorization: Bearer`
# (micro-beacon#10), and this is the file that `authorization.credentials_file`
# reads. Same secret, same scopes, still not an administrator.
#
# A SECOND FILE AND NOT A SHARED ONE, because the two directories are two
# read-only mounts into two containers, and mounting Prometheus's secrets
# directory into Alertmanager to save a copy would hand Alertmanager the
# analytics and lantern tokens as well — three credentials to deliver one.
write_secret alertmanager/secrets/beacon_token "${CF_BEACON_TOKEN:-}"

# `analytics` and `lantern` gate /metrics the same way and for the same reason,
# each with its own header and its own job in prometheus.yml — Prometheus
# attaches credentials per job and not per target, so three gated services are
# three jobs. Empty is the honest default here too.
write_secret prometheus/secrets/analytics_token "${CF_ANALYTICS_TOKEN:-}"
write_secret prometheus/secrets/lantern_token "${CF_LANTERN_TOKEN:-}"

# Alert delivery. Unconfigured falls back to the Beacon incident receiver, which
# is a degradation (no acknowledgement, no escalation) and not a failure —
# alerts still land where incidents already live.
#
# 4000, NOT 4011. This said 4011 — Beacon's own default bind port in its source —
# and the estate's compose normalises every service to `PORT: 4000` through the
# `x-common-env` anchor. From inside the Alertmanager container on 2026-08-09:
#
#   http://beacon:4011/api/alerts/webhook  can't connect: Connection refused
#   http://beacon:4000/api/alerts/webhook  HTTP/1.1 401 Unauthorized
#
# So the fallback every unconfigured alert has ever taken went to a port nothing
# binds. 4000 reaches the route; it still 401s, because the webhook presents no
# `x-beacon-token` and Alertmanager v0.27's `http_config` has no way to set an
# arbitrary header. That half is filed separately and is not a scrape-config
# problem — but a refused connection and an authentication failure are not the
# same finding, and only one of them is visible in a log.
#
# The fallback POST carries NO credential — a `url_file` receiver has no
# `http_config` here on purpose, because when these ARE configured they point at
# Slack or PagerDuty and Beacon's token must not be sent to either. So the
# fallback still 401s at Beacon. It loses nothing: every alert already reaches
# Beacon through the `beacon-incident` receiver, which now does authenticate, and
# the fallback was only ever a second copy of the same POST.
BEACON_FALLBACK="http://beacon:4000/api/alerts/webhook"
write_secret alertmanager/secrets/page_webhook_url   "${CF_PAGE_WEBHOOK_URL:-$BEACON_FALLBACK}"
write_secret alertmanager/secrets/ticket_webhook_url "${CF_TICKET_WEBHOOK_URL:-$BEACON_FALLBACK}"

# ------------------------------------------------------------- dashboards ---
# Regenerated from the validated palette every time, so a hand-edit to the JSON
# is reverted rather than silently kept. Grafana has no way to register a custom
# palette, so the colours are written into the panels — and the only thing that
# keeps forty panels agreeing is that one program writes all of them.
if command -v python3 >/dev/null 2>&1; then
  python3 grafana/build-dashboards.py
else
  echo "warning: python3 not found — using the committed dashboard JSON as-is" >&2
fi

# ------------------------------------------------------------------- guard ---
# The existing estate must be untouched. If its network is missing, Prometheus
# cannot scrape Beacon and the operator should know that now rather than from an
# empty panel in three weeks.
if ! docker network inspect stack_default >/dev/null 2>&1; then
  echo "warning: network 'stack_default' not found — the existing estate is not running." >&2
  echo "         The telemetry plane will come up, but the Beacon scrape will fail." >&2
fi

# ------------------------------------------------- networks, then the rest ---
# THE TELEMETRY FILE GOES UP ON ITS OWN FIRST, and `--gateway` was broken without
# it on any machine where the networks did not already exist.
#
# `docker-compose.telemetry.yml` CREATES `cf-micro-edge`, `cf-micro-app` and
# `cf-micro-vault`. `docker-compose.gateway.yml` declares the same three as
# `external: true`. Compose merges the top-level `networks:` map across `-f`
# files and the LAST declaration wins — so passing both in one invocation turned
# the creator into an attacher, and the command died with "network cf-micro-app
# declared as external, but could not be found".
#
# The gateway file's header has always said "the telemetry file must be up
# first: it creates the three networks this one attaches to as external". This is
# what "first" has to mean: a separate invocation, not an earlier `-f`.
if [[ "${1:-}" == "--gateway" ]]; then
  docker compose -p "$PROJECT" "${TELEMETRY[@]}" up -d
fi

docker compose -p "$PROJECT" "${FILES[@]}" up -d --remove-orphans

echo
echo "  Grafana       http://127.0.0.1:9091   (admin / \$CF_GRAFANA_ADMIN_PASSWORD)"
echo "  Prometheus    http://127.0.0.1:9090"
echo "  Alertmanager  http://127.0.0.1:9093"
echo "  Tempo         http://127.0.0.1:9094"
echo "  Loki          http://127.0.0.1:9092"
echo "  OTLP          grpc 127.0.0.1:9317 · http 127.0.0.1:9318"
echo
echo "Every port is bound to loopback. This is an operator plane, not a public surface."
