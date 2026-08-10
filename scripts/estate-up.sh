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
# TWO projects, not one. The telemetry plane keeps `cfmicro` — renaming a compose
# project renames its volumes, and those hold 15 days of metrics and 30 of logs.
# The gateway belongs to the estate it serves; see micro-org#257 and the note at
# step 3b below.
TELEMETRY_PROJECT=${COMPOSE_PROJECT_NAME:-cfmicro}
GW_PROJECT=${CF_GW_PROJECT:-${CF_PROJECT:-cloudsforge-estate}}

export CF_WEB_APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
# The environment is a SUFFIX ON THE SUBDOMAIN, not a prefix on the apex — see the
# long note in `compose/env/traefik.env`. An unset suffix means "no environment
# label", which is the unadorned form and is what a dev estate wants.
export CF_WEB_SUFFIX=${CF_WEB_SUFFIX:-.$CF_WEB_APEX}
export CF_SITE_HOST=${CF_SITE_HOST:-$CF_WEB_APEX}
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
# ── WHICH ENV FILE THE GATEWAY WILL ACTUALLY LOAD ─────────────────────────────
#
# It was `compose/env/traefik.env`, hard-coded, and that stopped being safe on
# 2026-08-05. Both environments now set `CF_WEB_APEX=cloudsforge.online` — they
# share the zone and differ in the SUFFIX — so a preflight that reads mainnet's
# file and compares apexes would agree with itself while a testnet bring-up was
# pointed at the wrong env file entirely. It reads the same variable
# `scripts/gateway-reload.sh` reads, so the two agree about which file is in
# play, and it compares the values that actually differ.
TRAEFIK_ENV="compose/env/${CF_TRAEFIK_ENV:-traefik}.env"
if [ ! -f "$TRAEFIK_ENV" ]; then
  echo "FATAL: $TRAEFIK_ENV does not exist." >&2
  echo "       CF_TRAEFIK_ENV=${CF_TRAEFIK_ENV:-traefik} names the env file the gateway loads." >&2
  exit 1
fi

envval() { grep -E "^$1=" "$TRAEFIK_ENV" 2>/dev/null | tail -1 | cut -d= -f2- ; }

for var in CF_WEB_APEX CF_WEB_SUFFIX CF_SITE_HOST; do
  eval "shell_val=\$$var"
  file_val=$(envval "$var")
  if [ -z "$file_val" ]; then
    echo "FATAL: $TRAEFIK_ENV defines no $var." >&2
    echo "       estate-web.yml renders NO ROUTERS without CF_WEB_SUFFIX, and policy.yml renders" >&2
    echo "       an empty CORS allowlist — the estate serves nothing, silently. Add:" >&2
    echo "         $var=$shell_val" >&2
    exit 1
  fi
  if [ "$file_val" != "$shell_val" ]; then
    echo "FATAL: $var disagrees between the two files that read it." >&2
    echo "         shell / compose : $shell_val" >&2
    echo "         $TRAEFIK_ENV : $file_val" >&2
    echo "       The surfaces would be served on one set of hostnames and identity's hand-off" >&2
    echo "       allowlist written for another, so sign-in works at Hub and 403s everywhere else." >&2
    exit 1
  fi
done
echo "  hostnames agree in both files: <surface>$CF_WEB_SUFFIX, site $CF_SITE_HOST"

# ── PREFLIGHT 1b: the three must describe ONE environment ─────────────────────
#
# They overlap on purpose — `CF_WEB_SUFFIX` ends in the apex and `CF_SITE_HOST`
# begins with the environment label — and overlapping values drift. The
# alternative was a Go conditional inside `gateway/dynamic/`, where the file
# provider renders templates before parsing YAML and one unbalanced action takes
# every file in the directory down at once (estate-web.yml's header records the
# three minutes that cost this week). Three plain strings and this check is the
# cheaper trade.
case "$CF_WEB_SUFFIX" in
  *".$CF_WEB_APEX") ;;
  *)
    echo "FATAL: CF_WEB_SUFFIX does not end in the apex." >&2
    echo "         CF_WEB_SUFFIX : $CF_WEB_SUFFIX" >&2
    echo "         CF_WEB_APEX   : $CF_WEB_APEX" >&2
    echo "       Every surface router would be served on a zone this estate does not hold." >&2
    exit 1 ;;
esac
# What is left when the apex is removed: '' for the unadorned environment, or
# '-testnet' for a labelled one. Anything else is not a hostname shape this
# estate's `splitEnvLabel()` can take apart, so a browser on it would resolve
# every sibling address somewhere that does not exist.
env_label=${CF_WEB_SUFFIX%".$CF_WEB_APEX"}
case "$env_label" in
  "")            expected_site="$CF_WEB_APEX" ;;
  -*[!-])        expected_site="${env_label#-}.$CF_WEB_APEX" ;;
  *)
    echo "FATAL: CF_WEB_SUFFIX is neither the bare apex nor '-<label>.<apex>'." >&2
    echo "         CF_WEB_SUFFIX : $CF_WEB_SUFFIX" >&2
    echo "       ui/packages/ui/src/surfaces.ts splits a hostname's first label on its LAST" >&2
    echo "       hyphen into <subdomain>-<environment>. A suffix of any other shape produces" >&2
    echo "       hostnames no bundle in this estate can resolve its siblings from." >&2
    exit 1 ;;
esac
if [ "$CF_SITE_HOST" != "$expected_site" ]; then
  echo "FATAL: CF_SITE_HOST is not this environment's apex surface." >&2
  echo "         CF_SITE_HOST : $CF_SITE_HOST" >&2
  echo "         expected     : $expected_site" >&2
  echo "       The marketing site's registry subdomain is the empty string, so it cannot take" >&2
  echo "       the suffix — '-testnet.$CF_WEB_APEX' is not a legal DNS label. Its host is the" >&2
  echo "       environment label alone, or the bare apex where there is no label." >&2
  exit 1
fi
echo "  hostname shape is consistent: label '${env_label:-none}', site $CF_SITE_HOST"

# ── PREFLIGHT 2: CF_API_HOST must be THIS environment's `api` surface ─────────
#
# Defect 1 above has a quieter sibling and it was live in this estate. The
# variable was DEFINED — so no `Host(``)` and no silence to look for — and set to
# `api.cloudsforge.online` while the apex was `cloudsforge.localtest.me`. Every
# router in `public-api.yml` was therefore live on a hostname nothing in this
# estate resolves, and `api.<apex>` — a surface the registry DECLARES, which the
# SDK and the developer portal both compose from it — answered 404. A route map
# that had "never once loaded" for one reason had stopped loading again for
# another.
#
# IT USED TO BE ENOUGH TO CHECK "ends with .$CF_WEB_APEX", AND IT IS NOT ANY
# MORE. Both environments share the apex now, so `api.cloudsforge.online` passes
# that test on the TESTNET gateway — and would publish testnet's whole v1 API on
# mainnet's API hostname, where Cloudflare would hand it to whichever tunnel
# registered last. The check is exact: `api` plus this environment's suffix,
# which is the same string `cloudsforgeHosts().api` composes in the browser.
#
# Checked rather than overwritten: this script has no business rewriting a
# committed env file. It refuses to start and says which line to change.
gateway_api_host=$(envval CF_API_HOST)
expected_api_host="api$CF_WEB_SUFFIX"
if [ -z "$gateway_api_host" ]; then
  echo "FATAL: $TRAEFIK_ENV defines no CF_API_HOST." >&2
  echo "       Every router in gateway/dynamic/public-api.yml would render Host(\`\`) and match" >&2
  echo "       no request ever sent, with nothing in Traefik's log. Add: CF_API_HOST=$expected_api_host" >&2
  exit 1
fi
if [ "$gateway_api_host" != "$expected_api_host" ]; then
  echo "FATAL: CF_API_HOST is not this environment's api surface." >&2
  echo "         CF_API_HOST : $gateway_api_host" >&2
  echo "         expected    : $expected_api_host" >&2
  echo "       https://$expected_api_host is what the registry declares and what every bundle," >&2
  echo "       the SDK and the developer portal compose. Anything else routes the public API" >&2
  echo "       on a host this environment does not own. Set: CF_API_HOST=$expected_api_host" >&2
  exit 1
fi
echo "  public API host is this environment's own: $gateway_api_host"

# ── PREFLIGHT 3: the registry and the gateway must agree about what exists ────
#
# `scripts/surface-routes.py` compares `ui/packages/ui/src/surfaces.ts` against
# the routers in `gateway/dynamic/`. It is here rather than only in CI because
# the failure it catches is invisible from every server-side probe: a surface
# with no router serves its bundle perfectly and answers no API call, which is a
# green estate and a broken product. Three such gaps were live at once the first
# time the estate was opened in a browser — `worlds-api` (since folded into
# `api.` and removed), `beacon`, and both title APIs — and each had been
# introduced by an edit to a DIFFERENT file.
#
# Not fatal. It reads sibling checkouts, and a missing one must not stop an
# estate from starting; it is loud, and `make check-surfaces` is the gate.
if ! python3 scripts/surface-routes.py; then
  echo "  !! the surface registry and the gateway disagree — surfaces above will not answer"
fi

# ── PREFLIGHT 4: a certificate a BROWSER will accept ──────────────────────────
#
# Before this, the gateway served Traefik's self-signed default and every
# verification path in this repository turned certificate checking off to reach
# it — `curl -k` in estate-verify, `ignoreHTTPSErrors: true` in estate-browser.
# So the transport was the one layer never exercised the way a person exercises
# it, and it was broken: a page loads after a click-through, and then every
# CROSS-ORIGIN call fails, because no browser offers an interstitial for an XHR.
# Sign-in reported "Cannot reach the server" with the whole estate healthy.
#
# Idempotent and unattended: it mints nothing that already exists and never
# prompts. The one step that needs a password — trusting the CA — is printed.
echo
echo "── 0a. the gateway's certificate, so a real browser can use this estate ─"
./scripts/gateway-cert.sh || exit 1


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
if ! docker compose -p "$TELEMETRY_PROJECT" -f "$TELEMETRY" up -d; then
  echo "the telemetry plane did not come up; it owns the networks the gateway attaches to" >&2
  exit 1
fi

echo
echo "── 3b. the gateway, wired to the estate's network and bound to 443 ──────"
# ── THE GATEWAY IS IN THE ESTATE'S PROJECT, AND WAS NOT (micro-org#257) ───────
#
# This said "a different compose PROJECT (`cfmicro`) from the estate's,
# deliberately", and the deliberation was about lifecycle: `make down` on the
# telemetry plane must not take the estate with it. That reason is real and is
# preserved — the gateway is still a separate `-f` and a separate invocation with
# its own lifecycle, and `down.sh` removes it by NAME rather than by project.
#
# What was wrong is which project it landed in. The gateway serves the estate's
# ~50 containers and was labelled with the telemetry plane's project, so
# `docker compose -p cloudsforge-estate ps` — the command an operator runs to see
# what is serving this estate — did not list it. The testnet twin of exactly this
# was deleted as an apparent orphan on 2026-08-05 and again on 2026-08-08, each
# time putting every public `*-testnet` hostname on 502 while all 46 services
# reported healthy.
#
# NO `-f "$TELEMETRY"` any more: with the projects split, merging the telemetry
# file into this invocation would build a second telemetry plane inside the
# estate's project. The estate overlay attaches to the estate's network as
# EXTERNAL, so this still fails with a named missing network if step 1 was
# skipped, rather than starting a gateway that resolves nothing.
if ! docker compose -p "$GW_PROJECT" -f "$GATEWAY" -f "$GATEWAY_ESTATE" up -d gateway; then
  echo "the gateway did not come up; the surfaces will not be reachable on their hostnames" >&2
  exit 1
fi

# Traefik reads its dynamic directory on a watch, and a verify that starts in the
# same second as the gateway asks a router table that has not been built yet.
# Three seconds, not a retry loop: the file provider is not slow, it is just not
# instantaneous, and a loop here would hide a genuinely dead provider.
sleep 3

# ── AND THE WATCH IS THE PART THAT DOES NOT WORK HERE ─────────────────────────
#
# The comment above was written believing the file provider's watch picks up an
# edit. On this host it does not, and the reason is the mount rather than
# Traefik: `gateway/dynamic/` is a virtiofs bind mount out of a Lima VM
# (`colima status` says `mountType: virtiofs`), and virtiofs forwards no
# host-originated inotify event into the guest. The watcher is registered on a
# filesystem that will never tell it anything.
#
# `docker compose up -d` does NOT close the gap, and that is the trap this
# closes: compose only recreates a container whose own definition changed, and
# editing a file INSIDE a bind mount changes nothing compose can see. So the
# ordinary "edit a router, run estate-up.sh" loop brings up an estate whose
# gateway is still routing the previous table, and the step below would then
# verify it and report green.
#
# So: ask, and only reload if the answer is no. Asking is two numbers and a
# digest; reloading unconditionally would restart the gateway on every run of
# this script and drop every connection through it for no reason.
if ! ./scripts/gateway-reload.sh --check >/dev/null 2>&1; then
  echo "  the gateway is serving configuration older than gateway/dynamic/ — reloading it"
  ./scripts/gateway-reload.sh || {
    echo "the gateway's dynamic directory does not render; the surfaces would be unreachable" >&2
    exit 1
  }
fi

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
