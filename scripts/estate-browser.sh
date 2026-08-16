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
#
# `chain` IS NOT A SURFACE AND WAS MISSING, WHICH SILENTLY WITHDREW FOUR JOURNEYS.
#
# It resolves to the Hearth JSON-RPC endpoint — `rpc$WEB_SUFFIX`, the hostname
# `gateway/dynamic/estate-web.yml` routes to the node and the same one every
# bundle in the estate reads the chain through. Nothing loads a PAGE there; the
# journeys that declare it use it for `eth_call` and `eth_getTransactionReceipt`,
# because a figure asserted only against the page it was rendered on is a figure
# checked against itself.
#
# Its absence was not visible as a failure. `browserJourneys()` drops any
# scenario whose `needs` this file has no address for, and reports it through
# `undeclared()` as `no address for chain` — so every journey that reads the
# chain has been quietly undeclared on every run of this script. That is four:
# BJ-FOR-06 and BJ-FOR-14, which check Foresight's mirror against the contract,
# and BJ-DEX-01 and BJ-DEX-02 below. Adding the address DECLARES them, and
# BJ-FOR-06 is red on this estate for a reason recorded in
# `beacon/src/browser/journeys.test.ts`. A red that was always true and never
# reported is the reason this line exists.
TARGETS="site=https://${SITE_HOST}"
TARGETS="$TARGETS,account=https://hub${WEB_SUFFIX}/account"
TARGETS="$TARGETS,identity=https://nimbus${WEB_SUFFIX}"
TARGETS="$TARGETS,chain=https://rpc${WEB_SUFFIX}"
for pair in \
  "hub hub" "market market" "trade trade" "worlds worlds" "create create" \
  "admin admin" "status status" "explorer explorer" "developers developers" \
  "network network" "foresight foresight" "exchange exchange" \
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
# (`compose/docker-compose.gateway.yml`,
# `compose/docker-compose.estate-gateway.yml`) and `compose/testnet.env:101`
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

# ── `--insecure-tls` IS GONE, AND THE ROOT IS NAMED INSTEAD ───────────────────
#
# This block used to argue for keeping `--insecure-tls` "until micro-beacon
# wires `collectPins` into `beacon browser`". It has. `runBrowser` now collects
# one SPKI per host per port and hands them to Chromium as
# `--ignore-certificate-errors-spki-list`, and `estatecert.ts` refuses to pin
# anything that failed for a reason OTHER than an untrusted root — so an expired
# certificate, one issued for a different hostname, and a substituted one all
# still fail, which is the entire difference from the flag that replaced them.
# `parseBrowserArgs` REFUSES `--insecure-tls` by name (exit 2, with the reason),
# so leaving it here would not have degraded to a warning: it would have made
# every run of this script die before it launched a browser.
#
# What the browser pins does not cover beacon's OWN `fetch` — BJ-XS-10 fetches
# every address the switcher offers, BJ-ACC-02 seeds an account over HTTP, and
# the DEX journeys read the chain through `rpc$WEB_SUFFIX`. Those go through
# Node, so the root is named for Node too: `--estate-ca <file>` trusts one PEM
# IN ADDITION to the system store, for this process only.
#
# WHICH IS WHY IT IS CONDITIONAL. `gateway/certs/ca.crt` is a LOCAL artifact —
# `scripts/gateway-cert.sh` mints `CN=CloudsForge Estate Local CA` on the
# machine the estate runs on, and `.gitignore` refuses the directory. A run
# against mainnet or testnet terminates on a public certificate at Cloudflare's
# edge, where there is no such file and none is wanted: naming a root that is
# not in the chain would trust a CA for nothing. Absent, beacon prints "no
# additional root was named; the system trust store stands unmodified", which is
# the correct sentence for a public estate and a legible one for a local estate
# whose certificate has not been minted yet.
#
# `ca.crt` and NOT `trust.crt`: the bundle is the CA plus every public root in
# `gateway/trust/`, and `trustEstateCa` parses ONE certificate out of the file it
# is given. Pointed at the bundle it would silently trust the first and drop the
# rest — and the first is the one already being asked for.
#
# The `curl -sk` in the preflight above is deliberately left alone. It asserts
# nothing about the product; it asks whether anything is listening at all, and it
# runs BEFORE the certificate could be read.
CA=${CF_ESTATE_CA:-gateway/certs/ca.crt}
# Absolute, because the `cd "$BEACON"` below moves out of `deploy/` and a
# relative path would resolve against a checkout that has no `gateway/`.
if [ -f "$CA" ]; then
  CA="$(cd "$(dirname "$CA")" && pwd)/$(basename "$CA")"
  set -- --estate-ca "$CA"
  echo "  naming one additional root for beacon's own requests: $CA"
else
  set --
  echo "  no local CA at $CA — the system trust store stands unmodified"
fi
echo

# ── ONE JOURNEY SIGNS, AND IT SAYS SO BEFORE THE RUN RATHER THAN AFTER ────────
#
# BJ-DEX-02 is the only journey in the catalogue that broadcasts a transaction:
# it presses Swap on the exchange, signs what the page built with a key held in
# this process, and reads the receipt off the chain. `docs/ecosystem/39-forge-
# exchange.md` §6 names it as the gate for phase H — "beacon drives a swap
# through the real gateway" — so it is not an optional extra, it is the
# measurement.
#
# It reads `BEACON_DEX_KEY` and SKIPS, loudly, when there is none. That skip is
# correct: a journey that signs needs a funded key, and falling back to checking
# that a browser which cannot sign says it cannot sign would be a green run
# proving nothing. What the skip does not do is explain itself to somebody
# reading a report of thirty journeys, which is what this block is for.
#
# The variable is passed through by `exec` and never printed. The test is
# `${BEACON_DEX_KEY:+set}` — the value is never substituted into a word, only
# its presence, because a shell that echoes a private key into a terminal has
# written it to scrollback, to a tmux buffer and to anything tailing the run.
#
# It is not minted here and there is no default. On testnet the key is an
# ordinary externally-owned account with a few EMBER on it; on mainnet
# `deploy/scripts/hearth-fund.js` caps funding at zero by policy, so pointing
# this at mainnet with a key set will skip on the balance check instead, which
# is also the right answer.
if [ -n "${BEACON_DEX_KEY:-}" ]; then
  echo "  BEACON_DEX_KEY is set — BJ-DEX-02 will sign a real swap and spend real gas"
else
  echo "  BEACON_DEX_KEY is unset — BJ-DEX-02 will skip; every other journey is unaffected"
fi
echo

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
  "$@" \
  --timeout "${CF_BROWSER_TIMEOUT_MS:-45000}" \
  --targets "$TARGETS"
