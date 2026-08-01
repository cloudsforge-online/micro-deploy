#!/usr/bin/env bash
# Drive the running slice and assert the seams that no unit test can reach.
#
#   cd deploy
#   docker compose -f compose/docker-compose.slice.yml up -d --build
#   ./scripts/slice-verify.sh
#
# Every check here failed to exist until the slice did. The estate had 41 pushed
# repositories, ~5,600 passing tests and no way to start one service, so nothing
# below had ever been true or false — it had never been asked.
set -uo pipefail

IDENTITY=${IDENTITY:-http://127.0.0.1:4401}
LEDGER=${LEDGER:-http://127.0.0.1:4402}
fails=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
code() { curl -s -o /tmp/slice.body -w '%{http_code}' "$@"; }

echo "── health, over a real socket ───────────────────────────────────────────"
for pair in "identity $IDENTITY" "ledger $LEDGER"; do
  set -- $pair
  [ "$(code "$2/livez")"  = 200 ] && ok "$1 /livez"  || bad "$1 /livez"
  # /readyz probes the database. /livez answers while it is unreachable, which is
  # the whole distinction the two endpoints exist to draw.
  [ "$(code "$2/readyz")" = 200 ] && ok "$1 /readyz" || bad "$1 /readyz"
done

echo "── identity publishes a signing key ─────────────────────────────────────"
jwks=$(curl -s "$IDENTITY/.well-known/jwks.json")
if printf '%s' "$jwks" | grep -q '"kty"'; then
  alg=$(printf '%s' "$jwks" | python3 -c "import sys,json;print(json.load(sys.stdin)['keys'][0].get('alg'))" 2>/dev/null)
  [ "$alg" = "RS256" ] && ok "JWKS serves an RS256 key" || bad "JWKS alg is $alg, expected RS256"
else
  bad "JWKS has no keys"
fi

echo "── a user can be created and can sign in ────────────────────────────────"
EMAIL="slice-$$@example.test"
PASS="correct-horse-battery-staple-42"
reg=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"handle\":\"slice$$\",\"password\":\"$PASS\"}")
utok=$(printf '%s' "$reg" | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
[ -n "$utok" ] && ok "register issues an access token" || bad "register: $(printf '%s' "$reg" | head -c 120)"

echo "── THE BOOTSTRAP GAP ────────────────────────────────────────────────────"
# A fresh deployment cannot issue its first service token. /service-tokens
# requires the `admin` role; users.roles defaults to '{}'; and NO route in
# identity grants a role. So no service can authenticate to another until
# somebody edits the database by hand. Asserted rather than worked around,
# because the day identity grows a bootstrap this check should fail and be
# deleted.
mint=$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' -d '{"service":"ledger","scopes":["ledger:read"]}')
[ "$mint" = 403 ] && ok "a normal user cannot mint a service token (403) — expected, and the gap" \
                  || bad "expected 403 for a non-admin, got $mint"

# The only way through today. If this stops being necessary, delete it.
docker compose -f compose/docker-compose.slice.yml exec -T postgres \
  psql -qtA -U cloudsforge -d identity \
  -c "update users set roles = array['admin'] where email = '$EMAIL';" >/dev/null 2>&1 \
  && ok "promoted to admin BY DIRECT SQL — the estate has no other path" \
  || bad "could not promote via SQL"

echo "── a service token crosses the wire ─────────────────────────────────────"
utok=$(curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
stok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' -d '{"service":"ledger","scopes":["ledger:read"]}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('token') or d.get('serviceToken') or d.get('accessToken') or '')" 2>/dev/null)
[ -n "$stok" ] && ok "identity minted a service token for ledger" || bad "no service token issued"

echo "── THE SEAM: ledger verifies identity's token over a real JWKS fetch ────"
# Until this ran, every test of @cloudsforge/auth fetched a JWKS from a stub in
# the same process. This is the first time one service has verified another's
# signature across a network.
[ "$(code "$LEDGER/entries" -H "authorization: Bearer $stok")" = 200 ] \
  && ok "GET /entries accepts identity's token" || bad "ledger refused a valid service token"
[ "$(code "$LEDGER/trial-balance" -H "authorization: Bearer $stok")" = 200 ] \
  && ok "GET /trial-balance accepts identity's token" || bad "trial-balance refused"

echo "── and refuses what it should ───────────────────────────────────────────"
[ "$(code "$LEDGER/entries")" = 401 ] && ok "no token is 401" || bad "an unauthenticated read was not 401"
[ "$(code "$LEDGER/entries" -H 'authorization: Bearer not.a.token')" = 401 ] \
  && ok "a forged token is 401" || bad "a forged token was not refused"

echo "── the books balance on an empty ledger ─────────────────────────────────"
tb=$(curl -s "$LEDGER/trial-balance" -H "authorization: Bearer $stok")
printf '%s' "$tb" | grep -q '"balanced":true' && ok "trial balance is balanced" || bad "trial balance: $tb"

echo
[ "$fails" -eq 0 ] && { echo "all seams verified"; exit 0; }
echo "$fails check(s) failed"; exit 1
