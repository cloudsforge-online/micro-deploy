#!/usr/bin/env bash
# Bring a FRESH estate to the point where services can talk to each other.
#
#   cd deploy
#   docker compose -f compose/docker-compose.estate.yml up -d
#   ./scripts/estate-bootstrap.sh
#
# ── WHY A BOOTSTRAP EXISTS AT ALL ──────────────────────────────────────────────
#
# A newly deployed estate cannot issue its own first credential.
#
#   * `POST /service-tokens` requires the `admin` role (identity/src/server.ts:1265,
#     via authenticateAdmin).
#   * `users.roles` defaults to '{}' and NO route in identity grants a role.
#   * admin-api's bootstrap endpoint returns 501 — deliberately.
#
# So the first admin is a direct UPDATE against identity's database. That is a
# considered decision, not an oversight, but it means the UPDATE has to be an
# EXPLICIT, NAMED STEP that somebody runs — which is what this file is. It was
# previously folklore buried in a verification script; folklore is how a
# production runbook acquires a step nobody can find at 3am.
#
# ── AND WHY IT HAS TO BE RE-RUN ────────────────────────────────────────────────
#
# identity issues service tokens with a TTL of 600 seconds
# (identity/src/tokens.ts:28) and nothing in the estate re-mints one. wallet built
# the seam — `const token = () => env.serviceToken` (wallet/src/index.ts:90), a
# function called per request precisely so a short-lived token could rotate — but
# it returns a static environment string, and its own comment says the rotation
# waits for "when identity starts minting them".
#
# The consequence is unavoidable and worth stating plainly: TEN MINUTES after
# this script runs, every service-to-service call in the money tier begins
# failing 401 until it is run again. This script does not fix that. It cannot:
# the fix belongs in identity (a longer-lived machine credential, or a
# client-credentials grant a service can call for itself) and in the services
# that hold one. It is written down here, and in the compose file, because a
# running environment is the only place this was ever going to be visible.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

COMPOSE=${COMPOSE:-compose/docker-compose.estate.yml}
IDENTITY=${IDENTITY:-http://127.0.0.1:4100}
TOKENS_FILE=${TOKENS_FILE:-compose/estate/tokens.env}

# A throwaway operator for a throwaway environment. Overridable so a developer
# can bootstrap an account they will actually sign in as.
ADMIN_EMAIL=${ADMIN_EMAIL:-estate-admin@example.test}
ADMIN_HANDLE=${ADMIN_HANDLE:-estateadmin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-correct-horse-battery-staple-42}

fails=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }

jsonfield() { python3 -c "import sys,json
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('')" 2>/dev/null; }

echo "── 1. identity must be answering ────────────────────────────────────────"
ready=$(curl -s -o /dev/null -w '%{http_code}' "$IDENTITY/readyz")
if [ "$ready" = 200 ]; then
  ok "identity /readyz"
else
  bad "identity /readyz returned $ready — bring the environment up first"
  echo "$fails failure(s); nothing was bootstrapped"; exit 1
fi

echo "── 2. an operator account ───────────────────────────────────────────────"
# Register is idempotent for our purposes: if the account exists the login below
# still works, so a re-run is safe.
curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"handle\":\"$ADMIN_HANDLE\",\"password\":\"$ADMIN_PASSWORD\"}" \
  >/dev/null 2>&1
ok "registered or already present: $ADMIN_EMAIL"

echo "── 3. THE MANUAL UPDATE — the estate has no other path ──────────────────"
# THIS IS THE DOCUMENTED BOOTSTRAP STEP. In a real deployment it is run by a
# human with database access, once, and recorded in the change log. If identity
# ever grows a real bootstrap, delete this block and the check in estate-verify
# that asserts a non-admin is refused.
docker compose -f "$COMPOSE" exec -T postgres \
  psql -qtA -U cloudsforge -d identity \
  -c "update users set roles = array['admin'] where email = '$ADMIN_EMAIL';" >/dev/null 2>&1 \
  && ok "promoted $ADMIN_EMAIL to admin BY DIRECT SQL" \
  || bad "could not promote via SQL"

echo "── 4. sign in as the operator ───────────────────────────────────────────"
utok=$(curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | jsonfield accessToken)
if [ -n "$utok" ]; then
  ok "operator access token acquired"
else
  bad "could not sign in as $ADMIN_EMAIL"
  echo "$fails failure(s); nothing was bootstrapped"; exit 1
fi

echo "── 5. mint one service token per credential ─────────────────────────────"
# Each line is:  ENV_VAR  service  comma-separated-scopes
#
# The scopes are the NARROWEST set that credential's holder needs, not the whole
# grant. identity de-duplicates but never widens — "a service that asks for one
# scope gets a token that says one scope, even when its allowlist permits six"
# (identity/src/serviceTokens.ts) — so asking narrowly is what makes a
# least-privilege call site actually least-privilege.
#
# hub-api holds SIX separate tokens rather than one with the union, which is the
# entire reason the scope vocabulary is granular.
#
# No `declare -A`: bash here is 3.2 and an associative array once silently broke
# five suites in this estate.
CREDENTIALS="
WALLET_SERVICE_TOKEN|wallet|ledger:read,ledger:post,ledger:reserve,custody:address:create,pricing:read,policy:decide
SETTLEMENT_SERVICE_TOKEN|settlement|ledger:read,ledger:post,custody:sign:treasury,custody:treasury:read
BILLING_LEDGER_TOKEN|billing|ledger:read,ledger:post,ledger:reserve
MINT_SERVICE_TOKEN|mint|ledger:read,ledger:post,ledger:reserve,custody:sign:deployer
MARKET_SERVICE_TOKEN|market|ledger:read,ledger:post,ledger:reserve,policy:decide
TRADE_SERVICE_TOKEN|trade|ledger:read,ledger:post,ledger:reserve,pricing:read,billing:read,billing:grant
WORLDS_SERVICE_TOKEN|worlds|ledger:read,ledger:post,billing:read,billing:grant
NDA_SERVICE_TOKEN|nda|worlds:read,worlds:write,billing:read,billing:grant
COMMUNITY_SERVICE_CREDENTIAL|community|ledger:read,ledger:post,policy:decide
ADMIN_API_SERVICE_TOKEN|admin-api|ledger:read,market:read,market:admin,billing:read
ANALYTICS_TOKEN|analytics|analytics:ingest,analytics:read
HUB_LEDGER_TOKEN|hub-api|ledger:read
HUB_WALLET_TOKEN|hub-api|wallet:read
HUB_BILLING_TOKEN|hub-api|billing:read
HUB_PRICING_TOKEN|hub-api|pricing:read
HUB_POLICY_TOKEN|hub-api|policy:decide
HUB_ACTIVITY_TOKEN|hub-api|notify:read
"

mkdir -p "$(dirname "$TOKENS_FILE")"
tmp="$TOKENS_FILE.tmp"
{
  echo "# Generated by scripts/estate-bootstrap.sh — DO NOT COMMIT."
  echo "# Every value below is a 10-minute credential (identity/src/tokens.ts:28)."
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$tmp"

minted=0
while IFS='|' read -r var service scopes; do
  [ -z "${var:-}" ] && continue
  # Turn the comma list into a JSON array without jq, which is not a dependency
  # anywhere else in this repository.
  json_scopes=$(printf '%s' "$scopes" | python3 -c "import sys,json;print(json.dumps([s for s in sys.stdin.read().strip().split(',') if s]))")
  response=$(curl -s -X POST "$IDENTITY/service-tokens" \
    -H "authorization: Bearer $utok" -H 'content-type: application/json' \
    -d "{\"service\":\"$service\",\"scopes\":$json_scopes}")
  token=$(printf '%s' "$response" | jsonfield token)
  if [ -n "$token" ]; then
    echo "$var=$token" >> "$tmp"
    minted=$((minted+1))
  else
    # Name the service AND what identity said. A token that silently fails to
    # mint becomes a 401 in a service log an hour later with no cause attached.
    bad "$var ($service): $(printf '%s' "$response" | head -c 160)"
  fi
done <<EOF
$(printf '%s' "$CREDENTIALS" | grep -v '^$')
EOF

mv "$tmp" "$TOKENS_FILE"
ok "minted $minted credential(s) into $TOKENS_FILE"

echo "── 6. hand the tokens to the services that need them ────────────────────"
# `--env-file` rather than `env_file:` on each service. The compose file names
# each variable on exactly the service that reads it, so this fills those in
# without handing every container the whole estate's secrets — the fan-out that
# pricing/src/env.ts calls out by name.
if docker compose --env-file "$TOKENS_FILE" -f "$COMPOSE" up -d >/tmp/estate-bootstrap-up.log 2>&1; then
  ok "services recreated with real credentials"
else
  bad "recreate failed; see /tmp/estate-bootstrap-up.log"
  tail -20 /tmp/estate-bootstrap-up.log
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "bootstrapped. Credentials expire in 10 minutes — re-run this script to renew."
  echo "next:  ./scripts/estate-verify.sh"
  exit 0
fi
echo "$fails step(s) failed"
exit 1
