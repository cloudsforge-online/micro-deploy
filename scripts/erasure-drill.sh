#!/usr/bin/env bash
# Delete a real user and prove, per service, that nothing still names them.
#
#   cd deploy && ./scripts/erasure-drill.sh
#
# ── WHAT THIS IS FOR ───────────────────────────────────────────────────────────
#
# Rule 6 says every service holding a `user_id` erases on `identity.user.deleted`.
# It was true of two services. Sixteen now claim it, and a claim is what this
# file exists to disbelieve: a subscriber nobody has watched work is a subscriber
# nobody knows works, and a unit test that mocks the event bus proves nothing at
# all about whether a deletion request is honoured.
#
# So this creates an account, gives it something to lose in every registered
# service, deletes it through the real route with the real password check, and
# then waits for each service's residual count to reach zero on its own. Nothing
# on the path is stubbed: identity writes its outbox row in the same transaction
# as the state change, the leased relay signs and POSTs it, each consumer claims
# its inbox row and runs its own handler.
#
# ── THE THREE ASSERTIONS, AND WHY EACH IS NEEDED ───────────────────────────────
#
#   1. BEFORE > 0.  An erasure of nothing succeeds trivially. Every check here
#      first proves the service actually held the person, because an assertion
#      over an empty table is this estate's most-repeated defect: a check that
#      cannot fail, reported as a pass.
#
#   2. AFTER = 0.   No row in that database still names the subject. Uniform
#      across services that delete and services that lawfully retain a
#      de-identified record — see `erasure/register.psv`.
#
#   3. A NEW INBOX ROW.  Rows reaching zero is not by itself proof the EVENT did
#      it; a service that never had the rows, or a truncate between runs, looks
#      identical. The inbox carries only `(topic, event_id)` — no payload, so
#      there is nothing in it to scope to a user — so the acknowledgement is a
#      new row RELATIVE TO A BASELINE captured before the deletion. estate-verify
#      learned this the hard way: it polled `count(*) >= 1` and the previous run's
#      acknowledgement satisfied the poll instantly the moment the environment
#      outlived a single run.
#
# `set -u` is load-bearing and has already caught an ordering bug in its sibling.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

COMPOSE=${COMPOSE:-compose/docker-compose.estate.yml}
PROJECT=${PROJECT:-cloudsforge-estate}
IDENTITY=${IDENTITY:-http://127.0.0.1:4100}
NOTIFY=${NOTIFY:-http://127.0.0.1:4110}
REGISTER=${REGISTER:-erasure/register.psv}
# Long enough for the relay's poll, the per-subscriber HTTP hop and a retry.
# Short enough that a broken seam fails a deploy rather than hanging it.
DEADLINE=${DEADLINE:-90}

fails=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); }
note() { printf '       %s\n' "$1"; }

dc()   { docker compose -p "$PROJECT" -f "$COMPOSE" "$@"; }

# One place that talks to Postgres. `-qtA` is tuples-only and unaligned, so the
# answer is the value and not a box drawn around it.
psqlq() {
  db=$1; shift
  dc exec -T postgres psql -qtA -U cloudsforge -d "$db" -c "$*" 2>/dev/null | tr -d ' \r'
}
psqlx() {
  db=$1; shift
  dc exec -T postgres psql -q -U cloudsforge -d "$db" -c "$*" >/dev/null 2>&1
}

[ -f "$REGISTER" ] || { echo "erasure-drill: no register at $REGISTER" >&2; exit 2; }

# ── the register, read once ───────────────────────────────────────────────────
#
# Held in parallel line-oriented strings rather than arrays of structs, because
# bash 3.2 has neither. `rows` is the working set; a row is re-split with the
# same IFS wherever it is used, so there is exactly one parse format in the file.
rows=$(grep -v '^[[:space:]]*#' "$REGISTER" | grep -v '^[[:space:]]*$')
[ -n "$rows" ] || { echo "erasure-drill: the register has no rows" >&2; exit 2; }
count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')

echo "── the subject ──────────────────────────────────────────────────────────"
# `$$` keeps concurrent runs from colliding on the handle's unique index.
EMAIL="erasure-drill-$$@example.test"
PASS="correct-horse-battery-staple-42"
reg=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"handle\":\"erasure$$\",\"password\":\"$PASS\"}")
utok=$(printf '%s' "$reg" | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
[ -n "$utok" ] || { bad "register did not issue a token: $(printf '%s' "$reg" | head -c 160)"; exit 1; }

# Captured while the account still answers: the token dies with the account, and
# every assertion below is keyed on this id.
uid=$(curl -s "$IDENTITY/auth/me" -H "authorization: Bearer $utok" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('user',{}).get('id',''))" 2>/dev/null)
[ -n "$uid" ] || { bad "could not read the drill user's id"; exit 1; }
# The id is a random uuid for an account created seconds ago and deleted at the
# end of this run. It is printed because every failure below is unreadable
# without it, and it names nobody once the run finishes.
ok "a drill account exists ($uid)"

echo
echo "── giving the subject something to lose, in $count service(s) ───────────"
# A real, authenticated user act where one exists. notify holds the most personal
# data in the estate — addresses, phone numbers, push tokens — so it earns a real
# API write rather than an INSERT.
curl -s -X PUT "$NOTIFY/preferences" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' \
  -d '{"preferences":[{"category":"security","channel":"in_app","digest":"instant"}]}' >/dev/null
# activity fills itself: `identity.user.registered` and `identity.session.created`
# were both emitted by the registration above and are both subscribed, so its
# rows arrive over the same bus this drill is testing.

# A here-string, never a pipe. `rows | while` runs the loop in a SUBSHELL, so
# `fails` incremented inside it is discarded at the closing `done` and every
# failure below would be counted as a pass — the exact class of defect this file
# exists to catch, and it would be catching it in itself.
while IFS='|' read -r service database url action seed residual; do
  [ "$seed" = "-" ] && continue
  if psqlx "$database" "${seed//\{\{uid\}\}/$uid}"; then
    note "$service: seeded"
  else
    bad "$service: could not seed the drill row, so its erasure check would be vacuous"
  fi
done <<<"$rows"

# The relay is asynchronous, so activity's rows are not there the instant the
# registration returns. Wait for the first one rather than sleeping a guess.
for _ in $(seq 1 30); do
  [ "$(psqlq activity "select count(*) from activity_records where user_id = '$uid'")" != "0" ] && break
  sleep 1
done

echo
echo "── BEFORE: every service must actually hold the person ──────────────────"
# The baselines are carried to the AFTER phase in a file rather than in memory,
# so that what the second phase asserts against is the value the first phase
# actually observed, and the two cannot be re-derived differently.
BASE=$(mktemp -t erasure-drill)
trap 'rm -f "$BASE"' EXIT
while IFS='|' read -r service database url action seed residual; do
  before=$(psqlq "$database" "${residual//\{\{uid\}\}/$uid}")
  inbox=$(psqlq "$database" "select count(*) from inbox where topic = 'identity.user.deleted'")
  printf '%s|%s|%s|%s|%s|%s\n' "$service" "$database" "$action" "${before:-0}" "${inbox:-0}" "$residual" >>"$BASE"
  if [ "${before:-0}" -gt 0 ]; then
    ok "$service holds $before row(s) naming the subject ($action)"
  else
    bad "$service holds NOTHING for the subject — its erasure check would be vacuous"
  fi
done <<<"$rows"

echo
echo "── the deletion, through the route a user would use ─────────────────────"
# Password re-entry is required by identity (`src/server.ts:1844-1847`) and is
# not bypassed here: this is the same call the account settings page makes.
del=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$IDENTITY/users/me" \
  -H "authorization: Bearer $utok" -H 'content-type: application/json' \
  -d "{\"password\":\"$PASS\"}")
case "$del" in
  2*) ok "DELETE /users/me accepted ($del)" ;;
  *)  bad "DELETE /users/me answered $del — nothing below can pass"; exit 1 ;;
esac
# The event is written in the same transaction as the state change, at the
# REQUEST, not at the tombstone — so it is already in identity's outbox and the
# relay will carry it. The tombstone sweep is pulled forward only so the grace
# window does not make this a seven-day drill; it is the sweep's clock being
# compressed, not the sweep being bypassed.
psqlx identity "update jobs set run_at = now() where kind = 'identity.tombstone'"

echo
echo "── AFTER: no row in any database may still name the person ──────────────"
while IFS='|' read -r service database action before inbox_before residual; do
  q="${residual//\{\{uid\}\}/$uid}"
  left=""
  for _ in $(seq 1 "$DEADLINE"); do
    left=$(psqlq "$database" "$q")
    [ "${left:-1}" = "0" ] && break
    sleep 1
  done
  ack=$(psqlq "$database" "select count(*) from inbox where topic = 'identity.user.deleted'")
  if [ "${left:-1}" != "0" ]; then
    bad "$service: $left row(s) still name the subject after ${DEADLINE}s (was $before) — the subscription, the handler or the relay is broken"
  elif [ "${ack:-0}" -le "${inbox_before:-0}" ]; then
    # Zero rows and no acknowledgement is the shape of a check that passed for
    # the wrong reason, so it is a failure and not a pass with a caveat.
    bad "$service: 0 rows name the subject, but NO new inbox row arrived ($inbox_before → $ack) — the event never landed"
  else
    ok "$service: $before → 0 by $action, acknowledged ($inbox_before → $ack)"
  fi
done <"$BASE"

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mERASURE HONOURED\033[0m — %s service(s), one deletion, nothing left naming the subject.\n' "$count"
  exit 0
fi
printf '\033[31m%s FAILURE(S)\033[0m — a deletion request today would leave personal data behind.\n' "$fails"
exit 1
