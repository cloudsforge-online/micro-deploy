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
ACTIVITY=${ACTIVITY:-http://127.0.0.1:4403}
NOTIFY=${NOTIFY:-http://127.0.0.1:4404}
COMPOSE=${COMPOSE:-compose/docker-compose.slice.yml}
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
echo "── THE EVENT SEAM: outbox → signed HTTP → inbox ─────────────────────────"
# No route creates a subscription — deliberately: who receives which topic is deploy
# configuration, not something a caller decides. The deploy is this file, so it seeds the row.
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d identity -c \
  "insert into event_subscriptions (topic, url) values ('identity.session.created', 'http://activity:4000/ingest') on conflict do nothing" \
  >/dev/null 2>&1 && ok "subscription seeded: identity.session.created → activity" \
  || bad "could not seed the subscription row"

# A fresh login makes identity WRITE an outbox row; its relay must then sign it, POST it to
# activity's inbox, and activity must attribute it to the USER — not to the session id, which is
# the misattribution both suites missed because activity's fixtures imagined the producer.
curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$EMAIL\",\"password\":\"$PASS\"}" >/dev/null

seam=""
for _ in $(seq 1 30); do
  feed=$(curl -s "$ACTIVITY/feed" -H "authorization: Bearer $utok")
  seam=$(printf '%s' "$feed" | python3 -c "
import sys, json
try:
    records = json.load(sys.stdin).get('records', [])
except Exception:
    records = []
hits = [r for r in records if r.get('type') == 'security.session_created']
print(hits[0].get('summary', 'found') if hits else '')
" 2>/dev/null)
  [ -n "$seam" ] && break
  sleep 1
done
if [ -n "$seam" ]; then
  ok "the sign-in crossed the bus and landed in the user's own feed: $seam"
else
  bad "no session_created record reached the feed within 30s — the relay, the inbox gate, or the attribution is broken"
fi

echo "── THE ERASURE SEAM: the GDPR path, driven end to end ───────────────────"
# The contracts registry has said since it was written: "identity.user.deleted currently has no
# subscriber anywhere, which is precisely why there is no GDPR erasure path at all." The bus works
# now and a subscription is deploy configuration, so this drill makes the sentence false: delete
# an account and PROVE the consumer forgot the person.
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d identity -c \
  "insert into event_subscriptions (topic, url) values ('identity.user.deleted', 'http://activity:4000/ingest') on conflict do nothing" \
  >/dev/null 2>&1 && ok "subscription seeded: identity.user.deleted → activity" \
  || bad "could not seed the erasure subscription"
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d identity -c \
  "insert into event_subscriptions (topic, url) values ('identity.user.deleted', 'http://notify:4000/ingest') on conflict do nothing" \
  >/dev/null 2>&1 && ok "subscription seeded: identity.user.deleted → notify" \
  || bad "could not seed notify's erasure subscription"

# The subject's id, captured while the account still answers — the token dies with it.
uid=$(curl -s "$IDENTITY/auth/me" -H "authorization: Bearer $utok" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('user',{}).get('id',''))" 2>/dev/null)
[ -n "$uid" ] || bad "could not read the drill user's id"

# notify holds the most personal data in the estate; give it some to forget. A preference is a
# real, authenticated user act — and the erasure below must remove it.
curl -s -X PUT "$NOTIFY/preferences" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' \
  -d '{"preferences":[{"category":"security","channel":"in_app","digest":"instant"}]}' >/dev/null
nbefore=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d notify -c \
  "select count(*) from preferences where user_id = '$uid'" 2>/dev/null | tr -d ' ')
[ "${nbefore:-0}" -ge 1 ] && ok "notify holds $nbefore preference(s) for the user before the drill" \
  || bad "notify holds nothing for the user; its half of the drill would be vacuous"

# The user must EXIST in activity first — an erasure of nothing proves nothing.
before=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
  "select count(*) from activity_records where user_id = '$uid'" 2>/dev/null | tr -d ' ')
[ "${before:-0}" -ge 1 ] && ok "activity holds $before record(s) for $uid before the drill" \
  || bad "activity holds nothing for the user; the erasure would be vacuous"

# Request deletion (grace is 0 in the slice), then pull the HOURLY tombstone sweep forward.
# Stated plainly: the drill compresses the sweep's clock; it does not bypass the sweep. The event
# is still written by the real tombstone path, in the same transaction as the state change.
curl -s -X DELETE "$IDENTITY/users/me" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' -d "{\"password\":\"$PASS\"}" >/dev/null
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d identity -c \
  "update jobs set run_at = now() where kind = 'identity.tombstone'" >/dev/null 2>&1

erased=""
for _ in $(seq 1 30); do
  ack=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
    "select count(*) from inbox where topic = 'identity.user.deleted'" 2>/dev/null | tr -d ' ')
  [ "${ack:-0}" -ge 1 ] && { erased="yes"; break; }
  sleep 1
done
if [ -n "$erased" ]; then
  left=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
    "select count(*) from activity_records where user_id = '$uid'" 2>/dev/null | tr -d ' ')
  if [ "${left:-1}" -eq 0 ]; then
    ok "identity.user.deleted crossed the bus and activity forgot $uid ($before → 0; the inbox row is the acknowledgement)"
  else
    bad "the deletion event arrived but $left record(s) for $uid remain in activity"
  fi
  nack=""
  for _ in $(seq 1 15); do
    nack=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d notify -c \
      "select count(*) from inbox where topic = 'identity.user.deleted'" 2>/dev/null | tr -d ' ')
    [ "${nack:-0}" -ge 1 ] && break
    sleep 1
  done
  nleft=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d notify -c \
    "select count(*) from preferences where user_id = '$uid'" 2>/dev/null | tr -d ' ')
  if [ "${nack:-0}" -ge 1 ] && [ "${nleft:-1}" -eq 0 ]; then
    ok "and notify forgot the user too ($nbefore preference(s) → 0)"
  else
    bad "notify: ack=${nack:-0} remaining=${nleft:-?} — the service holding addresses and push tokens did not forget"
  fi
else
  bad "no identity.user.deleted reached activity within 30s — the tombstone, the relay, or the inbox is broken"
fi

[ "$fails" -eq 0 ] && { echo "all seams verified"; exit 0; }
echo "$fails check(s) failed"; exit 1
