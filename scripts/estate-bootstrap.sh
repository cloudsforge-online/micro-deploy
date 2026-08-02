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
# ── THE TEN-MINUTE CLIFF, AND WHAT NOW FIXES IT ────────────────────────────────
#
# This file used to say that ten minutes after it ran, every service-to-service
# call in the money tier began failing 401 until it was run again — because
# identity issues service tokens with a 600s TTL (identity/src/tokens.ts:28) and
# nothing re-minted one. It named the fix it could not make: "a longer-lived
# machine credential, or a client-credentials grant a service can call for
# itself". **identity now has exactly that.**
#
#   POST /service-credentials          (admin) creates a long-lived credential
#   POST /service-tokens/exchange      (that credential) mints a 600s token
#
# So this script now provisions TWO things per service, and they are different
# in kind:
#
#   * a SERVICE TOKEN, which still expires in ten minutes. Every consuming
#     service still reads one from its environment today, so it is still minted
#     here and the ten-minute property of that particular string is unchanged.
#   * a SERVICE CREDENTIAL, which does not expire, and from which a service can
#     mint its own tokens for as long as it runs — including after a restart
#     days later, which no token could ever have survived.
#
# THE TTL IS DELIBERATELY NOT LENGTHENED. Ten minutes is the security property
# SD-05 bought; the defect was never the lifetime, it was that the thing a
# container held AT REST was a token. See identity/src/serviceCredentials.ts.
#
# THE CLIFF IS NOT GONE FROM THE ESTATE UNTIL EVERY CONSUMER ADOPTS THE
# CREDENTIAL. Each service must call the exchange from its token provider
# instead of returning a static string — wallet's `const token = () =>
# env.serviceToken` (wallet/src/index.ts:90) is the seam, and it was always
# meant for this. Until an owner does that for their service, that service is
# still on the cliff and re-running this script is still its only renewal.
# `estate-verify.sh` proves the exchange works end to end over a real socket.
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
  echo "# TWO KINDS OF SECRET LIVE HERE AND THEY EXPIRE DIFFERENTLY:"
  echo "#   *_SERVICE_TOKEN / *_TOKEN      a 10-minute token (identity/src/tokens.ts:28)"
  echo "#   *_IDENTITY_CREDENTIAL          long-lived; mints its own tokens, survives a restart"
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

echo "── 5b. one long-lived CREDENTIAL per service — the cliff fix ────────────"
# The distinct services above. A credential belongs to a SERVICE, not to a call
# site, because identity reads the service off the credential row and never off
# the request — so one credential mints every token that service is allowed,
# which is why hub-api needs one here despite holding six separate tokens.
#
# Scopes are deliberately NOT listed. The exchange defaults to the service's
# whole IDENTITY_SERVICE_TOKEN_GRANTS allowlist, and a long-running provider
# wants that: at boot it cannot know which of its call sites will be reached. A
# caller that knows better narrows the request itself, and identity never widens.
SERVICES="wallet settlement billing mint market trade worlds nda community admin-api analytics hub-api"

# A stable label so a re-run can retire the credential the previous run created
# rather than piling up a live secret per bootstrap. The secret is unrecoverable
# by design, so "reuse the existing one" is not available — replace-and-revoke
# is, and it is the honest operation.
CRED_LABEL="estate-bootstrap"

# Every live credential this script created before, revoked before new ones are
# made. Read once rather than per service: 12 services would otherwise be 12
# identical list calls.
existing=$(curl -s "$IDENTITY/service-credentials" -H "authorization: Bearer $utok")
stale=$(printf '%s' "$existing" | python3 -c "
import sys, json
try: creds = json.load(sys.stdin).get('credentials', [])
except Exception: creds = []
print(' '.join(c['id'] for c in creds
                if c.get('label') == '$CRED_LABEL' and not c.get('revokedAt')))" 2>/dev/null)

revoked=0
for id in ${stale:-}; do
  rc=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$IDENTITY/service-credentials/$id/revoke" -H "authorization: Bearer $utok")
  [ "$rc" = 200 ] && revoked=$((revoked+1))
done
[ "$revoked" -gt 0 ] && ok "revoked $revoked credential(s) from a previous bootstrap"

credentialled=0
for service in $SERVICES; do
  # WALLET_IDENTITY_CREDENTIAL, HUB_API_IDENTITY_CREDENTIAL, and so on. A new
  # suffix rather than reusing *_SERVICE_TOKEN: the two are different kinds of
  # thing and a container that confused them would send a credential where a
  # token belongs. It also avoids a collision — community's TOKEN variable is
  # already, confusingly, called COMMUNITY_SERVICE_CREDENTIAL.
  var="$(printf '%s' "$service" | tr 'a-z-' 'A-Z_')_IDENTITY_CREDENTIAL"
  response=$(curl -s -X POST "$IDENTITY/service-credentials" \
    -H "authorization: Bearer $utok" -H 'content-type: application/json' \
    -d "{\"service\":\"$service\",\"label\":\"$CRED_LABEL\"}")
  secret=$(printf '%s' "$response" | jsonfield secret)
  if [ -n "$secret" ]; then
    echo "$var=$secret" >> "$tmp"
    credentialled=$((credentialled+1))
  else
    bad "$var ($service): $(printf '%s' "$response" | head -c 160)"
  fi
done

mv "$tmp" "$TOKENS_FILE"
ok "minted $minted token(s) and $credentialled credential(s) into $TOKENS_FILE"

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
  echo "bootstrapped."
  echo
  echo "  The *_SERVICE_TOKEN values expire in 10 minutes. Every service that still"
  echo "  reads one from its environment is still on the cliff, and re-running this"
  echo "  script is still its only renewal."
  echo
  echo "  The *_IDENTITY_CREDENTIAL values do not expire. A service that mints through"
  echo "  POST /service-tokens/exchange never needs this script again."
  echo
  echo "next:  ./scripts/estate-verify.sh"
  exit 0
fi
echo "$fails step(s) failed"
exit 1
