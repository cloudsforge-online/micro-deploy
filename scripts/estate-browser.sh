#!/usr/bin/env bash
# Drive the tier-3 BROWSER journeys against the running estate.
#
#   cd deploy && ./scripts/estate-browser.sh          # or: make estate-browser
#
# ── WHY THIS IS BESIDE `estate-verify.sh` AND NOT INSIDE IT ────────────────────
#
# The two prove different things and cost different amounts, and folding them
# together would damage both. Four reasons, in the order they matter:
#
#   1. **COST, WHICH DECIDES HOW OFTEN A CHECK IS RUN.** `estate-verify.sh` is
#      183 curl assertions and finishes in well under a minute. Every browser
#      journey launches a Chromium, loads a bundle and waits for a SPA to mount;
#      its own deadline is 120 SECONDS for that reason. A verifier that takes
#      twenty minutes gets run less than one that takes two, and the one people
#      stop running is the one that stops catching anything. Keeping them apart
#      keeps `estate-verify.sh` cheap enough to run after every change.
#
#   2. **DIFFERENT FAILURE MODES, WHICH MUST NOT BE MIXED.** A missing Chromium
#      is a SKIP for the browser tier — a lean deployment choosing not to ship a
#      browser is a decision, not an outage. `estate-verify.sh` has no third
#      state: it has `ok` and `bad` and a `fails` counter. A skip folded into it
#      would have to become one or the other, and both answers are wrong.
#
#   3. **DIFFERENT DEPENDENCIES.** `estate-verify.sh` needs curl, python3 and
#      bash 3.2, and that is deliberate — it runs anywhere. This needs Node ≥22,
#      tsx, `playwright-core` and a Chromium binary, all of them in
#      `../beacon/node_modules`. Making the deploy's verifier depend on a service
#      checkout being installed would mean the estate could not be verified from
#      a clean machine.
#
#   4. **DIFFERENT OWNERS.** The assertions live in `micro-beacon`, where the T3
#      catalogue and the declaration rules are. This file supplies ADDRESSES and
#      nothing else: it holds no scenario, no selector and no expectation, so a
#      new journey needs no change here.
#
# The cost of being beside is that it can be forgotten. That is paid for in two
# places: `make estate-browser`, and the line `estate-up.sh` prints when it
# finishes.
#
# ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────
#
# It does not start anything. `estate-up.sh` does that. Pointing a browser at an
# estate that is not up produces a page of timeouts that read as product
# failures, so this checks the gateway is answering FIRST and says so plainly.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
BEACON=${CF_BEACON_DIR:-../beacon}

# ── THE ADDRESSES ─────────────────────────────────────────────────────────────
#
# Public hostnames, never compose-network names. Loading `http://tessera-web:8080`
# would work — nginx answers — and the bundle would then derive its API hosts from
# the hostname `tessera-web`, call `https://nimbus.tessera-web`, and fail for a
# reason that has nothing to do with the product. Beacon's own
# `src/browser/journeys.ts` records that as "a wrong answer wearing the costume of
# a real failure, which is worse than a skip".
#
# `site` IS THE BARE APEX, and this is the one that would be got wrong. Every
# other surface is `<subdomain>.<apex>`; `site` has no subdomain row in
# `ui/packages/ui/src/surfaces.ts`, so the gateway routes it on the apex host
# itself (`gateway/dynamic/estate-web.yml`, the `cf-web-site` router) and
# `https://site.<apex>` answers 404 from the catch-all. Driven, not assumed: that
# 404 is what a first run against `site.<apex>` returned.
#
# `account` IS A PATH, not a host. The sign-in surface has no bundle of its own —
# micro-ui's `signin` registry row rides on Hub at `/account`, and micro-hub-web
# serves it. Beacon resolves a surface key to whatever string it is given, so this
# needs no special case there.
#
# `identity` is `nimbus.<apex>` because that is the name the shared UI calls it by
# and therefore the only one whose CORS allowance and hand-off allowlist are real.
TARGETS="site=https://${APEX}"
TARGETS="$TARGETS,account=https://hub.${APEX}/account"
TARGETS="$TARGETS,identity=https://nimbus.${APEX}"
for pair in \
  "hub hub" "market market" "trade trade" "worlds worlds" "create create" \
  "admin admin" "status status" "explorer explorer" "developers developers" \
  "network network" "foresight foresight" "foresight-admin foresight-admin" \
  "emberkin emberkin" "aetherholm aetherholm" "tessera tessera"; do
  # No `declare -A`: bash here is 3.2, and an associative-array map once silently
  # broke five suites in this repository.
  set -- $pair
  TARGETS="$TARGETS,$1=https://$2.${APEX}"
done

echo "── the gateway must be answering before a browser is pointed at it ──────"
# THREE ATTEMPTS, NOT A LOOP. Docker Desktop's loopback port-forward stalls
# occasionally on this estate — `curl --resolve …:443:127.0.0.1` returns 000
# three times in a row and then 200 with nothing restarted — and one 000 is not
# evidence that the estate is down. A bounded retry absorbs that; an unbounded
# one would hide a gateway that is genuinely dead, which is the failure this
# preflight exists to name.
gw=000
for _ in 1 2 3; do
  gw=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "hub.${APEX}:443:127.0.0.1" "https://hub.${APEX}/account/login")
  [ "$gw" = 200 ] && break
  sleep 2
done
if [ "$gw" != 200 ]; then
  echo "FATAL: https://hub.${APEX}/account/login answered $gw, not 200." >&2
  echo "       Every estate-level journey begins by signing in, and the sign-in page is" >&2
  echo "       served there. Bring the estate up first:  ./scripts/estate-up.sh" >&2
  exit 2
fi
echo "  gateway answering, sign-in surface served on hub.${APEX}"
echo

# ── --insecure-tls, AND WHY IT IS NOT A DEFAULT IN BEACON ─────────────────────
#
# The gateway terminates TLS with Traefik's built-in `CN=TRAEFIK DEFAULT CERT`,
# because `ui/packages/ui/src/surfaces.ts` emits `https://` unconditionally and
# there is no CA on a laptop. Chromium refuses it with
# ERR_CERT_AUTHORITY_INVALID, and Node's `fetch` refuses it with the far less
# helpful `TypeError: fetch failed`.
#
# So the flag is passed HERE, by the script that knows this estate's certificate
# is self-signed, and beacon's own default stays strict. A production browser
# journey must fail on an expired certificate — that is one of the few outages a
# synthetic monitor sees before a customer does.

# ── AND WHY THIS `cd`s RATHER THAN PASSING A PATH ─────────────────────────────
#
# `node --import tsx` resolves `tsx` FROM THE WORKING DIRECTORY, not from the
# script it is asked to load. Run from `deploy/`, it fails with
# `Cannot find package 'tsx' imported from …/deploy/` — which names the deploy
# repository for a dependency that belongs to beacon, and reads as this
# repository having a broken install. Driven, not guessed: that is the error the
# first version of this line produced.
if [ ! -d "$BEACON/node_modules/tsx" ]; then
  echo "FATAL: $BEACON has no node_modules." >&2
  echo "       The journeys, the catalogue and the driver live in micro-beacon; this script only" >&2
  echo "       supplies addresses. Install it:  (cd $BEACON && pnpm install)" >&2
  echo "       Set CF_BEACON_DIR if the checkout is somewhere else." >&2
  exit 2
fi
cd "$BEACON" || exit 2
exec node --import tsx src/cli.ts browser \
  --insecure-tls \
  --timeout "${CF_BROWSER_TIMEOUT_MS:-45000}" \
  --targets "$TARGETS"
