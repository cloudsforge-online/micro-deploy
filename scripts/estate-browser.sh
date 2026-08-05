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

# ── THREE VARIABLES, BECAUSE AN ENVIRONMENT IS A SUFFIX NOW ───────────────────
#
# Changed 2026-08-05. Testnet used to be a PREFIX ON THE APEX
# (`hub.testnet.cloudsforge.online`) and was configured and unreachable:
# Cloudflare's Universal SSL is `*.cloudsforge.online` and a wildcard matches
# exactly ONE label, so every two-label testnet hostname failed the TLS handshake
# at the edge. It is a SUFFIX ON THE SUBDOMAIN now — `hub-testnet.cloudsforge.online`
# — and both environments share the zone `cloudsforge.online`.
#
# `WEB_SUFFIX` is READ, never derived as `.$APEX`, because on a shared apex the
# derived value is a real MAINNET hostname that really answers. A testnet browser
# run would then drive seventeen mainnet surfaces and report them green.
APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
WEB_SUFFIX=${CF_WEB_SUFFIX:-.$APEX}
SITE_HOST=${CF_SITE_HOST:-$APEX}
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
# `site` IS THE APEX SURFACE, and this is the one that would be got wrong. Every
# other surface is `<subdomain>$WEB_SUFFIX`; `site` has no subdomain row in
# `ui/packages/ui/src/surfaces.ts`, so the gateway routes it on the apex surface's
# own host (`gateway/dynamic/estate-web.yml`, the `cf-web-site` router) and
# `https://site$WEB_SUFFIX` answers 404 from the catch-all. Driven, not assumed:
# that 404 is what a first run against `site.<apex>` returned.
#
# It is `$SITE_HOST` and NOT the empty string plus the suffix, which would be
# `-testnet.cloudsforge.online` — not a legal DNS label. That is the whole reason
# the apex surface carries a variable of its own rather than being derived.
#
# `account` IS A PATH, not a host. The sign-in surface has no bundle of its own —
# micro-ui's `signin` registry row rides on Hub at `/account`, and micro-hub-web
# serves it. Beacon resolves a surface key to whatever string it is given, so this
# needs no special case there.
#
# `identity` is `nimbus$WEB_SUFFIX` because that is the name the shared UI calls it
# by and therefore the only one whose CORS allowance and hand-off allowlist are real.
TARGETS="site=https://${SITE_HOST}"
TARGETS="$TARGETS,account=https://hub${WEB_SUFFIX}/account"
TARGETS="$TARGETS,identity=https://nimbus${WEB_SUFFIX}"
for pair in \
  "hub hub" "market market" "trade trade" "worlds worlds" "create create" \
  "admin admin" "status status" "explorer explorer" "developers developers" \
  "network network" "foresight foresight" \
  "emberkin emberkin" "aetherholm aetherholm" "tessera tessera"; do
  # No `declare -A`: bash here is 3.2, and an associative-array map once silently
  # broke five suites in this repository.
  set -- $pair
  TARGETS="$TARGETS,$1=https://$2${WEB_SUFFIX}"
done

echo "── the gateway must be answering before a browser is pointed at it ──────"
# ── THE PORT IS READ, BECAUSE 443 WAS HARD-CODED AND TESTNET IS NOT ON IT ─────
#
# This line used to say `--resolve "hub.${APEX}:443:127.0.0.1"` with the port
# written out. Both compose files publish the gateway on `${CF_GATEWAY_PORT:-443}`
# (`compose/docker-compose.gateway.yml:311`,
# `compose/docker-compose.estate-gateway.yml:55`) and `compose/testnet.env:101`
# sets it to 10443, so nothing was listening on 443 in a testnet project and this
# preflight could never have passed there — it would have printed FATAL and told
# the operator to bring an estate up that was already up.
#
# The URL carries the port too, not just the `--resolve`. `--resolve` only maps a
# host:port pair to an address; a URL with no port is port 443 whatever the
# mapping says, so parameterising one without the other keeps the same bug.
GW_PORT=${CF_GATEWAY_PORT:-443}
# THREE ATTEMPTS, NOT A LOOP. Docker Desktop's loopback port-forward stalls
# occasionally on this estate — `curl --resolve …:$GW_PORT:127.0.0.1` returns 000
# three times in a row and then 200 with nothing restarted — and one 000 is not
# evidence that the estate is down. A bounded retry absorbs that; an unbounded
# one would hide a gateway that is genuinely dead, which is the failure this
# preflight exists to name.
gw=000
for _ in 1 2 3; do
  gw=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "hub${WEB_SUFFIX}:${GW_PORT}:127.0.0.1" \
    "https://hub${WEB_SUFFIX}:${GW_PORT}/account/login")
  [ "$gw" = 200 ] && break
  sleep 2
done
if [ "$gw" != 200 ]; then
  echo "FATAL: https://hub${WEB_SUFFIX}:${GW_PORT}/account/login answered $gw, not 200." >&2
  echo "       Every estate-level journey begins by signing in, and the sign-in page is" >&2
  echo "       served there. Bring the estate up first:  ./scripts/estate-up.sh" >&2
  exit 2
fi
echo "  gateway answering, sign-in surface served on hub${WEB_SUFFIX}"
echo

# ── --insecure-tls, WHAT IT NOW COSTS, AND WHERE THE FIX BELONGS ──────────────
#
# **THE PREMISE OF THIS FLAG HAS CHANGED AND THE FLAG HAS NOT.**
#
# It used to read: "the gateway terminates TLS with Traefik's built-in
# `CN=TRAEFIK DEFAULT CERT` … there is no CA on a laptop". Both halves are now
# false. `scripts/gateway-cert.sh` mints `CN=CloudsForge Estate Local CA` and a
# wildcard leaf, `gateway/dynamic/tls.yml` serves it, and `estate-verify.sh`
# asserts the chain with `--cacert` and no `-k`. There IS a CA on this laptop,
# and its public key can be pinned.
#
# That matters because `--insecure-tls` is not a warning suppressant. In
# `beacon/src/cli.ts:294` it sets `NODE_TLS_REJECT_UNAUTHORIZED=0` process-wide
# AND passes `ignoreHttpsErrors: true` to every browser context — validation off
# for every host, every error, for ever. Pointed at staging, this suite would
# report green through an expired certificate, one issued for the wrong
# hostname, and an active man-in-the-middle. It is the estate's signature defect
# in the suite written to end it, and it is the reason the whole estate could be
# green while unusable in Chrome.
#
# THE FIX IS NOT HERE, AND IS NOT A LOCAL SHIM. `micro-beacon` has already built
# the narrow lever — `src/browser/estatecert.ts`, which reads the certificate the
# gateway is really serving, refuses to pin anything that fails for a reason
# OTHER than an untrusted root (so expiry and a wrong hostname still fail), and
# pins one SPKI through Chromium's `--ignore-certificate-errors-spki-list`. Its
# header already names this CA. But `collectPins` is wired into `beacon smoke`
# only; the `beacon browser` command this script calls still takes
# `--insecure-tls` and nothing else.
#
# So: reported to micro-beacon, which owns both the flag and the module —
# `runBrowser` should take the `collectPins` path `runSmokeCommand` already
# does, and `--insecure-tls` should stop implying `ignoreHttpsErrors`. Until it
# does, the flag stays, because the alternative is sixteen journeys that die at
# `page.goto` and report nothing about the product. It is recorded here rather
# than quietly kept, because a stale justification is how a shortcut becomes a
# policy.

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
