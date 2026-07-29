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
FILES=(-f compose/docker-compose.telemetry.yml)
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

# Beacon gates /metrics behind auth, deliberately — an open /metrics publishes
# the shape of the estate to anyone who can reach the port. Prometheus reads the
# token from this file via `http_headers: files:` rather than from its config,
# because a token in a config file is a token in a backup and in a screenshot.
#
# An EMPTY file is the honest default: the scrape then 401s and
# `BeaconScrapeFailing` fires, which is a visible, actionable state. Writing a
# guessed token would produce the same 401 with no explanation.
printf '%s' "${CF_BEACON_TOKEN:-}" > prometheus/secrets/beacon_token
chmod 600 prometheus/secrets/beacon_token

# Alert delivery. Unconfigured falls back to the Beacon incident receiver, which
# is a degradation (no acknowledgement, no escalation) and not a failure —
# alerts still land where incidents already live.
BEACON_FALLBACK="http://beacon:4011/api/alerts/webhook"
printf '%s' "${CF_PAGE_WEBHOOK_URL:-$BEACON_FALLBACK}"   > alertmanager/secrets/page_webhook_url
printf '%s' "${CF_TICKET_WEBHOOK_URL:-$BEACON_FALLBACK}" > alertmanager/secrets/ticket_webhook_url
chmod 600 alertmanager/secrets/*_webhook_url

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
