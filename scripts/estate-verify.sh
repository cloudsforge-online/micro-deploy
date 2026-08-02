#!/usr/bin/env bash
# Drive the running estate and assert the seams that no unit test can reach.
#
#   cd deploy
#   docker compose -f compose/docker-compose.estate.yml up -d --build
#   ./scripts/estate-bootstrap.sh      # the admin UPDATE, then the service tokens
#   ./scripts/estate-verify.sh
#
# Every check here failed to exist until the environment did. The estate had 41
# pushed repositories, ~5,600 passing tests and no way to start one service, so
# nothing below had ever been true or false — it had never been asked.
#
# ── THE BAR ────────────────────────────────────────────────────────────────────
#
# A service that boots is not a service that works. Health is checked for all 21
# services because a service that cannot answer /readyz cannot be in any flow —
# but every section after that drives a REAL FLOW and asserts a REAL EFFECT:
# a token minted by one service and accepted by another, an event that crosses
# the bus and lands in a feed, a deletion that empties rows in two databases.
# The count of services proves nothing on its own and is not reported as if it
# did.
#
# `set -u` is load-bearing: it already caught an ordering bug here where a
# variable was read before it was captured.
set -uo pipefail

# Host ports are 4100 + the service's index in micro-org's registry (portFor,
# cfctl.ts:868) — derived from the one list that orders every repository rather
# than picked, because the estate has twice lost time to a hand-chosen port that
# already belonged to something else.
IDENTITY=${IDENTITY:-http://127.0.0.1:4100}
POLICY=${POLICY:-http://127.0.0.1:4101}
LEDGER=${LEDGER:-http://127.0.0.1:4102}
WALLET=${WALLET:-http://127.0.0.1:4103}
SETTLEMENT=${SETTLEMENT:-http://127.0.0.1:4104}
PRICING=${PRICING:-http://127.0.0.1:4105}
BILLING=${BILLING:-http://127.0.0.1:4106}
CUSTODY=${CUSTODY:-http://127.0.0.1:4107}
ACTIVITY=${ACTIVITY:-http://127.0.0.1:4109}
NOTIFY=${NOTIFY:-http://127.0.0.1:4110}
STUDIO=${STUDIO:-http://127.0.0.1:4111}
MINT=${MINT:-http://127.0.0.1:4112}
MARKET=${MARKET:-http://127.0.0.1:4113}
TRADE=${TRADE:-http://127.0.0.1:4114}
WORLDS=${WORLDS:-http://127.0.0.1:4115}
NDA=${NDA:-http://127.0.0.1:4116}
COMMUNITY=${COMMUNITY:-http://127.0.0.1:4117}
DEVPLATFORM=${DEVPLATFORM:-http://127.0.0.1:4118}
HUB=${HUB:-http://127.0.0.1:4119}
ADMIN=${ADMIN:-http://127.0.0.1:4120}
ANALYTICS=${ANALYTICS:-http://127.0.0.1:4121}
COMPOSE=${COMPOSE:-compose/docker-compose.estate.yml}
fails=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
code() { curl -s -o /tmp/slice.body -w '%{http_code}' "$@"; }

echo "── health, over a real socket ───────────────────────────────────────────"
# Every service in the environment, not a sample. A service that boots is not a
# service that works — that is what the flows below are for — but a service that
# does not answer /readyz cannot be in any flow at all, so this is the floor.
#
# No `declare -A`: bash on macOS is 3.2 and an associative-array port map once
# silently broke five suites here. A space-separated pair list works everywhere.
for pair in \
  "identity $IDENTITY" "policy $POLICY" "ledger $LEDGER" "wallet $WALLET" \
  "settlement $SETTLEMENT" "pricing $PRICING" "billing $BILLING" \
  "custody $CUSTODY" "activity $ACTIVITY" "notify $NOTIFY" "studio $STUDIO" \
  "mint $MINT" "market $MARKET" "trade $TRADE" "worlds $WORLDS" "nda $NDA" \
  "community $COMMUNITY" "devplatform $DEVPLATFORM" "hub-api $HUB" \
  "admin-api $ADMIN" "analytics $ANALYTICS"; do
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
docker compose -f compose/docker-compose.estate.yml exec -T postgres \
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
echo "── THE MONEY SEAM: a real double-entry posting, and a refusal ───────────"
# The estate's strongest assertion is a DEFERRED CONSTRAINT in ledger's schema
# that refuses an unbalanced journal even to a caller holding a database
# connection. Nothing had ever driven it from outside the process. This does:
# one balanced entry that must be accepted, one unbalanced entry that must be
# refused, and a trial balance that must still balance afterwards.
#
# Posted with a token minted for `wallet`, carrying ledger:post — a real
# credential for a real caller, not ledger talking to itself.
wtok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' \
  -d '{"service":"wallet","scopes":["ledger:read","ledger:post"]}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -n "$wtok" ] && ok "identity minted a ledger:post token for wallet" || bad "no wallet token issued"

# The subject of the deposit. Captured BEFORE the entry is posted, because
# `set -u` turns a read-before-capture into an immediate failure rather than a
# posting against the empty string — which is the ordering bug it already caught
# once in this file.
uid=$(curl -s "$IDENTITY/auth/me" -H "authorization: Bearer $utok" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('user',{}).get('id',''))" 2>/dev/null)
[ -n "$uid" ] && ok "subject resolved: $uid" || bad "could not read the drill user's id"

idem="estate-verify-$$-deposit"
# deposit_credited: custody gains an asset, the user gains a liability claim on
# it. Σ debits = Σ credits, which is the only thing the constraint cares about.
balanced=$(cat <<JSON
{"kind":"deposit_credited","originatingService":"wallet","actor":"service:wallet",
 "idempotencyKey":"$idem","description":"estate-verify deposit",
 "postings":[
  {"direction":"debit","amount":"1000","assetCode":"SHARD","sequence":0,
   "account":{"subject":"custody","assetCode":"SHARD","purpose":"available","type":"asset"}},
  {"direction":"credit","amount":"1000","assetCode":"SHARD","sequence":1,
   "account":{"subject":"user:$uid","assetCode":"SHARD","purpose":"available","type":"liability"}}]}
JSON
)
post=$(code -X POST "$LEDGER/entries" -H "authorization: Bearer $wtok" \
  -H 'content-type: application/json' -d "$balanced")
[ "$post" = 201 ] && ok "a balanced deposit_credited posted (201)" \
                  || bad "balanced entry rejected with $post: $(head -c 200 /tmp/slice.body)"

# The same request again. Idempotency is what makes a retried deploy-time call
# safe, and ledger answers 200-on-replay rather than posting the money twice.
replay=$(code -X POST "$LEDGER/entries" -H "authorization: Bearer $wtok" \
  -H 'content-type: application/json' -d "$balanced")
[ "$replay" = 200 ] && ok "the same idempotency key replayed (200), it did not double-post" \
                    || bad "expected 200 on replay, got $replay"

# THE REFUSAL. 1000 debited, 1 credited. If this is ever accepted, money has
# been created, and every downstream reconciliation is reporting on a lie.
unbalanced=$(cat <<JSON
{"kind":"adjustment","originatingService":"wallet","actor":"service:wallet",
 "idempotencyKey":"estate-verify-$$-unbalanced","description":"must be refused",
 "postings":[
  {"direction":"debit","amount":"1000","assetCode":"SHARD","sequence":0,
   "account":{"subject":"custody","assetCode":"SHARD","purpose":"available","type":"asset"}},
  {"direction":"credit","amount":"1","assetCode":"SHARD","sequence":1,
   "account":{"subject":"user:$uid","assetCode":"SHARD","purpose":"available","type":"liability"}}]}
JSON
)
refused=$(code -X POST "$LEDGER/entries" -H "authorization: Bearer $wtok" \
  -H 'content-type: application/json' -d "$unbalanced")
case "$refused" in
  2*) bad "AN UNBALANCED JOURNAL WAS ACCEPTED ($refused) — the ledger invented money" ;;
  *)  ok "an unbalanced journal was refused ($refused)" ;;
esac

# And the books still balance, which is the assertion that would catch a partial
# write from the refusal above.
tb2=$(curl -s "$LEDGER/trial-balance" -H "authorization: Bearer $stok")
printf '%s' "$tb2" | grep -q '"balanced":true' \
  && ok "trial balance still balances after a real posting and a refusal" \
  || bad "trial balance after posting: $tb2"

# The money actually landed on the subject's account, not merely in the journal.
bal=$(curl -s "$LEDGER/accounts/user:$uid/balances" -H "authorization: Bearer $wtok")
printf '%s' "$bal" | grep -q '1000' \
  && ok "the user's SHARD balance reflects the deposit" \
  || bad "the deposit did not reach the subject's balance: $(printf '%s' "$bal" | head -c 200)"

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

# THE INBOX BASELINES, captured BEFORE the deletion.
#
# This drill used to poll `select count(*) from inbox where topic =
# 'identity.user.deleted' >= 1` and treat any row as proof. That was only ever
# true because the environment was thrown away between runs: the moment this
# environment persisted across two runs, the PREVIOUS run's acknowledgement
# satisfied the poll instantly, the script stopped waiting, and it then reported
# that records "remain" — a false failure produced by an assertion that was
# never scoped to the subject it was about.
#
# The inbox carries only (topic, event_id, received_at) — no payload, so there is
# nothing in it to scope to this user. So the wait is on a NEW acknowledgement
# relative to the baseline, and the actual assertion is the property that matters:
# this subject's rows reach zero.
inbox_before=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
  "select count(*) from inbox where topic = 'identity.user.deleted'" 2>/dev/null | tr -d ' ')
ninbox_before=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d notify -c \
  "select count(*) from inbox where topic = 'identity.user.deleted'" 2>/dev/null | tr -d ' ')

# Request deletion (grace is 0 in this environment), then pull the HOURLY tombstone sweep forward.
# Stated plainly: the drill compresses the sweep's clock; it does not bypass the sweep. The event
# is still written by the real tombstone path, in the same transaction as the state change.
curl -s -X DELETE "$IDENTITY/users/me" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' -d "{\"password\":\"$PASS\"}" >/dev/null
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d identity -c \
  "update jobs set run_at = now() where kind = 'identity.tombstone'" >/dev/null 2>&1

# Wait on the ERASURE ITSELF, not on a proxy for it: this subject's rows reaching
# zero is the thing the GDPR path promises.
left=""
for _ in $(seq 1 45); do
  left=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
    "select count(*) from activity_records where user_id = '$uid'" 2>/dev/null | tr -d ' ')
  [ "${left:-1}" -eq 0 ] && break
  sleep 1
done
ack=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
  "select count(*) from inbox where topic = 'identity.user.deleted'" 2>/dev/null | tr -d ' ')
if [ "${left:-1}" -eq 0 ] && [ "${ack:-0}" -gt "${inbox_before:-0}" ]; then
  ok "identity.user.deleted crossed the bus and activity forgot $uid ($before → 0; a NEW inbox row, ${inbox_before:-0} → ${ack:-0}, is the acknowledgement)"
elif [ "${left:-1}" -eq 0 ]; then
  bad "activity holds no records for $uid, but no NEW inbox row arrived (${inbox_before:-0} → ${ack:-0}) — the rows may never have been there"
else
  bad "$left record(s) for $uid remain in activity after 45s — the tombstone, the relay, or the inbox is broken"
fi

nleft=""
for _ in $(seq 1 30); do
  nleft=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d notify -c \
    "select count(*) from preferences where user_id = '$uid'" 2>/dev/null | tr -d ' ')
  [ "${nleft:-1}" -eq 0 ] && break
  sleep 1
done
nack=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d notify -c \
  "select count(*) from inbox where topic = 'identity.user.deleted'" 2>/dev/null | tr -d ' ')
if [ "${nleft:-1}" -eq 0 ] && [ "${nack:-0}" -gt "${ninbox_before:-0}" ]; then
  ok "and notify forgot the user too ($nbefore preference(s) → 0)"
else
  bad "notify: new ack ${ninbox_before:-0} → ${nack:-0}, remaining=${nleft:-?} — the service holding addresses and push tokens did not forget"
fi

[ "$fails" -eq 0 ] && { echo "all seams verified"; exit 0; }
echo "$fails check(s) failed"; exit 1
