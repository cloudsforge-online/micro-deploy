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
# Section 5e's operator call. 4107 is DERIVED, not chosen: index 7 in
# `deployableRepos()`, the same rule every host port in the compose file follows,
# and `make check-web` recomputes it. Reached on loopback rather than through the
# gateway because this script runs before the gateway is guaranteed to be up.
CUSTODY=${CUSTODY:-http://127.0.0.1:4107}
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

echo "── 3. THE BOOTSTRAP — ONE TRANSACTION, ONCE PER DATABASE ────────────────"
#
# THIS IS THE DOCUMENTED BOOTSTRAP STEP, and it is now a transaction rather than
# an UPDATE. In a real deployment a human with database access runs it once and
# records it in the change log; here the script runs it, but the DATABASE — not
# this script — is what makes it one-shot.
#
# ── WHAT THIS USED TO BE, AND WHY IT NO LONGER WORKS ──────────────────────────
#
# For months this was one statement:
#
#     update users set roles = array['admin'] where email = '<the operator>';
#
# `micro-identity` migration 12 refuses it. `users_roles_need_a_grant` is a
# DEFERRED constraint trigger: a row that GAINS a privileged role is rejected at
# COMMIT — SQLSTATE 23514 — unless a `platform_role_grants` row for that user and
# role was written IN THE SAME TRANSACTION. Deferred, so no ordering inside the
# transaction escapes it, and a trigger rather than a handler check because the
# threat model here explicitly includes someone holding a psql connection. The
# statement above is exactly what identity's own `makeAdmin` test helper ran, and
# it went red the moment the trigger landed.
#
# Same-transaction, and not merely "some grant row exists somewhere", is the
# point: with the weaker rule an administrator who was demoted stays re-promotable
# for ever on the row that authorised the FIRST promotion — one approval, unlimited
# grants. `granted_at` defaults to `transaction_timestamp()`, which is one value
# for a whole transaction and a different one in the next, and the trigger compares
# against it.
#
# The SQL below is taken from migration 12's header and identity's README, which
# are the maintained copies. It is not paraphrased here.
#
# ── WHY THIS SCRIPT IS STILL RE-RUNNABLE AND THE DATABASE IS STILL ONE-SHOT ───
#
# Those are different claims and both are true. `platform_role_grants_one_bootstrap`
# is a PARTIAL unique index on `source = 'bootstrap'`, so a second bootstrap grant
# is refused for ever, from any client, including a psql prompt — 23505. But this
# script's main job is minting the 10-minute service tokens in section 5, and that
# has to be re-runnable several times an hour. So the promotion is CONDITIONAL:
# already-bootstrapped is a no-op that says so, which is precisely what migration
# 12 says an already-bootstrapped environment should do — "nothing, deliberately".
#
# The one-shot property is then ASSERTED rather than assumed, below.
#
# The old note here said "if identity ever grows a real bootstrap, delete this
# block". It has, and this IS that bootstrap — the step is permanent, so the note
# is gone rather than left pointing at work that is finished.
psql_identity() {
  docker compose -f "$COMPOSE" exec -T postgres \
    psql -qtA -v ON_ERROR_STOP=1 -U cloudsforge -d identity "$@" 2>&1
}

# Migration 12 must have run. Without the table every check below would "pass" by
# erroring in a way the old code discarded with `>/dev/null 2>&1` — which is how a
# promotion that never happened looked identical to one that did.
if [ "$(psql_identity -c "select to_regclass('platform_role_grants') is not null;" | tr -d '[:space:]')" = "t" ]; then
  ok "identity migration 12 is applied — platform_role_grants exists"
else
  bad "platform_role_grants is missing: identity has not run migration 12, so no administrator can be created"
  echo "$fails failure(s); nothing was bootstrapped"; exit 1
fi

granted=$(psql_identity -c "select count(*) from platform_role_grants where source = 'bootstrap';" | tr -d '[:space:]')
if [ "${granted:-0}" = "0" ]; then
  # The verbatim shape from migration 12's header. `lower(btrim(...))` because
  # identity normalises on write and matching the raw string would miss the row.
  if psql_identity -c "
begin;
insert into platform_role_grants (user_id, role, source, actor, reason)
select id, 'admin', 'bootstrap', 'estate-bootstrap.sh',
       'first operator of this environment; no approval queue can exist before one'
  from users where email = lower(btrim('$ADMIN_EMAIL'));
update users set roles = array['player','admin']
 where email = lower(btrim('$ADMIN_EMAIL'));
commit;" >/tmp/estate-bootstrap-promote.log 2>&1; then
    ok "promoted $ADMIN_EMAIL: grant row and roles update, in ONE transaction"
  else
    bad "the bootstrap transaction was refused: $(head -c 300 /tmp/estate-bootstrap-promote.log)"
  fi
else
  ok "already bootstrapped ($granted grant row) — the promotion is a no-op, by design"
fi

# The promotion is confirmed by READING IT BACK, not by psql's exit status. A
# transaction whose SELECT matched no user commits happily and promotes nobody:
# `insert ... select` over zero rows is not an error, and neither is an UPDATE
# that matches nothing. That silent pair is the failure this asserts away.
holds=$(psql_identity -c "select 'admin' = any(roles) from users where email = lower(btrim('$ADMIN_EMAIL'));" | tr -d '[:space:]')
[ "$holds" = "t" ] \
  && ok "$ADMIN_EMAIL holds the admin role, read back from the database" \
  || bad "$ADMIN_EMAIL does not hold admin after the bootstrap (read back: '${holds:-no such user}')"

# ── THE ASSERTION THAT MAKES THE ONE-SHOT REAL ────────────────────────────────
#
# A control nobody exercises is a control nobody has. This attempts a SECOND
# bootstrap grant and requires the database to refuse it with SQLSTATE 23505 —
# the partial unique index — and it checks the CODE, not the message text, which
# is why `VERBOSITY verbose` is set.
#
# Wrapped in a transaction that is rolled back, so the assertion leaves nothing
# behind. The index is a plain unique index and fires on the INSERT itself rather
# than at commit, so the rollback costs the assertion nothing.
#
# Ordered AFTER the promotion above on purpose: run against a database that has
# not been bootstrapped yet, this insert would SUCCEED, and the assertion would be
# testing the opposite of what it claims.
# Fed on STDIN, not `-c`. `psql -c` treats its whole argument as SQL, so a
# leading `\set VERBOSITY verbose` is parsed as part of the statement and psql
# answers `unrecognized value "verbosebegin;insert…" for "VERBOSITY"` — which is
# an error, so a naive check for "did this fail" would have passed for entirely
# the wrong reason. Caught by running it; the assertion now reads the SQLSTATE it
# claims to read.
second=$(docker compose -f "$COMPOSE" exec -T postgres \
  psql -qtA -U cloudsforge -d identity 2>&1 <<SQL
\set VERBOSITY verbose
begin;
insert into platform_role_grants (user_id, role, source, actor, reason)
select id, 'admin', 'bootstrap', 'estate-bootstrap.sh', 'a second bootstrap, which must be refused'
  from users where email = lower(btrim('$ADMIN_EMAIL'));
rollback;
SQL
)
if printf '%s' "$second" | grep -q '23505'; then
  ok "a second bootstrap is refused by the database — SQLSTATE 23505, from a psql prompt"
else
  bad "a second bootstrap was NOT refused; the estate can mint unlimited unapproved administrators: $(printf '%s' "$second" | head -c 300)"
fi

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
#
# ── THE SCOPES ARE NO LONGER WRITTEN HERE ─────────────────────────────────────
#
# Each line is now `VAR|service|scopes`, where an EMPTY scopes field means "this
# service's whole derived grant". The variable NAMES stay hand-written because
# they are genuine deploy facts — each compose service reads one specific name,
# and `BILLING_LEDGER_TOKEN` and `COMMUNITY_SERVICE_CREDENTIAL` are not derivable
# from anything. The SCOPES are read from `IDENTITY_SERVICE_TOKEN_GRANTS`, which
# `scripts/derive-grants.mjs` generates from the services themselves.
#
# This is not tidying. The hand-written scopes here had drifted from the grant
# map they must be a subset of, and identity refuses a mint outside the allowlist
# — so `NDA_SERVICE_TOKEN` asking for `worlds:read,worlds:write` (nda's grant is
# now `billing:read,worlds:title`) would simply have failed, and this script's
# only signal would have been a `bad` line in a wall of output. Two copies of a
# subset relation, maintained by hand, in the same file.
#
# `hub-api` KEEPS ITS SIX EXPLICIT NARROW LINES, and that is the whole reason the
# empty-field convention exists rather than always using the full grant. Its six
# tokens are the AD-05 separation: an attacker reaching that process should find
# six narrow read tokens, not one that can move money. Collapsing them into one
# whole-allowlist token would trade that away for a shorter file.
#
# `analytics` is GONE from this list. It has no grant, because it makes no
# outbound service call — `ANALYTICS_TOKEN` is an inbound `/metrics` secret and
# was never an identity-minted token. Asking identity to mint one produced a
# token that opened nothing.
# ── ELEVEN LINES REMOVED, AND WHY THIS IS A SECRET FIX AND NOT A TIDY-UP ──────
#
# `WALLET_SERVICE_TOKEN`, `WORLDS_SERVICE_TOKEN`, `MINT_SERVICE_TOKEN`,
# `NDA_SERVICE_TOKEN`, `BILLING_LEDGER_TOKEN` and hub-api's six were all still
# being minted for services that RETIRED them. Each of those repositories now
# holds a long-lived `*_IDENTITY_CREDENTIAL` and exchanges it at
# POST /service-tokens/exchange, and each detects the old variable only to
# complain about it: `legacyServiceTokenPresent` in its env.ts, and an ERROR line
# at boot — "WORLDS_SERVICE_TOKEN is set and is IGNORED". Four of those errors
# were read off the running containers of this estate, not inferred.
#
# So every run of this script was minting ELEVEN REAL, LIVE JWTs that nothing
# would ever present, and writing them to disk. A credential that no code reads
# is not a harmless leftover: it is a bearer token with a real `sub` and real
# scopes, sitting in a file, whose only remaining function is to be stolen. The
# smallest possible blast radius for a secret is not to have minted it.
#
# What stays is what a service still calls `requiredSecret` on — checked in each
# repository's env.ts rather than assumed from the variable's name:
#   settlement, market, trade, admin-api  still read a 10-minute token.
#   community                             reads a long-lived CREDENTIAL.
#   tessera, emberkin                     read a 10-minute token; see below.
#   ledger                                reads a long-lived CREDENTIAL; see below.
#
# `emberkin` is on this list for exactly tessera's reason and was checked the same
# way rather than assumed from the variable's name: `emberkin/src/index.ts:60` is
# `const token = (): string => env.serviceToken`, so the value is PRESENTED as a
# bearer and must be a JWT. `EMBERKIN_IDENTITY_CREDENTIAL` is also minted, by 5b,
# and handing that to it instead would 401 every one of its three upstreams.
#
# ── LEDGER IS OFF THIS LIST AGAIN, AND THIS TIME IT IS THE FIX ────────────────
#
# It was added here because `ledger/src/jobs.ts:251` calls the indexer's custody
# aggregate and nothing was handing it a bearer: the call went out
# unauthenticated, the indexer answered 401, ledger mapped that to `undefined`,
# the run was UNOBSERVED, and EMBER froze — on an authentication error, while
# reporting the same state it correctly reports when no chain is followed.
#
# Handing it a token from this list fixed that for exactly 600 seconds. The token
# minted here lives 600s (identity/src/tokens.ts:28) and ledger's reconciliation
# job runs every 900s (`ledger/src/jobs.ts:108`), so it authenticated on the first
# run after a bootstrap and never again. Ledger was the one service on that cliff
# whose credential is used AFTER it — settlement, market and trade are driven on
# request paths inside the window; a background job on a 900s timer cannot be.
#
# So the entry is deleted rather than renewed. `ledger/src/env.ts:362` now reads
# `LEDGER_IDENTITY_CREDENTIAL` and exchanges it per call, and section 5b below
# already mints that credential for every service in the grants map — ledger
# included, with no edit here, which is the point of deriving SERVICES from the
# grants rather than listing them. Leaving the line in would keep minting a real,
# live JWT with a real `sub` and real scopes, writing it to disk, for no reader:
# the smallest blast radius for a secret is not to have minted it.
#
# The GRANT was never the missing piece and must not be added by hand — ledger
# declares `INDEXER_SCOPES = ['indexer:read']` in its own source and
# `derive-grants.mjs` picked it up on its next run. A grant says what identity MAY
# mint; this list is what a service is actually HANDED.
# hub-api's six narrow tokens are gone because hub-api itself retired them, NOT
# because the AD-05 separation they expressed was wrong; its credential is
# exchanged for tokens per upstream and the narrowing moved into that exchange.
#
# ── TESSERA IS ON THIS LIST, AND THE VARIABLE'S NAME LIES ─────────────────────
#
# `TESSERA_SERVICE_CREDENTIAL` is spelled like community's long-lived credential
# and is NOT one. `tessera/src/index.ts:127` presents the value straight through
# as a bearer — `token: async () => env.serviceCredential ?? ''` — under a header
# that says "until this service is granted a credential in the deploy, the
# credential IS the token". So it must be minted here, as a TOKEN, or the Kiln
# sends studio a bearer that is not a JWT and gets 401 with nothing in either log
# naming the cause. It is the same variable-name trap the comment above records
# for community, in the opposite direction, which is why the SCOPES are derived
# and only the NAME is hand-written: names are deploy facts, authority is not.
#
# The ten-minute expiry is real and is not papered over: a firing attempted more
# than ten minutes after a bootstrap 401s until the next run. The fix is
# micro-tessera adopting `ServiceTokenProvider`, which its own comment names.
#
# ── FORESIGHT IS ON THIS LIST, AND ITS CLIFF IS THE WORST OF THE THREE ────────
#
# Checked the same way, not assumed from the variable's name: `foresight/src/
# index.ts:101` is `const token = () => env.serviceToken`, handed straight to the
# `HttpClient` for custody, the indexer, the ledger, policy and admin-api. There
# is no `ServiceTokenProvider`, no `/service-tokens/exchange` call and no `cfsc_`
# handling anywhere in `foresight/src`. So the value is PRESENTED and must be a
# ten-minute JWT; `FORESIGHT_IDENTITY_CREDENTIAL` (which 5b mints, and which sits
# in this same file looking like the obvious answer) would 401 all five.
#
# Unlike tessera's and emberkin's, foresight's custody calls come from LEASED
# BACKGROUND JOBS — `market.deploy` and `resolution.post`. That is exactly the
# shape that froze EMBER through `ledger`: a 600-second token behind a longer
# timer. A market approved eleven minutes after a bootstrap sits unfinished until
# the next one. Recorded rather than papered over; micro-foresight owns the fix
# and `index.ts:101` is already the seam for it.
CREDENTIALS="
SETTLEMENT_SERVICE_TOKEN|settlement|
MARKET_SERVICE_TOKEN|market|
TRADE_SERVICE_TOKEN|trade|
COMMUNITY_SERVICE_CREDENTIAL|community|
ADMIN_API_SERVICE_TOKEN|admin-api|
TESSERA_SERVICE_CREDENTIAL|tessera|
EMBERKIN_SERVICE_TOKEN|emberkin|
FAUCET_CUSTODY_TOKEN|faucet|
FORESIGHT_SERVICE_TOKEN|foresight|
"

# The grants, read from the compose file the estate actually runs with. `python3`
# is already this script's JSON tool; `jq` is not a dependency anywhere here.
GRANTS_JSON=$(python3 - "$COMPOSE" <<'PY'
import re, sys, json
text = open(sys.argv[1]).read()
m = re.search(r'IDENTITY_SERVICE_TOKEN_GRANTS: >-\n((?:\s{8,}\S.*\n)+)', text)
if not m:
    print('{}'); sys.exit(0)
print(json.dumps(json.loads(re.sub(r'\s+', ' ', m.group(1)))))
PY
)
if [ "$GRANTS_JSON" = "{}" ] || [ -z "$GRANTS_JSON" ]; then
  bad "could not read IDENTITY_SERVICE_TOKEN_GRANTS out of $COMPOSE — nothing can be minted"
  echo "$fails failure(s); nothing was bootstrapped"; exit 1
fi

# The services that have a grant. Derived, so a service added to the map gets a
# credential on the next run without anybody remembering to edit a second list.
SERVICES=$(printf '%s' "$GRANTS_JSON" | python3 -c "import sys,json;print(' '.join(sorted(json.load(sys.stdin))))")
ok "read grants for $(printf '%s' "$SERVICES" | wc -w | tr -d ' ') service(s) from $COMPOSE"

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
  # An empty scopes field means "this service's whole derived grant"; anything
  # else is a deliberate narrowing, which is hub-api's six tokens and only those.
  # identity de-duplicates but never widens, so asking narrowly is what makes a
  # least-privilege call site actually least-privilege.
  json_scopes=$(GRANTS="$GRANTS_JSON" SERVICE="$service" SCOPES="$scopes" python3 -c "
import os, sys, json
scopes = [s for s in os.environ['SCOPES'].strip().split(',') if s]
if not scopes:
    scopes = json.loads(os.environ['GRANTS']).get(os.environ['SERVICE'], [])
print(json.dumps(scopes))")
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
# SERVICES is derived above from IDENTITY_SERVICE_TOKEN_GRANTS. It used to be a
# twelve-name list here, and it was the third place in this repository holding a
# copy of "which services exist" — it named `analytics`, which needs no token,
# and omitted `beacon`, `custody`, `emberkin`, `faucet` and `foresight`, two of
# which were stranded on the expiring-token seam precisely because they had no
# credential to exchange.

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

echo "── 5c. event subscriptions — WHO RECEIVES WHAT IS DEPLOY CONFIGURATION ──"
#
# No route in any service creates a subscription, deliberately: which consumer
# receives which topic is a deployment decision, not something a caller makes at
# runtime. The deploy is this script, so this is where the rows belong — they
# were previously seeded by `estate-verify.sh`, which meant the estate only had a
# working event bus while a verification was running.
#
# A row lives in the PRODUCER's database, because that is where the outbox and its
# relay are. `on conflict do nothing` against the (topic, url) unique constraint
# makes a re-run a no-op.
#
# ── ONE CONSUMER THAT CANNOT BE SUBSCRIBED, AND ONE THAT NOW CAN ──────────────
#
# **The relay cannot authenticate, so a consumer that demands a token can never
# be fed by the bus.** `identity/src/outbox.ts:325` sends exactly two headers —
# `cf-signature` and `cf-event-id` — and `event_subscriptions` has no column for a
# credential (topic, url, active, created_at; identity/src/migrations.ts:58).
#
#   * **analytics** `POST /ingest` still calls `authenticate(ctx, deps)` then
#     `requireExactScope(principal, SCOPE_INGEST)` before it reads a byte
#     (analytics/src/server.ts:468-469). STILL NOT SUBSCRIBED. Seeding it here
#     once gave `attempts=67, last_error=POST http://analytics:4000/ingest → 401`
#     and an empty inbox — measured, not predicted.
#
#   * **admin-api** `POST /v1/events` USED TO demand `admin:audit:write` and no
#     longer does. micro-admin-api removed the bearer check because "no outbox
#     relay in this estate can present a bearer, and this service was additionally
#     verifying a signature format nobody sends, so the mirror received nothing at
#     all" (admin-api/src/server.ts:25-35). It now verifies the body with
#     `verifyDelivery` against OUTBOX_SIGNING_SECRET, over the exact bytes
#     received, BEFORE `JSON.parse` — which is precisely what the relay sends. So
#     the audit mirror is subscribable, and is subscribed below.
#
# The remaining fix — a credential per subscription — belongs to micro-identity's
# outbox and micro-analytics. Recorded rather than half-configured.
subscribe() {
  db=$1; topic=$2; url=$3
  docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d "$db" -c \
    "insert into event_subscriptions (topic, url) values ('$topic', '$url') on conflict do nothing" \
    >/dev/null 2>&1 \
    && ok "$db → $topic → $url" \
    || bad "could not seed $topic → $url in $db"
}

# identity.user.registered had NO SUBSCRIBER, and two services classify it:
# activity turns it into a feed record (activity/src/classify.ts:190) and
# analytics counts it as "the denominator of every onboarding cohort"
# (analytics/src/catalogue.ts:307). Both were consumers with no producer.
#
# Only activity is subscribed. analytics is one of the two consumers the relay
# cannot authenticate to — see above. Its onboarding denominator stays zero, and
# that is now a named gap in another repository rather than a silence here.
subscribe identity identity.user.registered http://activity:4000/ingest

# The two estate-verify already relied on, moved to where a deploy belongs. They
# stay idempotent, so the copies still in the verifier are no-ops.
subscribe identity identity.session.created http://activity:4000/ingest
subscribe identity identity.user.deleted   http://activity:4000/ingest
subscribe identity identity.user.deleted   http://notify:4000/ingest

# ── WALLET'S INBOX WAS FED BY NOBODY ──────────────────────────────────────────
#
# `wallet/src/server.ts:441` serves `POST /events` and branches on exactly three
# topics — `indexer.deposit.confirmed`, `settlement.outbound.confirmed` and
# `settlement.outbound.failed`. Not one row in any producer's
# `event_subscriptions` pointed at `http://wallet:4000/events`. Queried, not
# assumed: settlement's table held five rows, all for admin-api and analytics;
# indexer's database had no such table at all.
#
# So the two seams that MOVE A USER'S MONEY had no delivery path. A confirmed
# deposit never credited a balance and a completed withdrawal never settled its
# reservation, and both failed by silence — wallet answered /readyz, the
# producers wrote their outbox rows, and nothing connected the two. This is the
# same shape as `identity.user.registered` above: a consumer with no producer,
# invisible because every individual part was healthy.
#
# It also went unnoticed because wallet's intake was refusing the contract's
# signature until tonight, so seeding these rows earlier would have produced a
# retry storm of 401s rather than a working seam — the defect masked its own
# wiring.
subscribe indexer    indexer.deposit.confirmed     http://wallet:4000/events
subscribe settlement settlement.outbound.confirmed http://wallet:4000/events
subscribe settlement settlement.outbound.failed    http://wallet:4000/events

echo "── 5d. the audit mirror — admin-api subscribes to the audited topics ────"
#
# Claim 9 of the eleven "one platform" tests — an operator answers "where did this
# user's money go" from admin-web alone — passes end to end once these rows exist.
#
# THE MIRROR CONSUMES THE EXISTING DOMAIN TOPICS. A parallel `*.audit.recorded`
# stream was considered and rejected: `action` IS the topic name
# (contracts/packages/events/src/audit.ts, `AuditMirrorRow.action`), so a second
# stream would be a second call site that can disagree with the first, and the
# disagreement would be invisible until a dispute turned on it.
#
# The list is READ FROM THE CONTRACT, not written here. `AUDITED_TOPICS` is
# derived in contracts from `TOPIC_AUDIT[...].audited`, and a topic that becomes
# audited must not need a second edit in this file to be mirrored — that is the
# same class of second copy the grant map was.
AUDIT_CONTRACT=${AUDIT_CONTRACT:-../contracts/packages/events/src/audit.ts}
audited=$(python3 - "$AUDIT_CONTRACT" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
block = text[text.index('TOPIC_AUDIT'):]
# Braces are balanced explicitly rather than matched with `\{([^}]*)\}`, which
# stops at the first inner `}` and would read the wrong body the moment a spec
# object gains a nested one. Checked against the contract's own AUDITED_TOPICS
# export and agrees exactly — the count is 30 as of this commit, and it moved
# from 28 while this change was being written, which is precisely why the list
# is read from the contract instead of being written down here.
topics = []
for m in re.finditer(r"'([a-z][a-z0-9.]+)':\s*\{", block):
    i = block.index('{', m.end() - 1)
    depth = 0
    for j in range(i, len(block)):
        if block[j] == '{':
            depth += 1
        elif block[j] == '}':
            depth -= 1
            if depth == 0:
                break
    if re.search(r'\baudited:\s*true', block[i:j]):
        topics.append(m.group(1))
print('\n'.join(sorted(set(topics))))
PY
)
audited_count=$(printf '%s\n' "$audited" | grep -c . || true)
# A floor, for the reason estate-scopes.mjs gives about set differences: a parser
# that silently returned nothing would subscribe admin-api to NOTHING and this
# step would report a cheerful zero failures.
if [ "${audited_count:-0}" -ge 26 ]; then
  ok "read $audited_count audited topic(s) from the contract"
else
  bad "parsed only ${audited_count:-0} audited topics from $AUDIT_CONTRACT — the parser is broken, not the contract"
fi

# A row lives in the PRODUCER's database, because that is where the outbox and its
# relay are. The producer is the topic's first segment, which is not a convention
# this file invents: contracts requires `<service>.<aggregate>.<past-tense-verb>`.
#
# `subscribe_all <consumer-name> <url> <topics…>` — a producer that is not deployed
# in THIS estate has no database to hold the row, and a topic with no backend
# producer at all (the `web.*` family, which frontends emit) has none either. Both
# are NAMED as skipped rather than silently dropped or noisily failed.
subscribe_all() {
  consumer=$1; url=$2; shift 2
  count=0
  missing=""
  for topic in "$@"; do
    db=$(printf '%s' "$topic" | cut -d. -f1)
    if docker compose -f "$COMPOSE" exec -T postgres \
         psql -qtA -U cloudsforge -d postgres \
         -c "select 1 from pg_database where datname = '$db'" 2>/dev/null | grep -q 1; then
      docker compose -f "$COMPOSE" exec -T postgres psql -q -U cloudsforge -d "$db" -c \
        "insert into event_subscriptions (topic, url) values ('$topic', '$url') on conflict do nothing" \
        >/dev/null 2>&1 && count=$((count+1)) \
        || bad "could not subscribe $consumer to $topic in $db"
    else
      missing="$missing $topic"
    fi
  done
  ok "$consumer subscribed to $count topic(s) → $url"
  [ -n "$missing" ] && ok "  not subscribed, producer not deployed here:$missing" || true
}

subscribe_all admin-api http://admin-api:4000/v1/events $audited

# ── ANALYTICS, WHICH COULD NOT BE SUBSCRIBED UNTIL NOW ────────────────────────
#
# `POST /ingest` used to call `authenticate()` and demand `analytics:ingest`
# before it read a byte, which no relay could satisfy — seeding it here once gave
# `attempts=67, last_error=… → 401` and an empty inbox. micro-analytics has since
# made the route MAC-only, verifying the delivery signature over the raw bytes,
# so its subscriptions are real for the first time.
#
# Its topic list is its own (`EVENT_TOPICS`, analytics/src/catalogue.ts:343),
# derived from the catalogue rather than repeated here — it overlaps the audited
# set but is not the same list, and neither is a subset of the other.
analytics_topics=$(python3 - "${ANALYTICS_CATALOGUE:-../analytics/src/catalogue.ts}" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError:
    sys.exit(0)
block = text[text.index('const EVENTS'):]
print('\n'.join(sorted({m.group(1) for m in re.finditer(r"^\s{2}'([a-z][a-z0-9.]+)':", block, re.M)})))
PY
)
if [ -n "$analytics_topics" ]; then
  subscribe_all analytics http://analytics:4000/ingest $analytics_topics
else
  bad "could not read EVENT_TOPICS from analytics' catalogue — analytics stays unsubscribed"
fi

echo "── 5e. the faucet's own custody address — minted once, then reused ──────"
#
# ── WHY THIS IS A BOOTSTRAP STEP AND NOT A COMPOSE VALUE ─────────────────────
#
# `micro-faucet` holds NO key. It sends an unsigned legacy transfer to
# `micro-custody` and receives bytes back (`faucet/src/custodyclient.ts`), so what
# the deploy has to supply is not a secret but an ADDRESS — plus the two fields
# custody binds it to. That address cannot be written into the compose file
# because it does not exist until custody derives it, and it cannot be derived
# here because `POST /v1/addresses` takes the next BIP-44 index off a seed whose
# state lives in custody's database.
#
# ── IT MUST BE THE FAUCET'S OWN, AND NOT THE PINNED TREASURY ─────────────────
#
# custody's pinned `(ember, testnet)` treasury is SETTLEMENT'S. Signing the
# faucet's drips out of it would put two services on one nonce, which
# `settlement/src/worker.ts:8-18` exists because is how a payment is permanently
# lost. So this mints a SECOND treasury-purpose address. That is allowed and is
# not a second pin: `getTreasuryPin` is consulted only for `purpose: 'deposit'`
# (`custody/src/keys.ts:307`), so the pin plays no part in signing a transfer.
#
# ── AND IT MUST NOT MINT A NEW ONE EVERY RUN ────────────────────────────────
#
# `POST /v1/addresses` was NOT idempotent when this was written — every call
# derived a fresh index and returned a different address. This script runs several
# times an hour, so minting unconditionally would strand the faucet's balance on a
# previous address after every bootstrap and leave a trail of funded keys nothing
# can spend. The lookup below is therefore the primary path and the mint is the
# exception: an address is REUSED when one already carries this (userId, orderId)
# binding.
#
# Custody gained idempotency on 2026-08-04 (migration 6: `custody_keys_binding_uniq`
# and `custody_keys_idempotency_uniq`, with the duplicate-key violation as the
# correctness path rather than a lookup). A repeat now answers 200 with
# `reused: true` instead of minting. **The lookup below stays.** It is no longer
# load-bearing for correctness, but this script parses status-agnostically and is
# unaffected either way, and a bootstrap that depends on the server having been
# migrated is a bootstrap that fails on a fresh estate — which is the one case it
# exists for.
#
# The binding fields are read out of the compose file rather than repeated here.
# custody compares seven identity fields character for character and its 403
# deliberately does not name the one that disagreed (`custody/src/keys.ts:277`),
# so a second hand-typed copy of `faucet-estate-treasury-1` would be a 403 that
# cannot be debugged from any response.
#
# ── ONE FUNCTION, BECAUSE THERE ARE NOW THREE OF THESE ──────────────────────────
#
# `custody_address <purpose> <userId> <orderId> <minting-service> <what>` sets
# `CUSTODY_ADDR` to a reused or freshly minted `(ember, testnet)` address, and to
# the empty string on failure. A global rather than stdout: `ok`/`bad` print to
# stdout, and a helper that both reported and returned would have to choose one.
#
# `<minting-service>` is the service whose GRANT is asked for the one-off
# `custody:address:create` token. It is a parameter rather than a constant
# because the honest answer differs per caller and the difference is a real
# least-privilege decision: see each call site.
custody_address() {
  cad_purpose=$1; cad_user=$2; cad_order=$3; cad_service=$4; cad_what=$5
  CUSTODY_ADDR=""

  # The operator surface, which serves userId and orderId. The SIGNING surface
  # deliberately does not (`GET /v1/addresses/:address` publishes existence and
  # placement only), because publishing the binding under the same credential
  # that uses it would make the /sign check circular.
  CUSTODY_ADDR=$(curl -s "$CUSTODY/v1/admin/keys" -H "authorization: Bearer $utok" | \
    USER_ID="$cad_user" ORDER_ID="$cad_order" PURPOSE="$cad_purpose" python3 -c "
import sys, json, os
try: keys = json.load(sys.stdin).get('keys', [])
except Exception: keys = []
for k in keys:
    if (k.get('userId') == os.environ['USER_ID'] and k.get('orderId') == os.environ['ORDER_ID']
            and k.get('purpose') == os.environ['PURPOSE'] and k.get('chain') == 'ember'
            and k.get('network') == 'testnet'):
        print(k['address']); break" 2>/dev/null)

  if [ -n "$CUSTODY_ADDR" ]; then
    ok "$cad_what already exists: $CUSTODY_ADDR"
    return 0
  fi

  cad_tok=$(curl -s -X POST "$IDENTITY/service-tokens" \
    -H "authorization: Bearer $utok" -H 'content-type: application/json' \
    -d "{\"service\":\"$cad_service\",\"scopes\":[\"custody:address:create\"]}" | jsonfield token)
  if [ -z "$cad_tok" ]; then
    bad "identity would not mint custody:address:create for $cad_service — no $cad_what"
    return 1
  fi
  cad_created=$(curl -s -X POST "$CUSTODY/v1/addresses" \
    -H "authorization: Bearer $cad_tok" -H 'content-type: application/json' \
    -d "{\"chain\":\"ember\",\"network\":\"testnet\",\"purpose\":\"$cad_purpose\",\"scheme\":\"hd_bip44\",\"userId\":\"$cad_user\",\"orderId\":\"$cad_order\"}")
  CUSTODY_ADDR=$(printf '%s' "$cad_created" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('key', {}).get('address', ''))
except Exception: print('')" 2>/dev/null)
  if [ -n "$CUSTODY_ADDR" ]; then
    ok "minted $cad_what ($cad_purpose): $CUSTODY_ADDR"
  else
    bad "custody would not mint $cad_what: $(printf '%s' "$cad_created" | head -c 200)"
    return 1
  fi
}

faucet_user=$(grep -m1 'FAUCET_CUSTODY_USER_ID:' "$COMPOSE" | sed 's/.*: *//')
faucet_order=$(grep -m1 'FAUCET_CUSTODY_ORDER_ID:' "$COMPOSE" | sed 's/.*: *//')
if [ -z "$faucet_user" ] || [ -z "$faucet_order" ]; then
  bad "could not read the faucet's custody binding out of $COMPOSE — the faucet cannot sign"
else
  # Minted under `wallet`'s grant rather than the faucet's own, which is
  # `custody:sign:treasury` and nothing else. The faucet does not provision its
  # own key and must not be able to: an address-creating faucet is a faucet that
  # can mint itself a fresh unfunded signer and report a balance problem as a
  # configuration one.
  custody_address treasury "$faucet_user" "$faucet_order" wallet "the faucet's treasury address"
  faucet_addr=$CUSTODY_ADDR

  # Appended to the tokens file so section 6's `--env-file` hands it to the
  # container. It is NOT a secret — the address is public on chain the moment the
  # first drip lands, and `GET /v1/faucet` publishes it deliberately so an
  # operator can top the faucet up — but it belongs in the same generated file as
  # the tokens because it is generated by the same run and consumed the same way.
  if [ -n "$faucet_addr" ]; then
    echo "FAUCET_FUNDING_ADDRESS=$faucet_addr" >> "$TOKENS_FILE"
  fi
fi

echo "── 5f. foresight's oracle and treasury addresses ────────────────────────"
#
# Two more addresses that cannot be compose values, for section 5e's reason
# exactly: neither exists until custody derives it off a BIP-44 seed whose state
# lives in custody's own database. `foresight/src/env.ts` makes both REQUIRED and
# validates the 0x-prefixed 20-byte shape, and `ForesightMarket`'s constructor
# reverts `BadConstruction` on a zero oracle or a zero treasury — so the
# placeholders in the compose file boot the service and cannot produce a working
# market. Fail-closed, exactly as `FAUCET_FUNDING_ADDRESS` is.
#
# ── THE ORACLE IS `purpose: deployer`, AND THAT IS NOT A MISTAKE ──────────────
#
# `custody/src/gates.ts:35` has three signable purposes and none of them signs a
# contract CALL: `transfer` requires empty calldata and says in terms that
# widening it would turn the key into a signing oracle. So foresight's oracle
# resolves a market by CREATING a contract — `ForesightResolver`, whose
# constructor calls `oracleAct` and which then deploys with no runtime code — and
# the market checks `msg.sender == createAddress(oracle, nonce)`, which is
# exactly as strong as checking the oracle address itself
# (`foresight/src/resolve.ts:19-33`, `ForesightMarket._isOracle`). A
# `treasury`-purpose oracle would be refused by custody's shape gate at the first
# resolution, with a market's winners waiting on it.
#
# **THE ORACLE NEEDS GAS.** It broadcasts a real creation transaction per
# resolution. A freshly derived address holds nothing, so an unfunded oracle is a
# market that resolves in the database and never on chain. That top-up is an
# operator act on this testnet (`scripts/ember-seed.js` holds the only funding
# key and deliberately does not spend it for anything but the custody seed set),
# and it is named here rather than left to be discovered from a stuck job.
#
# ── THE MINTING SERVICE IS `foresight` ITSELF, UNLIKE THE FAUCET ──────────────
#
# `custody:address:create` IS in foresight's derived grant — it mints a deployer
# address per market at `deploy.ts:340` and must be able to. So asking under its
# own name here is honest, where asking under `wallet` for the faucet was the
# point (the faucet has no such grant and must not).
foresight_user=$(grep -m1 'FORESIGHT_ORACLE_USER_ID:' "$COMPOSE" | sed 's/.*: *//')
foresight_order=$(grep -m1 'FORESIGHT_ORACLE_ORDER_ID:' "$COMPOSE" | sed 's/.*: *//')
if [ -z "$foresight_user" ] || [ -z "$foresight_order" ]; then
  bad "could not read foresight's oracle binding out of $COMPOSE — no market can resolve"
else
  custody_address deployer "$foresight_user" "$foresight_order" foresight "foresight's oracle address"
  [ -n "$CUSTODY_ADDR" ] && echo "FORESIGHT_ORACLE_ADDRESS=$CUSTODY_ADDR" >> "$TOKENS_FILE"

  # The settlement fee's destination, bound into every market at deploy time.
  # `purpose: treasury` and a DIFFERENT orderId from the oracle's: one address
  # per role, because custody binds seven fields per key and a shared row would
  # put the fee and the oracle on one nonce — `settlement/src/worker.ts:8-18`'s
  # lesson. It never signs anything here; `ForesightMarket.settle()` pushes to it
  # permissionlessly, and it is an EOA rather than a contract precisely because a
  # reverting treasury is how a market becomes unsettleable.
  custody_address treasury "$foresight_user" foresight-estate-treasury-1 foresight "foresight's treasury address"
  [ -n "$CUSTODY_ADDR" ] && echo "FORESIGHT_TREASURY_ADDRESS=$CUSTODY_ADDR" >> "$TOKENS_FILE"
fi

echo "── 6. hand the tokens to the services that need them ────────────────────"
# `--env-file` rather than `env_file:` on each service. The compose file names
# each variable on exactly the service that reads it, so this fills those in
# without handing every container the whole estate's secrets — the fan-out that
# pricing/src/env.ts calls out by name.
# `--wait`, not a bare `up -d`. Without it this returns as soon as the daemon has
# ACCEPTED the recreate, and a verification started immediately afterwards asks a
# service that is still booting: `nda /livez` and `nda /readyz` both failed here
# once for exactly that reason, on a container that was healthy forty seconds
# later. A start-order race that reads as a flaky estate is the most expensive
# kind of green-then-red there is.
if docker compose --env-file "$TOKENS_FILE" -f "$COMPOSE" up -d --wait >/tmp/estate-bootstrap-up.log 2>&1; then
  ok "services recreated with real credentials"
else
  bad "recreate failed; see /tmp/estate-bootstrap-up.log"
  tail -20 /tmp/estate-bootstrap-up.log
fi

echo "── 7. seed the product surfaces ─────────────────────────────────────────"
#
# ── WHY SEEDING IS A BOOTSTRAP STEP ───────────────────────────────────────────
#
# A freshly deployed estate does not merely lack credentials, it lacks CONTENT.
# Foresight opens with no questions, Market with no listings, Mint with no
# orders — and an operator looking at five empty product surfaces cannot tell a
# working deployment from a broken one. That is the same class of problem as the
# first administrator: something a new environment cannot produce for itself and
# which therefore has to be an explicit, named step somebody runs.
#
# ── WHY IT IS ITS OWN SCRIPT AND NOT ANOTHER SECTION HERE ─────────────────────
#
# It will grow. Every service the estate gains that has a surface will want a few
# honest rows, and this file is already nine hundred lines of credential
# machinery that nobody should have to scroll past to find a seeded market. The
# domains live in `scripts/seed/`, one file each, and each states its own
# idempotency discriminator and its own refusals.
#
# ── IT IS ADDITIVE, SO IT CANNOT FAIL A BOOTSTRAP ─────────────────────────────
#
# A bootstrap that went red because a marketplace could not be filled would be
# reporting a content problem as a credential problem, and the next person would
# learn to ignore the red. So the seeder's exit code is REPORTED here and does
# not touch `fails`. Everything above this line is what makes the estate work;
# this is what makes it worth looking at.
#
# `CF_SEED_SKIP=1` skips it, for a bootstrap run purely to renew the ten-minute
# tokens — which is most of them.
#
# ── THE MISSING INTERPRETER USED TO BE A GREEN LINE, AND IT WAS THE WHOLE BUG ──
#
# This branch read:
#
#     elif ! command -v node >/dev/null 2>&1; then
#       ok "seeding skipped: no node on this machine (the seeder needs Node >= 22)"
#
# **The deployment host has no Node and never has.** So seeding was skipped on
# every bootstrap this estate has ever run, and the skip was reported as `ok`. On
# 2026-08-05 both live estates were measured with `foresight.markets` 0,
# `market.listings` 0, `market.collections` 0, `mint.tokens` 0,
# `community.communities` 0, `nda.worlds` 0 and `beacon.probes` 0 — five empty
# products, green for months, because a missing tool was reported as a decision.
#
# The distinction this now draws is between a skip somebody CHOSE (`CF_SEED_SKIP`,
# still `ok`) and a step that could not run (now `bad`). `scripts/node-tool.sh`
# tries to remove the cause first: it fetches one pinned, checksum-verified Node
# into `.tools/`, which needs no privilege and installs nothing system-wide. Only
# if that also fails does this fail, and then it says exactly what is missing.
if [ "${CF_SEED_SKIP:-0}" = "1" ]; then
  ok "seeding skipped (CF_SEED_SKIP=1)"
elif [ ! -x scripts/estate-seed.mjs ]; then
  bad "scripts/estate-seed.mjs is missing or not executable"
elif ! SEED_NODE=$(./scripts/node-tool.sh); then
  bad "no Node >= 22 could be found or fetched, so THE PRODUCT SURFACES WERE NOT SEEDED — see node-tool's output above. This used to be reported as a successful skip, which is how five surfaces stayed empty"
else
  # `$SEED_NODE`, not the shebang: on a host with no `node` on PATH the shebang
  # cannot resolve, and the interpreter node-tool just placed is in `.tools/`.
  # `estate-seed.mjs` re-execs itself with `process.execPath`, so the vendored
  # build carries through to the re-exec and to every domain module.
  if "$SEED_NODE" ./scripts/estate-seed.mjs; then
    ok "product surfaces seeded"
  else
    # Named, not swallowed. A surface that could not be filled is worth knowing
    # about; it is just not worth failing a credential bootstrap over.
    ok "seeding reported at least one failure — see its output above; the bootstrap itself is unaffected"
  fi

  # ── AND THEN IT IS ASKED, RATHER THAN ASSUMED ────────────────────────────────
  #
  # Seeding reporting success is not the same as a surface having content: every
  # domain above can legitimately report `skip`, and seven skips in a row is an
  # empty estate that printed no failures. `--check` reads each surface back
  # through the same front door a visitor uses and names the empty ones.
  #
  # It is REPORTED here and does not touch `fails`, for the reason this section
  # already gives — a credential bootstrap must not go red over content. The
  # check that does go red is `estate-verify.sh`, which calls the same mode.
  if "$SEED_NODE" ./scripts/estate-seed.mjs --check >/tmp/estate-seed-check.log 2>&1; then
    ok "every product surface has content"
  else
    ok "at least one product surface is still EMPTY after seeding — see /tmp/estate-seed-check.log; ./scripts/estate-verify.sh fails on this"
    grep -E 'is EMPTY|status page' /tmp/estate-seed-check.log | head -10
  fi
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
