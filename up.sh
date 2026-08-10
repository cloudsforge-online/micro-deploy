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

# ── THE GATEWAY IS ITS OWN PROJECT, AND IT IS THE ESTATE'S (micro-org#257) ────
#
# It used to share `$PROJECT` with the telemetry plane, so the container every
# public hostname depends on was labelled `cfmicro` while the ~50 services it
# serves are labelled `cloudsforge-estate`. `docker compose -p cloudsforge-estate
# ps` did not list it, which is how the TESTNET gateway came to be deleted twice
# in three days as an apparent orphan, both times taking every public hostname to
# 502 with all 46 services healthy.
#
# It was also armed here, on mainnet, in a way the issue did not name: the
# telemetry invocation below passes `--remove-orphans`, and without `--gateway`
# the gateway file was not passed at all. So a plain `./up.sh` — the documented,
# idempotent, safe-to-repeat command — would have found `cfmicro-gateway-1` in
# its project, seen no service for it, and DELETED THE MAINNET GATEWAY. Measured
# on the host on 2026-08-10, before the split: the gateway carried
# `com.docker.compose.project=cfmicro` and `docker-compose.telemetry.yml` defines
# no `gateway` service.
#
# Splitting the projects removes both. The telemetry plane keeps `cfmicro` (its
# named volumes carry 15 days of metrics and 30 of logs, and renaming a project
# renames its volumes), and the gateway moves to the estate it serves.
GW_PROJECT="${CF_GW_PROJECT:-${CF_PROJECT:-cloudsforge-estate}}"
GATEWAY=(-f compose/docker-compose.gateway.yml)

# ---------------------------------------------------------------- secrets ---
# Written, never committed. `.gitignore` in each directory refuses them, so a
# credential cannot be added to the repository by accident — which is a stronger
# guarantee than remembering not to.
mkdir -p prometheus/secrets alertmanager/secrets
# 0750, not the umask's 0775. A directory that anybody can list is a directory
# whose file NAMES leak even when the files themselves are 0640, and `ls` on a
# secrets directory is a map of which credentials this host holds. The group is
# the operator's, which is the group the two containers are given in
# docker-compose.telemetry.yml.
chmod 750 prometheus/secrets alertmanager/secrets

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
# 0640 and not 0600 or 0644 — see the note at the Beacon token below.
write_secret() {
  local path="$1" value="${2:-}"
  if [[ -z "$value" && -s "$path" ]]; then
    echo "up.sh: keeping the existing $(basename "$path") — nothing in .env to replace it with" >&2
  else
    printf '%s' "$value" > "$path"
  fi
  chmod 640 "$path"
}

# ── ONE CREDENTIAL MUST HAVE ONE HOME (micro-org#156) ────────────────────────
# `estate_token`, `fp` and `resolve_token` live in their own file because this
# script ends by talking to Docker and so cannot be run in CI, while a rule about
# credentials that nothing exercises is true only on the day it is written.
# `scripts/check-token-resolution.sh` runs them against fixtures instead.
# shellcheck source=scripts/resolve-token.sh
. scripts/resolve-token.sh

# All three resolved BEFORE the first file is written. A refusal on the third
# token must not leave the first two already rewritten — half a rotation applied
# is the state this whole section exists to prevent.
beacon_token=$(resolve_token BEACON_TOKEN CF_BEACON_TOKEN) || exit 1
analytics_token=$(resolve_token ANALYTICS_TOKEN CF_ANALYTICS_TOKEN) || exit 1
lantern_token=$(resolve_token LANTERN_TOKEN CF_LANTERN_TOKEN) || exit 1

# Beacon gates /metrics behind auth, deliberately — an open /metrics publishes
# the shape of the estate to anyone who can reach the port. Prometheus reads the
# token from this file via `http_headers: files:` rather than from its config,
# because a token in a config file is a token in a backup and in a screenshot.
#
# An EMPTY file is the honest default: the scrape then 401s and
# `BeaconScrapeFailing` fires, which is a visible, actionable state. Writing a
# guessed token would produce the same 401 with no explanation.
#
# ── 0640, AND THE ARGUMENT THAT MADE IT 0644 WAS ABOUT A GROUP (micro-org#340) ─
#
# The history is worth keeping because both previous answers were wrong in a way
# that looked right.
#
# It was `chmod 600` first, and 0600 is unreadable by the process that has to
# read it. Prometheus and Alertmanager both run as the image default `nobody`
# (uid 65534, gid 65534, measured with `docker exec … id` on 2026-08-09 and
# again on 2026-08-10); these files are written by the operator (uid 1000) and
# mounted read-only, so owner-only means owner-only for a user that is not in
# the container. Setting the token produced the SAME dead scrape as not setting
# it, with a different message:
#
#   unable to read headers file /etc/prometheus/secrets/beacon_token
#
# So it became `chmod 644`, and that worked, and it also made three live scrape
# credentials readable by every account on the host — which is what #340 found.
# The note here defended it on the grounds that "no such account exists". That is
# a statement about today's host, offered in place of a permission.
#
# The mistake in both is the same: this was never an OWNER problem. The container
# and the operator do not need the same uid, they need one group in common. So
# `docker-compose.telemetry.yml` gives prometheus and alertmanager the operator's
# gid as a SUPPLEMENTARY group, and the files are 0640 owned by the operator.
# The reading process is inside the group; nothing else on the host is.
#
# Measured on mainnet on 2026-08-10, after: prometheus/secrets and
# alertmanager/secrets 0750, the six files 0640, `/api/v1/targets` 37 active,
# 37 up, 0 down, with beacon, analytics and lantern all `up`.
#
# THE ORDER MATTERS IF YOU EVER REDO THIS BY HAND: the containers must carry the
# group BEFORE the files stop being world-readable. Tighten first and the scrape
# dies silently, which is the failure #310/#311 were about.
write_secret prometheus/secrets/beacon_token "$beacon_token"

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
write_secret alertmanager/secrets/beacon_token "$beacon_token"

# `analytics` and `lantern` gate /metrics the same way and for the same reason,
# each with its own header and its own job in prometheus.yml — Prometheus
# attaches credentials per job and not per target, so three gated services are
# three jobs. Empty is the honest default here too.
write_secret prometheus/secrets/analytics_token "$analytics_token"
write_secret prometheus/secrets/lantern_token "$lantern_token"

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
# THE NETWORKS ARE MADE FIRST, BY A SCRIPT, AND NO COMPOSE FILE OWNS THEM.
#
# `docker-compose.telemetry.yml` used to CREATE `cf-micro-edge`, `cf-micro-app`
# and `cf-micro-vault`. `docker-compose.gateway.yml` declares the same three as
# `external: true` — and so, since 2026-08-10, does the telemetry file. Compose
# merges the top-level `networks:` map across `-f` files and the LAST declaration
# wins, so which file "owned" a network used to depend on the ORDER of the `-f`
# flags. That is not a discipline, it is a coin toss with a paragraph of
# documentation attached, and the host proved it had already been lost: all three
# networks were live with no compose labels at all, which made every
# telemetry-only invocation — this line, and step 3a of scripts/estate-up.sh —
# fail outright with "found but has incorrect label com.docker.compose.network".
#
# One script owns them now, every compose file attaches, and the ordering hazard
# does not exist to be got wrong.
./scripts/ensure-networks.sh

docker compose -p "$PROJECT" "${TELEMETRY[@]}" up -d --remove-orphans

# The gateway, second and in its own project. NO `--remove-orphans` HERE, ever:
# `$GW_PROJECT` is the estate's project, and every service in the estate is an
# orphan from the point of view of a gateway compose file. That flag on this line
# would delete the estate.
if [[ "${1:-}" == "--gateway" ]]; then
  docker compose -p "$GW_PROJECT" "${GATEWAY[@]}" up -d
fi

echo
echo "  Grafana       http://127.0.0.1:9091   (admin / \$CF_GRAFANA_ADMIN_PASSWORD)"
echo "  Prometheus    http://127.0.0.1:9090"
echo "  Alertmanager  http://127.0.0.1:9093"
echo "  Tempo         http://127.0.0.1:9094"
echo "  Loki          http://127.0.0.1:9092"
echo "  OTLP          grpc 127.0.0.1:9317 · http 127.0.0.1:9318"
echo
echo "Every port is bound to loopback. This is an operator plane, not a public surface."
