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

echo "── THE BOOTSTRAP GAP, AND THE GUARD THAT NOW CLOSES IT ──────────────────"
# A fresh deployment cannot issue its first service token. /service-tokens
# requires the `admin` role and users.roles defaults to '{}', so no service can
# authenticate to another until an operator exists. That much is unchanged.
mint=$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' -d '{"service":"ledger","scopes":["ledger:read"]}')
[ "$mint" = 403 ] && ok "a normal user cannot mint a service token (403) — expected, and the gap" \
                  || bad "expected 403 for a non-admin, got $mint"

# ── WHAT CHANGED, AND WHY THIS FILE NO LONGER PROMOTES ANYBODY ────────────────
#
# This block used to run `update users set roles = array['admin']` against the
# drill user, with `>/dev/null 2>&1` on it. `micro-identity` migration 12 refuses
# that statement — `users_roles_need_a_grant` is a deferred constraint trigger
# that rejects, at COMMIT, any row gaining a privileged role without a
# `platform_role_grants` row written in the same transaction. Discarded output is
# how that would have looked exactly like success.
#
# It is NOT re-implemented here with a grant row, for a reason worth stating: the
# bootstrap grant is capped at one per database for ever by a partial unique
# index, and spending it on a throwaway drill user would consume the estate's one
# unapproved administrator on a verification run. So this file now signs in as the
# operator `estate-bootstrap.sh` created, and the drill user stays unprivileged —
# which is also truer, because the erasure drill below DELETES the drill user and
# deleting the estate's only operator is not a thing a verification should do.
#
# The two identities are kept strictly apart from here on: `atok` mints, `utok` is
# the subject of the user-facing flows.
ADMIN_EMAIL=${ADMIN_EMAIL:-estate-admin@example.test}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-correct-horse-battery-staple-42}

# ── MIGRATION 12'S CONTROLS, EXERCISED RATHER THAN TRUSTED ────────────────────
#
# Both are asserted on SQLSTATE, not on message text, and both run from a psql
# prompt — the client the threat model assumes an attacker already has.
#
# 1. The bare UPDATE this file used to run must now fail. Wrapped in a transaction
#    and rolled back; the trigger is DEFERRED so it fires at COMMIT, which is why
#    this commits rather than rolls back and then asserts the commit was refused.
# Fed on STDIN, not `-c`. `psql -c` treats its whole argument as SQL, so a leading
# `\set VERBOSITY verbose` becomes part of the statement and psql answers
# `unrecognized value "verbosebegin;update…" for "VERBOSITY"`. That IS an error,
# so a check for "did this fail" would have passed for entirely the wrong reason —
# the assertion would have been green while testing nothing. Caught by running it.
psql_identity_verbose() {
  docker compose -f "$COMPOSE" exec -T postgres \
    psql -qtA -U cloudsforge -d identity 2>&1
}

bare=$(psql_identity_verbose <<SQL
\set VERBOSITY verbose
begin;
update users set roles = array['player','admin'] where email = lower(btrim('$EMAIL'));
commit;
SQL
)
printf '%s' "$bare" | grep -q '23514' \
  && ok "a bare 'update users set roles' is refused at COMMIT (23514) — the promotion lever is gone" \
  || bad "the bare admin UPDATE was NOT refused; anyone with psql can mint an operator: $(printf '%s' "$bare" | head -c 200)"

# 2. A second bootstrap grant must be refused for ever by the partial unique index.
second=$(psql_identity_verbose <<SQL
\set VERBOSITY verbose
begin;
insert into platform_role_grants (user_id, role, source, actor, reason)
select id, 'admin', 'bootstrap', 'estate-verify.sh', 'a second bootstrap, which must be refused'
  from users where email = lower(btrim('$ADMIN_EMAIL'));
rollback;
SQL
)
printf '%s' "$second" | grep -q '23505' \
  && ok "a second bootstrap grant is refused (23505) — one unapproved administrator, for ever" \
  || bad "a SECOND bootstrap grant was accepted: $(printf '%s' "$second" | head -c 200)"

# 3. The grant table is append-only, so the one-shot index above cannot be re-armed
#    by deleting the row that arms it.
appendonly=$(psql_identity_verbose <<SQL
\set VERBOSITY verbose
begin;
delete from platform_role_grants where source = 'bootstrap';
rollback;
SQL
)
printf '%s' "$appendonly" | grep -q 'append-only' \
  && ok "deleting a grant row is refused — the one-shot index cannot be re-armed" \
  || bad "a grant row could be DELETED, which re-arms the bootstrap: $(printf '%s' "$appendonly" | head -c 200)"

echo "── a service token crosses the wire ─────────────────────────────────────"
# The operator, not the drill user. Captured before anything reads it; `set -u`
# is what turns a missed capture here into an immediate failure.
atok=$(curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
if [ -n "$atok" ]; then
  ok "signed in as the bootstrapped operator $ADMIN_EMAIL"
else
  bad "could not sign in as $ADMIN_EMAIL — run ./scripts/estate-bootstrap.sh first"
  echo; echo "$fails failure(s)"; exit 1
fi
# Minted for `beacon`, not for `ledger`. This used to name `ledger` as the caller,
# which was always a fiction — a service token names WHO IS CALLING, and ledger
# does not call itself. It only ever worked because the hand-written grant map
# happened to list `ledger`, and the derived map does not: ledger makes no tokened
# outbound call, so it holds no grant and identity now refuses to mint for it.
#
# `beacon` is the honest caller here and its whole derived grant is `ledger:read`,
# from the scopes it names at its own exchange call site
# (beacon/src/ecosystem.ts:563). A monitor reading the trial balance is exactly
# this request.
stok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"beacon","scopes":["ledger:read"]}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('token') or d.get('serviceToken') or d.get('accessToken') or '')" 2>/dev/null)
[ -n "$stok" ] && ok "identity minted a ledger:read token for beacon" || bad "no service token issued"

# ledger holds no grant, so it cannot be named as a caller at all. This is the
# derivation's effect made visible rather than left as an absence.
[ "$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' -d '{"service":"ledger","scopes":["ledger:read"]}')" = 403 ] \
  && ok "identity refuses to mint for ledger — it makes no outbound call, so it has no grant" \
  || bad "identity minted a token naming ledger as the caller"

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
wtok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
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

echo
echo "── THE TEN-MINUTE CLIFF: a call made AFTER its token expired ────────────"
#
# THE DEFECT THIS SECTION EXISTS FOR. Service tokens expire in 600 seconds
# (identity/src/tokens.ts:28). Consuming services read theirs from an environment
# variable at boot and nothing re-minted it, because nothing COULD: the only
# issuer was an operator holding the `admin` role. The estate therefore worked
# perfectly for the first ten minutes of any deployment and then every
# service-to-service call in the money tier failed 401.
#
# WHY NOTHING CAUGHT IT. Every check above — and every per-service suite in the
# estate — mints a token and uses it seconds later. **No token has ever been
# asked to outlive itself here.** That is the shape that let this through two
# reviewers and twenty-one test suites, and it is why the section below is
# written the way it is: the token is deliberately allowed to DIE first, and the
# call that must then succeed is a real one, against a real service, over a real
# socket.
#
# WHY IT DOES NOT TAKE TEN MINUTES. identity now accepts a requested lifetime
# that may only ever SHORTEN (identity/src/tokens.ts, clampServiceTtl), so the
# cliff is reproduced at three seconds rather than six hundred. The ceiling is
# asserted below too — a caller that asks for a day must still get ten minutes,
# because "just make the TTL longer" is the wrong fix and this is where that
# would be caught.
#
# The sleep must clear the token's TTL *plus* the verifier's clock tolerance,
# which is 5s by default (runtime/packages/auth/src/index.ts:106). 3 + 5 = 8, so
# 12 is comfortably past it without being slow.
CLIFF_TTL=3
CLIFF_SLEEP=12

cred=$(curl -s -X POST "$IDENTITY/service-credentials" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' \
  -d '{"service":"wallet","label":"estate-verify cliff drill"}')
cred_secret=$(printf '%s' "$cred" | python3 -c "import sys,json;print(json.load(sys.stdin).get('secret',''))" 2>/dev/null)
cred_id=$(printf '%s' "$cred" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
# Captured BEFORE anything reads them. `set -u` turns a read-before-capture into
# an immediate failure rather than a curl carrying the empty string — the
# ordering bug this file has already caught once.
[ -n "$cred_secret" ] && ok "identity issued a long-lived service credential for wallet" \
  || bad "no service credential issued: $(printf '%s' "$cred" | head -c 160)"

# A credential is NOT a token. Presenting it to a peer must achieve nothing —
# that is what keeps it a key to identity's door rather than a second
# PAY_SERVICE_TOKEN with the run of the estate.
[ "$(code "$LEDGER/entries" -H "authorization: Bearer $cred_secret")" = 401 ] \
  && ok "the credential itself is refused by ledger — it is not a bearer token" \
  || bad "ledger ACCEPTED a raw service credential; it must only ever accept a token"

short=$(curl -s -X POST "$IDENTITY/service-tokens/exchange" \
  -H "authorization: Bearer $cred_secret" -H 'content-type: application/json' \
  -d "{\"scopes\":[\"ledger:read\"],\"ttlSeconds\":$CLIFF_TTL}")
short_token=$(printf '%s' "$short" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
short_ttl=$(printf '%s' "$short" | python3 -c "import sys,json;print(json.load(sys.stdin).get('expiresIn',''))" 2>/dev/null)
[ "$short_ttl" = "$CLIFF_TTL" ] && ok "wallet minted its own ${CLIFF_TTL}s token — no operator involved" \
  || bad "exchange did not honour ttlSeconds: $(printf '%s' "$short" | head -c 160)"

# T+0: it works. This is the half every existing test already proves.
[ "$(code "$LEDGER/entries" -H "authorization: Bearer $short_token")" = 200 ] \
  && ok "the freshly minted token is accepted by ledger" \
  || bad "ledger refused a token identity had just minted"

echo "  … letting the token expire (${CLIFF_SLEEP}s) — this is the wait no suite ever did"
sleep "$CLIFF_SLEEP"

# T+12: THE CLIFF ITSELF, reproduced across the wire. Before this fix every
# service in the money tier reached this state ten minutes after deploy and
# stayed there.
expired_code=$(code "$LEDGER/entries" -H "authorization: Bearer $short_token")
[ "$expired_code" = 401 ] \
  && ok "the expired token is now refused (401) — the cliff, reproduced" \
  || bad "an EXPIRED service token was answered $expired_code; expiry is not being enforced"

# And the fix: the credential outlived the token, so wallet mints a replacement
# for itself. No redeploy, no operator, no re-run of estate-bootstrap.
after=$(curl -s -X POST "$IDENTITY/service-tokens/exchange" \
  -H "authorization: Bearer $cred_secret" -H 'content-type: application/json' \
  -d '{"scopes":["ledger:read"]}')
after_token=$(printf '%s' "$after" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
after_ttl=$(printf '%s' "$after" | python3 -c "import sys,json;print(json.load(sys.stdin).get('expiresIn',''))" 2>/dev/null)
if [ "$(code "$LEDGER/entries" -H "authorization: Bearer $after_token")" = 200 ]; then
  ok "wallet re-minted past its own expiry and ledger accepted it — THE CLIFF IS CLOSED"
else
  bad "a service could not obtain a working token after its first one expired"
fi

# THE TTL CEILING IS NOT NEGOTIABLE. If someone ever "fixes" the cliff by
# raising the TTL, or by letting a caller ask for a longer one, it fails here.
[ "$after_ttl" = 600 ] && ok "the default service-token TTL is still 600s — not lengthened" \
  || bad "expected a 600s TTL, got ${after_ttl:-none} — has SERVICE_TTL_SECONDS been changed?"
greedy_ttl=$(curl -s -X POST "$IDENTITY/service-tokens/exchange" \
  -H "authorization: Bearer $cred_secret" -H 'content-type: application/json' \
  -d '{"ttlSeconds":86400}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('expiresIn',''))" 2>/dev/null)
[ "$greedy_ttl" = 600 ] && ok "a caller asking for a day is clamped to 600s" \
  || bad "ttlSeconds was not clamped: got ${greedy_ttl:-none}"

# A credential cannot mint outside its service's allowlist, and cannot name a
# different service — the service is read off the row, never off the request.
[ "$(code -X POST "$IDENTITY/service-tokens/exchange" -H "authorization: Bearer $cred_secret" \
     -H 'content-type: application/json' -d '{"scopes":["custody:sign:treasury"]}')" = 403 ] \
  && ok "wallet's credential cannot mint the treasury signing scope (403)" \
  || bad "a credential minted a scope outside its allowlist"

# Revocation — the containment lever a bearer JWT cannot have.
revoke_code=$(code -X POST "$IDENTITY/service-credentials/$cred_id/revoke" \
  -H "authorization: Bearer $atok")
[ "$revoke_code" = 200 ] && ok "the drill credential was revoked" || bad "revoke returned $revoke_code"
[ "$(code -X POST "$IDENTITY/service-tokens/exchange" -H "authorization: Bearer $cred_secret" \
     -H 'content-type: application/json' -d '{}')" = 401 ] \
  && ok "a revoked credential mints nothing (401) — a compromised service is contained" \
  || bad "a REVOKED credential could still mint a token"

echo
echo "── THE ONBOARDING TOPIC THAT HAD NO SUBSCRIBER ──────────────────────────"
# `identity.user.registered` is consumed by TWO services — activity turns it into
# a feed record (activity/src/classify.ts:190) and analytics counts it as "the
# denominator of every onboarding cohort" (analytics/src/catalogue.ts:307) — and
# nothing subscribed either of them, so both were consumers with no producer and
# every onboarding metric in the estate was structurally zero.
#
# `estate-bootstrap.sh` now seeds the row as deploy configuration. THIS ASSERTS
# THE DELIVERY, NOT THE ROW: a subscription that exists and never delivers is the
# same outage with a tidier database — which is exactly what seeding analytics
# proved, at `attempts=67, last_error=… → 401`, because its `/ingest` demands a
# scoped token the relay has no way to present. activity takes a signature alone,
# so activity is the consumer this asserts and analytics is a named gap in
# another repository.
areg=""
for _ in $(seq 1 30); do
  areg=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d activity -c \
    "select count(*) from inbox where topic = 'identity.user.registered'" 2>/dev/null | tr -d ' ')
  [ "${areg:-0}" -ge 1 ] && break
  sleep 1
done
if [ "${areg:-0}" -ge 1 ]; then
  ok "identity.user.registered crossed the bus into activity ($areg acknowledgement(s)) — it had no subscriber at all"
else
  bad "no identity.user.registered reached activity in 30s — the topic still has no working consumer"
fi

echo
echo "── THE GRANTS ARE DERIVED, AND THE COMPOSE FILE STILL AGREES ────────────"
#
# `IDENTITY_SERVICE_TOKEN_GRANTS` is generated by `scripts/derive-grants.mjs`
# from the services' own declarations. This asserts the generated block still
# matches what the services say — a hand-edit here is reverted by the next run
# rather than quietly kept, which is the property that stops the grant map going
# stale again.
#
# Its exit status is read directly rather than piped through `grep`, because a
# `grep` on the output would pass when the tool crashed and printed nothing.
if (cd "$(dirname "$0")/.." && node scripts/derive-grants.mjs --check) >/tmp/derive-grants.out 2>&1; then
  ok "$(tail -1 /tmp/derive-grants.out)"
else
  bad "the compose grants disagree with the services: $(head -c 400 /tmp/derive-grants.out)"
fi

echo
echo "── THE CROSS-TITLE ACHIEVEMENT: the grant, driven end to end ────────────"
#
# ── WHY THIS IS A FLOW AND NOT A STRING MATCH ─────────────────────────────────
#
# A grant that is present and WRONG looks identical to a grant that is present
# and right, so asserting the compose file contains `worlds:title` proves
# nothing. `nda` held `worlds:read,worlds:write` for months — both present, both
# real scopes, both useless for this call.
#
# This drives the exact path `emberkin/src/worldsclient.ts` drives: resolve the
# title id from worlds' public registry, PUT the definition (worlds refuses an
# unlock for an achievement it has never been told about), then POST the unlock.
# Every request carries a token minted for `emberkin` from the DERIVED grant.
#
# It matters more than usual right now. The clients used to post to
# `/internal/achievements`, a route worlds does not serve, and classified the 404
# as "the peer refused" — so every cross-title badge was discarded, not delayed.
# That is fixed, and a 404 is now a wiring fault that retries loudly. So until
# this grant works, badges pile up retrying instead of vanishing: a better
# failure, still a failure.
etok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"emberkin","scopes":["worlds:title"]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -n "$etok" ] && ok "identity minted worlds:title for emberkin — it had no grant at all before" \
  || bad "identity would not mint worlds:title for emberkin"

# The title must be registered before it has an id. Registration is an operator
# action (`worlds:admin` for a service, role:admin for a user), which is why this
# uses the operator's token and not emberkin's — a title cannot register itself.
# `serviceUrl` is REQUIRED — worlds answers 400 "serviceUrl is required" without
# it, which is the registry refusing to record a title it could never reach. The
# URL names where the emberkin SERVICE would be; nothing in this section calls it,
# because the achievement path is title → worlds, never the reverse.
curl -s -X POST "$WORLDS/v1/titles" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' \
  -d '{"slug":"emberkin","name":"Emberkin","serviceUrl":"http://emberkin:4000","capabilities":[]}' >/dev/null 2>&1
tid=$(curl -s "$WORLDS/v1/titles" \
  | python3 -c "
import sys, json
try: titles = json.load(sys.stdin).get('titles', [])
except Exception: titles = []
print(next((t['id'] for t in titles if t.get('slug') == 'emberkin'), ''))" 2>/dev/null)
# Captured BEFORE it is read into a URL. `set -u` is what turns a missed capture
# here into a failure rather than a request against `/v1/titles//achievements`.
[ -n "$tid" ] && ok "emberkin is registered in worlds: $tid" \
  || bad "emberkin is not in worlds' title registry — the badge path cannot be driven"

akey="estate-verify-$$"
if [ -n "$tid" ] && [ -n "$etok" ]; then
  # The definition. `PUT` is an upsert, so this is idempotent.
  defc=$(code -X PUT "$WORLDS/v1/titles/$tid/achievements" -H "authorization: Bearer $etok" \
    -H 'content-type: application/json' \
    -d "{\"key\":\"$akey\",\"name\":\"Estate Verify\",\"description\":\"\",\"points\":10,\"rewardShards\":\"0\"}")
  [ "$defc" = 200 ] && ok "worlds accepted the achievement definition under worlds:title" \
    || bad "defining the achievement returned $defc (401/403 means the grant is wrong; 404 means the route is)"

  # THE UNLOCK. 201 on a fresh badge, 200 on one that had already happened.
  unlock=$(code -X POST "$WORLDS/v1/titles/$tid/achievements/unlock" \
    -H "authorization: Bearer $etok" -H 'content-type: application/json' \
    -d "{\"userId\":\"$uid\",\"key\":\"$akey\"}")
  [ "$unlock" = 201 ] && ok "a cross-title achievement UNLOCKED (201) — the badge exists in worlds" \
    || bad "the unlock returned $unlock, expected 201"

  # Replayed. The delivery job retries with a stable idempotency key, so the
  # second attempt must be accepted and must not create a second badge.
  replay=$(code -X POST "$WORLDS/v1/titles/$tid/achievements/unlock" \
    -H "authorization: Bearer $etok" -H 'content-type: application/json' \
    -d "{\"userId\":\"$uid\",\"key\":\"$akey\"}")
  [ "$replay" = 200 ] && ok "replaying the unlock is 200, not a second badge — the retry is safe" \
    || bad "the replayed unlock returned $replay, expected 200"
fi

# ── THE NEGATIVE, WHICH IS WHAT MAKES THE POSITIVE MEAN ANYTHING ──────────────
#
# A token minted for a service whose grant does NOT include `worlds:title` must
# be refused by the same route. Without this, the checks above would also pass if
# worlds had stopped checking scopes altogether.
#
# `community` is used because its derived grant is ledger/policy/indexer only, so
# identity will mint it a real, valid, correctly-signed token that simply does not
# carry this authority — which is precisely the case that must 403 rather than 401.
ctok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"community","scopes":["ledger:post"]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
if [ -n "$tid" ] && [ -n "$ctok" ]; then
  # Captured into a variable and THEN compared, rather than `[ "$(code …)" = 403 ]`.
  # The body here carries escaped quotes, and wrapping that command substitution
  # in a further layer of double quotes makes bash re-process them before `[` ever
  # runs — which produced `[: too many arguments` and, because `[` failing is
  # indistinguishable from the assertion failing, reported that worlds had
  # ACCEPTED an unauthorised unlock. It had not: worlds answered 403 with
  # "missing required authority: worlds:title" throughout. A false red, but the
  # same shape as a false green, so it is fixed rather than worked around.
  refused=$(code -X POST "$WORLDS/v1/titles/$tid/achievements/unlock" \
    -H "authorization: Bearer $ctok" -H 'content-type: application/json' \
    -d "{\"userId\":\"$uid\",\"key\":\"$akey\"}")
  [ "$refused" = 403 ] \
    && ok "a valid token without worlds:title is refused (403) — the scope is doing the work" \
    || bad "worlds answered $refused to an unlock from a credential with no worlds:title, expected 403"
fi

# identity must also refuse to MINT a scope outside a service's derived grant.
# `worlds:title` is held by title services; `community` is not one.
[ "$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' \
     -d '{"service":"community","scopes":["worlds:title"]}')" = 403 ] \
  && ok "identity refuses to mint worlds:title for community — the allowlist is enforced at the mint" \
  || bad "identity minted a scope outside community's grant"

# `worlds` gained `aetherholm:provision`, the provisioning bridge's authority.
# The aetherholm SERVICE is not deployed in this estate — only its frontend — so
# the call it authorises cannot be driven here, and this asserts the half that
# can be: identity mints it for worlds and for nobody else. Said plainly rather
# than dressed up as an end-to-end proof it is not.
wtok2=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"worlds","scopes":["aetherholm:provision"]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -n "$wtok2" ] && ok "identity mints aetherholm:provision for worlds (the call itself needs the aetherholm service, which this estate does not run)" \
  || bad "worlds cannot be minted aetherholm:provision"
[ "$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' \
     -d '{"service":"nda","scopes":["aetherholm:provision"]}')" = 403 ] \
  && ok "nda is refused aetherholm:provision — the registry says worlds alone holds it" \
  || bad "a service other than worlds was minted aetherholm:provision"

echo
echo "── THE AUDIT MIRROR: admin-api receives the audited topics ──────────────"
#
# Claim 9 of the eleven "one platform" tests — an operator answers "where did this
# user's money go" from admin-web alone — needs these rows to exist and the relay
# to reach them.
#
# `POST /v1/events` used to demand `admin:audit:write`, which no outbox relay in
# this estate can present, so the mirror received nothing at all. admin-api now
# verifies the signature the relay actually sends and reads no bearer, so the
# subscription works. The ledger posting earlier in this file is the event under
# test: `ledger.entry.posted` is one of the audited topics.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  mirror=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge \
    -d admin_api -c "select count(*) from audit_events where action = 'ledger.entry.posted'" 2>/dev/null | tr -d ' ')
  [ "${mirror:-0}" -ge 1 ] && break
  sleep 1
done
[ "${mirror:-0}" -ge 1 ] \
  && ok "ledger.entry.posted reached admin-api's audit mirror ($mirror row(s)) — the operator log is no longer empty" \
  || bad "no audited event reached admin-api in 15s — the mirror is still not receiving"

echo
echo "── THE FIFTEEN FRONTENDS: served, and proved to be more than a 200 ──────"
#
# ── THE TRAP THIS SECTION EXISTS FOR ───────────────────────────────────────────
#
# **A bundle that 404s leaves the network perfectly idle, and the page still
# loads.** nginx answers 200 on `/` because index.html is on disk; the browser
# then asks for a script that is not there, gets nothing, and renders a blank
# body. `domcontentloaded` fires anyway. A check that the container answers 200
# on `/` — which is what "the frontend is up" usually means — passes against a
# completely broken application, and so does the container's own /healthz, which
# every frontend's nginx.conf says in its own words: "it says the server is up —
# never that the app works".
#
# The legacy estate solved this with a real browser
# (stack/infra/beacon/src/journeys/web.js:41-55: wait for network idle, then
# assert the body has text the application itself produced). There is no browser
# here and adding one to a bash script would be the wrong place for it — that is
# the T3 harness being built in micro-beacon, per docs/ecosystem/22 §4.
#
# ── SO WHAT IS ASSERTED, AND WHAT IS NOT ───────────────────────────────────────
#
# Every assertion below is about the ARTEFACT the browser would receive:
#
#   1. `/` is 200 AND carries THIS BUILD's release stamp. Docker Desktop keeps a
#      stale bind-mount cache and a container serving a file that no longer
#      matches disk looks exactly like a config bug — an hour went into that
#      once, with three wrong theories written down before the cause was found.
#      A page not carrying the release compose asked for is a stale artefact and
#      is named as one here rather than left to be diagnosed.
#   2. EVERY asset index.html references is fetched and must be 200. This is the
#      one that catches a 404ing bundle.
#   3. The CSS carries `--cf-ember`. That token lives in
#      `@cloudsforge/ui`'s tokens.css, a package consumed through a `link:`
#      SYMLINK INTO A SIBLING REPOSITORY. If the `uipkg` build context were ever
#      dropped from docker-compose.estate.yml, or the design system failed to
#      resolve the way micro-service-template's `/contracts` did, the build would
#      emit a stylesheet without it. This is the check that the symlink survived
#      containerisation, and it is asserted on all fifteen because the failure
#      would be estate-wide and silent.
#   4. The JS bundle is over 50 kB. An empty or stub entry chunk is served with a
#      200 and a correct content type.
#   5. An ENUMERATED client route answers 200 and serves the shell — the address
#      survives a hard refresh, which is what client-side routing means.
#   6. AN ADDRESS THE SURFACE DOES NOT OWN ANSWERS **404**, and serves the shell
#      anyway. This is the estate's standing rule and doc 22 asserts it once per
#      surface as `BJ-<KEY>-404`: `error_page 404 /index.html`, never
#      `try_files $uri /index.html`, because a "page not found" delivered as a
#      200 is indexed by search engines, called healthy by uptime checks and
#      passed by link checkers — and a deploy that drops a route then looks
#      exactly like a deploy that did not.
#
# WHAT IS STILL NOT COVERED, said plainly: nothing here executes the bundle. A
# module that throws on line one passes all six. That is precisely the gap the
# T3 harness closes, and pretending otherwise would be the second time this
# estate believed an image worked because CI read its metadata without ever
# running it.
#
# Ports are 4100 + the repo's index in micro-org's registry, as everywhere else;
# the four surfaces that registry does not carry are documented beside their
# containers in compose/docker-compose.estate.yml.
#
# No `declare -A` — bash here is 3.2, and an associative-array port map once
# silently broke five suites in this repository.

WEB_RELEASE=${CLOUDSFORGE_RELEASE:-estate}
# A path no surface enumerates, on purpose. If a surface ever claims it, this
# check starts passing for the wrong reason, so it is deliberately unlovely.
WEB_MISSING=/cf-estate-verify-no-such-page

# Fields: name  port  a-route-the-surface-DOES-own
#
# Each route below is read out of that repo's own nginx.conf enumeration (the one
# `location ~ ^/(…)` block, which its test/routes.test.ts pins against app.tsx),
# not out of doc 22 — a document is a lead, never evidence.
web_surface() {
  name=$1; port=$2; owned=$3
  base="http://127.0.0.1:$port"
  notes=""

  # 1. the shell, and the build identity
  body=$(curl -s -w '\n%{http_code}' "$base/")
  status=$(printf '%s' "$body" | tail -1)
  html=$(printf '%s' "$body" | sed '$d')
  if [ "$status" != 200 ]; then
    bad "$name: GET / returned $status"
    return
  fi
  if printf '%s' "$html" | grep -q "name=\"cf-release\" content=\"$WEB_RELEASE\""; then
    notes="release=$WEB_RELEASE"
  else
    bad "$name: the page does not carry release '$WEB_RELEASE' — a STALE ARTEFACT is being served, not a configuration bug"
    return
  fi

  # 2. every asset the shell references
  assets=$(printf '%s' "$html" | python3 -c "
import sys, re
html = sys.stdin.read()
# src= on <script>, href= on <link>. Only same-origin absolute paths: a CDN URL
# would be a different claim and this estate serves none.
urls = re.findall(r'<(?:script|link)\b[^>]*?(?:src|href)=\"(/[^\"]+)\"', html)
print('\n'.join(sorted(set(urls))))
" 2>/dev/null)
  if [ -z "$assets" ]; then
    bad "$name: index.html references no assets at all — the build produced a shell with nothing in it"
    return
  fi
  count=0; broken=""
  for a in $assets; do
    ac=$(curl -s -o /dev/null -w '%{http_code}' "$base$a")
    [ "$ac" = 200 ] && count=$((count+1)) || broken="$broken $a($ac)"
  done
  if [ -n "$broken" ]; then
    bad "$name: the page points at asset(s) that do not exist —$broken. The container answers 200 on / and the application cannot start."
    return
  fi
  notes="$notes, $count asset(s)"

  # 3. the design system reached the bundle, through the sibling-repo symlink
  css=$(printf '%s' "$assets" | grep '\.css$' | head -1)
  if [ -z "$css" ]; then
    bad "$name: no stylesheet in the shell — @cloudsforge/ui's tokens cannot have been bundled"
    return
  fi
  if curl -s "$base$css" | grep -q -- '--cf-ember'; then
    notes="$notes, design system"
  else
    bad "$name: $css carries no --cf-ember token — @cloudsforge/ui did not reach the bundle (the link: symlink into ../ui)"
    return
  fi

  # 4. the entry chunk is real code
  js=$(printf '%s' "$assets" | grep '\.js$' | head -1)
  if [ -z "$js" ]; then
    bad "$name: the shell references no script — there is no application to mount"
    return
  fi
  bytes=$(curl -s "$base$js" | wc -c | tr -d ' ')
  if [ "${bytes:-0}" -gt 50000 ]; then
    notes="$notes, ${bytes}B of js"
  else
    bad "$name: $js is only ${bytes}B — a stub or an error page, not an application bundle"
    return
  fi

  # 5. an enumerated client route survives a hard refresh
  owned_body=$(curl -s -w '\n%{http_code}' "$base$owned")
  owned_status=$(printf '%s' "$owned_body" | tail -1)
  if [ "$owned_status" != 200 ]; then
    bad "$name: $owned answered $owned_status — an enumerated client route does not survive a hard refresh"
    return
  fi
  if ! printf '%s' "$owned_body" | sed '$d' | grep -q "$js"; then
    bad "$name: $owned answered 200 without the app shell — nginx served something that is not index.html"
    return
  fi
  notes="$notes, $owned 200"

  # 6. THE 404 RULE. Status AND body, because either alone passes the wrong way:
  #    `try_files $uri /index.html` gives the shell with a 200, and a bare nginx
  #    error page gives a 404 with no application in it. Both are wrong and they
  #    are wrong in opposite directions.
  missing_body=$(curl -s -w '\n%{http_code}' "$base$WEB_MISSING")
  missing_status=$(printf '%s' "$missing_body" | tail -1)
  if [ "$missing_status" != 404 ]; then
    bad "$name: $WEB_MISSING answered $missing_status, not 404 — an unknown address is being reported as a success"
    return
  fi
  if ! printf '%s' "$missing_body" | sed '$d' | grep -q "$js"; then
    bad "$name: $WEB_MISSING answered 404 without the app shell — the visitor gets nginx's error page, not NotFoundPage"
    return
  fi
  notes="$notes, $WEB_MISSING 404-with-shell"

  # A missing ASSET must 404 rather than resolve to something. It currently
  # answers 404 with the shell's HTML body, because `error_page 404 /index.html`
  # is a server-level directive and catches the `/assets/` location's `=404` too
  # — so every frontend's nginx.conf states an intent ("a JavaScript request
  # answered with HTML fails with a syntax error that names the wrong file") that
  # its own configuration does not achieve. The STATUS is what stops a browser
  # executing it, so the status is what is asserted here; the content type is
  # recorded as a finding for the fifteen frontend repositories rather than
  # asserted in a suite that cannot fix it.
  ac=$(curl -s -o /dev/null -w '%{http_code}' "$base/assets/cf-estate-verify-missing.js")
  if [ "$ac" != 404 ]; then
    bad "$name: a missing asset answered $ac — a broken deploy would serve the shell as JavaScript"
    return
  fi

  ok "$name ($port): $notes"
}

for rec in \
  "hub-web 4122 /portfolio" \
  "site 4123 /products" \
  "admin-web 4124 /approvals" \
  "mint-web 4125 /launch" \
  "trade-web 4126 /bots" \
  "worlds-web 4127 /player" \
  "explorer-web 4128 /chains" \
  "network-site 4129 /faucet" \
  "market-web 4130 /listings" \
  "devportal-web 4131 /apps" \
  "status-web 4132 /history" \
  "foresight-web 4136 /rules" \
  "foresight-admin-web 4137 /categories" \
  "emberkin-web 4138 /party" \
  "aetherholm-web 4139 /cities"; do
  set -- $rec
  web_surface "$1" "$2" "$3"
done

echo
echo "── THE GATEWAY: the surfaces on the hostnames a browser will use ────────"
#
# Everything above reaches a container on a loopback port. NO BROWSER EVER WILL.
# `cloudsforgeHosts()` reads `window.location.hostname`, strips a known
# subdomain to get the apex, and rebuilds every sibling host as
# `https://<sub>.<apex>` — no port. So a bundle opened on 127.0.0.1:4122 resolves
# identity to `http://localhost:4001`, which nothing in this estate serves. The
# hostnames below are the only addresses under which the estate is a working
# product rather than fifteen isolated static servers.
#
# `--resolve` rather than DNS: the default apex is a public wildcard pointing at
# 127.0.0.1, but a suite that needs the internet to answer a question about
# loopback is a suite that goes red on a train.
#
# `-k`: the gateway serves Traefik's self-signed default here, which is right for
# loopback and wrong to ship.
WEB_APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
GW_PORT=${CF_GATEWAY_HTTPS_PORT:-443}

gw() {
  gw_host=$1; gw_path=$2; shift 2
  curl -sk -o /tmp/estate-gw.body -w '%{http_code}' \
    --resolve "$gw_host:$GW_PORT:127.0.0.1" "https://$gw_host:$GW_PORT$gw_path" "$@"
}

# The gateway has to be up. NOT skipped when it is not: half the estate's browser
# surface is the routing, and a suite that quietly stops checking it reports green
# on an environment no browser can use.
if [ "$(gw "hub.$WEB_APEX" /healthz)" = 200 ]; then
  ok "the gateway is answering on :$GW_PORT"
else
  bad "no gateway on https://…:$GW_PORT — run ./scripts/estate-up.sh, or 'docker compose -p cfmicro -f compose/docker-compose.telemetry.yml -f compose/docker-compose.gateway.yml -f compose/docker-compose.estate-gateway.yml up -d'"
fi

# Every surface on its registry hostname. The subdomain is the `subdomain` field
# of that surface's row in ui/packages/ui/src/surfaces.ts — which is why Forge
# Create is `create.` though its repository is micro-mint-web, and the developer
# platform is `developers.` though its repository is micro-devportal-web.
for rec in \
  "hub hub-web" \
  ". site" \
  "market market-web" \
  "create mint-web" \
  "trade trade-web" \
  "worlds worlds-web" \
  "explorer explorer-web" \
  "network network-site" \
  "developers devportal-web" \
  "admin admin-web" \
  "status status-web" \
  "foresight foresight-web" \
  "foresight-admin foresight-admin-web" \
  "emberkin emberkin-web" \
  "aetherholm aetherholm-web"; do
  set -- $rec
  sub=$1; repo=$2
  # `site` has an EMPTY subdomain in the registry: it is the bare apex.
  if [ "$sub" = "." ]; then host="$WEB_APEX"; else host="$sub.$WEB_APEX"; fi
  gwc=$(gw "$host" /)
  if [ "$gwc" = 200 ] && grep -q "name=\"cf-release\" content=\"$WEB_RELEASE\"" /tmp/estate-gw.body; then
    ok "https://$host → $repo"
  else
    bad "https://$host answered $gwc and did not serve $repo's shell"
  fi
done

echo "── the surfaces' own APIs, behind the same hostname ─────────────────────"
# Every frontend resolves its API base by comparing origins (`resolveApiBase`,
# e.g. hub-web/src/lib/hosts.ts:34-42): served from its registry host, the base is
# the EMPTY STRING and every request is relative. micro-network-site states the
# obligation outright — "the base is '' and the drip request is relative, which is
# what the registry asserts AND WHAT THE GATEWAY THEREFORE HAS TO ROUTE"
# (network-site/src/lib/hosts.ts:63-64).
#
# Routing only the bundle leaves every surface loading beautifully and answering
# nothing. A 401 is the RIGHT answer here — it proves the service replied — and it
# is asserted as such: what must never happen is a 404 (no router) or a 502 (a
# router pointing at nothing).
for rec in \
  "hub /v1/dashboard hub-api" \
  "admin /v1/approvals admin-api" \
  "market /v1/listings market" \
  "create /v1/catalogue mint" \
  "trade /v1/bots trade" \
  "worlds /v1/titles worlds" \
  "developers /v1/scopes devplatform"; do
  set -- $rec
  sub=$1; path=$2; svc=$3
  apic=$(gw "$sub.$WEB_APEX" "$path")
  case "$apic" in
    404|502|000) bad "https://$sub.$WEB_APEX$path answered $apic — $svc is not routed behind its own surface's hostname" ;;
    *) ok "https://$sub.$WEB_APEX$path → $svc ($apic)" ;;
  esac
done

echo "── THE SIGN-IN SEAM: the blocker doc 22 §8.1 calls the largest ──────────"
#
# Every estate-level browser journey begins with signing in, and until today
# NOTHING IN THE ESTATE SERVED A SIGN-IN PAGE. `signInRedirect()` sends every
# signed-out visitor of every product to `${accountUrl()}/login`; `accountUrl()`
# resolved `account.<apex>`, which no repository serves and which identity would
# refuse to render HTML for. micro-ui added a `signin` registry row riding on Hub
# at `/account`, and micro-hub-web now serves the page. This is the environment's
# half: the address has to be REACHABLE, on the hostname the redirect names.
if [ "$(gw "hub.$WEB_APEX" /account/login)" = 200 ]; then
  ok "https://hub.$WEB_APEX/account/login is served — the redirect every SPA makes now lands somewhere"
else
  bad "hub.$WEB_APEX/account/login is not served; every 'Sign in' button in the estate leads nowhere"
fi

# identity, on the hostname the shared UI calls it by. `consumeAuthCallback` posts
# to `${cloudsforgeHosts().nimbus}/auth/handoff/redeem` (ui/packages/ui/src/
# index.tsx) — a route that did not exist under its old name and 404'd everywhere,
# returning null exactly as it does for a stale code, so it read as an expiry
# rather than as a wrong address. A 404 here would reproduce that silently.
redeem=$(gw "nimbus.$WEB_APEX" /auth/handoff/redeem -X POST -H 'content-type: application/json' \
  -H "origin: https://hub.$WEB_APEX" -d '{"code":"not-a-real-code"}')
case "$redeem" in
  404) bad "POST nimbus.$WEB_APEX/auth/handoff/redeem is 404 — the route the SSO callback posts to is unreachable" ;;
  000|502) bad "nimbus.$WEB_APEX is not routed to identity ($redeem)" ;;
  *) ok "POST nimbus.$WEB_APEX/auth/handoff/redeem reaches identity and refuses a forged code ($redeem)" ;;
esac

# THE CORS PREFLIGHT. The sign-in page is on `hub.<apex>` and identity is on
# `nimbus.<apex>`: every call it makes is cross-origin, and identity sends no CORS
# headers of its own — it has no CORS setting at all. The gateway is the only
# thing that can permit this, and a missing allowlist entry fails CLOSED and in
# silence: the browser discards the response and nothing server-side records that
# anything was refused.
allow=$(curl -sk -D - -o /dev/null -X OPTIONS \
  --resolve "nimbus.$WEB_APEX:$GW_PORT:127.0.0.1" \
  -H "origin: https://hub.$WEB_APEX" \
  -H 'access-control-request-method: POST' \
  -H 'access-control-request-headers: content-type' \
  "https://nimbus.$WEB_APEX:$GW_PORT/auth/handoff/redeem" \
  | tr -d '\r' | grep -i '^access-control-allow-origin:' | head -1)
case "$allow" in
  *"https://hub.$WEB_APEX"*) ok "the gateway permits hub.$WEB_APEX to call identity ($allow)" ;;
  *) bad "no CORS allowance for https://hub.$WEB_APEX on nimbus.$WEB_APEX (got '${allow:-nothing}') — sign-in cannot complete in a browser" ;;
esac

# pay. and vault. — the two hostnames micro-hub-web named as missing and could not
# add from its own repository (hub-web/src/lib/money.ts:34-41). `hosts().pay` is
# wallet and `hosts().keyvault` is custody, and both are called with the USER'S
# OWN token from Hub's origin, so both need the app CORS allowlist that the API
# host deliberately does not carry.
# The paths are the ones hub-web actually calls, read off its own call sites
# (hub-web/src/lib/money.ts:140 and :192) rather than picked: `/health` was tried
# first here and answered 404 from custody, which is indistinguishable at a glance
# from the router being absent. A 401 is the pass — it proves the service replied.
for rec in "pay /v1/deposits wallet" "vault /v1/exports custody"; do
  set -- $rec
  sub=$1; path=$2; svc=$3
  pc=$(gw "$sub.$WEB_APEX" "$path")
  case "$pc" in
    404|000|502) bad "https://$sub.$WEB_APEX$path answered $pc — $svc is not reachable on the hostname Hub calls it by" ;;
    *) ok "https://$sub.$WEB_APEX → $svc ($pc)" ;;
  esac
  pa=$(curl -sk -D - -o /dev/null -X OPTIONS --resolve "$sub.$WEB_APEX:$GW_PORT:127.0.0.1" \
    -H "origin: https://hub.$WEB_APEX" -H 'access-control-request-method: POST' \
    -H 'access-control-request-headers: content-type,authorization' \
    "https://$sub.$WEB_APEX:$GW_PORT$path" | tr -d '\r' \
    | grep -i '^access-control-allow-origin:' | head -1)
  case "$pa" in
    *"https://hub.$WEB_APEX"*) ok "  …and Hub's origin is allowed to call it" ;;
    *) bad "  …but hub.$WEB_APEX may not call $sub.$WEB_APEX (got '${pa:-nothing}')" ;;
  esac
done

echo "── CROSS-SURFACE SSO: the hand-off, driven end to end ───────────────────"
#
# THE DEFECT THIS SECTION EXISTS FOR. `IDENTITY_HANDOFF_ORIGINS` defaulted to ''
# and no compose file in this repository set it. `isAllowedOrigin` is
# `env.handoffOrigins.includes(origin)` over an empty array
# (identity/src/handoff.ts:32), so `createHandoffCode` returned null for EVERY
# origin and `POST /auth/handoff` answered 403 to everyone. A person could sign in
# at Hub and reach NO OTHER SURFACE — which is where most of the 86 tier-T3
# scenarios in doc 22 go on their second step.
#
# Nothing caught it because nothing in this repository had ever minted a hand-off
# code: identity's own suite sets the variable in `testsupport.ts:47`, so the
# empty-by-default case was only ever exercised by a deployment, and there had
# never been one.
#
# Driven through the gateway rather than the loopback port, because the origins
# on the allowlist are gateway origins and a check against 127.0.0.1:4100 would
# prove something the browser cannot do.
so_email="sso-$$@example.test"
so_reg=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$so_email\",\"handle\":\"sso$$\",\"password\":\"$PASS\"}")
so_tok=$(printf '%s' "$so_reg" | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
[ -n "$so_tok" ] && ok "a second account for the hand-off drill" || bad "could not register the hand-off drill user"

# Hub mints a code for Market — one real surface handing a session to another.
so_code=$(curl -sk -X POST --resolve "nimbus.$WEB_APEX:$GW_PORT:127.0.0.1" \
  "https://nimbus.$WEB_APEX:$GW_PORT/auth/handoff" \
  -H "authorization: Bearer $so_tok" -H 'content-type: application/json' \
  -H "origin: https://hub.$WEB_APEX" \
  -d "{\"redirectOrigin\":\"https://market.$WEB_APEX\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
if [ -n "$so_code" ]; then
  ok "identity minted a hand-off code for https://market.$WEB_APEX"
else
  bad "identity refused to mint a hand-off code — IDENTITY_HANDOFF_ORIGINS does not name market.$WEB_APEX, and cross-surface SSO is dead"
fi

# Market redeems it, presenting the Origin a browser would send. This is the
# assertion that proves the whole path: the code is bound to the origin it was
# minted for and matched against the browser's own header
# (identity/src/handoff.ts:73-86).
so_new=$(curl -sk -X POST --resolve "nimbus.$WEB_APEX:$GW_PORT:127.0.0.1" \
  "https://nimbus.$WEB_APEX:$GW_PORT/auth/handoff/redeem" \
  -H 'content-type: application/json' -H "origin: https://market.$WEB_APEX" \
  -d "{\"code\":\"${so_code:-nothing-was-minted}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
if [ -n "$so_new" ]; then
  ok "market.$WEB_APEX redeemed it and holds a session — A USER CAN CROSS SURFACES"
else
  bad "the hand-off code could not be redeemed from https://market.$WEB_APEX"
fi

# THE BINDING ITSELF. A code minted for Market must be worthless from anywhere
# else, or the allowlist is decoration. Minted fresh: the one above is spent.
so_code2=$(curl -sk -X POST --resolve "nimbus.$WEB_APEX:$GW_PORT:127.0.0.1" \
  "https://nimbus.$WEB_APEX:$GW_PORT/auth/handoff" \
  -H "authorization: Bearer $so_tok" -H 'content-type: application/json' \
  -d "{\"redirectOrigin\":\"https://market.$WEB_APEX\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
so_theft=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  --resolve "nimbus.$WEB_APEX:$GW_PORT:127.0.0.1" \
  "https://nimbus.$WEB_APEX:$GW_PORT/auth/handoff/redeem" \
  -H 'content-type: application/json' -H 'origin: https://not-a-cloudsforge-surface.example' \
  -d "{\"code\":\"${so_code2:-nothing-was-minted}\"}")
case "$so_theft" in
  2*) bad "A HAND-OFF CODE MINTED FOR MARKET WAS REDEEMED FROM ANOTHER ORIGIN ($so_theft) — the origin binding is not enforced" ;;
  *)  ok "the same code is refused from a foreign origin ($so_theft) — the binding holds" ;;
esac

# And an origin that is not a surface must not get a code at all.
so_bad=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  --resolve "nimbus.$WEB_APEX:$GW_PORT:127.0.0.1" \
  "https://nimbus.$WEB_APEX:$GW_PORT/auth/handoff" \
  -H "authorization: Bearer $so_tok" -H 'content-type: application/json' \
  -d '{"redirectOrigin":"https://not-a-cloudsforge-surface.example"}')
[ "$so_bad" = 403 ] && ok "an origin off the allowlist is refused a code (403)" \
  || bad "expected 403 for an unlisted redirectOrigin, got $so_bad"

# The /internal refusal, still winning over every router this work added. It is a
# router at priority 100000 pointed at an unreachable service, so 502 is the pass.
# Asserted on a SURFACE host, because the routers added for the fifteen bundles
# are the ones that could have shadowed it.
[ "$(gw "hub.$WEB_APEX" /internal/anything)" = 502 ] \
  && ok "/internal is still refused on a surface host — nothing added here outranks it" \
  || bad "/internal on hub.$WEB_APEX was not refused; the priority-100000 rule has been shadowed"

[ "$fails" -eq 0 ] && { echo; echo "all seams verified"; exit 0; }
echo; echo "$fails check(s) failed"; exit 1
