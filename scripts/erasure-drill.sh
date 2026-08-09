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
#
# ── `</dev/null` IS THE LOAD-BEARING PART OF BOTH OF THESE ────────────────────
#
# `docker compose exec` forwards stdin to the container even under `-T`, which
# disables the TTY and not the stream. Every caller below sits inside a
# `while read` loop fed by a here-string or a file, so the FIRST psql call
# swallowed the whole remaining list and the loop ended after one iteration.
#
# The symptom is the reason this is a comment and not a one-character fix: the
# drill reported on service one, said nothing whatsoever about services two
# through sixteen, and exited 0. A coverage check that silently covers one row
# is worse than no coverage check, and this file exists to catch exactly that
# shape of defect elsewhere in the estate.
psqlq() {
  db=$1; shift
  dc exec -T postgres psql -qtA -U cloudsforge -d "$db" -c "$*" </dev/null 2>/dev/null | tr -d ' \r'
}
psqlx() {
  db=$1; shift
  dc exec -T postgres psql -q -U cloudsforge -d "$db" -c "$*" </dev/null >/dev/null 2>&1
}

[ -f "$REGISTER" ] || { echo "erasure-drill: no register at $REGISTER" >&2; exit 2; }

# ── `SCAN`: THE RESIDUAL QUERY THAT CANNOT BE OUT OF DATE ─────────────────────
#
# A per-service list of tables to check is a list that goes stale the first time
# somebody adds a column, and it can only ever assert what its author remembered.
# `SCAN` asks the database instead: every text, uuid, varchar and jsonb column in
# every table in `public`, counted for any row containing the subject's id.
#
# It is deliberately blunt and deliberately over-broad. It found the defect three
# separate agents hit independently — the `outbox` table keeps the user id in its
# `actor` and its `payload`, in every repository, and no erasure handler had ever
# touched it. A curated table list would not have, because nobody thinks of the
# transport as a place personal data comes to rest.
#
# `query_to_xml` is how a count is taken over a table named by a row rather than
# by the query text: plain SQL cannot interpolate an identifier, and this stays
# a single statement, needing no function, no plpgsql and no privileges the drill
# does not already have.
#
# It is a full scan of every table. That is fine here — a drill database holds
# tens of rows — and it is not something to point at production.
#
# ── DECLARED RETENTION IS SUBTRACTED, NEVER HIDDEN ────────────────────────────
#
# Some services keep a row that still names the person, lawfully and on purpose:
# an invoice under a tax record-keeping obligation, a settlement sweep source
# whose custody binding is the only way the coin at that address is ever
# recoverable. Those are decisions with a basis behind them, and each one is
# argued table by table in its own service's erasure handler.
#
# They are handled by NAMING the tables in the register's `retained` column,
# which does two things at once: `SCAN` skips them, so the service can pass, and
# the drill COUNTS them separately and prints what survived. A retention nobody
# can see is indistinguishable from a service that forgot to erase — so the
# choice here is between a green tick that hides it and a green tick that reads
# out the exception, and only the second is worth having.
#
# A table NOT named here that still holds the subject is a failure. That is the
# whole force of the mechanism: retention has to be declared in advance, in the
# file the deploy reads, rather than discovered afterwards in a query result.
scan_sql() {
  printf "%s" "select coalesce(sum(n), 0)::int from (select (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I where %I::text like %L', table_schema, table_name, column_name, '%$1%'), false, true, '')))[1]::text::int as n from information_schema.columns where table_schema = 'public' and data_type in ('text','uuid','character varying','jsonb') and $2) t"
}

# `retained` as a SQL predicate. `-` means nothing is retained, which has to read
# as "exclude no table" rather than as an empty IN list.
not_retained() {
  case "$1" in
    -|'') printf 'true' ;;
    *)    printf "table_name not in (%s)" "$(printf '%s' "$1" | sed "s/[^,]*/'&'/g")" ;;
  esac
}

# The register's `residual` cell, turned into runnable SQL.
residual_sql() {
  if [ "$1" = "SCAN" ]; then scan_sql "$2" "$(not_retained "$3")"; else printf '%s' "${1//\{\{uid\}\}/$2}"; fi
}

# The mirror image: how much the declared exceptions actually kept.
retained_sql() {
  scan_sql "$1" "table_name in ($(printf '%s' "$2" | sed "s/[^,]*/'&'/g"))"
}

# ── the register, read once ───────────────────────────────────────────────────
#
# Held in parallel line-oriented strings rather than arrays of structs, because
# bash 3.2 has neither. `rows` is the working set; a row is re-split with the
# same IFS wherever it is used, so there is exactly one parse format in the file.
rows=$(grep -v '^[[:space:]]*#' "$REGISTER" | grep -v '^[[:space:]]*$')
[ -n "$rows" ] || { echo "erasure-drill: the register has no rows" >&2; exit 2; }
count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')

# ── EVERY ROW HAS EXACTLY SIX DELIMITERS, CHECKED BEFORE ANYTHING RUNS ────────
#
# The cells hold SQL, and SQL's string concatenation operator is `||` — which is
# two of this file's field delimiter. Two seeds used it, split into extra fields,
# and `residual` was then read as a fragment of the seed. That failed loudly
# ("the residual query did not run") only by luck; a row that split the other way
# would have run a DIFFERENT service's query and reported a pass.
#
# So the shape is checked here, once, before a user is created. Use `concat(a, b)`
# in a cell, never `||`.
malformed=$(awk -F'|' 'NF != 7 { print NR ": " $1 " has " (NF - 1) " delimiters, expected 6" }' <<<"$rows")
if [ -n "$malformed" ]; then
  echo "erasure-drill: $REGISTER is malformed — a cell almost certainly contains a '|':" >&2
  printf '  %s\n' "$malformed" >&2
  exit 2
fi

echo "── the subject ──────────────────────────────────────────────────────────"
# `$$` keeps concurrent runs from colliding on the handle's unique index.
EMAIL="erasure-drill-$$@example.test"
# A FRESH SECRET PER RUN, for the same reason `$$` is in the address above: this
# is a real account on a real estate. It was a constant in a PUBLIC file until
# 2026-08-09. The drill erases this subject at the end, but it exists for the
# length of the run, and nothing here needs the password after the sign-in below.
#
# `od -N24` and not `tr -dc … | head -c 32`: `tr` reading /dev/urandom never ends,
# so `head` closing the pipe kills it with SIGPIPE and `set -o pipefail`
# hands the assignment a non-zero status. `od` reads exactly 24 bytes and exits.
PASS=$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')
reg=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"handle\":\"erasure$$\",\"password\":\"$PASS\"}")
printf '%s' "$reg" | grep -q '"verificationRequired":true' \
  || { bad "register did not ask for verification: $(printf '%s' "$reg" | head -c 160)"; exit 1; }
ok "registered; the address must be proved before the account can act"

# ── PROVING THE ADDRESS, WITHOUT A MAILBOX AND WITHOUT A SHORTCUT ─────────────
#
# `email_verification_tokens` stores a `token_hash` and nothing else — identity
# never keeps the plaintext, correctly — so the token cannot be read out of the
# table it is checked against. It is read instead from the `verifyUrl` on the
# `identity.email.verification_requested` event identity itself emitted, which is
# the same string the email would have carried. The user's own flow, one hop
# earlier.
#
# The token is a CREDENTIAL. It goes from psql into curl inside one pipeline and
# is never echoed, never written to a file, and never interpolated into a message
# — including the failure message below, which reports only whether one was found.
vtok=$(psqlq identity "select payload->>'verifyUrl' from outbox where topic = 'identity.email.verification_requested' and payload->>'email' = '$EMAIL' order by occurred_at desc limit 1" \
  | sed 's/.*[#?&]token=//; s/&.*//')
[ -n "$vtok" ] || { bad "no verification event carried a link for the drill account"; exit 1; }
verified=$(curl -s -X POST "$IDENTITY/auth/email/verify" -H 'content-type: application/json' \
  -d "{\"token\":\"$vtok\"}")
unset vtok
printf '%s' "$verified" | grep -q '"accessToken"' \
  || { bad "verification was refused"; exit 1; }
ok "the address is proved through /auth/email/verify"

# Signed in through the ordinary route. `identifier`, not `email` — the field is
# named for the fact that a handle works here too.
utok=$(curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
[ -n "$utok" ] || { bad "sign-in did not issue a token"; exit 1; }

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
while IFS='|' read -r service database url action retained seed residual; do
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
# ── THE TEMPLATE IS SPELLED OUT, BECAUSE `-t` MEANS TWO DIFFERENT THINGS ──────
#
# This was `mktemp -t erasure-drill`. On BSD/macOS that is a PREFIX and works. On
# GNU coreutils — which is what the estate host runs — `-t` is the deprecated
# "treat as a name in TMPDIR" form and the name must still end in at least three
# X's, so it fails with `too few X's in template`.
#
# What that cost, measured on the live mainnet estate on 2026-08-05: `$BASE` was
# empty, so every `>>"$BASE"` in the BEFORE loop was a redirect to '' that failed,
# so NOTHING was recorded — and the AFTER loop, which reads `<"$BASE"`, iterated
# over nothing at all. The drill then printed **ERASURE HONOURED — 16 service(s)**
# and exited 0, against an estate where fourteen of the sixteen have no
# subscription and had never received the event (micro-org #203, #220).
#
# That is precisely the vacuous check this file exists to refuse, in this file.
# So: an explicit template that both mktemp implementations accept, and then the
# two guards below, because a temporary file is a dependency and an unusable one
# has to stop the run rather than empty it.
BASE=$(mktemp "${TMPDIR:-/tmp}/erasure-drill.XXXXXX") || BASE=''
[ -n "$BASE" ] && [ -w "$BASE" ] || {
  echo "erasure-drill: could not create the baseline file — nothing below could be verified" >&2
  exit 2
}
trap 'rm -f "$BASE"' EXIT
while IFS='|' read -r service database url action retained seed residual; do
  before=$(psqlq "$database" "$(residual_sql "$residual" "$uid" "$retained")")
  inbox=$(psqlq "$database" "select count(*) from inbox where topic = 'identity.user.deleted'")
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$service" "$database" "$action" "${before:-?}" "${inbox:-0}" "$residual" "$retained" >>"$BASE"
  # A query that ERRORED and a query that answered zero both come back empty from
  # psql, and they mean opposite things: one is "the service holds nothing", the
  # other is "this check never ran". Kept apart, because a check that never ran
  # must never be reported as a check that passed.
  case "$residual:$before" in
    # ── ACK-ONLY: a service that never held the raw subject in the first place ──
    #
    # `analytics` is pseudonymous by construction: it stores
    # HMAC(pepper, "cf.analytics.lookup.v1|" || subject) and never the subject
    # (`analytics/src/pseudonym.ts`), so a scan for the person's id finds
    # nothing before the deletion as well as after, and asserting "0 rows"
    # against it would be the vacuous check this drill exists to refuse.
    #
    # What IS asserted for it is the acknowledgement: a new inbox row proves the
    # event reached the handler and the per-subject salt was destroyed. That is
    # the whole of the fix that mattered here — until its subscription was
    # seeded, `eraseSubject` was code no event could ever reach.
    ACK-ONLY:*) note "$service: pseudonymous by construction; asserted by acknowledgement, not by row count" ;;
    *:'')       bad "$service: the residual query did not run against '$database' — is the service migrated?" ;;
    *:0)        bad "$service holds NOTHING for the subject — its erasure check would be vacuous" ;;
    *)          ok "$service holds $before row(s) naming the subject ($action)" ;;
  esac
done <<<"$rows"

# ── THE AFTER PHASE VERIFIES WHAT THIS FILE HOLDS, SO CHECK IT HOLDS IT ───────
#
# The second half of the guard above. `<"$BASE"` over a short file is silent: it
# checks the services it finds and says nothing whatsoever about the ones it does
# not, which is how a partial baseline becomes a full pass. One line per register
# row, counted before a real user is deleted, so a shortfall costs nothing.
baselined=$(wc -l <"$BASE" | tr -d ' ')
[ "$baselined" = "$count" ] || {
  echo "erasure-drill: baselined $baselined of $count service(s) — the AFTER phase would silently skip the rest" >&2
  exit 2
}

echo
echo "── the deletion, through the route a user would use ─────────────────────"
# Password re-entry is required by identity (`src/server.ts`) and is
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
while IFS='|' read -r service database action before inbox_before residual retained; do
  q=$(residual_sql "$residual" "$uid" "$retained")
  left=""
  for _ in $(seq 1 "$DEADLINE"); do
    # ACK-ONLY waits on the acknowledgement instead: there is no row count to
    # fall, so polling one would exit instantly and prove nothing.
    if [ "$residual" = "ACK-ONLY" ]; then
      left=0
      now=$(psqlq "$database" "select count(*) from inbox where topic = 'identity.user.deleted'")
      [ "${now:-0}" -gt "${inbox_before:-0}" ] && break
    else
      left=$(psqlq "$database" "$q")
      [ "${left:-1}" = "0" ] && break
    fi
    sleep 1
  done
  ack=$(psqlq "$database" "select count(*) from inbox where topic = 'identity.user.deleted'")
  if [ -z "$left" ]; then
    bad "$service: the residual query did not run against '$database' — nothing was verified"
  elif [ "$left" != "0" ]; then
    bad "$service: $left row(s) still name the subject after ${DEADLINE}s (was $before) — the subscription, the handler or the relay is broken"
  elif [ "${ack:-0}" -le "${inbox_before:-0}" ]; then
    # Zero rows and no acknowledgement is the shape of a check that passed for
    # the wrong reason, so it is a failure and not a pass with a caveat.
    bad "$service: 0 rows name the subject, but NO new inbox row arrived ($inbox_before → $ack) — the event never landed"
  else
    if [ "$residual" = "ACK-ONLY" ]; then
      ok "$service: acknowledged ($inbox_before → $ack) — $action"
    else
      ok "$service: $before → 0 by $action, acknowledged ($inbox_before → $ack)"
    fi
    # Declared retention, read out rather than left implicit. Counted AFTER the
    # erasure, so this is what a regulator would actually still find.
    if [ "$retained" != "-" ] && [ -n "$retained" ]; then
      kept=$(psqlq "$database" "$(retained_sql "$uid" "$retained")")
      note "retained by declaration: ${kept:-?} row(s) in $retained — basis in ${service}/src/erasure.ts"
    fi
  fi
done <"$BASE"

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mERASURE HONOURED\033[0m — %s service(s), one deletion, nothing left naming the subject.\n' "$count"
  exit 0
fi
printf '\033[31m%s FAILURE(S)\033[0m — a deletion request today would leave personal data behind.\n' "$fails"
exit 1
