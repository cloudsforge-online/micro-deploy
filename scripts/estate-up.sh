#!/usr/bin/env bash
# Bring the whole estate up, in the one order that works, and prove it.
#
#   cd deploy && ./scripts/estate-up.sh
#
# ── WHY THIS FILE EXISTS ───────────────────────────────────────────────────────
#
# `docker-compose.estate.yml`'s own header has told readers to run
# `./scripts/estate-up.sh` since the day it was written. THE FILE DID NOT EXIST.
# That is this estate's most-repeated defect wearing its usual costume — a
# document describing something other than reality — in the header of the file
# that starts everything.
#
# It also has real work to do now. Until the frontends and the gateway joined,
# "up" was one compose file and a bootstrap. It is now four compose files across
# two projects with a strict ordering, and an ordering that lives only in a
# README is an ordering somebody gets wrong at 3am.
#
# ── THE ORDER, AND WHY EACH STEP IS WHERE IT IS ────────────────────────────────
#
#   0. the EMBER testnet     hearth's own compose file plus the owner's miner on
#                            the host. FIRST, because the indexer verifies the
#                            chain id at boot and a follower with no provider is
#                            a service that reports healthy and indexes nothing.
#   1. the estate            postgres, 22 services, 16 frontends. It creates the
#                            network `cloudsforge-estate_default` that step 3
#                            attaches to, so it cannot be later.
#   2. the bootstrap         the admin UPDATE, the service tokens, the long-lived
#                            credentials. Services are RECREATED by it, so it
#                            must finish before anything routes to them.
#   3. telemetry + gateway   telemetry owns the three `cf-micro-*` networks and
#                            declares them; the gateway file attaches to them as
#                            external, so telemetry cannot be later either.
#   3c. the seeders          custody addresses that actually hold coin, so the
#                            solvency check compares two real numbers. AFTER the
#                            bootstrap, because it needs a service token.
#   4. estate-verify         the only step that decides whether any of it worked.
#
# ── ONE VARIABLE, READ BY TWO MECHANISMS ───────────────────────────────────────
#
# `CF_WEB_APEX` is interpolated by COMPOSE into identity's
# IDENTITY_HANDOFF_ORIGINS, and rendered by TRAEFIK's file provider into every
# surface router and the CORS allowlist. Neither can see the other's file. It is
# exported once here so the two cannot drift — and when they drift, the symptom
# is a sign-in that works at Hub and hands off nowhere, which is a long way from
# the cause.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

ESTATE=compose/docker-compose.estate.yml
TELEMETRY=compose/docker-compose.telemetry.yml
GATEWAY=compose/docker-compose.gateway.yml
GATEWAY_ESTATE=compose/docker-compose.estate-gateway.yml
GW_PROJECT=${COMPOSE_PROJECT_NAME:-cfmicro}

export CF_WEB_APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
export CLOUDSFORGE_RELEASE=${CLOUDSFORGE_RELEASE:-estate}

# ── PREFLIGHT: the two copies of CF_WEB_APEX must agree, BEFORE anything starts ─
#
# This is the third time a gateway configuration in this repository has been
# wrong in a way that produced SILENCE rather than an error:
#
#   1. `CF_API_HOST` undefined in the env file the gateway loads → every public
#      router rendered `Host(``)`, a valid rule matching no request ever sent.
#      Traefik logged nothing; the whole public API was dead.
#   2. A Go template action inside a YAML COMMENT → one unparseable file, and the
#      file provider published NO configuration from ANY file in the directory,
#      including the priority-100000 `/internal` refusal. Logged once, at start.
#   3. The variable below, read by two mechanisms that cannot see each other:
#      COMPOSE interpolates it into identity's IDENTITY_HANDOFF_ORIGINS, and
#      TRAEFIK's file provider renders it into every surface router and the CORS
#      allowlist from compose/env/traefik.env. Drift is invisible: the surfaces
#      answer, and cross-surface sign-in 403s somewhere else entirely.
#
# So it is checked here, loudly, before a container starts.
#
# WHY THE TEMPLATE DOES NOT SIMPLY HARD-FAIL INSTEAD. Because of defect 2: a
# template error takes down every file in `gateway/dynamic/`, and losing the
# `/internal` refusal to a missing web variable is a worse outcome than serving
# no surfaces. The conditional in estate-web.yml therefore renders NOTHING when
# the variable is unset — and this check, plus estate-verify's per-surface
# failure, is what makes that absence loud instead of quiet.
TRAEFIK_ENV=compose/env/traefik.env
gateway_apex=$(grep -E '^CF_WEB_APEX=' "$TRAEFIK_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)
if [ -z "$gateway_apex" ]; then
  echo "FATAL: $TRAEFIK_ENV defines no CF_WEB_APEX." >&2
  echo "       The gateway would render fifteen routers with an empty Host() and serve nothing," >&2
  echo "       silently. Add: CF_WEB_APEX=$CF_WEB_APEX" >&2
  exit 1
fi
if [ "$gateway_apex" != "$CF_WEB_APEX" ]; then
  echo "FATAL: CF_WEB_APEX disagrees between the two files that read it." >&2
  echo "         shell / compose : $CF_WEB_APEX" >&2
  echo "         $TRAEFIK_ENV : $gateway_apex" >&2
  echo "       The surfaces would be served on one apex and identity's hand-off allowlist" >&2
  echo "       written for another, so sign-in works at Hub and 403s everywhere else." >&2
  exit 1
fi
echo "  apex agrees in both files: $CF_WEB_APEX"


# EVERY SERVICE HERE BUILDS FROM A WORKING TREE, not from a published image, so
# the environment is only ever as green as every checkout on this machine — and a
# sibling repository's in-flight work stops the whole estate rather than its own
# container. It has already happened twice: micro-indexer (which is why `indexer`
# sits behind a profile) and micro-admin-api, whose Dockerfile copies the
# `runtimepkgs` context and NOT `contractspkgs`, so the `@cloudsforge/
# contracts-events` import added in its 24fb2c7 cannot resolve at build time.
#
# `CF_ESTATE_BUILD=0` starts from the images already on the machine. It is an
# ESCAPE, not a default: skipping the build is how you verify an environment that
# does not match the source it was built from, which is the failure this whole
# repository exists to stop being possible.
if [ "${CF_ESTATE_BUILD:-1}" = 0 ]; then
  BUILD_FLAG=""
  echo "!! CF_ESTATE_BUILD=0 — using the images already on this machine."
  echo "!! What runs may not match the working trees it was built from."
else
  BUILD_FLAG="--build"
fi

# ── 0. THE CHAIN, AND WHY IT IS PART OF "UP" RATHER THAN BESIDE IT ────────────
#
# "The full stack includes the EMBER chain." Until it did, `LEDGER_RECONCILE_ASSETS`
# named EMBER, every scheduled reconciliation recorded `unavailable/failed`, and
# the estate's whole chain-backing guarantee — ledger migration 11, the indexer's
# confirmed-only aggregate, the job that joins them — had only ever exercised its
# REFUSAL branch. A guarantee that has only ever said no is indistinguishable
# from one that can only say no.
#
# FIRST, not last: `indexer` verifies the chain id against `contracts-chain` at
# boot, and starting it against nothing is the failure its own env.ts names — "a
# follower with no provider reports healthy and indexes nothing".
#
# `CF_EMBER=0` skips it. That is a legitimate configuration — the refusal branch
# is the correct verdict for an estate without a chain and `estate-verify.sh`
# says so out loud rather than passing quietly — but it is not the default,
# because the default is the whole stack.
if [ "${CF_EMBER:-1}" = 0 ]; then
  echo "!! CF_EMBER=0 — no EMBER testnet. Every EMBER reconciliation will record"
  echo "!! unavailable/failed and freeze, which is correct and proves nothing."
else
  echo "── 0. the EMBER testnet, and the owner's miner outside the stack ────────"
  ./scripts/ember-testnet.sh up || exit 1
  # The miner is deliberately NOT a compose service. It holds the owner's key —
  # Hearth binds the coinbase public key into the PoW seed, so a miner that mines
  # to you must hold your key — and that wallet must outlive `down -v`, a volume
  # prune, and the VM being resized. On the host it does.
  ./scripts/ember-miner.sh start || exit 1
  echo
fi

echo "── 1. the estate: 22 services, 16 frontends, one database each ──────────"
echo "     apex: $CF_WEB_APEX   release: $CLOUDSFORGE_RELEASE"
# --wait blocks on every healthcheck rather than on the daemon accepting the
# request. Without it the bootstrap races identity's first migration and the
# failure reads as a flaky stack rather than as a start-order bug.
if ! docker compose -f "$ESTATE" up -d $BUILD_FLAG --wait; then
  echo "the estate did not come up healthy; nothing below was attempted" >&2
  exit 1
fi

echo
echo "── 2. bootstrap: the admin UPDATE, the tokens, the credentials ──────────"
./scripts/estate-bootstrap.sh || exit 1

echo
echo "── 3a. telemetry, which OWNS the three cf-micro-* networks ──────────────"
# TWO INVOCATIONS, NOT ONE, AND THIS IS THE REASON.
#
# `docker-compose.telemetry.yml` CREATES `cf-micro-edge`, `cf-micro-app` and
# `cf-micro-vault`; `docker-compose.gateway.yml` declares the same three as
# `external: true`. Compose merges the top-level `networks:` map across `-f`
# files and the LAST declaration wins, so naming both files in one command turns
# the creator into an attacher and the command fails with "network cf-micro-app
# declared as external, but could not be found" on any machine where they do not
# already exist.
#
# The gateway file's own header says "the telemetry file must be up first"; this
# is what "first" has to mean. `up.sh --gateway` passed both in one invocation
# and had the same defect — fixed there too.
if ! docker compose -p "$GW_PROJECT" -f "$TELEMETRY" up -d; then
  echo "the telemetry plane did not come up; it owns the networks the gateway attaches to" >&2
  exit 1
fi

echo
echo "── 3b. the gateway, wired to the estate's network and bound to 443 ──────"
# A different compose PROJECT (`cfmicro`) from the estate's, deliberately: the
# telemetry plane and the gateway have their own lifecycle and `make down` must
# not take the estate with them. The estate overlay attaches to the estate's
# network as EXTERNAL, so this fails with a named missing network if step 1 was
# skipped, rather than starting a gateway that resolves nothing.
if ! docker compose -p "$GW_PROJECT" -f "$TELEMETRY" -f "$GATEWAY" -f "$GATEWAY_ESTATE" up -d; then
  echo "the gateway did not come up; the surfaces will not be reachable on their hostnames" >&2
  exit 1
fi

# Traefik reads its dynamic directory on a watch, and a verify that starts in the
# same second as the gateway asks a router table that has not been built yet.
# Three seconds, not a retry loop: the file provider is not slow, it is just not
# instantaneous, and a loop here would hide a genuinely dead provider.
sleep 3

# ── 3c. THE SEEDERS ───────────────────────────────────────────────────────────
#
# A chain alone makes the solvency check compare 0 against 0, which is the
# plumbing working and the arithmetic untested — and `0 == 0` is the exact shape
# of the defect this release removed one service downstream. The seeder puts real,
# distinct amounts on real custody addresses and credits the ledger with the same
# numbers, so `clean` means two independently-computed 31-EMBER totals agreed.
#
# AFTER the bootstrap, because it mints a `wallet` token to register the
# addresses and post the credits. Idempotent by target balance, so re-running
# `estate-up.sh` tops up nothing and posts nothing twice.
#
# NOT FATAL. It waits for 60 confirmations, which on a chain mined from scratch
# is minutes; an estate that is otherwise healthy should not be reported as
# broken because a seed is still maturing. `estate-verify.sh` skips its driven
# EMBER section with a message that names this script when the set is empty.
if [ "${CF_EMBER:-1}" != 0 ]; then
  echo
  echo "── 3c. seeding EMBER custody, so the solvency check has real arithmetic ─"
  node scripts/ember-seed.js || echo "  (the seed is not complete; estate-verify will say so rather than pass quietly)"
fi

echo
echo "── 4. verify — the only step that decides whether any of it worked ──────"
# NOT `exec`, so that step 5 can be reached. `exec` replaced this shell with the
# verifier, which is why nothing has ever been printed after it.
./scripts/estate-verify.sh
verify_status=$?

echo
echo "── 5. and the tier that verify cannot reach ─────────────────────────────"
# ── WHY THIS IS A LINE OF TEXT AND NOT A FIFTH STEP ───────────────────────────
#
# `estate-verify.sh` is 183 curl assertions in under a minute. The browser tier
# launches a Chromium per journey, with a 120-second deadline each, and needs
# Node, tsx, playwright-core and a browser binary out of `../beacon/node_modules`
# — none of which this repository's verifier depends on today, deliberately, so
# that the estate can be verified from a clean machine. Running it here would
# make the cheap check as expensive as the expensive one, and a verifier that
# takes twenty minutes gets run less than one that takes two.
#
# So it is named rather than run. The cost of being beside is being forgotten,
# and this line plus `make estate-browser` is what that costs instead.
echo "  Nothing above executed a bundle. A module that throws on line one passes"
echo "  every assertion in estate-verify. To drive the sixteen surfaces in a real"
echo "  browser — sign-in, a refusal, a deep link, the product switcher:"
echo
echo "      make estate-browser"
echo
exit $verify_status
