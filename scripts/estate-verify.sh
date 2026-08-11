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

# ── WHICH ESTATE THIS RUN IS ASKING ABOUT ─────────────────────────────────────
#
# This file addressed MAINNET AND ONLY MAINNET, and nothing in it said so. The
# host ports below were the literal `41xx` series, `GW_PORT` fell back to 443,
# the hostnames fell back to `cloudsforge.localtest.me`, and every
# `docker compose exec` resolved the project from the working directory. Point it
# at testnet and NONE of that fails loudly, because testnet is a different value
# for each one:
#
#   CF_PORT_BASE=5          debug ports are the 51xx series, not 41xx
#   CF_GATEWAY_PORT=10443   the browser port, not 443
#   CF_WEB_SUFFIX           `-testnet.cloudsforge.online`, not `.cloudsforge.online`
#   CF_SITE_HOST            `testnet.cloudsforge.online`
#   CF_EMBER_NETWORK        `testnet` — chain 7412, not mainnet's 7411
#   CF_PROJECT=cf-testnet   a different container namespace and a different postgres
#
# So a run intended for testnet connected to MAINNET's ports, opened MAINNET's
# databases through `docker compose exec -T postgres`, and reported a verdict —
# a true one, about the wrong estate. That is worse than this repository's named
# defect class of a check that cannot fail: it is a check that passes loudly for
# a subject nobody asked about.
#
# THE FIX IS TO READ THE FILE THE DEPLOY READS, NOT TO COPY ITS VALUES.
# `scripts/release-deploy.sh` selects an environment with `ESTATE_ENV`, and
# `compose/mainnet.env` / `compose/testnet.env` already carry all six. Reading
# them here means the verify cannot disagree with the deploy about which estate
# exists. A second copy of the same six values is the hand-maintained list this
# repository has already paid for four times.
#
#   ./scripts/estate-verify.sh                                   # mainnet
#   ESTATE_ENV=compose/testnet.env ./scripts/estate-verify.sh    # testnet
#
# The values are EXPORTED rather than only assigned, because two consumers read
# them from the environment and not from these variables: `docker compose` itself
# interpolates `CF_PROJECT` for `name:` (docker-compose.estate.yml:64), which is
# how thirty-three `exec -T postgres` calls below find the right database without
# a single `-p` flag; and the gateway section reads `CF_WEB_SUFFIX` directly.
#
# NOT `source`d. These are docker-compose env files, not shell — a value holding
# a space, a `$` or a backtick is legal there and is code here. Six anchored
# `sed` reads instead, and nothing else in the file is even looked at.
#
# An explicit shell override still wins, both over the file and over the
# defaults: every assignment here and below is still `:-`, so
# `IDENTITY=… ./scripts/estate-verify.sh` keeps behaving exactly as it did.
ESTATE_ENV=${ESTATE_ENV:-compose/mainnet.env}
if [ ! -f "$ESTATE_ENV" ]; then
  echo "estate-verify: $ESTATE_ENV does not exist." >&2
  echo "               Without it this run falls back to mainnet's ports, mainnet's project" >&2
  echo "               and mainnet's hostnames, and reports on whichever estate answers them." >&2
  exit 2
fi
envget() { sed -n "s/^$1=//p" "$ESTATE_ENV" | tail -1 | tr -d '\r'; }
for cf in CF_PROJECT CF_PORT_BASE CF_GATEWAY_PORT CF_WEB_APEX CF_WEB_SUFFIX CF_SITE_HOST CF_EMBER_NETWORK; do
  # Shell first, file second. `eval` on a name from this fixed list only.
  eval "cur=\${$cf:-}"
  [ -n "$cur" ] || cur=$(envget "$cf")
  [ -n "$cur" ] && eval "export $cf=\"\$cur\""
done
# Announced, not assumed. A run that reports 76 failures is unreadable unless the
# first line says which estate it was asking about — that ambiguity is the whole
# reason this block exists.
echo "estate: ${CF_SITE_HOST:-cloudsforge.localtest.me}  env: ${ESTATE_ENV##*/}  project: ${CF_PROJECT:-cloudsforge-estate}  ports: ${CF_PORT_BASE:-4}1xx  chain: ${CF_EMBER_NETWORK:-mainnet}"

# Host ports are 4100 + the service's index in micro-org's registry (portFor,
# cfctl.ts) — derived from the one list that orders every repository rather
# than picked, because the estate has twice lost time to a hand-chosen port that
# already belonged to something else.
#
# The LEADING DIGIT is `$PB`, not a literal `4`. It is the one character
# `compose/testnet.env` changes to move all forty-five debug ports at once
# (`CF_PORT_BASE=5`), and `docker-compose.estate.yml` publishes them as
# `${CF_PORT_BASE:-4}1xx` — so this expression is the same expression, not a
# parallel convention that has to be kept in step by hand.
PB=${CF_PORT_BASE:-4}
IDENTITY=${IDENTITY:-http://127.0.0.1:${PB}100}
POLICY=${POLICY:-http://127.0.0.1:${PB}101}
LEDGER=${LEDGER:-http://127.0.0.1:${PB}102}
WALLET=${WALLET:-http://127.0.0.1:${PB}103}
SETTLEMENT=${SETTLEMENT:-http://127.0.0.1:${PB}104}
PRICING=${PRICING:-http://127.0.0.1:${PB}105}
BILLING=${BILLING:-http://127.0.0.1:${PB}106}
CUSTODY=${CUSTODY:-http://127.0.0.1:${PB}107}
ACTIVITY=${ACTIVITY:-http://127.0.0.1:${PB}109}
NOTIFY=${NOTIFY:-http://127.0.0.1:${PB}110}
STUDIO=${STUDIO:-http://127.0.0.1:${PB}111}
MINT=${MINT:-http://127.0.0.1:${PB}112}
MARKET=${MARKET:-http://127.0.0.1:${PB}113}
TRADE=${TRADE:-http://127.0.0.1:${PB}114}
WORLDS=${WORLDS:-http://127.0.0.1:${PB}115}
NDA=${NDA:-http://127.0.0.1:${PB}116}
COMMUNITY=${COMMUNITY:-http://127.0.0.1:${PB}117}
DEVPLATFORM=${DEVPLATFORM:-http://127.0.0.1:${PB}118}
HUB=${HUB:-http://127.0.0.1:${PB}119}
ADMIN=${ADMIN:-http://127.0.0.1:${PB}120}
ANALYTICS=${ANALYTICS:-http://127.0.0.1:${PB}121}
# The title service, not its frontend. Derived (registry index 24, immediately
# before tessera's 4125) and measured on the app host on 2026-08-10, where
# `cloudsforge-estate-aetherholm-1` publishes 4124 and reports healthy. Named here
# because the worlds/aetherholm section below stopped being able to claim this
# service is absent from the estate.
AETHERHOLM=${AETHERHOLM:-http://127.0.0.1:${PB}124}
# 4125 on the host, 4022 in the container. tessera is the one service here that does not bind
# 4000, and THAT number is argued rather than picked — 23-tessera.md §10.1. The BIND port is a
# different question from the HOST port and is untouched.
#
# The host port was 4140 until micro-org's registry was swept from 46 rows to 70. tessera now has
# a row, so this is derived (index 25) rather than chosen — and 4140 has been REASSIGNED to
# aetherholm-web, so had this stayed at 4140 the checks below would not have failed to connect.
# They would have driven another service's container and reported green.
TESSERA=${TESSERA:-http://127.0.0.1:${PB}125}
# The bundle, not the service. Named rather than written inline at the `/world-assets/` check
# below, because a bare literal is a port `scripts/web-check.py` cannot resolve to a repository
# and therefore cannot recompute. It derives to 4140 — it was 4141 until the P13 fold removed
# `foresight-admin-web` from micro-org's registry at index 39 and moved everything below it down
# by one. `web-check.py` named all seven; this is one of them.
TESSERA_WEB=${TESSERA_WEB:-http://127.0.0.1:${PB}140}
# The observability sink. Derived — `deployableRepos()` index 41, immediately after
# tessera-web's 4140 — and `scripts/web-check.py` recomputes it from micro-org rather
# than trusting this line. Until recently there was nothing on this port at all: the
# service was absent from the estate compose file entirely while sixteen frontends
# posted browser telemetry at it.
LANTERN=${LANTERN:-http://127.0.0.1:${PB}141}
COMPOSE=${COMPOSE:-compose/docker-compose.estate.yml}

# WHICH CHAIN THIS ESTATE IS ON — 0x1cf3 is 7411 (`hearth`), 0x1cf4 is 7412
# (`hearth-testnet`), per `hearth/node/src/params.js`.
#
# The EMBER section near the end of this file asserted `0x1cf4` as a literal, from
# when there was one chain, and it had become a check that could not pass: 8545 is
# now the MAINNET seed and answers 7411, so every EMBER section would have taken
# the "no chain here" skip on a host with a perfectly healthy chain — a skip that
# is loud but is still not evidence. `CF_EMBER_NETWORK` is the same variable
# `docker-compose.estate.yml` keys its `env_file:` on, so this file and the estate
# cannot disagree about which chain they mean. It is also the value queried as
# `watched_addresses.network`, which is the row the indexer writes under
# `INDEXER_CHAINS`.
#
# DEFINED HERE, NOT BESIDE ITS FIRST USE: `/v1/custody/ember/<network>/total` is
# read at line ~2086, long before the EMBER section, and an empty expansion there
# would have produced a 404 that reads exactly like a broken route.
EMBER_NETWORK=${CF_EMBER_NETWORK:-mainnet}
case "$EMBER_NETWORK" in
  mainnet) ember_chain_want=0x1cf3; ember_chain_dec=7411 ;;
  testnet) ember_chain_want=0x1cf4; ember_chain_dec=7412 ;;
  *) echo "estate-verify: CF_EMBER_NETWORK is \"$EMBER_NETWORK\"; expected mainnet or testnet" >&2; exit 2 ;;
esac
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
  "admin-api $ADMIN" "analytics $ANALYTICS" "tessera $TESSERA"; do
  set -- $pair
  [ "$(code "$2/livez")"  = 200 ] && ok "$1 /livez"  || bad "$1 /livez"
  # /readyz probes the database. /livez answers while it is unreachable, which is
  # the whole distinction the two endpoints exist to draw.
  [ "$(code "$2/readyz")" = 200 ] && ok "$1 /readyz" || bad "$1 /readyz"
done

echo "── the databases this estate declares are the databases it HAS ──────────"
# ── THE FILE THAT ONLY EVER RUNS ONCE, AND THE LIST NOBODY COMPARED ──────────
#
# `compose/estate/initdb.sql` is mounted at
# `/docker-entrypoint-initdb.d/10-databases.sql`, and postgres runs that
# directory ONLY against an empty data directory. Every estate that already
# exists ran the file once, months ago, with whatever list it held that day, so
# adding a `CREATE DATABASE` line changes nothing on a running server — and
# until this block nothing anywhere compared the list the file declares against
# the databases a server actually has, in either direction.
#
# THE FAILURE THIS WOULD HAVE CAUGHT, WHICH IS NOT HYPOTHETICAL. Deploying 2.5.8
# with `COMPOSE_PROFILES=pool` on mainnet: `pool-migrate` exited 1 with
# `PostgresError: database "pool" does not exist`, `--wait` failed the whole
# deploy, and the estate refused. The file declared `pool`; this server had 28 of
# the 29 names. It was created by hand and the deploy re-run. That is the right
# direction to fail in and the most expensive place to discover it — at deploy
# time, on the estate, as a stack trace rather than a sentence — and it was only
# loud at all because pool's migrator runs eagerly. A service that connects
# lazily would have deployed green and failed on its first real request.
# micro-org#306.
#
# WHY HERE AND NOT ONLY AS A `release-deploy.sh` PRE-FLIGHT. This runs per estate
# on a schedule, so it answers the question when nobody is deploying anything —
# which is the moment the answer is cheap. It also reaches the estate a deploy
# pre-flight would not. `initdb.sql` ran once per estate with whatever list it
# held on that estate's first boot, and the two estates were bootstrapped at
# different times, so testnet is the MORE likely of the two to have drifted —
# and testnet is deployed to far less often, so a check that only runs during a
# deploy would ask it least where it matters most. (This paragraph used to say
# testnet was stopped for bitcoind's IBD. Bitcoin reached its tip on 2026-08-10
# and testnet now runs on the app host, 48 containers healthy on 2026-08-11. The
# argument never depended on that; the drift does not care whether anyone is
# looking.)
#
# ── THE FAILURE POLICY, WHICH IS THE ONLY REAL DECISION HERE ─────────────────
#
# The diff itself is three commands. Both directions are failures, and that is a
# decision rather than an oversight:
#
#   DECLARED BUT ABSENT is the `pool` defect exactly. A service whose database
#   this server lacks cannot migrate and cannot serve.
#
#   PRESENT BUT UNDECLARED is the SAME defect seen from the other estate. A
#   database that exists here and is not in the file is one a FRESH estate would
#   come up without — the identical stack trace, deferred to whoever bootstraps
#   next. It is also how an abandoned service's data outlives the decision to
#   abandon it, silently. Both remedies are cheap and both are a decision
#   somebody should make on purpose: add the line, or drop the database.
#
# NEVER SKIPS. If psql cannot be reached this reports a failure rather than the
# success it did not establish — the estate has already been bitten by checks
# that went quiet when their input vanished and still looked like evidence.
initdb_sql="$(dirname "$COMPOSE")/estate/initdb.sql"
if [ ! -f "$initdb_sql" ]; then
  bad "database drift: $initdb_sql is missing, so the declared list cannot be read"
else
  # The same `docker compose exec -T postgres` path the thirty-three database
  # checks below use, so this asks the postgres of the estate named at the top of
  # this run and not whichever one happens to answer.
  db_live=$(docker compose -f "$COMPOSE" exec -T postgres \
    psql -qtA -U cloudsforge -d postgres \
    -c "select datname from pg_database where datistemplate = false and datname <> 'postgres' order by 1" \
    2>/dev/null | tr -d '\r' | sed '/^$/d')
  # `template0`, `template1` and `postgres` are the server's own and are excluded
  # by the query, not by a name list here — a name list is the thing that goes
  # stale.
  db_declared=$(grep -oE '^[[:space:]]*CREATE DATABASE[[:space:]]+[a-z_]+' "$initdb_sql" \
    | awk '{print $3}' | sort -u)
  if [ -z "$db_live" ]; then
    # Anchored on the query returning NOTHING, which no reachable server can do:
    # a postgres with zero non-template databases is not a state this estate has.
    bad "database drift: could not read pg_database through 'compose exec -T postgres' — not checked, so not passing"
  else
    db_missing=$(comm -23 <(printf '%s\n' "$db_declared") <(printf '%s\n' "$db_live"))
    db_extra=$(comm -13 <(printf '%s\n' "$db_declared") <(printf '%s\n' "$db_live"))
    db_dn=$(printf '%s\n' "$db_declared" | wc -l | tr -d ' ')
    db_ln=$(printf '%s\n' "$db_live" | wc -l | tr -d ' ')
    if [ -n "$db_missing" ]; then
      bad "declared in initdb.sql and ABSENT from this server: $(printf '%s' "$db_missing" | tr '\n' ' ') — every service that owns one of these will fail its migration at deploy time. Create it: CREATE DATABASE <name> OWNER cloudsforge"
    fi
    if [ -n "$db_extra" ]; then
      bad "on this server and NOT declared in initdb.sql: $(printf '%s' "$db_extra" | tr '\n' ' ')— a fresh estate would come up without them. Add the line, or drop the database"
    fi
    [ -z "$db_missing" ] && [ -z "$db_extra" ] &&
      ok "initdb.sql declares $db_dn databases and this server has exactly those $db_ln"
  fi
fi

echo "── identity publishes a signing key ─────────────────────────────────────"
jwks=$(curl -s "$IDENTITY/.well-known/jwks.json")
if printf '%s' "$jwks" | grep -q '"kty"'; then
  alg=$(printf '%s' "$jwks" | python3 -c "import sys,json;print(json.load(sys.stdin)['keys'][0].get('alg'))" 2>/dev/null)
  [ "$alg" = "RS256" ] && ok "JWKS serves an RS256 key" || bad "JWKS alg is $alg, expected RS256"
else
  bad "JWKS has no keys"
fi

echo "── a user can be created and can sign in ────────────────────────────────"
# ── THIS DRILL WAS ASSERTING A ROUTE THAT NO LONGER EXISTS ────────────────────
#
# It used to read `accessToken` straight out of `POST /auth/register`. That route
# stopped minting one deliberately: identity now answers 202 `verificationRequired`
# and `signInRefusal` refuses the account until the link is spent, because the old
# behaviour signed a user in on an address nobody had proved control of. The
# owner reported both halves from the live product — *"i didn't receive any
# registration email and i was able to login directly."*
#
# So `$utok` was empty, and EVERY later section that needs a signed-in user
# inherited that emptiness: the money seam, the sign-in seam, SSO, erasure, the
# achievement grant, tessera. Ninety-five checks failed on mainnet from this one
# line, and each of those failures was a report about this drill rather than
# about the estate. A harness that asserts a removed route does not fail loudly;
# it fails everywhere, which is much harder to read.
#
# The registration flow is now driven the way a person drives it, one hop at a
# time, which is also what makes the drill able to detect the real defect it was
# blind to before: a verification link that is never issued.
EMAIL="slice-$$@example.test"
# A FRESH SECRET PER RUN. This was a constant in a PUBLIC file until 2026-08-09,
# and this account is registered on the REAL estate and is not deleted afterwards —
# so every verification run left behind a real account whose password anyone could
# read. Nothing needs it to be stable: it is spent on the sign-in below and the run
# never signs in as this user again. `$$` already makes the account per-run.
#
# `od -N24` and not `tr -dc … | head -c 32`: `tr` reading /dev/urandom never ends,
# so `head` closing the pipe kills it with SIGPIPE and `set -o pipefail`
# hands the assignment a non-zero status. `od` reads exactly 24 bytes and exits.
# 48 hex characters clears identity's minimum with room to spare, and hex needs no
# shell quoting anywhere it is interpolated into JSON below.
PASS=$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')

# ── THE REGISTRATION CHALLENGE, AND WHY THE RETRY BELOW IS NOT A SHORTCUT ─────
#
# micro-org#361 put a Cloudflare Turnstile in front of `POST /auth/register`, and
# release 2.5.19 turned it on. This drill went red the same minute and in the
# familiar shape: `challenge_required`, then no verification link, then no
# session, then every later section that needs a signed-in user — a report about
# the drill, not about the estate, exactly like the 202 breakage documented
# above.
#
# A SCRIPT CANNOT SOLVE A TURNSTILE. That is what one is for, so there is no
# honest fix that makes this call succeed as an anonymous caller. There is one
# bypass identity grants on purpose — `challengeBypass` in
# `identity/src/server.ts` excuses a SERVICE PRINCIPAL — and it is how micro-
# beacon has kept registering since the same release. This drill takes the same
# door, and only after being refused at the front one.
#
# THE ORDER IS THE POINT. The unauthenticated attempt comes first and its refusal
# is an assertion: it proves the gate is ON in this environment, which is the one
# half of "the widget works" an unattended run can establish. A drill that simply
# presented a bearer would pass just as happily against an estate whose Turnstile
# had been switched off by a missing variable.
#
# WHAT IT STILL DOES NOT PROVE: that a HUMAN gets through the widget. Nothing
# automated can. That is a manual check against hub-web.
#
# The credential is BEACON_IDENTITY_CREDENTIAL from the untracked
# `compose/estate/tokens.env` — reused rather than minted anew, because beacon is
# already the estate's synthetic-registration principal and a second credential
# would be a second thing to rotate. Override with VERIFY_SERVICE_CREDENTIAL.
# Neither it nor the token it buys is ever echoed, including in the failures.
#
# `REG_BEARER` is empty on an unchallenged deployment and stays that way, so
# `register_as_drill` below sends no Authorization header there — the anonymous
# path remains the path an unchallenged estate is checked on.
REG_BEARER=''

# Register, handling the challenge. Prints the response body.
#
# TWO drills register: this one, and the SSO hand-off further down. The second is
# where the cascade landed the first time — it registered, was refused, then set
# `email_verified_at` on an account that did not exist, then failed the login and
# reported it as "the SSO checks are NOT a verdict on the allowlist". One helper
# rather than two copies, because a third caller appearing and being written the
# anonymous way is exactly how this comes back.
register_as_drill() {
  local body out
  body="{\"email\":\"$1\",\"handle\":\"$2\",\"password\":\"$PASS\"}"
  out=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' -d "$body")
  if [ -n "$REG_BEARER" ] && printf '%s' "$out" | grep -q '"code":"challenge_required"'; then
    out=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
      -H "authorization: Bearer $REG_BEARER" -d "$body")
  fi
  printf '%s' "$out"
}

reg=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"handle\":\"slice$$\",\"password\":\"$PASS\"}")
if printf '%s' "$reg" | grep -q '"code":"challenge_required"'; then
  ok "the registration challenge is ON — a caller with neither a solved challenge nor a service principal is refused"
  service_credential=${VERIFY_SERVICE_CREDENTIAL:-${BEACON_IDENTITY_CREDENTIAL:-}}
  if [ -n "$service_credential" ]; then
    # The long-lived credential goes in the header and buys a short-lived token;
    # identity shape-checks its prefix before it touches the database.
    REG_BEARER=$(curl -s -X POST "$IDENTITY/service-tokens/exchange" \
      -H "authorization: Bearer $service_credential" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('token') or d.get('accessToken') or '')" 2>/dev/null)
  fi
  unset service_credential
  if [ -z "$REG_BEARER" ]; then
    bad "this drill cannot pass the registration challenge: no service token could be minted. Set BEACON_IDENTITY_CREDENTIAL — 'set -a; . compose/estate/tokens.env; set +a' — and re-run. EVERY check below this line is then about that variable and not about the estate"
  else
    reg=$(curl -s -X POST "$IDENTITY/auth/register" -H 'content-type: application/json' \
      -H "authorization: Bearer $REG_BEARER" \
      -d "{\"email\":\"$EMAIL\",\"handle\":\"slice$$\",\"password\":\"$PASS\"}")
  fi
else
  # Not a failure: `parseTurnstile` refuses a half-configured deployment at boot,
  # so an unchallenged register means an operator set neither variable — which is
  # every developer machine and every micro network.
  ok "register is not challenged here, so this deployment has no Turnstile configured (micro-org#361)"
fi
printf '%s' "$reg" | grep -q '"verificationRequired":true' \
  && ok "register asks for the address to be proved, and mints no session" \
  || bad "register: $(printf '%s' "$reg" | head -c 160)"

# ── PROVING THE ADDRESS WITHOUT A MAILBOX, AND WITHOUT A SHORTCUT ─────────────
#
# `email_verification_tokens` holds a `token_hash` and nothing else — identity
# never keeps the plaintext, correctly — so the token cannot be read back out of
# the table it is checked against. It is read instead from the `verifyUrl` on the
# `identity.email.verification_requested` event identity itself emitted: the same
# string the email would have carried, one hop earlier in the user's own flow.
# `scripts/erasure-drill.sh` has driven it this way for some time; this is that
# pattern, not a new one.
#
# The token is a CREDENTIAL. It goes from psql into curl and is never echoed,
# never written to a file, and never interpolated into a message — including the
# failure below, which reports only whether one was found.
#
# THE DRILL ADDRESS STAYS ON A RESERVED DOMAIN, and that is deliberate rather
# than left over. `@example.test` is reserved by RFC 6761 §6, so micro-notify
# declines to route mail to it at all (micro-org#243) — and because the link
# above is read from the OUTBOX, this drill needs no mailbox and loses nothing by
# that. A deliverable address here would be strictly worse: every run would send
# a real message to a mailbox that does not exist, spend an allowance real
# recipients share, and earn a bounce, on a schedule. Spending the mail allowance
# on synthetic accounts is the exact defect #243 exists to have fixed; a
# verification drill that reintroduced it would be an unusually good joke.
vtok=$(docker compose -f "$COMPOSE" exec -T postgres \
  psql -qtA -U cloudsforge -d identity </dev/null 2>/dev/null \
  -c "select payload->>'verifyUrl' from outbox where topic = 'identity.email.verification_requested' and payload->>'email' = '$EMAIL' order by occurred_at desc limit 1" \
  | tr -d ' \r' | sed 's/.*[#?&]token=//; s/&.*//')
if [ -n "$vtok" ]; then
  ok "registration emitted a verification link"
else
  bad "no verification event carried a link for the drill account"
fi
verified=$(curl -s -X POST "$IDENTITY/auth/email/verify" -H 'content-type: application/json' \
  -d "{\"token\":\"$vtok\"}")
unset vtok
utok=$(printf '%s' "$verified" | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
[ -n "$utok" ] && ok "the address is proved, and verification mints the first session" \
  || bad "verification was refused: $(printf '%s' "$verified" | head -c 160)"

# And the ordinary route works afterwards. `identifier`, not `email` — a handle
# works here too, which is why the field is named for the fact rather than the type.
login_tok=$(curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
  -d "{\"identifier\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
[ -n "$login_tok" ] && ok "a verified account can sign in through /auth/login" \
  || bad "login refused a verified account"
[ -n "$utok" ] || utok="$login_tok"

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

# NO DEFAULT, AND THIS LINE USED TO HAVE ONE. The literal it carried was the same
# string `estate-bootstrap.sh` defaulted to, and on mainnet that made it the
# operator's REAL password — published, in a public repository, against an estate
# whose /v1/auth/login answers from the open internet. Read that file's operator
# block for the measurement. It is rotated; the value now lives only in the host's
# untracked `compose/estate/tokens.env`, under ESTATE_ADMIN_PASSWORD:
#
#     set -a; . compose/estate/tokens.env; set +a
#
# Refusing to run beats guessing. A verification that signs in with a stale password
# reports a red estate, and the red is this line rather than anything it verifies.
ADMIN_PASSWORD=${ADMIN_PASSWORD:-${ESTATE_ADMIN_PASSWORD:-}}
if [ -z "$ADMIN_PASSWORD" ]; then
  echo "ADMIN_PASSWORD (or ESTATE_ADMIN_PASSWORD) is not set, and it has no default." >&2
  echo "Source compose/estate/tokens.env first, then re-run." >&2
  exit 2
fi

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
# (beacon/src/ecosystem.ts). A monitor reading the trial balance is exactly
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
#
# ── EMBER, AND NOT SHARD, SINCE 2026-08-05 ───────────────────────────────────
#
# This probe posted SHARD until ledger migration 13 (`retired_asset_guard`)
# reached the estate. SHARD was retired on 2026-08-04, and that migration
# refuses a retired asset as the CONSIDERATION for an acquisition —
# `deposit_credited` is exactly such a kind — so the posting below started
# answering 400 `retired_asset`, and three checks in this section went red
# describing a ledger that was working correctly.
#
# The guard is deliberately narrower than "no posting may name a retired asset":
# 121 SHARD accounts still hold real liability and withdrawals and transfers of
# it must keep working, so it is only ACQUISITION that is refused. That is why
# the fix is to change the probe's asset rather than to relax the rule.
#
# EMBER is the estate's settled asset and is not retired, so this section is
# once again asserting what it is named for — balance, idempotency and that the
# money lands on the subject — rather than re-discovering the guard.
balanced=$(cat <<JSON
{"kind":"deposit_credited","originatingService":"wallet","actor":"service:wallet",
 "idempotencyKey":"$idem","description":"estate-verify deposit",
 "postings":[
  {"direction":"debit","amount":"1000","assetCode":"EMBER","sequence":0,
   "account":{"subject":"custody","assetCode":"EMBER","purpose":"available","type":"asset"}},
  {"direction":"credit","amount":"1000","assetCode":"EMBER","sequence":1,
   "account":{"subject":"user:$uid","assetCode":"EMBER","purpose":"available","type":"liability"}}]}
JSON
)
post=$(code -X POST "$LEDGER/entries" -H "authorization: Bearer $wtok" \
  -H 'content-type: application/json' -d "$balanced")
[ "$post" = 201 ] && ok "a balanced deposit_credited posted (201)" \
                  || bad "balanced entry rejected with $post: $(head -c 200 /tmp/slice.body)"

# Captured HERE, not later. `code` writes every response to the same
# /tmp/slice.body, and four more calls overwrite it before the unwind below
# needs this id.
deposit_entry_id=$(python3 -c "import json;print(json.load(open('/tmp/slice.body')).get('entry',{}).get('id',''))" 2>/dev/null || true)

# The same request again. Idempotency is what makes a retried deploy-time call
# safe, and ledger answers 200-on-replay rather than posting the money twice.
replay=$(code -X POST "$LEDGER/entries" -H "authorization: Bearer $wtok" \
  -H 'content-type: application/json' -d "$balanced")
[ "$replay" = 200 ] && ok "the same idempotency key replayed (200), it did not double-post" \
                    || bad "expected 200 on replay, got $replay"

# THE REFUSAL. 1000 debited, 1 credited. If this is ever accepted, money has
# been created, and every downstream reconciliation is reporting on a lie.
#
# EMBER here for a sharper reason than above. This check asserts only that the
# entry was REFUSED, so with SHARD it would have gone green whether the ledger
# caught the imbalance or migration 13 caught the retired asset first — a check
# passing for a reason it does not name, which is worse than one that fails.
# EMBER cannot trip the retired guard, so a green line here means the balance
# constraint held, and nothing else.
unbalanced=$(cat <<JSON
{"kind":"adjustment","originatingService":"wallet","actor":"service:wallet",
 "idempotencyKey":"estate-verify-$$-unbalanced","description":"must be refused",
 "postings":[
  {"direction":"debit","amount":"1000","assetCode":"EMBER","sequence":0,
   "account":{"subject":"custody","assetCode":"EMBER","purpose":"available","type":"asset"}},
  {"direction":"credit","amount":"1","assetCode":"EMBER","sequence":1,
   "account":{"subject":"user:$uid","assetCode":"EMBER","purpose":"available","type":"liability"}}]}
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
  && ok "the user's EMBER balance reflects the deposit" \
  || bad "the deposit did not reach the subject's balance: $(printf '%s' "$bal" | head -c 200)"

# ── AND NOW PUT IT BACK ──────────────────────────────────────────────────────
#
# THE DRILL ABOVE FREEZES EMBER IF IT IS LEFT STANDING, and it has done, twice.
#
# 1000 wei of custody was credited to the ledger and no coin arrived on any
# chain to match it. EMBER is reconciled on this estate
# (`LEDGER_RECONCILE_ASSETS=SHARD,EMBER,LTC`) and carries NO tolerance entry,
# and `ledger/src/env.ts` is explicit that "an asset absent from the map gets
# zero tolerance, not infinity". So the drill's 1000 wei is not a rounding
# nuisance — it is drift, the only kind there is, and the next reconciliation
# run freezes EMBER and refuses every withdrawal in the asset estate-wide.
#
# That is not a hypothesis. It happened on 2026-08-05, and the incident record
# names the cause as "synthetic deposit_credited rows posted directly to
# POST /entries by a test harness against the live mainnet estate" — this
# harness, this section, these postings. It was cleared by hand with
# reconciliation_correction entries, and the harness then did it again.
#
# A verification run must not be able to take the estate's payouts down. So the
# drill unwinds itself: every assertion above has already been made against a
# real posting, and reversing it afterwards costs the section nothing it was
# testing. `POST /entries/:id/reverse` is the ledger's own first-class unwind
# (ledger/src/server.ts) rather than a hand-built mirror-image entry — it
# writes `reverses_entry_id`, so the pair is legible afterwards as a drill and
# not as two unrelated movements of money.
if [ -n "${deposit_entry_id:-}" ]; then
  rev=$(code -X POST "$LEDGER/entries/$deposit_entry_id/reverse" \
    -H "authorization: Bearer $wtok" -H 'content-type: application/json' \
    -d "{\"idempotencyKey\":\"$idem-reversal\",\"kind\":\"reversal\",
         \"originatingService\":\"wallet\",\"actor\":\"service:wallet\",
         \"description\":\"estate-verify unwinding its own deposit drill: the 1000 wei above is backed by no chain coin, and EMBER reconciles at zero tolerance\"}")
  case "$rev" in
    201|200) ok "…and the drill unwound itself ($rev) — custody is back where it started, so this run cannot freeze EMBER" ;;
    *) bad "THE DEPOSIT DRILL COULD NOT BE UNWOUND ($rev): 1000 wei of unbacked EMBER custody is now standing, and the next reconciliation will freeze the asset and refuse every withdrawal. Reverse entry $deposit_entry_id by hand: $(head -c 200 /tmp/slice.body)" ;;
  esac
else
  bad "the deposit drill's entry id could not be read, so its 1000 wei cannot be unwound — EMBER will freeze on the next reconciliation unless the entry with idempotency key '$idem' is reversed by hand"
fi

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

echo "── WALLET'S MONEY INTAKE: one scheme accepted, the other refused ────────"
#
# ── WHAT THIS SECTION EXISTS FOR ───────────────────────────────────────────────
#
# `wallet/src/server.ts` served `POST /events` reading `x-cloudsforge-signature`
# and verifying `sha256=<hmac over the body>`. Every producer — indexer,
# settlement, ledger, identity — signs the contract's way, `cf-signature:
# t=<seconds>,v1=<hmac over "seconds.body">`. So wallet refused all four while
# answering /readyz, and their relays retried for ever.
#
# Measured on the running estate BEFORE the fix, not inferred: a correctly
# contract-signed envelope answered 401 and the legacy MAC answered 202. After
# it, that inverts, and the inversion is what the last two checks assert. Both
# directions are driven, because a verifier that accepts everything passes the
# positive check alone.
#
# The legacy scheme is refused rather than kept as a second arm, and that is the
# security property under test: it covers the body ALONE with no timestamp, so a
# captured POST to a route that CREDITS MONEY stays valid for ever. micro-wallet
# deleted its signer as well as its verifier so nothing in the repository can
# mint one.
#
# ── AND THE SEAM ITSELF, WHICH HAD NO WIRING AT ALL ───────────────────────────
#
# Fixing the verifier proved nothing on its own, because NOTHING WAS SUBSCRIBED
# TO WALLET. Queried on the running estate: settlement's `event_subscriptions`
# held five rows, all for admin-api and analytics, and indexer's database had no
# such table. The deposit-crediting seam — the path by which a user's money
# appears — had a producer, a consumer, a signature scheme they now agree on, and
# no row joining them. estate-bootstrap.sh seeds those rows now; this drives one
# through and asserts it landed.
# READ OUT OF THE RUNNING SIGNER, never copied here and no longer read from the
# compose file either. Writing it out would be a second copy of a value that
# already exists, which is the class of artefact this repository keeps finding
# rotted — the gateway route map, the hand-written grant list, the MAP.md files.
# It is also the one shape a verifier must not have: a hardcoded expectation
# still passes after the deploy changes underneath it.
#
# WHY THE CONTAINER AND NOT THE FILE. It used to grep the signing variable
# out of $COMPOSE, which worked only while the key was a literal in a PUBLIC
# file. The key now arrives by `env_file:` from gitignored `compose/secrets/`,
# so the compose file no longer contains it and that grep would return empty —
# and an empty secret makes both signature checks below pass vacuously, which is
# the failure mode the check on the next line exists to catch.
#
# `indexer` is deliberately the container asked: it is the PRODUCER whose relay
# signs the delivery this section drives. Reading the key from the actual signer
# means a rotation that reached the verifier but not the producer — exactly the
# partition a staged rotation exists to prevent — shows up here as a mismatch
# rather than as a green run.
wi_secret=$(docker compose -f "$COMPOSE" exec -T indexer printenv OUTBOX_SIGNING_SECRET 2>/dev/null | tr -d '\r\n')
[ -n "$wi_secret" ] \
  && ok "read the estate outbox secret out of the running indexer container" \
  || bad "indexer holds no OUTBOX_SIGNING_SECRET — the two signature checks below would pass vacuously"
# The defect this file was rotated to close: the key must not be back in the
# public compose file under any name. A regression here is a disclosure, not a
# style problem, so it is asserted every run rather than reviewed.
grep -qE '^ +[A-Z_]*(SIGNING_SECRET|_SECRETS): +[^$]' "$COMPOSE" \
  && bad "a signing secret is a LITERAL in $COMPOSE again — it is a public file; see runbooks/runbook-outbox-signing-secret.md" \
  || ok "no signing secret is a literal in $COMPOSE — the key comes from gitignored compose/secrets/"
wi_event=$(python3 -c 'import uuid;print(uuid.uuid4())')

# Seeded here as well as in the bootstrap, so this section is true against an
# estate bootstrapped before those rows existed. Idempotent, exactly as 5c's are.
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d indexer -c \
  "insert into event_subscriptions (topic, url) values ('indexer.deposit.confirmed', 'http://wallet:4000/events') on conflict do nothing" \
  >/dev/null 2>&1 && ok "subscription seeded: indexer.deposit.confirmed → wallet" \
  || bad "could not seed indexer.deposit.confirmed → wallet; is indexer migrated?"

# Nothing is credited by this, and that is deliberate rather than a shortcut. The
# address belongs to nobody, so `claimCredit` returns `ignored: unknown_address`
# — but `withInbox` has already inserted `(topic, event_id)` by then
# (wallet/src/outbox.ts), so the inbox row is the proof the delivery was
# authenticated, parsed and dispatched. Crediting a real balance to prove a
# signature scheme would put a money movement inside a security check.
wi_before=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d wallet \
  -c "select count(*) from deposit_credits" 2>/dev/null | tr -d '\r ')
docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d indexer >/dev/null 2>&1 <<SQL
insert into outbox (id, topic, key, producer, version, actor, correlation_id, payload)
values ('$wi_event', 'indexer.deposit.confirmed',
        'ethereum:sepolia:0x000000000000000000000000000000000000dead', 'indexer', 1, 'system', '$wi_event',
  '{"chain":"ethereum","network":"sepolia","address":"0x000000000000000000000000000000000000dead",
    "direction":"in","assetCode":"ETH","assetKind":"native","tokenAddress":null,"amount":"1",
    "txHash":"0x$wi_event","logIndex":null,"blockHeight":1,"confirmations":64}'::jsonb);
SQL

# INDEXER'S OWN RELAY does the delivery: it builds the envelope, signs it with the
# contract's signDelivery and POSTs it. Nothing here signs anything — that is what
# makes this a producer-to-consumer test rather than a test of curl.
wi_landed=""
for _ in $(seq 1 30); do
  wi_landed=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d wallet \
    -c "select event_id from inbox where topic = 'indexer.deposit.confirmed' and event_id = '$wi_event'" \
    2>/dev/null | tr -d '\r ')
  [ -n "$wi_landed" ] && break
  sleep 1
done
if [ -n "$wi_landed" ]; then
  ok "indexer's relay signed it, wallet verified it, and it is in wallet's inbox — THE MONEY BUS CARRIES"
else
  wi_why=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d indexer \
    -c "select attempts || ' attempt(s): ' || coalesce(last_error, 'none') from outbox_deliveries where event_id = '$wi_event'" 2>/dev/null | tr -d '\r')
  bad "no contract-signed delivery reached wallet's inbox within 30s — ${wi_why:-no delivery row at all}"
fi

wi_after=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d wallet \
  -c "select count(*) from deposit_credits" 2>/dev/null | tr -d '\r ')
[ "$wi_before" = "$wi_after" ] \
  && ok "and it credited nothing ($wi_after credit rows, unchanged) — an unowned address is ignored, not paid" \
  || bad "the probe deposit CREDITED SOMETHING: deposit_credits went $wi_before → $wi_after"

# ── THE TWO SCHEMES, OVER THE SAME BYTES ──────────────────────────────────────
#
# One body, written once and posted twice with `--data-binary` so the bytes signed
# are the bytes sent. Verification happens before the parse, so a re-serialised
# body would be a different test.
wi_probe=$(python3 -c 'import uuid;print(uuid.uuid4())')
printf '{"id":"%s","topic":"probe.wallet.intake","payload":{}}' "$wi_probe" >/tmp/wallet-intake.json
wi_contract_sig=$(python3 - "$wi_secret" /tmp/wallet-intake.json <<'PY'
import hashlib, hmac, sys, time
secret, path = sys.argv[1], sys.argv[2]
body = open(path, 'rb').read()
t = int(time.time())
print('t=%d,v1=%s' % (t, hmac.new(secret.encode(), b'%d.' % t + body, hashlib.sha256).hexdigest()))
PY
)
wi_legacy_sig=$(python3 - "$wi_secret" /tmp/wallet-intake.json <<'PY'
import hashlib, hmac, sys
secret, path = sys.argv[1], sys.argv[2]
print('sha256=' + hmac.new(secret.encode(), open(path, 'rb').read(), hashlib.sha256).hexdigest())
PY
)
# `probe.wallet.intake` is a topic wallet does not subscribe to, so a 2xx here is
# the AUTHENTICATION verdict and nothing else — 202 `topic_not_subscribed`. That
# keeps a signature test off every crediting path.
wi_c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WALLET/events" \
  -H 'content-type: application/json' -H "cf-signature: $wi_contract_sig" -H "cf-event-id: $wi_probe" \
  --data-binary @/tmp/wallet-intake.json)
wi_l=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WALLET/events" \
  -H 'content-type: application/json' -H "x-cloudsforge-signature: $wi_legacy_sig" -H "x-event-id: $wi_probe" \
  --data-binary @/tmp/wallet-intake.json)
case "$wi_c" in
  2*) ok "a contract-signed delivery is accepted ($wi_c) — it was 401 before the fix" ;;
  *)  bad "wallet refused a correctly contract-signed delivery ($wi_c) — no producer can reach it" ;;
esac
[ "$wi_l" = 401 ] \
  && ok "the legacy body-only MAC is refused (401) — it was 200 before the fix, and it is a permanent replay credential" \
  || bad "WALLET STILL ACCEPTS THE LEGACY MAC ($wi_l) — a captured POST to a crediting route is valid for ever"

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
# (identity/src/tokens.ts). Consuming services read theirs from an environment
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
# which is 5s by default (runtime/packages/auth/src/index.ts). 3 + 5 = 8, so
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
# a feed record (activity/src/classify.ts) and analytics counts it as "the
# denominator of every onboarding cohort" (analytics/src/catalogue.ts) — and
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
#
# ── THE DERIVATION CANNOT BE PERFORMED ON THE HOST THIS SCRIPT MOSTLY RUNS ON ─
#
# This was one line — run it, green or FAIL — and on the estate host it has
# NEVER ONCE PERFORMED A DERIVATION. Every mainnet run since it was added
# printed
#
#     FAIL the compose grants disagree with the services: ./scripts/estate-verify.sh: line 1001: node: command not found
#
# which names a disagreement between compose and the services when not one
# service was read. Two reasons, and the second is the one that matters
# (micro-org#259):
#
#   1. There is no `node` binary on the host. That much a container would fix.
#   2. THE HOST IS NOT A FULL CHECKOUT. `derive-grants.mjs` reads every
#      service's own `src/` from the estate root — `ESTATE = join(HERE, '..',
#      '..')`, derive-grants.mjs:96 — and the host carries `deploy`, `org`,
#      `contracts`, `ui`, the asset repositories and the browser surfaces, and
#      NOT ONE of the backend services whose declarations the derivation is made
#      of. Given node it would derive a grant map from 17 repositories, compare
#      it against a block built from 46, and fail. That failure is a fact about
#      the checkout, dressed as a fact about the estate.
#
# This repository has now paid for that shape three times — a custody drill that
# measured a set it had failed to empty, a bootstrap that printed "subscribed to
# 0 topic(s)" in green (both micro-deploy#6), and this. A check that reports on
# its own environment while claiming to report on the estate.
#
# So the preconditions are asked FIRST, and where they do not hold this says
# plainly that no derivation was performed here. A skip, with the reason: never
# a pass, and never a red line about services nothing read.
#
# ── WHAT IS ASKED, AND WHY IT IS NOT A LIST OF SERVICE NAMES ─────────────────
#
# `grant-gaps.json` is the file that already names, as deploy configuration,
# which repositories the derivation must be able to read — one entry per module
# micro-deploy supplies a grant for, each naming its service. Counting how many
# of those services have a `src/` here answers "is this the estate or a slice of
# it" out of a file this repository owns and keeps current, rather than out of a
# fourteenth hand-maintained copy of the service list. On the estate host that
# count is zero of eight; in a developer's checkout it is eight of eight.
#
# It is a PRECONDITION and not the verdict on partiality. `derive-grants.mjs`
# holds that verdict itself — `MIN_SERVICES`, derive-grants.mjs:592, "this is a
# partial estate, and a partial derivation silently removes authority from every
# service it missed" — and exits 2 for it, as it does for every other "this
# checkout cannot answer" (no scope registry at :112, an unparseable registry at
# :222, no grants block in compose at :653). Exit 1 is reserved for the estate
# actually disagreeing. So the exit status is now read BY VALUE rather than as
# pass/fail: 2 is this section's second skip, 1 is its only FAIL. That also
# means the gaps ratchet emptying — which it is designed to do, one entry at a
# time, as repositories declare for themselves — cannot silently switch the
# precondition off: the tool still refuses the checkout in its own words.
deploy_root=$(cd "$(dirname "$0")/.." && pwd)
estate_root=$(cd "$deploy_root/.." && pwd)
derive_skip=""
if ! command -v node >/dev/null 2>&1; then
  derive_skip="there is no node on this host, and the derivation is a node script"
elif [ ! -f "$estate_root/contracts/packages/auth/src/index.ts" ]; then
  derive_skip="micro-contracts is not checked out at $estate_root, so the scope registry every derived scope is validated against cannot be read here (derive-grants.mjs:112)"
else
  gap_want=0
  gap_have=0
  for gap_svc in $(sed -n 's/.*"service": *"\([a-z0-9-]*\)".*/\1/p' "$deploy_root/compose/estate/grant-gaps.json" | sort -u); do
    gap_want=$((gap_want + 1))
    [ -d "$estate_root/$gap_svc/src" ] && gap_have=$((gap_have + 1))
  done
  [ "$gap_have" -eq "$gap_want" ] || derive_skip="this is a slice of the estate and not the estate: $gap_have of the $gap_want service(s) named in compose/estate/grant-gaps.json have a src/ at $estate_root"
fi

if [ -z "$derive_skip" ]; then
  (cd "$deploy_root" && node scripts/derive-grants.mjs --check) >/tmp/derive-grants.out 2>&1
  derive_rc=$?
  case "$derive_rc" in
    0) ok "$(tail -1 /tmp/derive-grants.out)" ;;
    2) derive_skip="derive-grants refused this checkout rather than judging the estate from it — $(head -c 300 /tmp/derive-grants.out)" ;;
    1) bad "the compose grants disagree with the services: $(head -c 400 /tmp/derive-grants.out)" ;;
    # Not folded into the line above. `node` itself exits 1 for a module it
    # cannot load, and reporting that as "the services disagree" is the whole
    # defect this section was rewritten for, one layer down.
    *) bad "derive-grants exited $derive_rc, which is neither its agreement (0), its refusal of a checkout (2) nor a disagreement (1) — read it as a broken invocation, not as a verdict: $(head -c 400 /tmp/derive-grants.out)" ;;
  esac
fi

# ── THE SKIP STILL HAS TO ASSERT SOMETHING ───────────────────────────────────
#
# A skip that also stops checking the gate is how a check becomes a switched-off
# check: the derivation moves to CI, the CI step is deleted six weeks later in
# somebody's unrelated cleanup, and this file goes on printing a tidy `..` about
# a question nothing anywhere is asking. So where no derivation happened here,
# this asserts that the job which DOES perform it still carries the step —
# `estate-invariants` in micro-org's estate-ci.yml, the one checkout in the
# estate that clones all forty-six services onto one disk, refuses on
# `MIN_REPOS` and treats a failed clone as fatal (micro-org#260).
#
# Asserted by the STEP NAME as well as by the script's name, because
# `derive-grants.mjs` appears in that workflow's prose too, and a grep that a
# comment can satisfy is a grep that survives the deletion of the step it was
# watching. A rename goes red here and is answered by reading the workflow —
# which is the correct outcome for the one line tying these two repositories
# together.
if [ -n "$derive_skip" ]; then
  echo "  ..   NO DERIVATION WAS PERFORMED HERE: $derive_skip."
  echo "       This is not a pass. Nothing here read a single service's declarations."
  derive_wf="$estate_root/org/.github/workflows/estate-ci.yml"
  if [ ! -f "$derive_wf" ]; then
    bad "no derivation here AND no micro-org checkout at $estate_root/org to show the gate that does perform it still exists — this run has said nothing whatsoever about the grant map. The estate host does carry 'org' (micro-org#259); clone it beside deploy"
  elif ! grep -Fq 'derive-grants.mjs' "$derive_wf"; then
    bad "estate-ci.yml does not name derive-grants.mjs — the derivation is performed NOWHERE, and this section's skip is a silence. The step is micro-org#260; if that has not merged into the checkout being read here, this red is that PR and not the estate"
  elif ! grep -Fq 'The compose grant map still matches what the services declare' "$derive_wf"; then
    bad "estate-ci.yml names derive-grants.mjs but carries no step called 'The compose grant map still matches what the services declare' — the gate this skip defers to has been deleted or renamed (micro-org#260)"
  else
    ok "…and the estate-ci step that does perform it is still there — the gate this skip defers to has not been deleted"
  fi
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
wtok2=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"worlds","scopes":["aetherholm:provision"]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -n "$wtok2" ] && ok "identity mints aetherholm:provision for worlds" \
  || bad "worlds cannot be minted aetherholm:provision"
[ "$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' \
     -d '{"service":"nda","scopes":["aetherholm:provision"]}')" = 403 ] \
  && ok "nda is refused aetherholm:provision — the registry says worlds alone holds it" \
  || bad "a service other than worlds was minted aetherholm:provision"

# ── AND THE SCOPE IS NOW SPENT, NOT ONLY MINTED ──────────────────────────────
#
# This section used to say "the aetherholm SERVICE is not deployed in this estate
# — only its frontend — so the call it authorises cannot be driven here". That
# stopped being true and the comment outlived it: measured on the app host on
# 2026-08-10, `cloudsforge-estate-aetherholm-1` is running, healthy, and publishes
# 4124 like every other service in the registry.
#
# A mint that is never spent proves identity's allowlist and NOTHING about whether
# the door it unlocks opens. Those are two different failures, and this estate has
# already shipped the second one: two title clients POSTed `/internal/achievements`
# for months while worlds served no such route, and every credential involved was
# minted perfectly the whole time.
#
# THE SKU IS DELIBERATELY ONE THAT DOES NOT EXIST, AND THAT IS WHAT MAKES THIS
# SAFE TO RUN ON MAINNET. `provisioning.ts` tests `PROVISIONABLE_SKUS` FIRST —
# before it looks for a replay, before it opens a transaction, before the outbox —
# so an unrecognised SKU is refused without writing a row. The real route is driven
# with the real credential and no world is raised.
#
# 422 IS THE ASSERTION, and each of the other answers is a distinct defect this
# would otherwise miss: 401/403 means the minted scope did not open the door,
# 404 means the route is not served at all, 400 means the contract's own parser
# rejected a body built from its own field list, and 201 would mean aetherholm
# provisioned something it does not sell. Only 422 means it read the request as
# authorised and declined the catalogue entry — the answer `worlds/src/titleclient.ts`
# treats as terminal.
prov_body='{"entitlementId":"estate-verify-unsupported-sku","subject":"estate-verify","userId":"'"$uid"'","sku":"cf.aetherholm.no-such-sku","scope":"skerry","metadata":{}}'
prov=$(code -X POST "$AETHERHOLM/v1/provision" -H "authorization: Bearer $wtok2" \
  -H 'content-type: application/json' -d "$prov_body")
[ "$prov" = 422 ] \
  && ok "worlds' aetherholm:provision token is ACCEPTED by aetherholm and an unknown SKU is refused 422 — the scope is spent, not just minted" \
  || bad "aetherholm answered $prov to an authorised provision of an unsupported SKU, expected 422 (401/403 = the scope does not open the door, 404 = the route is not served, 201 = it provisioned something it does not sell)"

# THE SAME BODY, THE SAME ROUTE, AN ADMIN'S USER TOKEN. `server.ts` refuses any
# principal whose kind is not `service` BEFORE it checks scopes, in its own words:
# "a user token here is someone trying to raise a world without buying one". The
# operator's own token is the strongest form of that test — if administrator rights
# were enough to provision a world, every paid entitlement in the catalogue would be
# optional for anyone who could reach this route.
[ "$(code -X POST "$AETHERHOLM/v1/provision" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' -d "$prov_body")" = 403 ] \
  && ok "a user token is refused at /v1/provision even when it is the administrator's — provisioning is a service act" \
  || bad "aetherholm accepted a USER token at /v1/provision; a paid entitlement is not required to raise a world"

echo
echo "── STUDIO ACTUALLY WRITES: the check this file did not have ─────────────"
#
# ── WHY THIS SECTION EXISTS ───────────────────────────────────────────────────
#
# For the whole life of this environment, studio's entry above was `/livez` and
# `/readyz` and nothing else — and both were GREEN while every generation of
# every kind failed. `STUDIO_ASSET_ROOT` was unset in the compose file, so
# `studio/src/env.ts` fell back to `./out` → `/app/out`, which is root-owned
# in an image that runs `USER node`. The result:
#
#     EACCES: permission denied, mkdir '/app/out'
#
# on every firing, with a healthy container and a 200 on /readyz. Two probes
# passed, 178 assertions passed, and the service could not do the one thing it
# is for. That is this estate's signature failure — up and wrong, with the
# check that exists unable to see the thing that is broken — and the reason it
# survived is precisely that NOTHING HERE EXERCISED THE PATH THE VARIABLE
# CONTROLS. A value in a compose file proves nothing; the call it authorises
# proves everything.
#
# So this drives a real generation and then asserts the BYTES, which is the part
# a status field cannot fake. `placeholder` deliberately: it is deterministic,
# reserves no credit and reaches no model, so this costs nothing and cannot be
# the reason a spend cap is hit — but it takes the identical write path that a
# FLUX result takes, which is the path that was broken.
skit=$(curl -s -X POST "$STUDIO/v1/brand-kits" -H "authorization: Bearer $utok" \
  -H 'content-type: application/json' \
  -d '{"name":"estate-verify probe","accent":"#ff4d00"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['brandKit']['id'])" 2>/dev/null)
if [ -z "$skit" ]; then
  bad "studio would not create a brand kit — the generation below cannot be attempted"
else
  ok "studio created a brand kit"
  sjob=$(curl -s -X POST "$STUDIO/v1/brand-kits/$skit/generate" -H "authorization: Bearer $utok" \
    -H 'content-type: application/json' -d '{"kind":"mark","backend":"placeholder"}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['job']['id'])" 2>/dev/null)
  if [ -z "$sjob" ]; then
    bad "studio refused the generation request outright"
  else
    ok "studio accepted the generation (202, a leased job — it does not generate in the request)"
    sstatus=""; sdetail=""; ssum=""
    # Generous but bounded. A placeholder is a deterministic SVG and lands in
    # well under a second; the ceiling is here so a wedged runner fails the
    # check rather than hanging the suite.
    i=0
    while [ "$i" -lt 20 ]; do
      sbody=$(curl -s -m 10 "$STUDIO/v1/jobs/$sjob" -H "authorization: Bearer $utok")
      sstatus=$(printf '%s' "$sbody" | python3 -c "import sys,json;print(json.load(sys.stdin)['job']['status'])" 2>/dev/null)
      [ "$sstatus" = "queued" ] || [ "$sstatus" = "running" ] || break
      i=$((i+1)); sleep 1
    done
    sdetail=$(printf '%s' "$sbody" | python3 -c "import sys,json;print(json.load(sys.stdin)['job']['errorDetail'] or '')" 2>/dev/null)
    ssum=$(printf '%s' "$sbody" | python3 -c "import sys,json;print(json.load(sys.stdin)['provenance']['checksum'] or '')" 2>/dev/null)
    if [ "$sstatus" = "succeeded" ]; then
      ok "a generation SUCCEEDED in the estate — studio can write its asset root"
    else
      # Named in full, because "EACCES ... mkdir '/app/out'" is the entire
      # diagnosis and a status word alone sends the next reader to the database.
      bad "studio generation ended '$sstatus': ${sdetail:-no detail} — studio cannot write STUDIO_ASSET_ROOT"
    fi
    # The bytes, not the row. A `succeeded` with no file is exactly the kind of
    # green this section was written to distrust, and the checksum is content
    # addressing's own claim: recomputing it off the stored file is a check the
    # service cannot pass by writing a status.
    if [ -n "$ssum" ]; then
      shex=${ssum#sha256:}
      # `sh -c` inside the container: the asset root is a named volume and is
      # not visible from the host at all, which is the point of it.
      sfound=$(docker compose -f "$COMPOSE" exec -T studio sh -c \
        'find "$STUDIO_ASSET_ROOT" -type f -name "'"$shex"'.*" 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')
      if [ -n "$sfound" ]; then
        ok "the generated bytes are on disk at the checksum's own path ($(printf '%.8s' "$shex")…)"
        sreal=$(docker compose -f "$COMPOSE" exec -T studio node -e \
          'const c=require("crypto"),f=require("fs");console.log("sha256:"+c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' \
          "$sfound" 2>/dev/null | tr -d '\r')
        [ "$sreal" = "$ssum" ] \
          && ok "the stored file re-hashes to the checksum studio recorded — content addressing holds" \
          || bad "the stored file hashes to '$sreal', studio recorded '$ssum'"
      else
        bad "studio reported checksum $ssum but no file exists under STUDIO_ASSET_ROOT — a green with no bytes"
      fi
    else
      bad "studio recorded no checksum, so there is nothing to look for on disk"
    fi
  fi
fi

echo
echo "── TESSERA: the world, driven — provision, claim, and the two refusals ──"
#
# ── WHY THIS IS A FLOW AND NOT A HEALTH CHECK ─────────────────────────────────
#
# tessera answers /readyz above with everything else, and that proves it can open its database.
# It proves nothing about the four things this title is actually FOR, so each is driven and each
# is paired with the negative that makes it mean something:
#
#   1. `GET /v1/title` — the descriptor worlds reads before it holds any credential. Public by
#      contract. If `private_world` is missing from it, worlds' provisioning bridge never calls
#      this title at all (worlds/src/provisioning.ts) and a purchase is taken for a ward
#      nobody raises.
#   2. `POST /v1/provision` under worlds' `tessera:provision` — **the first code path the
#      `world.private.small` SKU has ever had.** It has existed in billing since
#      billing/src/migrations.ts and no title in this estate has ever served it. 201 on the
#      first ask, 200 AND THE SAME URN on the replay, because the idempotency is a PRIMARY KEY on
#      `provisions.entitlement_id` rather than a check-then-insert.
#   3. A Homestead claimed by a real signed-in user — 201 with `objectCap` 160 (§6.2's table) —
#      and a SECOND Homestead refused. The second refusal is the sharp one: it is a partial unique
#      index, `tessera_one_homestead`, so it holds against a caller with a database connection and
#      not merely against this route.
#   4. The scope, broken on purpose: a valid, correctly-signed service token that does NOT carry
#      `tessera:write` must be refused by the same route that just accepted a claim.
#
# Every request below is a real socket to a real container. The wards this reads did not exist
# before step 2 created one, which is why the order is not rearrangeable.
#
# NOTE ON WHAT IS NOT PROVED HERE: the Kiln. It is configured in this environment (STUDIO_URL and
# a token are both set) and it cannot work, because `tessera/src/studioclient.ts` posts to
# `POST /v1/generations` and micro-studio serves no such route — its generation route is
# `POST /v1/brand-kits/:id/generate` (studio/src/server.ts) and its status body is nested
# under `job`, not flat. Driving a firing here would assert a 202 this file could not distinguish
# from a working Kiln. It is recorded as a defect for micro-tessera and micro-studio to agree a
# contract on, rather than dressed up as a passing check.

# The descriptor, unauthenticated — which is itself the assertion. worlds reads this before it
# holds a credential for the title, so a service that gated it would be unreachable by the bridge.
tt=$(code "$TESSERA/v1/title")
if [ "$tt" = 200 ]; then
  tcap=$(python3 -c "
import json
b = json.load(open('/tmp/slice.body'))
print('yes' if b.get('slug') == 'tessera' and 'private_world' in (b.get('capabilities') or []) else 'no')" 2>/dev/null)
  [ "$tcap" = yes ] \
    && ok "tessera serves its title descriptor unauthenticated, declaring private_world — the capability worlds' bridge gates on" \
    || bad "tessera's descriptor is missing slug 'tessera' or the private_world capability; worlds would never call it"
else
  bad "GET /v1/title answered $tt — worlds cannot read this title's capabilities"
fi

# The read gate. No token at all must be 401 rather than an empty list: a 200 with `[]` is a world
# that looks empty rather than a world that refused, and a consumer files those differently.
# THE EXPECTATION HERE WAS INVERTED ON 2026-08-04, AND THE OLD ONE WAS THE DEFECT.
#
# This asserted 401 — "refuses an anonymous caller, rather than answering an empty world" — and
# micro-tessera decided the opposite, from its own design rather than to make a check pass:
# `dfa81f9 fix(wards): the Mosaic is public, so stop asking a stranger for a token to see the map`.
#
# The reasoning is in doc 23 §5 and worth keeping: the loop opens with "no account wall";
# micro-worlds already serves its title registry publicly because "a launcher listing games cannot
# require a token"; and a free self-serve account could already read the ward list, so the gate was
# a SIGNUP wall, not a security boundary. Opening it moved the 401 one request deeper onto
# `/v1/wards/:id/parcels`, which was opened too, for the same reason.
#
# PRESENCE STAYS 401 — that is live data about who is in a world right now, and it is checked
# below. So this is not "tessera opened up", it is a line drawn between the map and the people.
tw_anon=$(code "$TESSERA/v1/wards")
[ "$tw_anon" = 200 ] && ok "GET /v1/wards answers an anonymous caller (200) — the Mosaic is public by design" \
  || bad "tessera answered $tw_anon to an unauthenticated /v1/wards, expected 200 (see doc 23 §5)"

# ── PROVISIONING, UNDER THE GRANT THE DERIVATION JUST ADDED ───────────────────
#
# `worlds` gained `tessera:provision` from grant-gaps.json, and unlike its `aetherholm:provision`
# sibling — which cannot be driven, because that service has no container here — this one reaches
# a real route on a real container. That difference is the whole reason this section exists.
wtok3=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"worlds","scopes":["tessera:provision"]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -n "$wtok3" ] && ok "identity minted tessera:provision for worlds" \
  || bad "identity would not mint tessera:provision for worlds — the grant is missing"

# ── THE ENTITLEMENT ID, AND WHY THE ENTROPY IS AT THE FRONT ───────────────────
#
# A fresh id per run, so a re-run provisions a new ward rather than replaying the previous run's
# and reporting 200 where 201 was the thing under test.
#
# THE ORDER OF THE CHARACTERS IS LOAD-BEARING, and finding out why is what the second run of this
# section bought. `wardSlugFrom` (tessera/src/titlecontract.ts) strips non-alphanumerics
# and takes THE FIRST TWELVE CHARACTERS: `estate-verify-4321` and `estate-verify-8765` both become
# `private-estateverify`, and the second one violates `wards_slug_key`. So the timestamp and pid go
# first, where twelve characters can still tell two runs apart.
ENT="$(date +%s)$$-estate-verify"
tward=""
if [ -n "$wtok3" ]; then
  prov=$(code -X POST "$TESSERA/v1/provision" -H "authorization: Bearer $wtok3" \
    -H 'content-type: application/json' -H "Idempotency-Key: $ENT" \
    -d "{\"entitlementId\":\"$ENT\",\"subject\":\"user:$uid\",\"userId\":\"$uid\",\"sku\":\"world.private.small\",\"scope\":\"title\",\"metadata\":{}}")
  purn=$(python3 -c "import json;print(json.load(open('/tmp/slice.body')).get('urn',''))" 2>/dev/null)
  [ "$prov" = 201 ] && [ -n "$purn" ] \
    && ok "world.private.small PROVISIONED (201, $purn) — a SKU that has existed since billing/src/migrations.ts:405 and had never been served by any title" \
    || bad "provision returned $prov (422 means the sku is unserved; 403 means the grant is wrong; 404 means the route is)"

  # THE REPLAY. Same entitlement id, and the contract requires the SAME urn with replayed: true —
  # not merely a second success. A second ward under a second urn would be a purchase provisioned
  # twice, which is what the primary key on `provisions.entitlement_id` exists to prevent.
  replay2=$(code -X POST "$TESSERA/v1/provision" -H "authorization: Bearer $wtok3" \
    -H 'content-type: application/json' -H "Idempotency-Key: $ENT" \
    -d "{\"entitlementId\":\"$ENT\",\"subject\":\"user:$uid\",\"userId\":\"$uid\",\"sku\":\"world.private.small\",\"scope\":\"title\",\"metadata\":{}}")
  rurn=$(python3 -c "import json;b=json.load(open('/tmp/slice.body'));print(b.get('urn','') if b.get('replayed') is True else '')" 2>/dev/null)
  if [ "$replay2" = 200 ] && [ -n "$rurn" ] && [ "$rurn" = "$purn" ]; then
    ok "replaying the entitlement is 200 with the SAME urn and replayed:true — one purchase, one ward"
  else
    bad "the replayed provision returned $replay2 with urn '$rurn' (expected 200 and '$purn') — a redelivered entitlement would raise a second ward"
  fi

  # ── A SECOND, DIFFERENT ENTITLEMENT THAT SHARES A SLUG PREFIX ───────────────
  #
  # Found by running this section twice, which is the only way it surfaces. `wardSlugFrom`
  # (tessera/src/titlecontract.ts) builds `private-<first 12 alphanumerics of the
  # entitlement id>`, and the doc comment directly above it says the entitlement id is used
  # "because [it] is already unique" — but the truncation throws that uniqueness away. Two
  # DIFFERENT paid entitlements whose ids agree for twelve characters collide on `wards_slug_key`,
  # and the violation is not caught: it leaves the handler as a raw PostgresError and is logged
  # `unhandled request failure` — a **500** on somebody's paid provision, which is precisely the
  # outcome that comment exists to rule out.
  #
  # WHAT IS ASSERTED IS NARROW ON PURPOSE. 201 (a distinct ward) and 409 (a refusal on the merits)
  # are both defensible answers and both pass. **500 is not**, because an unhandled unique
  # violation tells the buyer nothing, tells worlds' bridge to retry for ever, and is
  # indistinguishable from the service being broken. This is a defect in micro-tessera, named here
  # rather than smoothed over, and this check goes green the day it is fixed either way.
  #
  # A UUID entitlement id does not escape it: UUIDv7's first twelve hex characters are its
  # 48-bit millisecond timestamp, so two provisions in one millisecond collide too.
  ENT2="${ENT}-second"
  prov2=$(code -X POST "$TESSERA/v1/provision" -H "authorization: Bearer $wtok3" \
    -H 'content-type: application/json' -H "Idempotency-Key: $ENT2" \
    -d "{\"entitlementId\":\"$ENT2\",\"subject\":\"user:$uid\",\"userId\":\"$uid\",\"sku\":\"world.private.small\",\"scope\":\"title\",\"metadata\":{}}")
  case "$prov2" in
    201|409)
      ok "a second entitlement sharing the first twelve characters is answered $prov2, not 500 — the slug truncation is handled"
      ;;
    500)
      bad "a second paid entitlement whose id shares 12 characters with the first returned 500 — wardSlugFrom (tessera/src/titlecontract.ts:192-195) truncates the entitlement id to 12 alphanumerics, wards_slug_key raises, and the PostgresError leaves the handler unhandled. A buyer gets a 500 and worlds' bridge retries for ever"
      ;;
    *)
      bad "a second entitlement sharing a slug prefix returned $prov2; expected 201 (a distinct ward) or 409 (a refusal on the merits)"
      ;;
  esac
fi

# ── THE NEGATIVE ON PROVISIONING ──────────────────────────────────────────────
#
# `community` is used for the same reason it is used against worlds' achievement route above: its
# derived grant is ledger/policy/indexer only, so identity mints it a real, valid, correctly-signed
# token that simply lacks this authority — which is the case that must 403 rather than 401.
if [ -n "${ctok:-}" ]; then
  prefused=$(code -X POST "$TESSERA/v1/provision" -H "authorization: Bearer $ctok" \
    -H 'content-type: application/json' \
    -d "{\"entitlementId\":\"nope-$$\",\"subject\":\"user:$uid\",\"userId\":\"$uid\",\"sku\":\"world.private.small\",\"scope\":\"title\",\"metadata\":{}}")
  [ "$prefused" = 403 ] \
    && ok "a valid token without tessera:provision is refused (403) — the scope is doing the work, not the route's existence" \
    || bad "tessera answered $prefused to a provision from a credential with no tessera:provision, expected 403"
fi

# And identity must refuse to MINT it outside worlds' grant. The registry says worlds alone holds
# it; this is that sentence, executed.
[ "$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' \
     -d '{"service":"community","scopes":["tessera:provision"]}')" = 403 ] \
  && ok "identity refuses to mint tessera:provision for community — the allowlist is enforced at the mint, not only at the gate" \
  || bad "identity minted tessera:provision for a service whose grant does not carry it"

# `tessera:write` is tessera's own INBOUND vocabulary: no service in this estate is granted it,
# because a title acts for a player and players present their own tokens. Asserted rather than
# assumed, because a grant that quietly appeared would be a credential able to claim land as
# anybody.
[ "$(code -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
     -H 'content-type: application/json' \
     -d '{"service":"community","scopes":["tessera:write"]}')" = 403 ] \
  && ok "no service in the estate can be minted tessera:write — the world is written by players, not by peers" \
  || bad "identity minted tessera:write for community; some service can now claim land as any user"

# ── THE CLAIM: a real signed-in person, and the refusal that is a database index ──
#
# `utok` is the drill user registered at the top of this file — a plain user token with no scopes
# at all, which is exactly what a player has. `requireUser` (tessera/src/server.ts) checks
# a scope ONLY for a service principal; a user is their own authority.
# ── THE WARD IS THE ONE THIS RUN RAISED, NOT WHATEVER /v1/wards LISTS FIRST ───
#
# This read `wards[0].id` for one run and it was wrong in a way that only a SECOND run exposed:
# the world is persistent, so run two claimed tile (0,0) in run one's ward, got a 409 for
# overlapping an existing parcel, and then got a 201 for the tile that was supposed to be the
# refusal — the two assertions passed each other's answers and both reported the opposite of the
# truth. A verification that is not hermetic against its own history is a verification that gets
# more wrong the longer the environment lives.
#
# So the ward id comes out of the URN this run's provision returned: `cf:tessera:ward:<uuid>`.
# `GET /v1/wards` is still driven — under the user's token, which is the read gate proving a
# player can see the world — but the id below is the one that was just minted.
tward=$(printf '%s' "$purn" | sed 's/.*://')
twards=$(curl -s -o /tmp/slice.body -w '%{http_code}' "$TESSERA/v1/wards" -H "authorization: Bearer $utok")
[ "$twards" = 200 ] && ok "a signed-in player can read the world (GET /v1/wards 200 under a plain user token, no scope)" \
  || bad "GET /v1/wards answered $twards to a signed-in player, expected 200"
# Captured BEFORE it is read into a body. `set -u` is what turns a missed capture here into a
# failure rather than a POST claiming a parcel in ward "".
[ -n "$tward" ] && ok "the ward this run raised is the one it will build in: $tward" \
  || bad "no ward id could be read out of the provision urn — nothing below can be claimed"

if [ -n "$tward" ]; then
  claim=$(code -X POST "$TESSERA/v1/parcels" -H "authorization: Bearer $utok" \
    -H 'content-type: application/json' \
    -d "{\"wardId\":\"$tward\",\"tier\":\"homestead\",\"originX\":0,\"originY\":0}")
  # objectCap is asserted, not just the status. §6.2 fixes a Homestead at 160 objects and states
  # it as a RENDERING budget that is not purchasable at any price — so the number appearing on the
  # row is the design's fifth refusal made checkable per parcel rather than promised in a document.
  ccap=$(python3 -c "import json;print(json.load(open('/tmp/slice.body')).get('parcel',{}).get('objectCap',''))" 2>/dev/null)
  if [ "$claim" = 201 ] && [ "$ccap" = 160 ]; then
    ok "a Homestead was CLAIMED (201) with objectCap 160 — free ground, and §6.2's budget on the row"
  else
    bad "the claim returned $claim with objectCap '$ccap' (expected 201 and 160)"
  fi

  # ── THE SECOND HOMESTEAD, WHICH THE DATABASE REFUSES ────────────────────────
  #
  # Different origin, so nothing about the tile overlap can be the reason it fails: the only thing
  # wrong with this request is that this account already has a Homestead. §4 — "a partial unique
  # index makes a second one unrepresentable". Unrepresentable, not merely refused: the index is
  # `tessera_one_homestead on parcels (owner_subject) where tier = 'homestead' and status =
  # 'held'`, so it holds against a caller holding a psql prompt and not only against this handler.
  #
  # This is the check that would have caught the class of defect found in this estate twice
  # tonight — a guard that grades an `if` in a handler rather than asking the index.
  second=$(code -X POST "$TESSERA/v1/parcels" -H "authorization: Bearer $utok" \
    -H 'content-type: application/json' \
    -d "{\"wardId\":\"$tward\",\"tier\":\"homestead\",\"originX\":64,\"originY\":64}")
  [ "$second" = 409 ] \
    && ok "a SECOND Homestead is refused (409) — one per account, held by an index rather than by a rule" \
    || bad "the second Homestead returned $second, expected 409; the one-per-account floor is not being enforced"

  # And the index itself, asked directly rather than inferred from the 409 above. A handler that
  # returned 409 from its own `if` would pass that check with the index dropped.
  hidx=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d tessera \
    -c "select count(*) from pg_indexes where tablename='parcels' and indexname='tessera_one_homestead'" 2>/dev/null | tr -d '[:space:]')
  [ "${hidx:-0}" = 1 ] \
    && ok "tessera_one_homestead exists in the schema — the 409 above is the database's answer, not the handler's" \
    || bad "no tessera_one_homestead index in tessera's schema; the 409 above is a handler's opinion and a psql prompt would beat it"

  # ── THE SCOPE, BROKEN ON PURPOSE ────────────────────────────────────────────
  #
  # The same route that just accepted a claim must refuse a valid service token that does not carry
  # `tessera:write`. Without this, everything above would also pass if tessera had stopped checking
  # scopes altogether — which is the exact condition a security scan in this estate was in for its
  # entire life.
  if [ -n "${ctok:-}" ]; then
    crefused=$(code -X POST "$TESSERA/v1/parcels" -H "authorization: Bearer $ctok" \
      -H 'content-type: application/json' -H "x-user-id: $uid" \
      -d "{\"wardId\":\"$tward\",\"tier\":\"plot\",\"originX\":128,\"originY\":128}")
    [ "$crefused" = 403 ] \
      && ok "a valid service token without tessera:write cannot claim land (403), even naming a user in x-user-id" \
      || bad "tessera answered $crefused to a claim from a credential with no tessera:write, expected 403"
  fi

  # ── DISCOVERY, AND THE REFUSAL THAT IS AN ABSENCE ───────────────────────────
  #
  # §6.5: the ranking function admits exactly two inputs, footfall and dwell, and
  # §7.1's FIRST refusal is that discovery can never be bought — "no promoted placement, no paid
  # ranking, no sponsored beacons, no boost … forever".
  #
  # A 200 alone would not test that. So the response is read for a `promoted` field, and its
  # ABSENCE is the assertion — the way `admin-web` asserts its missing og card. A ranking that
  # gained a paid input would almost certainly gain a field before it gained a route, and this is
  # the check that notices.
  disc=$(code "$TESSERA/v1/discover?wardId=$tward" -H "authorization: Bearer $utok")
  if [ "$disc" = 200 ]; then
    dpaid=$(python3 -c "
import json
b = json.load(open('/tmp/slice.body'))
rows = b.get('parcels') or []
banned = {'promoted','sponsored','boost','boosted','rank_paid','placementFee','bid'}
print('yes' if any(k in banned for r in rows if isinstance(r, dict) for k in r) else 'no')" 2>/dev/null)
    [ "$dpaid" = no ] \
      && ok "GET /v1/discover answers 200 and carries no promoted/sponsored/boost field — §7.1's first refusal, asserted as an absence" \
      || bad "a discovery row carries a paid-placement field; §7.1 says the feed is footfall, dwell and recency and nothing else, forever"
  else
    bad "GET /v1/discover answered $disc to a signed-in player, expected 200"
  fi
fi

# ── THE SPRITE PATH: WHICHEVER STATE THE MOUNT IS IN, ASSERTED ────────────────
#
# micro-tessera-web named this the item most likely to be missed. `/world-assets/` is served
# same-origin because a ward costs several hundred image requests and a cross-origin path puts a
# CORS preflight in front of every one; the bytes are NOT in the bundle image, they are mounted
# from wherever micro-tessera-assets is materialised.
#
# THESE LINES USED TO SAY "micro-tessera-assets has no materialise.py". It has one now, so there
# are two legitimate states rather than one, and asserting only the empty one would go red the
# first time somebody mounted a set — which is a check that punishes the thing it exists to
# encourage. Which state applies is READ FROM THE MOUNT'S OWN RECEIPT rather than from a variable
# this script is told, because the question worth answering is what the CONTAINER is serving.
#
#   no SET.json   no art mounted. Every sprite 404s, which is what tessera-web/nginx.conf:64-67
#                 says to expect, and the two wrong ways to fail are both silent:
#                   * 200 with index.html — the browser decodes HTML as a PNG and reports a
#                     corrupt image naming the wrong file.
#                   * 404 with nginx's own error page — indistinguishable from a network fault.
#   a SET.json    a set is mounted. Then the receipt names files, and A FILE THE RECEIPT NAMES
#                 MUST BE SERVED — a complete mount that nginx cannot reach is the same outage as
#                 no mount, arriving as a world full of holes.
#
# THE STATUS IS ASSERTED either way. THE BODY IS MEASURED AND REPORTED, NOT ASSERTED — the same
# call this file already makes for `/assets/`, and for the same cause: `error_page 404 /index.html`
# is a SERVER-level directive in every frontend's nginx.conf, so it catches this location's `=404`
# too. tessera-web/nginx.conf:64-72 states an intent its own configuration does not achieve,
# exactly as the other fifteen do. A red nobody is able to clear is a red everybody learns to
# ignore.
wa_set=$(curl -s -o /dev/null -w '%{http_code}' "$TESSERA_WEB/world-assets/SET.json")
if [ "$wa_set" = 200 ]; then
  # A set is mounted. Take a path OUT OF THE RECEIPT — never one written here, which would be a
  # copy of micro-tessera-assets' naming convention in a repository that does not own it, and
  # would pass or fail for reasons that have nothing to do with the mount.
  wa_first=$(curl -s "$TESSERA_WEB/world-assets/SET.json" \
    | python3 -c "import sys,json;f=[x for x in json.load(sys.stdin)['files'] if x.get('shipped')];print(f[0]['path'] if f else '')" 2>/dev/null)
  wa_provider=$(curl -s "$TESSERA_WEB/world-assets/SET.json" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('provider',''))" 2>/dev/null)
  if [ -z "$wa_first" ]; then
    bad "/world-assets/SET.json is served but names no shipped file — the receipt is not one materialise.py wrote"
  else
    wa_code=$(curl -s -o /tmp/sprite.png -w '%{http_code}' "$TESSERA_WEB/world-assets/$wa_first")
    if [ "$wa_code" = 200 ]; then
      ok "/world-assets/ serves the '$wa_provider' set — $wa_first is $(wc -c </tmp/sprite.png | tr -d ' ') bytes"
    else
      bad "/world-assets/SET.json names $wa_first and the mount answered $wa_code for it — the receipt and the bytes disagree, so the world renders with holes"
    fi

    # ── THE RESOLUTION, THROUGH THE RECEIPT — NOT A FILENAME WRITTEN HERE ─────
    #
    # This probe used to be `GET /world-assets/tiles/ashfield-ground-a.png`, a literal, with a
    # long note recording that the client's stable path carries no size and every materialised
    # filename does, so every ground tile was a hole. That mismatch is FIXED: `sprites.ts` no
    # longer composes `identity + '.png'`; it resolves identity → URL through this receipt, which
    # is what `materialise.py` has written `key` and `path` as two different strings for on all
    # 392 entries since the beginning. Measured, not assumed: before, 3 requests to
    # `/world-assets/` and all 404, 0 of 756,000 pixels painted; after, 4 requests all 200, 256
    # tiles, 361,706 pixels.
    #
    # So the literal is now exactly the WRONG shape — it would go red on a legitimate rename and
    # green on a broken resolver, which is the check inverted. What must hold is the CONTRACT: a
    # key in the receipt resolves, through the receipt, to a path the mount serves. Rename a file
    # and re-run materialise.py and both move together; only a diverged IDENTITY breaks, which is
    # a named hole with a reason rather than a silent empty world.
    #
    # A `tiles/` key specifically, because ground is the layer whose absence is invisible: an
    # object that fails to load is a missing stool, and a ground tile that fails to load is a
    # world that renders as nothing at all while every request returns 200.
    wa_key=$(curl -s "$TESSERA_WEB/world-assets/SET.json" | python3 -c "
import sys,json
f=[x for x in json.load(sys.stdin)['files'] if x.get('shipped') and str(x.get('key','')).startswith('tiles/')]
print(f[0]['key'] + '\t' + f[0]['path'] if f else '')" 2>/dev/null)
    if [ -z "$wa_key" ]; then
      bad "the receipt names no shipped 'tiles/' key — the renderer resolves ground through this map and there is nothing in it to resolve"
    else
      wa_id=$(printf '%s' "$wa_key" | cut -f1)
      wa_path=$(printf '%s' "$wa_key" | cut -f2)
      wa_res=$(curl -s -o /tmp/sprite2.png -w '%{http_code}' "$TESSERA_WEB/world-assets/$wa_path")
      # A PNG, checked by its magic bytes, because `error_page 404 /index.html` is a SERVER-level
      # directive in every frontend's nginx.conf: a 200 here can be the app shell, which the
      # browser decodes as a corrupt image naming the wrong file. Success and failure must not be
      # indistinguishable to this harness — that is precisely why 38 browser scenarios could not
      # see the original defect.
      #
      # READ IN PYTHON, NOT `od | grep`. The first draft of this line was
      # `od -An -tx1 | grep -q '89 50 4e 47'` and it went RED against a
      # byte-perfect 88KB PNG, because BSD `od` on macOS pads to three spaces
      # between bytes and GNU `od` pads to one. A check whose verdict depends on
      # a formatting default is a check that fails on the machine it was not
      # written on — and this one would have failed CLOSED-looking-OPEN: red on
      # a healthy mount, which is how a real red gets ignored.
      png=$(python3 -c "
import sys
sys.stdout.write('yes' if open('/tmp/sprite2.png','rb').read(8) == b'\x89PNG\r\n\x1a\n' else 'no')" 2>/dev/null)
      if [ "$wa_res" = 200 ] && [ "$png" = yes ]; then
        ok "  …and the renderer's identity '$wa_id' resolves through the receipt to $wa_path — real PNG bytes, and a rename cannot break it"
      elif [ "$wa_res" = 200 ]; then
        bad "  '$wa_id' resolved to $wa_path and the mount answered 200 with something that is not a PNG — nginx's error_page served the app shell, and the browser will report a corrupt image naming the wrong file"
      else
        bad "  '$wa_id' resolves through the receipt to $wa_path and the mount answered $wa_res — the receipt and the bytes disagree, so the world renders with holes"
      fi
    fi
  fi
else
  wa_body=$(curl -s -w '\n%{http_code}' "$TESSERA_WEB/world-assets/objects/seating-stool.png")
  wa_status=$(printf '%s' "$wa_body" | tail -1)
  wa_note=""
  printf '%s' "$wa_body" | sed '$d' | grep -q 'id="root"' \
    && wa_note=" (and it carries the app shell — server-level error_page catches this location too, a finding for micro-tessera-web, not a failure here)"
  if [ "$wa_status" = 404 ]; then
    ok "/world-assets/ 404s a sprite with no set mounted — the mount is wired and empty, the supported default$wa_note"
    echo "       To serve one:  python3 materialise.py --provider flux-2-pro --into <dir>   # micro-tessera-assets"
    echo "                      CF_WORLD_ASSETS=<dir> ./scripts/estate-up.sh"
  else
    bad "/world-assets/ answered $wa_status with no set mounted — a missing sprite must 404, not resolve to something. Check the CF_WORLD_ASSETS mount"
  fi
fi

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
echo "── THE SIXTEEN FRONTENDS: served, and proved to be more than a 200 ─────"
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
# (stack/infra/beacon/src/journeys/web.js: wait for network idle, then
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
#      containerisation, and it is asserted on all sixteen because the failure
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
# Ports are 4100 + the repo's index in micro-org's registry, as everywhere else.
# All sixteen are derived now — the registry's 46→70 sweep gave rows to the four
# surfaces it used to lack, and moved these numbers in the process. THE LIST
# BELOW IS NOT ALLOWED TO DRIFT FROM IT: `scripts/web-check.py` reads each name
# and port out of these records and recomputes them, because a port that has
# moved onto ANOTHER service does not fail here — it connects, gets a 200 from
# the wrong container, and reports green.
#
# No `declare -A` — bash here is 3.2, and an associative-array port map once
# silently broke five suites in this repository.

# ── THE RELEASE MARKER, WHICH COULD NOT PASS ON A RELEASED ESTATE ────────────
#
# This was `WEB_RELEASE=${CLOUDSFORGE_RELEASE:-estate}` and every check below
# compared the served `<meta name="cf-release">` against it as a LITERAL. The
# literal is right for exactly one kind of estate: a laptop that ran
# `compose build`, where `docker-compose.estate.yml:592` passes
# `RELEASE: ${CLOUDSFORGE_RELEASE:-estate}` as a build arg and the string
# `estate` is genuinely what got stamped.
#
# A RELEASED ESTATE STAMPS THE COMMIT. CI builds each frontend with its own SHA,
# so `hub-web:2.4.0` serves `content="5c94137e…"`, and this check therefore
# failed all sixteen surfaces on mainnet — twice each, because the gateway
# section below repeats it — and reported the failure as
# "a STALE ARTEFACT is being served". Thirty-two failures, every one of them
# describing a correctly released artefact as stale. A check that cannot pass is
# this repository's named defect; a check that cannot pass AND accuses the
# estate of the opposite of what is true is worse, because someone acts on it.
#
# ── WHAT IT COMPARES AGAINST NOW ──────────────────────────────────────────────
#
# The running container's own image label. Every image CI publishes carries
# `org.opencontainers.image.revision`, and it is the same commit the build arg
# stamped into the HTML:
#
#   ghcr.io/…/micro-hub-web:2.4.0  label revision = 5c94137e…
#   https://hub.cloudsforge.online  meta cf-release = 5c94137e…
#
# So the assertion becomes the one the old comment claimed and could not make:
# **the bytes a browser receives were built from the commit the running image
# says it was built from.** That is a real stale-artefact check — it catches an
# nginx serving a `dist/` from an older layer, a volume mount shadowing the
# built assets, or a cache in front of the gateway holding a previous release —
# and unlike a literal it stays true across every version without being edited.
#
# THE FALLBACKS, IN ORDER, AND WHY EACH EXISTS:
#   1. `CLOUDSFORGE_RELEASE` exported in the shell. An operator saying what they
#      expect always wins; that is what the variable was for.
#   2. the image's `org.opencontainers.image.revision`. A released estate.
#   3. the literal `estate`. A locally-built estate, where compose's build arg
#      default is what was stamped and there is no label to read.
#
# Resolved per surface rather than once, because the sixteen are sixteen
# repositories at sixteen commits — there is no single estate-wide SHA to read.
WEB_RELEASE=${CLOUDSFORGE_RELEASE:-estate}
# The expected marker for one compose service. Empty output is impossible: the
# literal is the floor. `2>/dev/null` on both hops because a surface that is not
# running at all is a different failure, reported by the caller as such.
web_release_for() {
  wr_svc=$1
  [ -n "${CLOUDSFORGE_RELEASE:-}" ] && { printf '%s' "$CLOUDSFORGE_RELEASE"; return; }
  wr_img=$(docker compose -f "$COMPOSE" ps -q "$wr_svc" 2>/dev/null | head -1)
  [ -n "$wr_img" ] && wr_img=$(docker inspect "$wr_img" --format '{{.Config.Image}}' 2>/dev/null)
  if [ -n "$wr_img" ]; then
    wr_rev=$(docker inspect "$wr_img" \
      --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null)
    [ -n "$wr_rev" ] && { printf '%s' "$wr_rev"; return; }
  fi
  printf '%s' "$WEB_RELEASE"
}
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
  want=$(web_release_for "$name")
  if printf '%s' "$html" | grep -q "name=\"cf-release\" content=\"$want\""; then
    notes="release=$(printf '%s' "$want" | cut -c1-12)"
  else
    # The served value is quoted back, because "it is not X" without "it is Y"
    # sends the reader to the container to find out, and the answer is here.
    got=$(printf '%s' "$html" | sed -n 's/.*name="cf-release" content="\([^"]*\)".*/\1/p' | head -1)
    bad "$name: serves cf-release '${got:-<absent>}', but its running image was built from '$want' — a STALE ARTEFACT is being served, not a configuration bug"
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
  "hub-web 4126 /portfolio" \
  "site 4127 /products" \
  "admin-web 4128 /approvals" \
  "mint-web 4129 /launch" \
  "trade-web 4130 /bots" \
  "worlds-web 4131 /player" \
  "explorer-web 4132 /chains" \
  "network-site 4133 /faucet" \
  "market-web 4134 /listings" \
  "devportal-web 4135 /apps" \
  "status-web 4136 /history" \
  "foresight-web 4138 /rules" \
  "emberkin-web 4137 /party" \
  "aetherholm-web 4139 /cities" \
  "tessera-web 4140 /wards"; do
  set -- $rec
  web_surface "$1" "$2" "$3"
done

echo
echo "── THE GATEWAY: the surfaces on the hostnames a browser will use ────────"
#
# Everything above reaches a container on a loopback port. NO BROWSER EVER WILL.
# `cloudsforgeHosts()` reads `window.location.hostname`, splits the first label
# into a surface and an environment, and rebuilds every sibling host as
# `https://<sub><suffix>` — no port. So a bundle opened on 127.0.0.1:4126 resolves
# identity to `http://localhost:4001`, which nothing in this estate serves. The
# hostnames below are the only addresses under which the estate is a working
# product rather than fifteen isolated static servers.
#
# `--resolve` rather than DNS: the default apex is a public wildcard pointing at
# 127.0.0.1, but a suite that needs the internet to answer a question about
# loopback is a suite that goes red on a train.
#
# ── A SURFACE'S HOSTNAME IS `<sub>$WEB_SUFFIX`, NOT `<sub>$WEB_SUFFIX` ─────────
#
# Changed 2026-08-05, and this file composed 68 hostnames the old way. An
# environment used to be a PREFIX ON THE APEX — testnet was
# `hub.testnet.cloudsforge.online` — and that form was configured and
# unreachable, because Cloudflare's Universal SSL is `*.cloudsforge.online` and a
# wildcard matches exactly ONE label. Every two-label testnet hostname failed the
# TLS handshake at the edge before a request reached this box. The environment is
# a SUFFIX ON THE SUBDOMAIN now: `hub-testnet.cloudsforge.online`.
#
# So the three variables `compose/env/traefik.env` defines are read here rather
# than one, and NONE of them is derived from another at runtime — deriving the
# suffix as `.$WEB_APEX` would silently address MAINNET from a testnet run, which
# on a shared apex is a real hostname that really answers. The `:-` defaults below
# are only for a laptop with no gateway env file, where every surface is under
# `cloudsforge.localtest.me` and there is no second environment to confuse.
#
#   WEB_APEX    the DNS zone. Used ALONE by nothing here any more; it is the
#               fallback the two below are built from on a bare laptop.
#   WEB_SUFFIX  everything after a surface's own name — `hub` + this is Hub.
#   SITE_HOST   the marketing site, whose registry subdomain is the EMPTY STRING.
#               It cannot be `""$WEB_SUFFIX`: that is `-testnet.cloudsforge.online`,
#               which is not a legal DNS label. It gets its own variable.
WEB_APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
WEB_SUFFIX=${CF_WEB_SUFFIX:-.$WEB_APEX}
SITE_HOST=${CF_SITE_HOST:-$WEB_APEX}
# ── AND THE PORT, WHOSE VARIABLE NAME NOTHING IN THIS REPOSITORY SET ─────────
#
# This read `${CF_GATEWAY_HTTPS_PORT:-443}`, and `CF_GATEWAY_HTTPS_PORT` is
# assigned in no compose file, no env file and no script — grep the tree. So it
# always took the 443 default. The name the gateway is actually published under is
# `CF_GATEWAY_PORT` (`compose/docker-compose.gateway.yml` and
# `compose/docker-compose.estate-gateway.yml`), and `compose/testnet.env:101`
# sets it to 10443. Every gateway assertion below therefore addressed port 443 in
# a testnet project, where nothing is bound — 000 across the board, reported as a
# dead gateway rather than as a suite looking at the wrong port.
#
# The dead name is kept as a first choice rather than deleted, so an operator who
# has it exported keeps the behaviour they had; it simply no longer shadows the
# real one.
GW_PORT=${CF_GATEWAY_HTTPS_PORT:-${CF_GATEWAY_PORT:-443}}

gw() {
  gw_host=$1; gw_path=$2; shift 2
  curl -sk -o /tmp/estate-gw.body -w '%{http_code}' \
    --resolve "$gw_host:$GW_PORT:127.0.0.1" "https://$gw_host:$GW_PORT$gw_path" "$@"
}

# ── THE TLS ASSERTION, AND WHY IT IS THE FIRST ONE IN THIS SECTION ────────────
#
# **`gw()` above uses `-k`, and for months that was the only client this estate
# had.** This section's own comment used to end "the gateway serves Traefik's
# self-signed default here, which is right for loopback and wrong to ship", and
# `estate-browser.sh` passed `ignoreHTTPSErrors: true` for the same reason. So
# 183 assertions and sixteen browser journeys all ran with certificate
# verification DISABLED — this repository's named defect class, a check that
# cannot fail, sitting under every other check in the file.
#
# It was not a cosmetic gap. A person opens `https://hub.<apex>`, clicks through
# the interstitial, and the PAGE loads — so the estate looks fine. The sign-in
# form then POSTs cross-origin to `https://nimbus.<apex>`, a hostname no
# interstitial has ever been offered for, and **no browser offers one for an
# XHR**. Chrome refuses it outright with `net::ERR_CERT_AUTHORITY_INVALID`,
# `fetch` rejects with `TypeError: Failed to fetch`, and every frontend in this
# estate maps that to "Cannot reach the server. Check your connection and try
# again." Reproduced with headless Chromium: `ignoreHTTPSErrors: true` navigates,
# `false` fails before a byte of HTML arrives.
#
# So this block does the one thing `-k` cannot: it VERIFIES. `--cacert` against
# the CA `scripts/gateway-cert.sh` mints, with no `-k` anywhere on the line, so a
# certificate from the wrong issuer, one whose SAN does not cover the host, or an
# expired one all FAIL here. `-k` stays on `gw()` below deliberately — those
# assertions are about routing, and making 183 of them depend on the certificate
# would report one fault as 183 — but the transport is now checked once, for
# real, and the estate can no longer be green while unusable in a browser.
#
# ── AND IT IS THE BUNDLE, NOT THE ESTATE CA ALONE ─────────────────────────────
#
# `gateway/certs/trust.crt` is `ca.crt` plus every public root in `gateway/trust/`,
# rebuilt by `gateway-cert.sh` on every run. It exists because the MAINNET gateway
# terminates on a Cloudflare Origin CA leaf now (`gateway/dynamic/tls.yml`) while
# TESTNET still serves this repository's own leaf, so one file that verifies both
# is what keeps a single `--cacert` argument correct in both environments.
#
# It is NOT a weakening of this assertion. A bundle adds ISSUERS, not exemptions:
# a certificate from an issuer in neither, one whose SAN does not cover the host,
# and an expired one all still fail here exactly as before. `-k` remains absent.
CA_FILE=${CF_CA_FILE:-gateway/certs/trust.crt}
if [ ! -s "$CA_FILE" ]; then
  bad "no CA bundle at $CA_FILE — the gateway is serving Traefik's self-signed default, so every CROSS-ORIGIN call from a real browser fails with ERR_CERT_AUTHORITY_INVALID while every check here passes. Run ./scripts/gateway-cert.sh"
else
  tls_fails=""
  # Four hosts, not one, and each is a different SAN case: the APEX SURFACE, a
  # surface, an API-only host, and the identity host every bundle calls
  # cross-origin.
  #
  # `$SITE_HOST` rather than `$WEB_APEX`, and the difference is the whole point of
  # the 2026-08-05 migration. On mainnet they are the same string and this is the
  # entry a wildcard does NOT match — `cloudsforge.online` needs its own SAN, which
  # `scripts/gateway-cert.sh` adds as `DNS:$a` beside `DNS:*.$a`. On TESTNET they
  # differ: the apex surface is `testnet.cloudsforge.online` (one label, covered by
  # the wildcard) while `$WEB_APEX` is the shared zone `cloudsforge.online`, which
  # THIS GATEWAY DOES NOT ROUTE — mainnet does. Probing the zone from a testnet run
  # would resolve a mainnet hostname to this box's loopback and report a
  # certificate fault that is really a routing question about another environment.
  #
  # `worlds-api$WEB_SUFFIX` was the fourth entry here until 2026-08-05 and is
  # deliberately not replaced by another hyphenated name: that hostname was
  # folded into `api.`, its router and its registry row are deleted, and a TLS
  # probe against a host the gateway no longer routes proves nothing about the
  # certificate — it 000s for a routing reason and reads as a certificate fault.
  # `api$WEB_SUFFIX` takes its place because it is the surviving name, it IS
  # routed, and it is the one a third party is handed.
  for tls_host in "$SITE_HOST" "hub$WEB_SUFFIX" "nimbus$WEB_SUFFIX" "api$WEB_SUFFIX"; do
    tls_code=$(curl -s --cacert "$CA_FILE" -o /dev/null -w '%{http_code}' \
      --resolve "$tls_host:$GW_PORT:127.0.0.1" "https://$tls_host:$GW_PORT/livez" 2>/dev/null)
    # 000 is curl's "the transfer never completed", which is what a rejected
    # certificate produces. Any HTTP status at all means the handshake VERIFIED —
    # a 404 from a host that serves no /livez still proves the certificate.
    [ "$tls_code" = "000" ] && tls_fails="$tls_fails $tls_host"
  done
  if [ -z "$tls_fails" ]; then
    ok "TLS verifies against $CA_FILE on $SITE_HOST and three subdomains — no -k, no ignoreHTTPSErrors"
  else
    bad "the gateway's certificate does NOT verify for:$tls_fails — a browser will fail every cross-origin call to them with ERR_CERT_AUTHORITY_INVALID and the page will report 'Cannot reach the server'. Run ./scripts/gateway-cert.sh --force"
  fi
fi

# The gateway has to be up. NOT skipped when it is not: half the estate's browser
# surface is the routing, and a suite that quietly stops checking it reports green
# on an environment no browser can use.
if [ "$(gw "hub$WEB_SUFFIX" /healthz)" = 200 ]; then
  ok "the gateway is answering on :$GW_PORT"
else
  bad "no gateway on https://…:$GW_PORT — run ./scripts/estate-up.sh, or 'make estate-gateway' (project ${CF_GW_PROJECT:-${CF_PROJECT:-cloudsforge-estate}}, not the telemetry plane's — micro-org#257)"
fi

# ── AND IS IT ANSWERING FROM THE FILES THAT ARE ON DISK? ──────────────────────
#
# Answering is not the same as answering from the current configuration, and the
# difference is invisible from outside: every assertion below drives the ROUTING,
# so a gateway running a router table from an hour ago passes or fails this suite
# on rules nobody can read any more. The failure that costs is not the red one —
# it is the GREEN run that verified configuration that no longer exists, and then
# the edit that gets reverted because "it did not work".
#
# `--providers.file.watch=true` does not fire on this host: the dynamic directory
# is a virtiofs bind mount out of a Lima VM, and virtiofs forwards no host-side
# inotify events into the guest. Measured, and written up in the script this
# calls. It IS correct on a Linux host, which is why the flag stays.
#
# Cheap enough to run every time — two numbers and a digest, no network — and it
# is here rather than only in the deploy path because the person who needs to be
# told is the one reading a result, not the one who ran the deploy.
if [ -x ./scripts/gateway-reload.sh ]; then
  if reload_out=$(./scripts/gateway-reload.sh --check 2>&1); then
    ok "the gateway is serving the configuration that is on disk"
  else
    bad "the gateway is running STALE configuration — every routing assertion below is about a router table that is no longer what this repository says. Run ./scripts/gateway-reload.sh"
    printf '%s\n' "$reload_out" | sed 's/^/     /'
  fi
else
  bad "scripts/gateway-reload.sh is missing or not executable — nothing here can tell whether the gateway is serving the current route map"
fi

# Every surface on its registry hostname. The subdomain is the `subdomain` field
# of that surface's row in ui/packages/ui/src/surfaces.ts — which is why Forge
# Create is `create.` though its repository is micro-mint-web, and the developer
# platform is `developers.` though its repository is micro-devportal-web.
#
# `lantern` and `beacon` are the last two, and they are the only entries here whose
# hostname ALSO serves an API — see the next loop, which drives the other half of
# each. They are checked here for the reason this loop exists at all: both are
# `inSwitcher: true` in the registry, so an operator can click them, and until
# micro-lantern-web and micro-beacon-web were deployed both answered
# `404 application/json` from their own service. That is a failure a bundle-only
# check on the other sixteen could never have seen, because on those sixteen no
# service ever owned the hostname.
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
  "emberkin emberkin-web" \
  "aetherholm aetherholm-web" \
  "tessera tessera-web" \
  "lantern lantern-web" \
  "beacon beacon-web"; do
  set -- $rec
  sub=$1; repo=$2
  # `site` has an EMPTY subdomain in the registry, so it is the one surface whose
  # hostname is not `<sub>$WEB_SUFFIX`: concatenating would give
  # `-testnet.cloudsforge.online` on testnet, which is not a legal DNS label. It is
  # `$SITE_HOST` — `cloudsforge.online` on mainnet, `testnet.cloudsforge.online` on
  # testnet — which is why that is a variable of its own and not derived here.
  if [ "$sub" = "." ]; then host="$SITE_HOST"; else host="$sub$WEB_SUFFIX"; fi
  gwc=$(gw "$host" /)
  # Same marker, same source of truth as the direct-port section above — the
  # running image's `org.opencontainers.image.revision`, not the literal
  # `estate`, which on a released estate is stamped nowhere and failed all
  # sixteen of these a second time.
  want=$(web_release_for "$repo")
  if [ "$gwc" = 200 ] && grep -q "name=\"cf-release\" content=\"$want\"" /tmp/estate-gw.body; then
    ok "https://$host → $repo"
  else
    bad "https://$host answered $gwc and did not serve $repo's shell (expected cf-release '$want')"
  fi
done

echo "── the surfaces' own APIs, behind the same hostname ─────────────────────"
# Every frontend resolves its API base by comparing origins (`resolveApiBase`,
# e.g. hub-web/src/lib/hosts.ts): served from its registry host, the base is
# the EMPTY STRING and every request is relative. micro-network-site states the
# obligation outright — "the base is '' and the drip request is relative, which is
# what the registry asserts AND WHAT THE GATEWAY THEREFORE HAS TO ROUTE"
# (network-site/src/lib/hosts.ts).
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
  "developers /v1/scopes devplatform" \
  "tessera /v1/wards tessera" \
  "lantern /v1/issues lantern" \
  "beacon /v1/gate beacon"; do
  set -- $rec
  sub=$1; path=$2; svc=$3
  apic=$(gw "$sub$WEB_SUFFIX" "$path")
  case "$apic" in
    404|502|000) bad "https://$sub$WEB_SUFFIX$path answered $apic — $svc is not routed behind its own surface's hostname" ;;
    *) ok "https://$sub$WEB_SUFFIX$path → $svc ($apic)" ;;
  esac
done

echo "── the two OPERATOR consoles: the bundle and the API must not shadow ────"
#
# ── WHY THIS IS A SEPARATE BLOCK AND NOT TWO MORE LINES IN THE LOOP ABOVE ─────
#
# **A STATUS CODE CANNOT ANSWER THIS QUESTION, AND THE LOOP ABOVE ONLY READS ONE.**
# It fails on 404, 502 and 000, which catches "no router" and "a router pointing at
# nothing". It cannot catch the opposite fault, which is the one these two
# hostnames are exposed to: a `cf-web-*` router matching the WHOLE host would
# answer `/v1` with the bundle's own index.html — a **200 carrying text/html where
# JSON was expected** — and the loop would print `ok`. This estate has been bitten
# by exactly that: `explorer.<apex>/chains/…` returned 200 index.html for weeks
# while a reader checking status codes concluded the route worked.
#
# So both directions are asserted, by CONTENT TYPE, on both hosts:
#
#   the bundle  `/`      must be text/html   — the console, not the API's 404 JSON
#   the API     `/v1/…`  must be JSON        — the service, not the bundle's shell
#
# `lantern` and `beacon` are the only two hostnames in this estate where a bundle
# was added IN FRONT OF a service that already owned the whole host, so they are
# the only pair where the priorities could be inverted by a later edit and
# everything above would stay green.
#
# The status is deliberately NOT pinned on the API side. Both services refuse an
# anonymous read — 401 is the right answer and proves the service replied — and
# pinning 401 would turn a future decision to open a read into a false alarm. The
# content type is the invariant; the status is the service's business.
#
# ── AND THIS BLOCK VERIFIES THE CERTIFICATE, WHERE `gw()` DOES NOT ────────────
#
# `gwv` below is `gw()` with `--cacert` in place of `-k`. The argument for `-k` on
# `gw()` is real and unchanged — 183 assertions all failing on one bad certificate
# would report one fault 183 times — but it does not reach this far: there are a
# dozen requests here, and these two hostnames are new, so nothing has ever established
# that the estate's certificate covers them. A SAN that does not cover
# `lantern<suffix>` would leave every one of these green under `-k` and every real
# browser refusing the page. `%{content_type}` is empty on a rejected handshake,
# so the `case` arms below fall to their own `bad` rather than passing silently.
gwv() {
  gwv_host=$1; gwv_path=$2; gwv_fmt=$3; shift 3
  curl -s --cacert "$CA_FILE" -o /tmp/estate-gwv.body -w "$gwv_fmt" \
    --resolve "$gwv_host:$GW_PORT:127.0.0.1" "https://$gwv_host:$GW_PORT$gwv_path" "$@"
}

for rec in \
  "lantern /v1/issues" \
  "beacon /v1/gate"; do
  set -- $rec
  sub=$1; path=$2
  host="$sub$WEB_SUFFIX"

  webct=$(gwv "$host" / '%{content_type}')
  webcode=$(gwv "$host" / '%{http_code}')
  case "$webct" in
    text/html*)
      if [ "$webcode" = 200 ]; then
        ok "https://$host/ → the bundle ($webcode $webct)"
      else
        bad "https://$host/ is text/html but answered $webcode — the console is routed and broken, which is not the same as unrouted"
      fi ;;
    *) bad "https://$host/ answered $webcode $webct — the bundle is NOT in front of the service on this host, so every operator who picks it out of the switcher gets the API's refusal instead of a page" ;;
  esac

  apict=$(gwv "$host" "$path" '%{content_type}')
  apicode=$(gwv "$host" "$path" '%{http_code}')
  case "$apict" in
    *json*) ok "https://$host$path → $sub ($apicode $apict)" ;;
    text/html*) bad "https://$host$path answered $apicode TEXT/HTML — THE BUNDLE IS SHADOWING ITS OWN API. The client will fail parsing JSON and name the wrong file; check that cf-api-$sub outranks cf-web-$sub in gateway/dynamic/estate-web.yml" ;;
    *) bad "https://$host$path answered $apicode $apict — neither the service's JSON nor the bundle's shell" ;;
  esac
done

# `/otlp` and `/ingest` are lantern's, and they are the two prefixes a `/v1`-only
# rule would have dropped: `/otlp/v1/logs` begins with `/otlp`, NOT with `/v1`.
# Dropping them would send every service's log export and every browser's error
# report to a static file server, and the estate would go silently blind — the
# exact fault this hostname already suffered for months. A JSON body here proves
# micro-lantern answered; the bundle's nginx has no such path and would serve the
# shell.
for path in /otlp/v1/logs /ingest/client; do
  ct=$(gwv "lantern$WEB_SUFFIX" "$path" '%{content_type}')
  case "$ct" in
    *json*) ok "https://lantern$WEB_SUFFIX$path reaches micro-lantern, not the bundle ($ct)" ;;
    *) bad "https://lantern$WEB_SUFFIX$path answered $ct — the telemetry sink is behind the bundle, so every log export and every browser error report is being answered by a static file server" ;;
  esac
done

# The sink itself, end to end, from an origin the allowlist now carries. The two
# consoles were added to LANTERN_RUM_ORIGINS with their containers; without those
# entries this answers 400 "origin is not allowed" and Lantern is blind to exactly
# the pages an operator opens when something is already wrong.
for origin in "https://lantern$WEB_SUFFIX" "https://beacon$WEB_SUFFIX"; do
  sinkcode=$(gwv "lantern$WEB_SUFFIX" /ingest/client '%{http_code}' -X POST -H "Origin: $origin" \
    -H 'content-type: application/json' -d '{"samples":[]}')
  [ "$sinkcode" = 202 ] \
    && ok "the RUM sink accepts $origin ($sinkcode)" \
    || bad "the RUM sink refused $origin ($sinkcode) — that console's own error reports are dropped; check LANTERN_RUM_ORIGINS"
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
if [ "$(gw "hub$WEB_SUFFIX" /account/login)" = 200 ]; then
  ok "https://hub$WEB_SUFFIX/account/login is served — the redirect every SPA makes now lands somewhere"
else
  bad "hub$WEB_SUFFIX/account/login is not served; every 'Sign in' button in the estate leads nowhere"
fi

# identity, on the hostname the shared UI calls it by. `consumeAuthCallback` posts
# to `${cloudsforgeHosts().nimbus}/auth/handoff/redeem` (ui/packages/ui/src/
# index.tsx) — a route that did not exist under its old name and 404'd everywhere,
# returning null exactly as it does for a stale code, so it read as an expiry
# rather than as a wrong address. A 404 here would reproduce that silently.
redeem=$(gw "nimbus$WEB_SUFFIX" /auth/handoff/redeem -X POST -H 'content-type: application/json' \
  -H "origin: https://hub$WEB_SUFFIX" -d '{"code":"not-a-real-code"}')
case "$redeem" in
  404) bad "POST nimbus$WEB_SUFFIX/auth/handoff/redeem is 404 — the route the SSO callback posts to is unreachable" ;;
  000|502) bad "nimbus$WEB_SUFFIX is not routed to identity ($redeem)" ;;
  *) ok "POST nimbus$WEB_SUFFIX/auth/handoff/redeem reaches identity and refuses a forged code ($redeem)" ;;
esac

# THE CORS PREFLIGHT. The sign-in page is on `hub<suffix>` and identity is on
# `nimbus<suffix>`: every call it makes is cross-origin, and identity sends no CORS
# headers of its own — it has no CORS setting at all. The gateway is the only
# thing that can permit this, and a missing allowlist entry fails CLOSED and in
# silence: the browser discards the response and nothing server-side records that
# anything was refused.
allow=$(curl -sk -D - -o /dev/null -X OPTIONS \
  --resolve "nimbus$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
  -H "origin: https://hub$WEB_SUFFIX" \
  -H 'access-control-request-method: POST' \
  -H 'access-control-request-headers: content-type' \
  "https://nimbus$WEB_SUFFIX:$GW_PORT/auth/handoff/redeem" \
  | tr -d '\r' | grep -i '^access-control-allow-origin:' | head -1)
case "$allow" in
  *"https://hub$WEB_SUFFIX"*) ok "the gateway permits hub$WEB_SUFFIX to call identity ($allow)" ;;
  *) bad "no CORS allowance for https://hub$WEB_SUFFIX on nimbus$WEB_SUFFIX (got '${allow:-nothing}') — sign-in cannot complete in a browser" ;;
esac

# pay. and vault. — the two hostnames micro-hub-web named as missing and could not
# add from its own repository (hub-web/src/lib/money.ts). `hosts().pay` is
# wallet and `hosts().keyvault` is custody, and both are called with the USER'S
# OWN token from Hub's origin, so both need the app CORS allowlist that the API
# host deliberately does not carry.
# The paths are the ones hub-web actually calls, read off its own call sites
# (hub-web/src/lib/money.ts and :192) rather than picked: `/health` was tried
# first here and answered 404 from custody, which is indistinguishable at a glance
# from the router being absent. A 401 is the pass — it proves the service replied.
for rec in "pay /v1/deposits wallet" "vault /v1/exports custody"; do
  set -- $rec
  sub=$1; path=$2; svc=$3
  pc=$(gw "$sub$WEB_SUFFIX" "$path")
  case "$pc" in
    404|000|502) bad "https://$sub$WEB_SUFFIX$path answered $pc — $svc is not reachable on the hostname Hub calls it by" ;;
    *) ok "https://$sub$WEB_SUFFIX → $svc ($pc)" ;;
  esac
  pa=$(curl -sk -D - -o /dev/null -X OPTIONS --resolve "$sub$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
    -H "origin: https://hub$WEB_SUFFIX" -H 'access-control-request-method: POST' \
    -H 'access-control-request-headers: content-type,authorization' \
    "https://$sub$WEB_SUFFIX:$GW_PORT$path" | tr -d '\r' \
    | grep -i '^access-control-allow-origin:' | head -1)
  case "$pa" in
    *"https://hub$WEB_SUFFIX"*) ok "  …and Hub's origin is allowed to call it" ;;
    *) bad "  …but hub$WEB_SUFFIX may not call $sub$WEB_SUFFIX (got '${pa:-nothing}')" ;;
  esac
done

echo "── CROSS-SURFACE SSO: the hand-off, driven end to end ───────────────────"
#
# THE DEFECT THIS SECTION EXISTS FOR. `IDENTITY_HANDOFF_ORIGINS` defaulted to ''
# and no compose file in this repository set it. `isAllowedOrigin` is
# `env.handoffOrigins.includes(origin)` over an empty array
# (identity/src/handoff.ts), so `createHandoffCode` returned null for EVERY
# origin and `POST /auth/handoff` answered 403 to everyone. A person could sign in
# at Hub and reach NO OTHER SURFACE — which is where most of the 86 tier-T3
# scenarios in doc 22 go on their second step.
#
# Nothing caught it because nothing in this repository had ever minted a hand-off
# code: identity's own suite sets the variable in `testsupport.ts`, so the
# empty-by-default case was only ever exercised by a deployment, and there had
# never been one.
#
# Driven through the gateway rather than the loopback port, because the origins
# on the allowlist are gateway origins and a check against 127.0.0.1:4100 would
# prove something the browser cannot do.
# ── REGISTRATION NO LONGER RETURNS A SESSION, AND THIS DRILL BLAMED THE WRONG
#    THING FOR IT ───────────────────────────────────────────────────────────────
#
# This read `accessToken` straight out of the register response. `micro-identity`
# 1.1.0 removed that session on purpose — `server.ts`, "NO SESSION. THIS
# IS THE POINT OF THE ROUTE'S 202" — so registration now answers 202 with no
# token and an account that cannot sign in until its email is verified.
#
# The drill then presented an EMPTY bearer, identity answered 401
# unauthenticated, and this section reported:
#
#   FAIL identity refused to mint a hand-off code — IDENTITY_HANDOFF_ORIGINS
#        does not name market…, and cross-surface SSO is dead
#
# which was false in every part. The allowlist was correct and SSO was working;
# the drill simply had no session. THAT IS THE EXPENSIVE KIND OF WRONG: it names
# a specific, plausible, already-fixed cause, so the next person spends their
# time on a variable that was never the problem. A check that cannot tell "the
# thing is broken" from "I could not test the thing" is worse than no check.
#
# So the session is obtained the way a real user gets one — the account is
# verified, then signed in — and the drill FAILS EARLY AND SAYS SO if it cannot
# get one, rather than carrying an empty token into an assertion about SSO.
#
# THE SECOND PLACE THE TURNSTILE LANDED. This registered anonymously, was refused
# `challenge_required` from release 2.5.19 on, then set `email_verified_at` on an
# account that had never been created, failed the login, and reported it as "the
# SSO checks below are NOT a verdict on the allowlist" — true, and about nothing.
# `register_as_drill` is the shared path; see the block where it is defined.
so_email="sso-$$@example.test"
so_reg=$(register_as_drill "$so_email" "sso$$")
so_tok=$(printf '%s' "$so_reg" | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)

if [ -z "$so_tok" ]; then
  # The verification link is delivered by mail, which this script cannot read, so
  # the flag is set directly. This is FIXTURE SETUP for the hand-off drill and is
  # deliberately not dressed up as a test of verification: whether registration
  # mail is actually delivered is its own assertion elsewhere, and doing it here
  # would hide a broken mail path behind a passing SSO check.
  docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d identity -c \
    "update users set email_verified_at = now() where email = lower(btrim('$so_email'))" >/dev/null 2>&1
  so_tok=$(curl -s -X POST "$IDENTITY/auth/login" -H 'content-type: application/json' \
    -d "{\"identifier\":\"$so_email\",\"password\":\"$PASS\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
fi

if [ -n "$so_tok" ]; then
  ok "a second account for the hand-off drill"
else
  bad "could not obtain a session for the hand-off drill user — the SSO checks below are NOT a verdict on the allowlist"
fi

# Hub mints a code for Market — one real surface handing a session to another.
# The STATUS is captured alongside the body, because 401 and 403 mean completely
# different things here and reporting them as one line is what made this section
# accuse the allowlist of a fault that was a missing session.
so_mint=$(curl -sk -o /tmp/estate-sso-mint.json -w '%{http_code}' \
  -X POST --resolve "nimbus$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
  "https://nimbus$WEB_SUFFIX:$GW_PORT/auth/handoff" \
  -H "authorization: Bearer $so_tok" -H 'content-type: application/json' \
  -H "origin: https://hub$WEB_SUFFIX" \
  -d "{\"redirectOrigin\":\"https://market$WEB_SUFFIX\"}")
so_code=$(python3 -c "import json;print(json.load(open('/tmp/estate-sso-mint.json')).get('code',''))" 2>/dev/null)
if [ -n "$so_code" ]; then
  ok "identity minted a hand-off code for https://market$WEB_SUFFIX"
elif [ "$so_mint" = "401" ]; then
  bad "the hand-off drill has no session (401) — this says NOTHING about the allowlist; fix the sign-in above first"
else
  bad "identity refused to mint a hand-off code ($so_mint) — IDENTITY_HANDOFF_ORIGINS does not name market$WEB_SUFFIX, and cross-surface SSO is dead"
fi

# Market redeems it, presenting the Origin a browser would send. This is the
# assertion that proves the whole path: the code is bound to the origin it was
# minted for and matched against the browser's own header
# (identity/src/handoff.ts).
so_new=$(curl -sk -X POST --resolve "nimbus$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
  "https://nimbus$WEB_SUFFIX:$GW_PORT/auth/handoff/redeem" \
  -H 'content-type: application/json' -H "origin: https://market$WEB_SUFFIX" \
  -d "{\"code\":\"${so_code:-nothing-was-minted}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null)
if [ -n "$so_new" ]; then
  ok "market$WEB_SUFFIX redeemed it and holds a session — A USER CAN CROSS SURFACES"
else
  bad "the hand-off code could not be redeemed from https://market$WEB_SUFFIX"
fi

# THE BINDING ITSELF. A code minted for Market must be worthless from anywhere
# else, or the allowlist is decoration. Minted fresh: the one above is spent.
so_code2=$(curl -sk -X POST --resolve "nimbus$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
  "https://nimbus$WEB_SUFFIX:$GW_PORT/auth/handoff" \
  -H "authorization: Bearer $so_tok" -H 'content-type: application/json' \
  -d "{\"redirectOrigin\":\"https://market$WEB_SUFFIX\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
so_theft=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  --resolve "nimbus$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
  "https://nimbus$WEB_SUFFIX:$GW_PORT/auth/handoff/redeem" \
  -H 'content-type: application/json' -H 'origin: https://not-a-cloudsforge-surface.example' \
  -d "{\"code\":\"${so_code2:-nothing-was-minted}\"}")
case "$so_theft" in
  2*) bad "A HAND-OFF CODE MINTED FOR MARKET WAS REDEEMED FROM ANOTHER ORIGIN ($so_theft) — the origin binding is not enforced" ;;
  *)  ok "the same code is refused from a foreign origin ($so_theft) — the binding holds" ;;
esac

# And an origin that is not a surface must not get a code at all.
so_bad=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
  --resolve "nimbus$WEB_SUFFIX:$GW_PORT:127.0.0.1" \
  "https://nimbus$WEB_SUFFIX:$GW_PORT/auth/handoff" \
  -H "authorization: Bearer $so_tok" -H 'content-type: application/json' \
  -d '{"redirectOrigin":"https://not-a-cloudsforge-surface.example"}')
[ "$so_bad" = 403 ] && ok "an origin off the allowlist is refused a code (403)" \
  || bad "expected 403 for an unlisted redirectOrigin, got $so_bad"

# The /internal refusal, still winning over every router this work added. It is a
# router at priority 100000 pointed at an unreachable service, so 502 is the pass.
# Asserted on a SURFACE host, because the routers added for the fifteen bundles
# are the ones that could have shadowed it.
[ "$(gw "hub$WEB_SUFFIX" /internal/anything)" = 502 ] \
  && ok "/internal is still refused on a surface host — nothing added here outranks it" \
  || bad "/internal on hub$WEB_SUFFIX was not refused; the priority-100000 rule has been shadowed"

echo
echo "── the chain-backing loop: solvency, or a refusal ───────────────────────"
# THE CHECK THAT THE LEDGER'S RECONCILIATION HAD NO INPUT FOR.
#
# ledger/src/reconcile.ts takes an optional `indexerObservedTotal` and, until
# `GET /v1/custody/:chain/:network/total` existed, NOTHING in the estate could
# produce one — it was supplied in exactly one place in 58 repositories, a test.
# Every scheduled run therefore took the `liability_sum` branch and compared the
# ledger against the ledger, on the one asset the check exists for.
#
# THIS SECTION USED TO ASSERT ONLY THE REFUSAL, and said so: "INDEXER_CHAINS is
# unset, so indexer follows no chain". That is no longer true. There is an EMBER
# testnet on this machine — `hearth/docker-compose.testnet.yml` run by
# `scripts/ember-testnet.sh`, plus the owner's miner on the host — the indexer
# follows `ember:testnet` from genesis, and `scripts/ember-seed.js` has put real
# coin on real custody addresses.
#
# So the refusal checks below stay (they are still the shape of every failure)
# and the SUCCESS PATH is now driven for the first time, at the foot of this
# file: chain → indexer → ledger → a reconciliation that is genuinely
# `observed_source = 'indexer'` and genuinely clean, then deliberately broken to
# prove it fails closed rather than silently passing.
INDEXER=${INDEXER:-http://127.0.0.1:${PB}108}

cb_anon=$(code "$INDEXER/v1/custody/ember/$EMBER_NETWORK/total")
[ "$cb_anon" = 401 ] && ok "the custody total refuses an anonymous caller (401)" \
  || bad "the custody total answered $cb_anon to no token — every other read here is public because chain facts are; Sigma over a set only the platform knows is not"

# ── THE CALLER IS NOW LEDGER ITSELF, AND THAT IS THE WHOLE POINT ──────────────
#
# This used to mint for `community`, with a note saying community was a stand-in because "ledger's
# [grant] does not [carry indexer:read], and cannot until its client exports the scope for
# `derive-grants.mjs` to find. So this drives the route with the credential shape ledger will
# eventually hold, without pretending ledger holds one today."
#
# It holds one today. `ledger/src/indexerclient.ts` exports `INDEXER_SCOPES = ['indexer:read']`,
# the derivation picked it up with nothing typed into the grants map by hand, and
# `estate-bootstrap.sh` now hands ledger the token its `env.ts` has always read.
#
# Driving it AS LEDGER is what separates two states that a health check cannot tell apart and that
# are completely different facts:
#
#   * EMBER frozen because no Hearth node is followed — CORRECT, argued in compose beside
#     LEDGER_RECONCILE_ASSETS. If the chain has not launched then no EMBER is backed by anything.
#   * EMBER frozen because ledger cannot AUTHENTICATE — a deployment defect. The 401 maps to
#     `undefined`, the run is unobserved, the run is `failed`, the asset freezes, and the
#     reconciliation table records exactly the same row as the honest case.
#
# A stand-in caller could never have told them apart, because a stand-in that authenticates proves
# nothing about the principal that actually makes the call. 401 below is therefore its own failure
# with its own message, and it is NOT allowed to pass as "refuses with a reason".
cb_tok=$(curl -s -X POST "$IDENTITY/service-tokens" -H "authorization: Bearer $atok" \
  -H 'content-type: application/json' -d '{"service":"ledger","scopes":["indexer:read"]}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
[ -n "$cb_tok" ] \
  && ok "identity minted indexer:read for LEDGER — the principal that actually makes the custody call, not a stand-in" \
  || bad "identity would not mint indexer:read for ledger; its INDEXER_SCOPES declaration has not reached the grants map"

# And the container is HOLDING one, which is a different fact from being allowed to mint it. This
# is the line whose absence froze EMBER: a grant says what identity MAY mint, the credential is what
# ledger is actually handed, and nothing was setting it.
#
# The variable CHANGED, and the check follows the variable rather than being dropped with it.
# `ledger/src/env.ts` reads `LEDGER_IDENTITY_CREDENTIAL` — long-lived, `cfsc_…` — and exchanges
# it per call. A JWT here would be the retired `LEDGER_SERVICE_TOKEN`, so the prefix is asserted:
# `cfsc_` and not `ey`, which is the difference between a credential that outlives the job's timer
# and a token that does not.
lsvc=$(docker inspect cloudsforge-estate-ledger-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep -c '^LEDGER_IDENTITY_CREDENTIAL=cfsc_' || true)
[ "${lsvc:-0}" -ge 1 ] \
  && ok "the ledger container holds a real long-lived LEDGER_IDENTITY_CREDENTIAL — it can authenticate to the indexer on EVERY run, not just the first" \
  || bad "ledger has no LEDGER_IDENTITY_CREDENTIAL in its environment; its custody call goes out unauthenticated, the 401 maps to undefined, and EMBER freezes on an auth error while LOOKING exactly like the honest no-chain freeze"

# AND THE RETIRED VARIABLE MUST BE GONE, not merely unused. `ledger/src/env.ts` keeps
# `legacyServiceTokenPresent` only to COMPLAIN about it: handing it back would be ignored, so a
# deploy that still set it would look configured and behave unconfigured. It is also a live JWT with
# a real `sub` and real scopes sitting in a file for no reader.
lleg=$(docker inspect cloudsforge-estate-ledger-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep -c '^LEDGER_SERVICE_TOKEN=ey' || true)
[ "${lleg:-0}" -eq 0 ] \
  && ok "the retired LEDGER_SERVICE_TOKEN is not in ledger's environment — nothing mints a credential no code reads" \
  || bad "ledger still holds a LEDGER_SERVICE_TOKEN; it is IGNORED by env.ts:363 and is a live bearer token minted for no reader"

# ── THE 600s CLIFF THAT USED TO BE REPORTED HERE IS FIXED, AND IS NOW DRIVEN ───
#
# This block used to end in an unconditional `bad`, and beneath it a workaround
# that re-minted ledger's token and recreated the container so the section below
# could be driven at all. Both are DELETED AS OBSOLETE, not as inconvenient: the
# defect they described no longer exists in the code they described it in.
#
# What it was: `LEDGER_SERVICE_TOKEN` carried a 600-second token
# (identity/src/tokens.ts) read once at import, and the reconciliation job
# runs every 900 seconds (`ledger/src/jobs.ts`). 600 < 900, so the
# chain-backing call authenticated for the FIRST run after a bootstrap and for no
# run after that, ever — and `estate-up.sh` bootstraps and verifies inside the
# window, which is exactly why it was invisible.
#
# What fixed it: `ledger/src/env.ts` reads the long-lived
# `LEDGER_IDENTITY_CREDENTIAL` and exchanges it for a fresh token PER CALL at
# `POST /service-tokens/exchange`. There is no expiry to outrun and nothing for
# this script to renew, so the workaround has no subject left.
#
# THE ASSERTION DID NOT GO AWAY WITH IT — IT MOVED, AND IT GOT STRONGER. A
# comment claiming the cliff is gone proves nothing; the two checks above assert
# the credential is the long-lived kind and the expiring one is absent, and the
# section below now drives a SECOND reconciliation more than 600 seconds after
# boot, which is the only evidence that distinguishes a fix from a first run.
#
# `ledger` migration 12 adds `unobserved_reason`, so the two freezes that used to
# be byte-identical are now separable AT THE ROW: `no_credential`, `unauthorized`
# and `not_configured` are deployment defects; `indexer_error` is the chain. That
# column is asserted below rather than described here.

if [ -z "$cb_tok" ]; then
  bad "could not obtain a service token carrying indexer:read; the custody route cannot be driven"
else
  cb_status=$(code -H "authorization: Bearer $cb_tok" "$INDEXER/v1/custody/ember/$EMBER_NETWORK/total")
  cb_code=$(python3 -c "import sys,json;print(json.load(open('/tmp/slice.body')).get('error',{}).get('code',''))" 2>/dev/null)
  case "$cb_status" in
    200)
      # Only legitimate if a chain is genuinely followed. Then the number must be
      # a STRING — a JSON number has already dropped the low digits of an
      # 18-decimal balance, and those digits are where a drift lives.
      cb_total=$(python3 -c "import sys,json;b=json.load(open('/tmp/slice.body'));print(type(b.get('total')).__name__)" 2>/dev/null)
      [ "$cb_total" = str ] && ok "the custody total answered a string total — the loop has a real input" \
        || bad "the custody total answered a $cb_total, not a string; an 18-decimal balance does not survive a JSON number"

      # AND IT MUST NOT BE ZERO OVER ZERO ADDRESSES. A 200 whose total is "0" and
      # whose `addresses` is 0 would be the exact defect this release removed —
      # "we did not look" reported as "the chain holds nothing" — and `custody.ts`
      # refuses that case rather than answering it, so seeing it here means the
      # refusal has been weakened. It is checked separately from the seeded
      # arithmetic below because it is a property of the ROUTE, not of the seed.
      cb_n=$(python3 -c "import json;print(json.load(open('/tmp/slice.body')).get('addresses',0))" 2>/dev/null)
      cb_at=$(python3 -c "import json;b=json.load(open('/tmp/slice.body'));print(b.get('observedAtBlock'),b.get('headHeight'),b.get('requiredConfirmations'))" 2>/dev/null)
      [ "${cb_n:-0}" -gt 0 ] 2>/dev/null \
        && ok "…summed over $cb_n registered custody addresses, read at block/head/depth $cb_at" \
        || bad "the custody total answered 200 over ZERO addresses — an empty set must be refused, never summed to 0"

      # ── WHICH PREFIXES THE ROUTE ACTUALLY SELECTS ON ────────────────────────
      #
      # Read here and used by the break in step 3 below, which used to hardcode
      # `deposit:` and was silently wrong the day a second prefix held value.
      #
      # This estate has 233 `deposit:` addresses and one `treasury:`, and the
      # treasury holds 24.1 of the 25.1 EMBER. So "break every deposit: label"
      # emptied 15 of 16 addresses and left 96% of the balance in place, and the
      # route then answered 200 with a perfectly TRUE total — over a custody set
      # the drill believed it had emptied. All three assertions below failed, and
      # every one of them was measuring a premise that was false rather than the
      # behaviour it was written for.
      #
      # A hardcoded prefix in a drill about the prefix set is the same defect the
      # release this drill guards exists to fix, one layer out: 2.5.4 made the
      # prefix list an explicit, ordered, queryable part of the route's answer
      # precisely so that nothing has to assume there is one of them. So the
      # drill asks. A prefix added to the estate tomorrow is covered by this
      # without anybody remembering it, which is the only version of this check
      # that keeps working.
      cb_prefixes=$(python3 -c "
import json, re, sys
b = json.load(open('/tmp/slice.body'))
ps = [p for p in (b.get('labelPrefixes') or []) if re.fullmatch(r'[A-Za-z0-9:._-]{1,24}', p)]
print('\n'.join(ps))" 2>/dev/null)
      ;;
    404)
      bad "the custody total answered 404 — a consumer files that as 'no custody here', which is a zero wearing a status code"
      ;;
    401|403)
      # ITS OWN BRANCH, AND IT MUST NEVER FALL INTO THE 5xx ONE ABOVE. A 401 here is not the chain
      # being absent; it is ledger being unable to ask. Both end in a frozen EMBER and an
      # `unavailable/failed` row, and only this line can tell an operator which one they have.
      bad "the custody total answered $cb_status to LEDGER'S OWN token — ledger cannot authenticate to the indexer, so its reconciliation is unobserved for a reason that has nothing to do with the chain. EMBER will freeze on an auth error while reporting the same state as the honest no-chain case"
      ;;
    50*)
      # A 503 `chain_not_followed` is the HONEST refusal: the indexer follows no chain here because
      # INDEXER_CHAINS is unset and Hearth has not launched. It is only honest when the caller got
      # far enough to be refused on the merits, which the 401 branch above is what establishes.
      [ -n "$cb_code" ] \
        && ok "the custody total refuses ledger with a reason ($cb_status $cb_code) rather than a number nobody measured — the freeze below is the chain's absence, not an auth failure" \
        || bad "the custody total answered $cb_status with no error code; an operator cannot act on it"
      ;;
    *)
      bad "the custody total answered $cb_status to a token carrying indexer:read"
      ;;
  esac
fi

# AND THE CONSEQUENCE, IN THE LEDGER. With no observation available, EMBER must
# be recorded `unavailable` / `failed` and frozen — never `liability_sum`, which
# is the vacuous branch, and never `clean`. `LEDGER_RECONCILE_ASSETS` names EMBER
# deliberately; see the compose comment for why it is not exempted.
cb_src=$(docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d ledger \
  -c "select observed_source||'/'||status from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1" 2>/dev/null | tr -d '[:space:]')
case "$cb_src" in
  "")                 ok "no EMBER reconciliation has run yet in this environment (the sweep is 15-minutely)" ;;
  liability_sum/*)    bad "AN EMBER RUN RECORDED liability_sum — the ledger compared itself against itself on a chain asset; migration 11 was supposed to make that impossible" ;;
  unavailable/failed) ok "EMBER records unavailable/failed and freezes — correct here, because no chain is followed" ;;
  indexer/*)          ok "EMBER was reconciled against a real chain observation ($cb_src)" ;;
  *)                  bad "an EMBER run recorded $cb_src, which is neither an observation nor an honest refusal" ;;
esac

echo
echo "── the EMBER chain, driven: clean, then deliberately broken ─────────────"
# ══════════════════════════════════════════════════════════════════════════════
# EVERYTHING ABOVE THIS LINE ASSERTS THE REFUSAL BRANCH. THIS DRIVES THE OTHER.
#
# The estate built a complete chain-backing guarantee and, until there was a
# chain on this machine, could only ever exercise its refusals: ledger migration
# 11 refusing a self-attested run at the database, the indexer refusing a partial
# sum, the job recording `unavailable/failed`. Every one of those is a `no`. None
# of them is evidence that a `yes` is reachable, and a guarantee that has only
# ever said no is indistinguishable from one that can only say no.
#
# So this section does four things in order, and each is a real effect:
#
#   1. CLEAN. Force the 15-minutely reconciliation to run now, and require a NEW
#      row with `observed_source = 'indexer'`, `status = 'clean'` and `drift = 0`
#      — the chain's own aggregate equalling the ledger's custody total to the
#      wei, over seeded amounts (7 + 11 + 13 EMBER) that are distinct and
#      non-round so a summing bug cannot balance by luck.
#   2. UNFROZEN. `asset_freezes` must no longer hold EMBER. Only an exactly-zero
#      drift lifts a freeze (`reconcile.ts`), so this is the assertion that the
#      run really was zero and not merely within tolerance.
#   3. BROKEN. Move the custody labels out of the `deposit:` prefix — the
#      indexer's set becomes empty — and run it again. The route must REFUSE with
#      `no_custody_addresses` rather than answer 0, and the ledger must record
#      `unavailable/failed` and RE-FREEZE. This is the whole point: an empty
#      observation must fail closed, not pass as a perfectly balanced zero.
#   4. RESTORED. Put the labels back, run once more, and require clean again —
#      so a verify run leaves the estate as it found it, and so the freeze is
#      demonstrably lift-able rather than one-way.
#
# THE BREAK IS AT THE INDEXER'S CUSTODY SET, NOT AT THE CHAIN. Stopping the miner
# would also work and takes fifteen minutes to become visible (a stopped miner
# only shows up once the confirmed height stops advancing); relabelling is
# instant, is exactly reversible, and exercises the guard whose comment says an
# empty set "far more often means nobody registered the addresses than that the
# platform holds none".
#
# IT IS SKIPPED, NOT FAILED, WHEN THERE IS NO CHAIN. An estate brought up without
# `./scripts/ember-testnet.sh up` is a legitimate configuration and the refusal
# branch above is the correct verdict for it. What must never happen is this
# section quietly passing while proving nothing, so the skip says so out loud.
# ══════════════════════════════════════════════════════════════════════════════
# ── THE CHAIN IS NOT ON THIS MACHINE ANY MORE ────────────────────────────────
#
# The app stack moved to a second host on 2026-08-10 (micro-org#338); the chains
# stayed behind. `127.0.0.1:8545` was true when one box ran both, and on the app
# host it is now the address of nothing. Measured there on 2026-08-10: this
# section SKIPPED with "chain id read: none" while the seed was healthy, answering
# 0x1cf3 to the same call over the link, and being reconciled against by the
# indexer in the very next section of this file. A skip is loud, but it is still
# not evidence — and this one reported the absence of a chain that three other
# checks in this run were provably talking to.
#
# `CF_CHAIN_HOST` is the SAME variable `compose/env/traefik.env` resolves the
# gateway's three `CF_*_UPSTREAM`s from, so the verifier and the estate cannot
# disagree about where the chain is. The fallback stays `127.0.0.1` rather than
# traefik's `host.docker.internal`: this script runs on the host, not in a
# container, and on a single-box estate loopback is still the right answer.
EMBER_RPC_HOST=${EMBER_HOST_RPC:-http://${CF_CHAIN_HOST:-127.0.0.1}:8545}

# ── BUT THE HOST IS THE WRONG PLACE TO ASK FROM, AND CF_CHAIN_HOST ALONE DID
#    NOT FIX THIS ───────────────────────────────────────────────────────────
#
# Pointing the curl above at `CF_CHAIN_HOST` was necessary and NOT sufficient.
# Measured on the app host on 2026-08-10, after that change: this section still
# skipped, now reading "no EMBER mainnet at http://10.10.0.1:8545", and the curl
# timed out at exit 28.
#
# The reason is specific to how this host reaches the chain. The link is a
# WireGuard interface created by a `--network host --cap-add NET_ADMIN` container,
# which puts `wg0` in the DOCKER ENGINE's network namespace — not in the Linux
# distribution's. `ip addr show wg0` from this shell says the device does not
# exist, while every container on a docker bridge routes over it perfectly well.
# So a probe run from the host is testing a path no service in this estate uses,
# and its failure says nothing about the chain.
#
# ASK THE INDEXER, FROM INSIDE, WITH ITS OWN SETTING. `INDEXER_RPC_EMBER_<NET>`
# is the exact URL the service whose reconciliation this section is about will
# use, so a disagreement between what that URL answers and what this file expects
# IS the defect, rather than a fact about the operator's shell. There is no curl
# in the service images — node is the one dependency every one of them is
# guaranteed to have, the same reasoning `docker-compose.hearth-seed.yml` gives
# for writing its healthcheck in node.
#
# The host curl is kept as the FALLBACK, not deleted: on a single-box estate the
# indexer may legitimately not be running, and loopback is then the right and only
# answer. Whichever path replied is named in every message below, because "no
# chain" and "no route from here to the chain" are different findings and this
# section spent a run reporting the first when it meant the second.
#
# THE PROGRAM ARRIVES ON STDIN rather than as `node -e '…'`. `docker compose exec`
# parses flags anywhere on its command line, so a `-e` meant for node is a coin
# toss over which program reads it; feeding the script to a bare `node` leaves no
# flag after the service name for compose to claim.
#
# AND THE VARIABLE IS NOT A URL. Measured in the running indexer on 2026-08-10,
# `INDEXER_RPC_EMBER_MAINNET` is `hearth-seed=http://10.10.0.1:8545` — the
# `<name>=<url>` form `INDEXER_CHAINS` pairs with, one entry per comma. The first
# revision of this helper passed the whole string to `new URL()`, which threw, and
# the throw was swallowed by `2>/dev/null` — so it reported the chain unreachable
# for exactly the reason this section already had a bad history of: an empty
# answer that looked like an absent chain and was really a broken probe.
ember_chain_id() {
  printf '%s' '
      const h=require("http");
      const raw=process.env["INDEXER_RPC_EMBER_"+process.env.CF_VERIFY_NET]||"";
      const first=raw.split(",")[0].trim();
      const spec=first.includes("=")?first.slice(first.indexOf("=")+1):first;
      if(!spec) process.exit(3);
      let u; try{u=new URL(spec)}catch(e){process.exit(4)}
      const q=h.request({host:u.hostname,port:u.port||80,path:u.pathname||"/",method:"POST",
        headers:{"content-type":"application/json"}},r=>{let d="";r.on("data",c=>d+=c);
        r.on("end",()=>{try{process.stdout.write(String(JSON.parse(d).result||""))}catch(e){}})});
      q.on("error",()=>{});q.setTimeout(5000,()=>q.destroy());
      q.end("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}");
  ' | docker compose -f "$COMPOSE" exec -T \
      -e CF_VERIFY_NET="$(printf '%s' "$EMBER_NETWORK" | tr '[:lower:]' '[:upper:]')" \
      indexer node 2>/dev/null | tr -d '\r\n'
}
ember_chain=$(ember_chain_id)
ember_probe_via="the indexer container, on its own INDEXER_RPC_EMBER_$(printf '%s' "$EMBER_NETWORK" | tr '[:lower:]' '[:upper:]')"
if [ -z "$ember_chain" ]; then
  ember_chain=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
    --data-binary '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$EMBER_RPC_HOST" 2>/dev/null \
    | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p')
  ember_probe_via="$EMBER_RPC_HOST, from this host — the indexer could not be asked"
fi

# psql against the estate's own databases. `-qtA` so a value is a value.
lsql() { docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d ledger "$@" 2>/dev/null; }
isql() { docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d indexer "$@" 2>/dev/null; }

# Force the leased job to be due now and wait for a run row NEWER than the one we
# started with. Waiting on a NEW ROW rather than sleeping a fixed amount is the
# same rule the rest of this file follows: a fixed sleep is either slower than it
# needs to be or shorter, and which one is a property of the machine.
#
# $1 = the id of the newest EMBER run before the trigger. Echoes the new row as
# `observed_source|status|drift`, or nothing if none arrived.
reconcile_now() {
  lsql -c "update jobs set run_at = now(), locked_until = null, locked_by = null
            where kind = 'ledger.reconcile' and key = 'asset:EMBER'" >/dev/null
  _n=0
  while [ "$_n" -lt 60 ]; do
    _row=$(lsql -c "select id||'|'||observed_source||'|'||status||'|'||coalesce(drift::text,'null')
                      from reconciliation_runs where asset_code='EMBER'
                     order by started_at desc limit 1")
    case "$_row" in
      "$1"|"$1"'|'*) : ;;
      ?*) printf '%s' "${_row#*|}"; return 0 ;;
    esac
    _n=$((_n + 1))
    sleep 2
  done
  return 1
}

if [ "$ember_chain" != "$ember_chain_want" ]; then
  echo "  ..   SKIPPED: no EMBER $EMBER_NETWORK reachable via $ember_probe_via (chain id read: ${ember_chain:-none},"
  echo "       wanted $ember_chain_want / $ember_chain_dec)."
  echo "       The refusal branch above is the correct verdict for an estate without a chain."
  echo "       To drive the success path:  ./scripts/ember-testnet.sh up && ./scripts/ember-miner.sh start"
  echo "                                   node scripts/ember-seed.js"
elif [ "$(isql -c "select count(*) from watched_addresses where chain='ember' and network='$EMBER_NETWORK' and label like 'deposit:%'")" = 0 ]; then
  echo "  ..   SKIPPED: the chain is up but nothing is registered as EMBER custody."
  echo "       A zero-balance custody set proves the plumbing and nothing about the arithmetic."
  echo "       Seed it:  node scripts/ember-seed.js"
else
  ok "an EMBER $EMBER_NETWORK is answering via $ember_probe_via on chain $ember_chain_dec"

  # ── 0. THE KEY, WHICH IS THE PART THAT CANNOT BE UNDONE ────────────────────
  #
  # Hearth binds the coinbase public key into the proof-of-work seed
  # (`chain/miner.js`) and signs the proof with the private key, so
  # the owner's miner MUST hold a real key — `hearthd --evm` refuses
  # `--miner-address` for exactly that reason. That makes a file on this machine
  # worth money, and every other check in this file is cheap by comparison: a
  # committed key cannot be un-committed, and a `docker volume prune` cannot be
  # un-pruned.
  #
  # Three assertions, in the order they matter, and NONE of them reads the key.
  EMBER_KEY=${EMBER_MINER_DATA:-$HOME/.cloudsforge/ember-testnet/miner}/coinbase-key.json
  if [ -f "$EMBER_KEY" ]; then
    # 1. OUTSIDE EVERY WORK TREE. Not "ignored" — absent, so no edit to any
    #    .gitignore and no `git add -A` anywhere can ever reach it.
    if (cd "$(dirname "$EMBER_KEY")" && git rev-parse --show-toplevel >/dev/null 2>&1); then
      bad "THE MINER'S KEY IS INSIDE A GIT WORK TREE ($EMBER_KEY). One 'git add -A' publishes it, and a published key cannot be unpublished"
    else
      ok "the miner's key is outside every git work tree — no ignore rule stands between it and a commit"
    fi
    # 2. 0600. `evmnode.js` writes it that way; this catches a later chmod.
    kmode=$(stat -f '%Lp' "$EMBER_KEY" 2>/dev/null || stat -c '%a' "$EMBER_KEY" 2>/dev/null)
    [ "$kmode" = 600 ] && ok "…and is mode 600" \
      || bad "the miner's key is mode ${kmode:-unknown}, not 600 — anything running as another user on this machine can read it"
    # 3. It is not empty of the thing that makes it a key. Checked by SHAPE, so
    #    nothing here ever holds the material: a file whose `privateKey` went
    #    missing is a miner that will silently generate a NEW key on next start
    #    and mine to an address the owner does not know about.
    python3 -c "import json,sys;d=json.load(open('$EMBER_KEY'));sys.exit(0 if isinstance(d.get('privateKey'),str) and d.get('address','').startswith('0x') else 1)" 2>/dev/null \
      && ok "…and still carries the key for $(python3 -c "import json;print(json.load(open('$EMBER_KEY'))['address'])" 2>/dev/null)" \
      || bad "the miner's key file has no usable privateKey/address; the next start would silently mine to a NEW address"
  else
    echo "  ..   no miner wallet at $EMBER_KEY — the owner's miner has never run here"
  fi

  # And the ignore rule this repository does carry, checked rather than trusted.
  git check-ignore -q .env.local 2>/dev/null \
    && ok "'.env.local' is genuinely ignored here (git check-ignore agrees) — the convention for an operator secret beside the compose file holds" \
    || bad "'.env.local' is NOT ignored in this repository; the estate's own convention for a local secret would commit it"

  # ── 1. CLEAN ───────────────────────────────────────────────────────────────
  before=$(lsql -c "select id from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
  run=$(reconcile_now "$before")
  if [ -z "$run" ]; then
    bad "the EMBER reconciliation job did not produce a new run within 120s — is the ledger's job runner alive?"
  else
    src=$(printf '%s' "$run" | cut -d'|' -f1)
    st=$(printf '%s' "$run" | cut -d'|' -f2)
    drift=$(printf '%s' "$run" | cut -d'|' -f3)
    [ "$src" = indexer ] \
      && ok "a forced run recorded observed_source = 'indexer' — the ledger asked the chain and got an answer" \
      || bad "the forced run recorded observed_source = '$src'. 'liability_sum' is the ledger checking itself and migration 11 should refuse it; 'unavailable' means the custody call failed"
    [ "$st" = clean ] && [ "$drift" = 0 ] \
      && ok "…and it is CLEAN with drift exactly 0: Σ on-chain custody equals the ledger's custody total, to the wei" \
      || bad "the observed run is $st with drift $drift — the chain and the books disagree (or the seed and the credit do)"

    # AND THE ROW MUST SAY IT DID NOT FAIL, not merely fail to say it did.
    # Migration 12 adds `unobserved_reason`, which is what finally separates the
    # two freezes that used to be byte-identical: `no_credential`, `unauthorized`
    # and `not_configured` are DEPLOYMENT defects (this file's business),
    # `indexer_error` is the chain (not this file's business). On an observed run
    # it must be NULL — a non-null reason beside `observed_source = 'indexer'`
    # would mean the column is being written by something other than the failure
    # path, which would make every assertion on it worthless.
    ureason=$(lsql -c "select coalesce(unobserved_reason,'(null)') from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
    [ "$ureason" = "(null)" ] \
      && ok "…and unobserved_reason is NULL, as an observed run requires" \
      || bad "the run observed the chain and STILL recorded unobserved_reason = '$ureason'; migration 12's column is being written outside the failure path, so no verdict read from it can be trusted"

    # A number, printed, because "clean" over nothing is the failure this whole
    # section exists to rule out. 31000000000000000000 wei is 7 + 11 + 13 EMBER.
    tot=$(lsql -c "select ledger_custody_total||' / '||coalesce(indexer_observed_total::text,'null')
                     from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
    case "$tot" in
      0*|"0 / 0") bad "the run balanced at ZERO — 0 == 0 is the plumbing working and the arithmetic untested" ;;
      *)          ok "…over a real position: ledger / chain = $tot wei" ;;
    esac
  fi

  # ── 2. UNFROZEN ────────────────────────────────────────────────────────────
  frozen=$(lsql -c "select count(*) from asset_freezes where asset_code='EMBER'")
  [ "$frozen" = 0 ] \
    && ok "EMBER is no longer frozen — and only an exactly-zero run lifts a freeze, so this is the run's own evidence" \
    || bad "EMBER is still frozen after a clean run; the 'delete from asset_freezes' in reconcile.ts did not fire"

  # ── 3. BROKEN, AND IT MUST FAIL CLOSED ─────────────────────────────────────
  # Out of EVERY configured prefix and into one nothing selects. Reversible by
  # construction: the label is prefixed, never rewritten, so step 4 strips it.
  #
  # `cb_prefixes` comes from the route's own `labelPrefixes` (see where it is
  # read, above). Hardcoding `deposit:` here is what made this drill test its own
  # false premise for three releases.
  if [ -z "${cb_prefixes:-}" ]; then
    bad "the route named NO label prefixes, so this drill cannot empty the custody set and every assertion below it would be measuring a set that was never emptied. That is the failure mode this block was rewritten to end — refusing instead"
  else
    cb_where=""
    for cb_p in $cb_prefixes; do
      cb_where="${cb_where}${cb_where:+ or }label like '${cb_p}%'"
    done
    isql -c "update watched_addresses set label = 'broken-by-verify/' || label
              where chain='ember' and network='$EMBER_NETWORK' and ($cb_where)" >/dev/null

    # AND IT MUST HAVE WORKED. The route is about to be asked whether it refuses an
    # EMPTY custody set; if the set is not empty, a 200 is the correct answer and
    # the three assertions below are all measuring the wrong thing while looking
    # like findings. Cheap to check, and it is the check whose absence cost a
    # release's worth of confusing red.
    cb_left=$(isql -c "select count(*) from watched_addresses
                        where chain='ember' and network='$EMBER_NETWORK' and ($cb_where)")
    [ "${cb_left:-1}" = 0 ] \
      || bad "the break left ${cb_left} address(es) still matching a configured prefix, so the custody set below is NOT empty and the refusal being tested for cannot be expected. Prefixes tried: $(printf '%s ' $cb_prefixes)"

    brk=$(code -H "authorization: Bearer $cb_tok" "$INDEXER/v1/custody/ember/$EMBER_NETWORK/total")
    brk_code=$(python3 -c "import json;print(json.load(open('/tmp/slice.body')).get('error',{}).get('code',''))" 2>/dev/null)
    if [ "$brk" = 200 ]; then
      brk_total=$(python3 -c "import json;print(json.load(open('/tmp/slice.body')).get('total'))" 2>/dev/null)
      bad "WITH AN EMPTY CUSTODY SET THE ROUTE ANSWERED 200 WITH total=$brk_total. That is 'we did not look' reported as 'the chain holds nothing', and it would reconcile clean against an empty ledger for ever"
    else
      # Any refusal is the right shape; the CODE is what an operator acts on, and a
      # refusal with no code sends them nowhere. `no_custody_addresses` is the one
      # this break should produce — a different code means something else broke too.
      [ -n "$brk_code" ] \
        && ok "with the custody set emptied the route refuses ($brk $brk_code) rather than answering 0" \
        || bad "with the custody set emptied the route answered $brk with no error code — an operator reading the freeze cannot tell why"
    fi

    before=$(lsql -c "select id from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
    run=$(reconcile_now "$before")
    src=$(printf '%s' "$run" | cut -d'|' -f1)
    st=$(printf '%s' "$run" | cut -d'|' -f2)
    case "$src/$st" in
      unavailable/failed)
        ok "the ledger recorded unavailable/failed — it FAILED CLOSED on an observation it could not make" ;;
      indexer/clean)
        bad "THE LEDGER RECONCILED CLEAN WITH NO OBSERVABLE CUSTODY SET. A withheld observation reached reconcileAsset as a number; this is the defect the whole release removed" ;;
      liability_sum/*)
        bad "the ledger fell back to liability_sum on EMBER — it compared itself against itself on a chain asset, which migration 11 must refuse" ;;
      *)
        bad "with the observation withheld the ledger recorded $src/$st, which is neither an honest refusal nor a clean run" ;;
    esac

    # AND IT MUST SAY WHICH KIND OF FAILURE IT WAS. This is the whole point of
    # migration 12's column and the reason it is asserted on a DRIVEN break rather
    # than described: the failure induced here is a CHAIN failure — the custody set
    # was emptied, ledger's credential was never touched — so the row must read
    # `indexer_error`. If it reads `no_credential`, `unauthorized` or
    # `not_configured` then the deployment is broken as well and the freeze above
    # is being produced by the wrong cause while looking identical, which is
    # precisely the confusion this release exists to end.
    breason=$(lsql -c "select coalesce(unobserved_reason,'(null)') from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
    case "$breason" in
      indexer_error)
        ok "…and it recorded unobserved_reason = 'indexer_error' — the row names the CHAIN as the cause, which is the truth here" ;;
      no_credential|unauthorized|not_configured)
        bad "the induced break was a CHAIN failure but the row recorded unobserved_reason = '$breason', a CREDENTIAL failure. ledger cannot authenticate to the indexer, and that defect has been hiding underneath a freeze that reads identically to the honest one" ;;
      "(null)")
        bad "the run failed with no unobserved_reason at all; migration 12's column is not being written on the failure path, so the two freezes are still indistinguishable" ;;
      *)
        bad "the failed run recorded an unrecognised unobserved_reason = '$breason'" ;;
    esac

    refroze=$(lsql -c "select count(*) from asset_freezes where asset_code='EMBER'")
    [ "$refroze" -ge 1 ] 2>/dev/null \
      && ok "…and EMBER is frozen again: an asset whose backing nobody can see cannot be withdrawn" \
      || bad "the run failed and EMBER was NOT frozen — the failure was recorded and acted on by nothing"

    # ── 4. RESTORED ────────────────────────────────────────────────────────────
    isql -c "update watched_addresses set label = replace(label, 'broken-by-verify/', '')
              where chain='ember' and network='$EMBER_NETWORK' and label like 'broken-by-verify/%'" >/dev/null
    # Counted over EVERY prefix, like the break — this read `deposit:%` and so
    # reported "15 addresses restored" out of 16 while calling the estate returned
    # to how it was found. The one it never counted is the treasury holding 96% of
    # the balance.
    restored=$(isql -c "select count(*) from watched_addresses where chain='ember' and network='$EMBER_NETWORK' and ($cb_where)")
    still_broken=$(isql -c "select count(*) from watched_addresses where chain='ember' and network='$EMBER_NETWORK' and label like 'broken-by-verify/%'")
    if [ "${still_broken:-1}" != 0 ]; then
      bad "the custody labels were NOT restored — ${still_broken} address(es) still carry the drill's prefix. EMBER will stay frozen after this verify run, and the estate has been left worse than it was found"
    else
      [ "${restored:-0}" -ge 1 ] 2>/dev/null \
        && ok "the custody labels are restored ($restored addresses across $(printf '%s ' $cb_prefixes)) — this section leaves the estate as it found it" \
        || bad "the custody labels were NOT restored; EMBER will stay frozen after this verify run"
    fi
  fi

  before=$(lsql -c "select id from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
  run=$(reconcile_now "$before")
  src=$(printf '%s' "$run" | cut -d'|' -f1)
  st=$(printf '%s' "$run" | cut -d'|' -f2)
  [ "$src/$st" = indexer/clean ] \
    && ok "and clean again ($src/$st) — the freeze was a state, not a one-way door" \
    || bad "after restoring the custody set the run is $src/$st, not indexer/clean; the estate has been left worse than it was found"

  # ── 5. AND IT STILL AUTHENTICATES PAST THE 600-SECOND CLIFF ────────────────
  #
  # EVERY CHECK ABOVE PASSES ON A BROKEN DEPLOYMENT IF IT IS RUN SOON ENOUGH.
  # That is not a hypothetical: it is exactly how the cliff stayed invisible.
  # `LEDGER_SERVICE_TOKEN` lived 600s, the reconciliation job runs every 900s,
  # and `estate-up.sh` bootstraps and verifies inside the window — so the one
  # path anybody ran produced a clean run and a lifted freeze while the estate
  # was guaranteed to freeze again at minute 15 and stay frozen for ever.
  #
  # A run at minute 0 therefore proves nothing about the fix, and this is the
  # check that proves something: wait until the container has been up longer
  # than the retired token would have lived, force ANOTHER reconciliation, and
  # require it to observe the chain. With `LEDGER_IDENTITY_CREDENTIAL` exchanged
  # per call there is no expiry to outrun and this costs only the wait; with the
  # old variable this is the run that returns `unauthorized`.
  #
  # The wait is real time and is spent rather than skipped, because the cheap
  # version of this check — asserting the variable's name and calling it proved —
  # is the class of check this file exists to eliminate. It can be skipped
  # explicitly for a fast local loop, and skipping SAYS SO instead of passing.
  cliff=${CF_VERIFY_TOKEN_CLIFF_SECONDS:-600}
  started=$(docker inspect cloudsforge-estate-ledger-1 --format '{{.State.StartedAt}}' 2>/dev/null)
  up=$(STARTED="$started" python3 -c "
import os,datetime,sys
s=os.environ['STARTED']
try:
    s=s[:26].rstrip('Z') if '.' in s else s.rstrip('Z')
    t=datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc)
    print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()))
except Exception:
    print(-1)" 2>/dev/null)
  if [ "${CF_VERIFY_SKIP_TOKEN_CLIFF:-0}" = 1 ]; then
    echo "  ..   SKIPPED BY REQUEST (CF_VERIFY_SKIP_TOKEN_CLIFF=1): the post-${cliff}s reconciliation is NOT proved."
    echo "       Every clean run above is also what a token-cliff deployment produces in its first ${cliff}s."
  elif [ "${up:--1}" -lt 0 ] 2>/dev/null; then
    bad "could not read the ledger container's start time, so the post-${cliff}s reconciliation cannot be proved"
  else
    if [ "$up" -lt "$cliff" ]; then
      wait_for=$((cliff - up + 15))
      echo "  ..   ledger has been up ${up}s; waiting ${wait_for}s to cross the ${cliff}s mark that the retired token died on"
      sleep "$wait_for"
    fi
    before=$(lsql -c "select id from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
    run=$(reconcile_now "$before")
    src=$(printf '%s' "$run" | cut -d'|' -f1)
    st=$(printf '%s' "$run" | cut -d'|' -f2)
    drift=$(printf '%s' "$run" | cut -d'|' -f3)
    lreason=$(lsql -c "select coalesce(unobserved_reason,'(null)') from reconciliation_runs where asset_code='EMBER' order by started_at desc limit 1")
    case "$lreason" in
      no_credential|unauthorized|not_configured)
        bad "MORE THAN ${cliff}s AFTER BOOT THE RECONCILIATION FAILED TO AUTHENTICATE (unobserved_reason = '$lreason'). This is the token cliff, alive: the clean runs above happened inside the window and prove nothing. EMBER will freeze and stay frozen, reading identically to an absent chain" ;;
      *)
        [ "$src/$st" = indexer/clean ] && [ "$drift" = 0 ] \
          && ok "MORE THAN ${cliff}s AFTER BOOT a fresh reconciliation still authenticated: $src/$st, drift $drift, unobserved_reason $lreason — the credential is exchanged per call and the 600s cliff is genuinely gone" \
          || bad "the post-${cliff}s run recorded $src/$st drift $drift (unobserved_reason $lreason) — it authenticated, but the loop no longer closes" ;;
    esac
  fi
fi

echo
echo "── the browser telemetry sink, driven to the ROW ────────────────────────"
# ── WHY THIS SECTION EXISTS ───────────────────────────────────────────────────
#
# `grep -c lantern` over the estate compose file returned 0. Sixteen frontends
# had been posting browser telemetry since the template was written and NOT ONE
# EVENT HAD EVER BEEN STORED, because the service was not deployed and the
# bundles were posting the wrong path, the wrong envelope key and the wrong
# record shape. Nothing here checked any of it, so nothing said so.
#
# ── AND WHY IT ASSERTS THE ROW RATHER THAN THE STATUS CODE ────────────────────
#
# Because a 202 from this route IS NOT SUCCESS. A correct path carrying a wrong
# record shape answers `202 {"stored":0}` — accepted, discarded in full, and
# reported to the caller as fine. That is the exact shape of the defect this
# whole section exists to catch, and asserting on the status code would step
# straight into it. So the positive check reads the row back out of Postgres.
lansql() { docker compose -f "$COMPOSE" exec -T postgres psql -qtA -U cloudsforge -d lantern "$@" 2>/dev/null; }
# `$WEB_SUFFIX` from the gateway section above, not a second reading of
# `CF_WEB_APEX`. This line used to re-derive its own `APEX` and compose
# `hub.${APEX}`, which is a duplicate of a value already in scope — and after the
# 2026-08-05 hostname migration it was the SILENT kind of duplicate: on testnet
# `hub.cloudsforge.online` is a real mainnet hostname that really answers, so the
# origin this posts under would have been accepted by nothing and refused by
# LANTERN_RUM_ORIGINS with a 400 that reads as a broken sink.
ORIGIN="https://hub${WEB_SUFFIX}"

[ "$(code "$LANTERN/livez")"  = 200 ] && ok "lantern /livez"  || bad "lantern /livez — the sink is not deployed"
[ "$(code "$LANTERN/readyz")" = 200 ] && ok "lantern /readyz" || bad "lantern /readyz"

# THE POSITIVE, read back from the table. A unique marker per run, so a stale row
# from an earlier run cannot make this pass.
marker="verify-$$-$(date +%s)"
# ── TRUNCATE FIRST, AND RETURN THE STATUS ────────────────────────────────────
#
# `curl -o FILE` does NOT touch FILE when the connection is refused, so the file
# keeps whatever the LAST SUCCESSFUL request left in it — including from an
# earlier run of this script. A `grep` over that stale body is a check that
# passes while the service is stopped.
#
# That is not hypothetical either: it is what the first version of this section
# did. Stopping the lantern container was supposed to turn every check below red
# and two of them stayed green, reading a body from the previous run. Truncating
# and requiring the status code is what makes the greps mean anything.
post() { : > /tmp/lantern.body
         curl -s -o /tmp/lantern.body -w '%{http_code}' --max-time 10 -X POST "$LANTERN/ingest/client" \
           -H "Origin: $ORIGIN" -H 'content-type: application/json' -d "$1"; }

post "{\"samples\":[{\"app\":\"$marker\",\"kind\":\"page_load\",\"route\":\"/verify\",\"valueMs\":42,\"attributes\":{\"probe\":true}}]}" >/dev/null
stored=$(lansql -c "select count(*) from rum_samples where app='$marker' and kind='page_load' and route='/verify' and value_ms=42")
[ "${stored:-0}" = 1 ] \
  && ok "a correctly-shaped sample REACHED POSTGRES — not merely a 202, the row is in rum_samples" \
  || bad "the sample did NOT reach rum_samples (found ${stored:-0}); browser telemetry is being accepted and discarded"

# ── THE THREE NEGATIVES: each defect the frontends actually shipped ───────────
#
# All three were live at once and each alone was enough. They are asserted
# separately because fixing one and not the others changes nothing observable.

# 1. The stale PATH. It must answer the diagnostic, and — the part that matters —
#    it must carry the CORS header, because a 4xx a browser cannot read is not a
#    4xx as far as the page is concerned. `curl` sees every refusal; Chrome does
#    not. That difference is why this asserts the HEADER and not just the body.
: > /tmp/lantern.body
hdrs=$(curl -s -D- -o /tmp/lantern.body --max-time 10 -X POST "$LANTERN/ingest/browser" \
        -H "Origin: $ORIGIN" -H 'content-type: application/json' -d '{}')
printf '%s' "$hdrs" | grep -qi "access-control-allow-origin: $ORIGIN" \
  && ok "the stale /ingest/browser path answers WHERE A BROWSER CAN HEAR IT (CORS header present)" \
  || bad "the /ingest/browser refusal carries no access-control-allow-origin — a page reads it as 'Failed to fetch', indistinguishable from the host being absent"
grep -q 'unknown_ingest_path' /tmp/lantern.body \
  && ok "…and names the path that does exist, rather than a bare 404" \
  || bad "the unknown-path reply no longer names the served paths"

# 2. The stale ENVELOPE key.
envcode=$(post '{"events":[{"app":"x","type":"PageLoad","message":"m"}]}')
# Matched WITHOUT the quotes around `samples`: the body is JSON, so they arrive
# escaped as \"samples\" and a pattern carrying bare quotes matches nothing. That
# is not a hypothetical — this check failed on its first run for exactly that
# reason, against a sink that was behaving correctly.
[ "$envcode" = 400 ] && grep -q 'this sink reads' /tmp/lantern.body \
  && ok "an \"events\" envelope is REFUSED by name, not silently dropped" \
  || bad "an \"events\" envelope is no longer refused by name (status $envcode); the old frontend shape would vanish quietly"

# 3. The stale RECORD key — the dangerous one, because it returns 2xx.
badcode=$(post "{\"samples\":[{\"app\":\"$marker-bad\",\"type\":\"PageLoad\",\"message\":\"m\"}]}")
[ "$badcode" = 202 ] && grep -q '"stored":0' /tmp/lantern.body && grep -q 'unknown_kind' /tmp/lantern.body \
  && ok "a record keyed \`type\` stores nothing AND SAYS SO (stored:0, unknown_kind) — the 202 that used to lie now explains itself" \
  || bad "a record keyed \`type\` did not report itself as dropped (status $badcode); a wrong shape is silently discarded again"

# The origin allowlist. The sink answers without a credential, so this is the
# only thing standing between it and any page on the internet.
[ "$(code -X POST "$LANTERN/ingest/client" -H 'Origin: https://evil.example' \
      -H 'content-type: application/json' -d '{"samples":[]}')" = 400 ] \
  && ok "an unlisted origin is refused — the allowlist is the sink's only defence and it is on" \
  || bad "an unlisted origin was NOT refused; any page on the internet can write to the triage view"

lansql -c "delete from rum_samples where app like '$marker%'" >/dev/null
# Asserted, not announced. An unconditional `ok` here would be one more line that
# cannot fail, in a section written because this estate keeps producing them.
left=$(lansql -c "select count(*) from rum_samples where app like '$marker%'")
[ "${left:-x}" = 0 ] \
  && ok "the probe rows are removed — this section leaves the estate as it found it" \
  || bad "the probe rows were NOT removed (${left:-unreadable} left); this run has polluted the telemetry plane"

echo "── THE PAGES HAVE SOMETHING ON THEM ─────────────────────────────────────"
#
# ── THE DEFECT THIS CLOSES, AND WHY NOTHING ABOVE COULD SEE IT ────────────────
#
# Every gateway check in this file asserts that a route ANSWERS. Not one asks
# whether it answers with anything. `https://api.<apex>/v1/listings` returning
# `200 {"listings":[]}` passes the surface loop above in every respect — it is
# not a 404, not a 502, it is JSON, and it is not the bundle's shell — and it is
# an empty marketplace.
#
# On 2026-08-05 that was the state of both live estates: `foresight.markets` 0,
# `market.listings` 0, `market.collections` 0, `mint.tokens` 0,
# `community.communities` 0, `nda.worlds` 0, `beacon.probes` 0. The seeding step
# in `estate-bootstrap.sh` had never once run, because the host has no Node and
# that branch reported the skip as `ok`. Five empty products, green for months,
# and the only way anybody found out was by opening a page.
#
# ── WHY IT SHELLS OUT INSTEAD OF CURLING SEVEN URLS HERE ──────────────────────
#
# `scripts/seed/lib.mjs` already holds the map: where each service is, which four
# have NO gateway route and must be read on loopback, and which read corresponds
# to which surface. Restating that in bash would be a second copy of it, and the
# copy that goes stale is always the one a person is not looking at. `--check`
# writes nothing, reads each surface through the same front door its own page
# uses, and is anonymous wherever a visitor is.
#
# ── AND WHY IT IS FATAL HERE AND NOT IN THE BOOTSTRAP ─────────────────────────
#
# `estate-bootstrap.sh` reports this and does not fail on it, deliberately: a
# credential bootstrap that went red because a marketplace was empty would be
# reporting a content problem as a credential problem, and the next person would
# learn to ignore the red. THIS file is where a content problem is a failure —
# it is the estate's own suite, and "the product has nothing in it" is exactly
# the kind of thing a suite exists to refuse to pass.
if ! SEED_NODE=$(./scripts/node-tool.sh 2>/tmp/estate-node-tool.log); then
  bad "no Node >= 22 could be found or fetched, so THE PAGES WENT UNCHECKED — see /tmp/estate-node-tool.log. This is the same missing interpreter that left every surface empty; it is a failure here and not a skip"
else
  if "$SEED_NODE" ./scripts/estate-seed.mjs --check >/tmp/estate-seed-check.log 2>&1; then
    ok "every product surface has content — $(grep -c '  ok ' /tmp/estate-seed-check.log) read back through the front door"
  else
    # Each empty surface named on its own line rather than one summary failure:
    # "content is missing" is not actionable, "the marketplace has nothing for
    # sale" is, and the count of failures should match the count of empty pages.
    while IFS= read -r line; do
      bad "$line"
    done < <(sed 's/\x1b\[[0-9;]*m//g' /tmp/estate-seed-check.log | grep -E 'FAIL' | sed 's/^ *FAIL *//')
    grep -qE 'FAIL' /tmp/estate-seed-check.log \
      || bad "estate-seed.mjs --check exited non-zero and named nothing — see /tmp/estate-seed-check.log"
  fi
fi

echo "── THE FAUCET, AND THE CHAIN THIS ESTATE ACTUALLY RUNS ──────────────────"
#
# ── WHY A ROUTE THAT 502s IS THE WORST OF THE THREE ANSWERS ───────────────────
#
# `micro-faucet` will only ever run against the EMBER testnet. `faucet/src/env.ts`
# is `export const NETWORK = 'testnet' as const`, annotated that way so that
# `NETWORK === 'mainnet'` is a COMPILE ERROR rather than a branch, and
# `faucet/src/index.ts` reads `eth_chainId` at boot and exits on anything
# that is not 7412. That is right and is not being weakened: a faucet is an
# unauthenticated withdrawal endpoint that happens to be pointed at a worthless
# chain, and the mainnet EMBER on this host is mined, publicly reachable and
# backs the ledger.
#
# So both faucet services carry `profiles: ["ember-testnet"]` and the mainnet
# estate runs none. **The gateway did not know that.** `cf-api-network` routed
# `network.<apex>/v1` to `cf-svc-faucet` unconditionally, so on mainnet:
#
#     https://network.cloudsforge.online/faucet     -> 200 text/html
#     https://network.cloudsforge.online/v1/faucet  -> 502    (measured 2026-08-05)
#
# A 502 is the estate saying "there is a faucet here and it has fallen over".
# There is no mainnet faucet and there is never going to be one, so the honest
# answer is the one `estate-web.yml`'s own rule already prescribes for a surface
# whose backend is absent: no `/v1` router, and a 404 from the bundle's nginx,
# which means "there is no such service". Nothing failed on the 502. A person
# found it.
#
# ── AND THE CHAIN ID, WHICH WAS SWAPPED EARLIER TODAY ─────────────────────────
#
# The estate briefly had mainnet and testnet the wrong way round. Nothing at this
# level would have noticed: both nodes speak an identical protocol and answer
# every request correctly, about the wrong chain. `faucet/src/env.test.ts`
# pins the faucet's own half — CHAIN_ID is 7412, mainnet is 7411, and the two are
# asserted to differ — so the SERVICE could not have been fooled. What had no
# check was the ESTATE: which chain this project's node is actually on, and
# whether a faucet is published for it.
FAUCET_RUNNING=$(docker compose -f "$COMPOSE" ps --status running --services 2>/dev/null | grep -cx faucet)

# 1. The node this environment points at is the chain this environment claims.
#    `ember_chain_dec` is derived from CF_EMBER_NETWORK at the head of this file.
#    It asks the same way the chain section above does — see the argument there.
#    Re-probing rather than reusing `ember_chain` is deliberate: this assertion is
#    about the estate's configuration and belongs with the faucet it guards, and a
#    node that changed identity between the two reads is worth catching.
faucet_chain=$(ember_chain_id)
if [ -z "$faucet_chain" ]; then
  faucet_chain=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
    --data-binary '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$EMBER_RPC_HOST" 2>/dev/null \
    | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')
fi
if [ -z "$faucet_chain" ]; then
  ok "no EMBER node reachable via $ember_probe_via, so the faucet's chain agreement is not asserted (the chain section above already reports this)"
elif [ "$faucet_chain" != "$ember_chain_want" ]; then
  bad "this estate is configured as EMBER $EMBER_NETWORK ($ember_chain_dec) but the node reached via $ember_probe_via answers chain $faucet_chain — every service in this project, the faucet included, is talking to the WRONG CHAIN and answering correctly about it"
else
  ok "the node reached via $ember_probe_via is EMBER $EMBER_NETWORK ($ember_chain_dec), which is what this project is configured for"
fi

# 2. A faucet runs here if and only if this is the testnet.
case "$EMBER_NETWORK:$FAUCET_RUNNING" in
  testnet:0)
    bad "this is the EMBER testnet and NO faucet container is running — a testnet whose coins only the miner's key can spend is not a testnet anybody else can use. Bring the estate up with --env-file compose/testnet.env, which sets COMPOSE_PROFILES=ember-testnet" ;;
  mainnet:0)
    ok "no faucet on the mainnet estate, which is the point: faucet/src/env.ts:63 fixes NETWORK to 'testnet' at compile time and mainnet EMBER is mined money" ;;
  mainnet:*)
    bad "a faucet container is RUNNING on the mainnet estate. It cannot dispense — index.ts:108-120 exits on any chain that is not 7412 — so this is a crash loop, and it means COMPOSE_PROFILES carries ember-testnet in an environment whose chain is $ember_chain_dec" ;;
  *)
    ok "a faucet runs on the EMBER testnet estate" ;;
esac

# 3. And the gateway agrees with 2, which is the half that was wrong.
#    `network<suffix>/v1/faucet` is the faucet's terms — the first call the drip
#    form makes (`network-site/src/pages/faucet.tsx`). Its CONTENT TYPE is the
#    invariant, for the reason the operator-console block above gives: a 200
#    carrying the SPA's index.html would pass a status-code check and fail in the
#    client as a parse error naming the wrong file.
fct=$(gwv "network$WEB_SUFFIX" /v1/faucet '%{content_type}')
fcode=$(gwv "network$WEB_SUFFIX" /v1/faucet '%{http_code}')
if [ "$FAUCET_RUNNING" -gt 0 ]; then
  case "$fct:$fcode" in
    *json*:200) ok "https://network$WEB_SUFFIX/v1/faucet → the faucet's terms ($fcode $fct)" ;;
    *json*)     bad "https://network$WEB_SUFFIX/v1/faucet answered $fcode — a faucet is running but its terms cannot be read, so the drip form renders disabled and says the faucet did not answer" ;;
    *)          bad "https://network$WEB_SUFFIX/v1/faucet answered $fcode $fct — a faucet is running and the gateway is not putting it on the hostname the form posts to" ;;
  esac
else
  case "$fcode" in
    502|503)
      bad "https://network$WEB_SUFFIX/v1/faucet answered $fcode — THERE IS NO FAUCET IN THIS ESTATE AND THE GATEWAY IS ADVERTISING ONE. A 5xx reads as 'the faucet fell over'; the true answer is that a $EMBER_NETWORK estate has no faucet by design. Gate cf-api-network on CF_EMBER_NETWORK in gateway/dynamic/estate-web.yml" ;;
    404)
      # The CONTENT TYPE is deliberately not pinned here, where the operator-console
      # block above does pin it, and the difference is worth stating. There the
      # question was whether the bundle was SHADOWING a service that exists, and
      # only the content type could answer it. Here no service exists, and 404 is
      # already the whole truth: "there is no faucet on this estate".
      #
      # The two bundles do not agree on how to say it — measured 2026-08-05,
      # `explorer.<apex>/v1/nope` answers `404 application/json` from micro-explorer's
      # nginx and `network.<apex>/v1/faucet` answers `404 text/html`, the SPA shell
      # served with an honest status. That is a difference between two other
      # repositories' nginx configurations, and failing here on it would make this
      # section permanently red for something it cannot fix and that is not the
      # defect. It is reported instead.
      ok "https://network$WEB_SUFFIX/v1/faucet → 404 $fct, which honestly means there is no faucet on a $EMBER_NETWORK estate" ;;
    200)
      bad "https://network$WEB_SUFFIX/v1/faucet answered 200 $fct with no faucet in this estate — either the SPA is shadowing the path (a 200 of index.html where JSON was expected) or something else has taken the route" ;;
    *)
      bad "https://network$WEB_SUFFIX/v1/faucet answered $fcode $fct — no faucet runs here, so this should be the bundle's 404 and it is not" ;;
  esac
fi

[ "$fails" -eq 0 ] && { echo; echo "all seams verified"; exit 0; }
echo; echo "$fails check(s) failed"; exit 1
