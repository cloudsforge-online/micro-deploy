#!/usr/bin/env python3
"""Every surface the registry declares must have a router at the gateway, and vice versa.

THE DRIFT THIS CLOSES, AND THE NIGHT IT WAS FOUND
-------------------------------------------------
`ui/packages/ui/src/surfaces.ts` is the one list of what CloudsForge serves. Every
frontend reads it at runtime — `cloudsforgeHosts()` composes `https://<subdomain>.<apex>`
for every sibling — so a row in that file IS a promise that an address answers.
`gateway/dynamic/estate-web.yml` is a hand-written list of the addresses that
actually do. Two lists of the same fact, maintained by different people, in
different repositories, in different languages.

They drifted, and the estate was opened in a browser for the first time:

  * `worlds-api.<apex>` — a registry surface with `subdomain: 'worlds-api'`, and
    the host `worlds-web` resolves its whole API against
    (`worlds-web/src/lib/hosts.ts:80`). NO ROUTER. Every request the Forge Worlds
    bundle made 404'd, while `worlds.<apex>/v1/titles` answered 200 beside it.
    micro-worlds-web had written the diagnosis in its own header and could not fix
    it from its own repository. (That surface is GONE now — the hostname was folded
    into `api.` and the row and its router were both deleted on 2026-08-05. It is
    left in this history because it is what the check was written for.)
  * `api.<apex>` — routed by `public-api.yml`, but against `CF_API_HOST`, which
    was pinned to `api.cloudsforge.online` while the estate ran on
    `cloudsforge.localtest.me`. A router on a host nothing resolves.
  * `emberkin.<apex>` and `aetherholm.<apex>` — their SERVICES joined the estate
    the same night and this file was not opened, so both bundles answered their
    own API calls with their own index.html.

Three instances of one defect in one night. The individual missing lines are not
the defect; the drift is, and a check is the only thing that ends it.

WHY A CHECK AND NOT A GENERATOR
-------------------------------
Generating `estate-web.yml` from the registry was considered and refused, for a
reason this repository has already paid for twice: that file is not a mapping, it
is an ARGUMENT. Half of it is prose explaining why `pay` and `vault` cannot live
on the API host, why the explorer gets no `/v1` router while it sits behind a
profile, why tessera's upstream port is 4022 and not 4000, and why a Go template
action inside a YAML comment is still an action. A generator would either discard
all of that or grow a per-surface exception table — which is the same hand-written
list again, one level less visible.

So the file stays hand-written and THIS makes it impossible for it to be wrong
quietly. That is the trade the brief asks for in as many words: "add the routes
explicitly *and* add a check that fails when a registry surface has no gateway
route — the drift is the defect, not the individual missing line."

WHAT IT CHECKS
--------------
  1. Every registry surface that is a HOST (no `basePath`) has a router whose
     rule matches its hostname. A `basePath` surface is a route on another
     surface's host and is checked against THAT host instead.
  2. Every host a router matches is a subdomain the registry declares. A router
     for a host nothing composes is dead configuration, and the estate has had
     exactly one — `foresight-admin`, which was fixed by ADDING the registry row
     rather than deleting the router, and is the reason this direction is
     checked too.
  3. A surface whose backend service is in `docker-compose.estate.yml` has an
     API router as well as a bundle router. This is the emberkin/aetherholm case
     and the one that recurs, because a service arriving is a compose-file edit
     and nothing pointed at this file.
  4. Every `cf-api-*`, `cf-web-*` or `cf-svc-*` name written in a COMMENT in
     `gateway/dynamic/*.yml` is actually defined there. See below.
  5. Every surface a browser loads a page from has a CORS origin, and no origin
     is allowlisted that no surface serves.
  6. Every `{{ env "X" }}` that `gateway/dynamic/` reads is SET in every
     `compose/env/traefik*.env`. Checks 1-3 read the FILE, and a router wrapped
     in `{{ if env … }}` is present in the file whether or not it exists at
     runtime — so without this, a conditional router is a route the check
     believes in and the gateway does not.
  7. No router, service or middleware is DEFINED TWICE in `gateway/dynamic/`.
  8. Every request header a BUNDLE sends cross-origin is in the CORS
     `accessControlAllowHeaders` list. A header outside the browser's safelist
     forces a preflight, and a preflight the gateway does not answer for kills
     the request before any service sees it. See below.
     Traefik's file provider merges a directory into one map per section and
     keeps the FIRST definition of a name, so a second one does not conflict,
     does not error and does not override — it is DROPPED. See below.
  9. The `websecure` and `tunnel` entrypoints carry the SAME middleware chain.
     `tunnel` is the only path a real user traverses and no local check drives
     it. See below.
 10. Every origin granted on `CF_VIEW_ORIGIN_SUFFIX` — another environment's
     frontends, reading this one with the reader's bearer — is a UI surface here
     and a bundle that can actually view another network in place. See below.

THE PATH EVERY REAL USER TAKES IS THE ONE NOTHING DRIVES
--------------------------------------------------------
Check 9 was added the way checks 4 and 7 were: the claim was already written
down, in `compose/docker-compose.gateway.yml`, and it named a check that did not
exist —

    # `scripts/surface-routes.py` check 9 fails when the two lists differ.

— which is precisely the defect check 4 exists for, one directory over, where
check 4 does not look. (It reads `gateway/dynamic/*.yml` and matches
`cf-(api|web|svc)-*` names; middleware names are deliberately outside it, and so
is every compose file.)

The claim is worth keeping, so it was made true instead of deleted. A router
listed on two entrypoints becomes one runtime router PER ENTRYPOINT, each with
its own entrypoint's middleware chain, so `websecure` and `tunnel` are two
independent lists of the same intent. `websecure` is :443 — which every check in
this repository drives, because every check runs on the host. `tunnel` is :81,
reached only through cloudflared, which is THE ONLY PATH A BROWSER ON THE
INTERNET TAKES. Drop `cf-cors@file` from that line and the estate stays green
locally, `curl -k https://hub.<apex>` still answers with an allowlist, and every
real visitor's cross-origin call is refused by their own browser.

CROSS-ENVIRONMENT ORIGINS ARE THE ONE GRANT THAT LEAVES THE ESTATE
------------------------------------------------------------------
Check 10 guards `CF_VIEW_ORIGIN_SUFFIX`, which exists because micro-org#459
retired the testnet FRONTENDS and kept the testnet ESTATE. A reader opens
`hub.cloudsforge.online`, picks Testnet in the bar, and the same bundle reads
`hub-testnet.cloudsforge.online` — cross-origin, carrying their bearer, from a
hostname of the OTHER environment. Nothing in the main allowlist names such an
origin by construction: that block is "every surface on THIS environment's own
hostnames", which is what it should be. So the testnet gateway answered the
preflight `HTTP/2 200` with `access-control-allow-credentials: true` and NO
`access-control-allow-origin`, every testnet page in the merged frontend read
"cannot reach the server", and the services behind them were healthy throughout.

The grant that fixes it is the only one in this repository pointed at hostnames
the estate rendering it does not serve, and it sits beside `allowCredentials`.
So it is fenced from three sides:

  * HERE, by check 10: an origin must be a `servesUi` surface in the registry,
    must already be in the main allowlist (so this can only ever RE-grant an
    existing surface on another environment's hostname, never introduce one),
    and must be a bundle that can view another network IN PLACE — which is a
    fact on disk, `src/lib/viewed.ts`, checked in both directions.
  * By check 6, which normally demands every gateway variable in every env file
    and here demands the opposite: set in ONE file, absent from the others. The
    asymmetry is the security property, so it is asserted rather than tolerated.
  * By `scripts/estate-up.sh` preflight 2b, which refuses a suffix equal to this
    environment's own (a grant that reads like one and is a no-op) or outside
    `CF_WEB_APEX` (a credentialed read granted to a domain nobody here owns).

A HEADER MISSING FROM THE CORS LIST IS A ROUTE NO BROWSER CAN CALL
------------------------------------------------------------------
Check 8 was added after `idempotency-key` was found absent from `cf-cors`.

`POST /markets/:id/deploy` on foresight REQUIRES an `Idempotency-Key` header of
8 to 200 characters and answers 400 without one (`idempotencyKeyOf`,
foresight/src/server.ts:1033-1040). The operator panel is the only browser that
calls it, and it has always called foresight CROSS-ORIGIN — from
`foresight-admin.<apex>` before the P13 fold and from `admin.<apex>` after it.

`idempotency-key` is not on the browser's CORS-safelisted request-header list,
so that call triggers an `OPTIONS` preflight, and the browser compares its
`Access-Control-Request-Headers` against what the gateway echoes back. The
gateway echoed `content-type`, `authorization`, `x-request-id` and the three
W3C trace headers. Not that one. So the browser refused the request before
sending it, and the deploy control could not have worked at any point.

WHY NOTHING CAUGHT IT, WHICH IS THE PART WORTH KEEPING. The estate's other
caller of that route is `scripts/foresight-market-journey.mjs`, which runs
under Node: no origin, no preflight, no CORS at all. It passed, repeatedly,
against a route no browser could reach — a check exercising a path by a
mechanism the real client does not use, which is the same class as the tests
behind the `/v1/quotes` and `market.listing` defects.

And it failed in the worst possible shape: Traefik never sees the refused
request, the service never sees it, nothing is logged anywhere, and the
operator gets an unexplained network failure on the screen that deploys a
market contract. This file already says of a missing CORS ORIGIN that it "fails
closed and silently"; a missing HEADER does the same thing for the same reason,
and was not checked.

The list is small and hand-written for the same reason the origin list is, so
it is made impossible for it to be wrong quietly.

TWO ROUTERS OF ONE NAME IS ONE ROUTER, AND NOBODY IS TOLD WHICH
---------------------------------------------------------------
Check 7 was added the same way check 4 was: after this script passed clean over
the defect it should have been the thing to catch.

`cf-api-worlds` was a router in `public-api.yml` — `api.<apex>` with the four
worlds prefixes — and, while `worlds-api.<apex>` was still routed, a DIFFERENT
router of the same name in `estate-web.yml`. The file provider iterates the directory
in sorted filename order and skips a name it has already seen, so `estate-web`
won on the `e`, `public-api`'s router never loaded, and the estate's public API
lost `/v1/titles`, `/v1/players`, `/v1/provisions` and `/v1/seasons`. All four
answered 502 from `cf-api-unrouted` — the catch-all, doing exactly its job on a
request that should never have reached it.

The whole announcement was one line, once, at startup:

    WRN HTTP router already configured, skipping
        filename=public-api.yml providerName=file routerName=cf-api-worlds

in a container whose log is otherwise the access log. Nothing polls it, no
alert reads it, and it does not repeat.

Checks 1-6 could not have caught it, and each reason is a real limit:

  * Check 1 passed: `api.<apex>` HAS a router — six of them, and the file that
    defines them is registered wholesale by `api_host_subdomain()`.
  * Check 2 passed: `api` is a declared registry subdomain.
  * Check 4 passed: both names are DEFINED. That check asks whether prose
    describes something real; this one is the opposite failure — two real
    definitions, one of which does not exist at runtime.
  * Checks 3, 5 and 6 never look at a router name at all.

Every one of them reads the FILE, and the file was right. What was wrong was
what the file provider MADE of two files, which is why this check is the only
one here that compares the directory against itself.

It is namespaced by section, deliberately: `cf-api-worlds` is legitimately both
a router and a service in `public-api.yml:154` and `:206`, because Traefik keys
those in different maps. Flagging that pair would be a check firing on correct
configuration, which check 3's docstring already records as worse than no check.

A ROUTER DESCRIBED IN PROSE IS NOT A ROUTER
-------------------------------------------
Check 4 was added after this script passed clean over the defect it should have
been the thing to catch. `estate-web.yml` carried, for weeks, a paragraph saying
what the explorer's API router would look like "the day it comes off the
profile":

    #   cf-api-explorer:  the same shape as cf-api-hub above, with the host
    #                     templated on explorer, PathPrefix `/v1`, priority 600,
    #                     and a cf-svc-indexer loadBalancer pointing at
    #                     http://indexer:4000.

The router was never defined, and the profile that was the reason had since been
removed — so the paragraph read, to anyone skimming the file that would know,
exactly like documentation of a router that was present. Meanwhile
`https://explorer.<apex>/v1/chains/ember/testnet/status` answered 404 with
`text/html`, `micro-network-site`'s chain panel rendered "Request failed (404)"
against a chain at tip height 2594, and every read `micro-explorer-web` made was
answered by its own index.html.

CHECKS 1-3 COULD NOT HAVE CAUGHT IT, and the reasons are worth stating because
each is a real limit rather than an oversight:

  * Check 1 passed: `explorer.<apex>` HAS a router — `cf-web-explorer`, the
    bundle — so the host was routed and the surface was not missing.
  * Check 2 passed: `explorer` is a declared registry subdomain.
  * Check 3 never ran for it. It resolves a surface to its backend by NAME
    EQUALITY — a compose service called `explorer` — and the service is called
    `indexer`. The registry has no `indexer` key at all; `explorer` IS the key
    that means "the chain index". So the surface fell into exactly the class the
    old comment on check 3 waved past as "the ones where the names differ …
    which are argued individually in estate-web.yml and are already routed".
    Four pairs were named there. `explorer`/`indexer` was a FIFTH, it was not
    named, and it was not routed. That comment was the bug.

Both holes are now closed: `BACKEND_BY_SUBDOMAIN` makes the name-mismatch pairs
data that check 3 reads rather than prose it trusts, and check 4 makes the
weaker but far more general claim that this file may not NAME a router it does
not DEFINE. Check 4 is the cheap one and the one that generalises: it needs no
registry, no compose file and no knowledge of what any surface is for, and it
would have fired on line 248 the day that paragraph was written.

DELIBERATE OMISSIONS ARE DECLARED, NOT SILENT
---------------------------------------------
`EXPECTED_UNROUTED` below names each surface that intentionally has no router and
says why. An entry there is a claim, so the check FAILS ON A STALE ONE too: a
surface listed as intentionally unrouted that has since gained a router is a
comment that has stopped being true, and this estate's whole record is that stale
copies are the thing that costs.

Exit 0 when the two agree. Exit 1 otherwise, and NEVER skips — a check that
cannot run reports failure rather than a success it did not establish.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
UI = MICRO / "ui" / "packages" / "ui"
WEB_MAP = ROOT / "gateway" / "dynamic" / "estate-web.yml"
API_MAP = ROOT / "gateway" / "dynamic" / "public-api.yml"
POLICY = ROOT / "gateway" / "dynamic" / "policy.yml"
TRAEFIK_ENV = ROOT / "compose" / "env" / "traefik.env"
ESTATE = ROOT / "compose" / "docker-compose.estate.yml"
GATEWAY_COMPOSE = ROOT / "compose" / "docker-compose.gateway.yml"

fails = []


def bad(msg):
    fails.append(msg)


# ── surfaces with no router, and the reason each one is allowed to have none ──
#
# Every entry is a CLAIM about the estate, checked in both directions below.
EXPECTED_UNROUTED = {
    # The registry says so itself: "NOTHING IS SERVED HERE TODAY … do not resolve
    # this one for a redirect until something answers it." identity binds 4001 and
    # renders no HTML at all (its server.ts §3 forbids it), and there is no
    # `account-web` among the sibling repositories. The address a person is
    # actually sent to sign in is the `signin` row, which rides on `hub`.
    "account": "no repository serves it; the registry row reserves the hostname and says so",
    # Forge Exchange: a plan, publicly stated, with no code anywhere. The registry
    # row carries `servesUi: false` and says as much in full, and the marketing
    # site publishes the plan as a card — which is why the key has to exist at all,
    # since the site's content model refuses a page whose key the registry does not
    # know.
    #
    # A ROUTER WOULD BE THE WRONG ANSWER HERE, and that is the reason this entry is
    # an entry rather than four lines of YAML. There is no upstream to name, so a
    # router could only point at some other service: `exchange.<apex>` would then
    # answer 200 with a bundle that is not Forge Exchange, or 502, and both are
    # worse than the 404 a plan honestly earns. The 404 is also what every other
    # unbuilt thing in this estate returns, so nothing has to explain it.
    #
    # THIS ENTRY IS DELETED IN THE SAME COMMIT THAT ADDS THE ROUTER. Check 1 fails
    # on a stale entry in the other direction too, so the day something serves this
    # hostname, this line is what fails and points at itself.
    "exchange": "planned, and nothing serves it: the registry row says `servesUi: false` and no repository exists",
    # `keyvault` is the registry key; `vault` is its subdomain. Routed under that
    # name — this entry exists so the key/subdomain mismatch is stated once rather
    # than looking like a gap.
    # (no entry needed: the check resolves by SUBDOMAIN, not by key)
}


# ── surfaces whose backend compose service has a DIFFERENT name ──────────────
#
# Check 3 otherwise resolves a surface to its backend by name equality, and every
# pair below would silently fall out of the check because the two names differ.
# That is not hypothetical: `explorer`/`indexer` fell out of it, and the explorer
# API router went undefined for weeks while this script reported no drift. See the
# module docstring.
#
# An entry is a CLAIM that `<subdomain>.<apex>` should carry an API router, so it
# is checked in both directions like EXPECTED_UNROUTED: a compose service named
# here that no longer exists is a stale mapping and fails too.
BACKEND_BY_SUBDOMAIN = {
    # The chain index. The registry has no `indexer` key — `explorer` IS the key
    # that means "the chain index", which is the substitution micro-network-site
    # had to name in its own header (network-site/src/lib/hosts.ts).
    "explorer": "indexer",
    "hub": "hub-api",
    "admin": "admin-api",
    # A drip is posted to the Network site's own hostname; `faucet` the registry
    # row is a PAGE on it (basePath /faucet), not a host.
    "network": "faucet",
    "pay": "wallet",
}


def registry_surfaces():
    """Read `SURFACES` by running micro-ui's own module. Never re-parsed here."""
    if not UI.is_dir():
        print(f"FAIL: micro-ui is not checked out at {UI} — the registry cannot be read.")
        print("      This is a failure, not a skip: every surface below would go unchecked.")
        sys.exit(1)
    script = (
        "import {SURFACES} from './src/surfaces.ts';"
        "console.log(JSON.stringify(SURFACES.map(s=>"
        "({key:s.key,kind:s.kind,subdomain:s.subdomain,basePath:s.basePath ?? null,"
        "servesUi:s.servesUi}))))"
    )
    try:
        out = subprocess.run(
            ["node", "--import", "tsx", "-e", script],
            cwd=UI, capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: could not run micro-ui's registry: {exc}")
        sys.exit(1)
    if out.returncode != 0:
        print(f"FAIL: micro-ui's registry exited {out.returncode}.")
        print(out.stderr.strip()[-2000:])
        sys.exit(1)
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("[")), None)
    if line is None:
        print("FAIL: micro-ui's registry produced no surface list.")
        print(out.stdout.strip()[-2000:])
        sys.exit(1)
    return json.loads(line)


# `Host(`sub{{ env "CF_WEB_SUFFIX" }}`)` and `Host(`{{ env "CF_SITE_HOST" }}`)`.
#
# TWO VARIABLES, NOT ONE, AND THE SECOND FORM IS NOT AN OMISSION. Changed
# 2026-08-05, when the environment moved from a PREFIX ON THE APEX
# (`hub.testnet.cloudsforge.online`) to a SUFFIX ON THE SUBDOMAIN
# (`hub-testnet.cloudsforge.online`) — the prefix form was two labels deep,
# Cloudflare's Universal SSL wildcard matches one, and every testnet hostname
# therefore failed the TLS handshake at the edge before reaching this estate.
#
# `CF_WEB_SUFFIX` is everything after a surface's own name, so a router reads
# `hub` + suffix. The `site` row's subdomain is the EMPTY STRING and cannot take
# a suffix — `-testnet.cloudsforge.online` is not a legal DNS label — so its host
# is declared outright as `CF_SITE_HOST`. Matching it here as an alternative
# rather than as an optional leading label is what keeps check 2 honest: the
# empty capture means "the apex surface", exactly as it did before.
HOST_RE = re.compile(
    r'Host\(`(?:([a-z0-9-]+)\{\{\s*env\s+"CF_WEB_SUFFIX"\s*\}\}'
    r'|\{\{\s*env\s+"CF_SITE_HOST"\s*\}\})`\)'
)
RULE_RE = re.compile(r"^\s*rule:\s*'(?P<rule>.+)'\s*$")
ROUTER_RE = re.compile(r"^    (?P<name>[a-z0-9-]+):\s*$")


SERVICE_RE = re.compile(r"^\s*service:\s*(?P<svc>[a-z0-9-]+)\s*$")


def gateway_routers():
    """{subdomain: [(router-name, serves_api)]} for every router in estate-web.yml.

    `serves_api` is read from the router's UPSTREAM, not from its path rule, and the
    distinction is the difference between a check and a false alarm. Two shapes carry an
    API and only one of them mentions `/v1`:

      * `Host(x) && PathPrefix(/v1)` -> cf-svc-*   the surface-plus-API shape, where a
        bundle and a service share one hostname and the prefix is what separates them.
      * `Host(x)` -> cf-svc-*                      the WHOLE-HOST shape, used where no
        bundle is served at all — nimbus, lantern, pay, vault. estate-web.yml
        argues for it explicitly: identity "serves 34 unversioned routes at the root … and
        picking prefixes here would be a second, drifting copy of that list".

    Keying on `/v1` alone reported `lantern` as missing an API router while its whole host
    was already routed to `cf-svc-lantern` — a check firing on the correct configuration,
    which is worse than no check because it trains a reader to ignore it.
    """
    if not WEB_MAP.exists():
        print(f"FAIL: {WEB_MAP} does not exist.")
        sys.exit(1)
    found = {}
    name, pending = None, None
    for line in WEB_MAP.read_text().splitlines():
        m = ROUTER_RE.match(line)
        if m:
            name = m.group("name")
            pending = None
            continue
        r = RULE_RE.match(line)
        if r and name is not None:
            pending = [(host.group(1) or "") for host in HOST_RE.finditer(r.group("rule"))]
            continue
        s = SERVICE_RE.match(line)
        if s and pending is not None:
            serves_api = s.group("svc").startswith("cf-svc-")
            for sub in pending:
                found.setdefault(sub, []).append((name, serves_api))
            name, pending = None, None
    return found


def api_host_subdomain():
    """The registry subdomain `CF_API_HOST` names, in EVERY environment's env file, or None.

    ── IT CHECKED ONE FILE AND ONE APEX, AND BOTH HAVE STOPPED BEING ENOUGH ────

    This read `compose/env/traefik.env` alone and asked whether `CF_API_HOST`
    ENDED WITH `.$CF_WEB_APEX`. Two things broke that on 2026-08-05:

      * Both environments now share the apex `cloudsforge.online`, so
        `api.cloudsforge.online` — MAINNET'S API HOST — satisfies "ends with the
        apex" in testnet's env file. The check would have passed while testnet
        published its entire v1 API on mainnet's hostname, where Cloudflare hands
        the request to whichever tunnel registered last.
      * The suffix form means the API host is `api` + `CF_WEB_SUFFIX`, exactly.
        There is nothing to slice and nothing to infer: the answer is a string
        comparison against the same value `cloudsforgeHosts().api` composes in
        the browser.

    So it is exact, and it is asked of every `traefik*.env` rather than of one.
    The subdomain it returns is `api` whenever it returns anything at all — the
    return value is kept because check 1 consumes it, and because the day a
    deployment genuinely serves its public API under another name, this is the
    one place that decision is written down.
    """
    files = sorted(ENV_DIR.glob("traefik*.env"))
    if not files:
        bad(f"no traefik*.env in {ENV_DIR} — CF_API_HOST cannot be checked")
        return None
    subs = set()
    for path in files:
        text = path.read_text()
        api = re.search(r"^CF_API_HOST=(\S+)", text, re.M)
        suffix = re.search(r"^CF_WEB_SUFFIX=(\S+)", text, re.M)
        if not api or not suffix:
            bad(f"{path.name} does not define both CF_API_HOST and CF_WEB_SUFFIX")
            continue
        api_host, web_suffix = api.group(1), suffix.group(1)
        if not api_host.endswith(web_suffix):
            # THE DEFECT THIS FUNCTION EXISTS FOR. `public-api.yml` routes on
            # CF_API_HOST; the registry composes `api` + this environment's
            # suffix. When they disagree, every router in that file is live on a
            # hostname this environment does not own — and now that both
            # environments share one zone, "does not own" can mean "belongs to
            # the other one", which is worse than a 404.
            bad(
                f"{path.name}: CF_API_HOST is '{api_host}' but CF_WEB_SUFFIX is "
                f"'{web_suffix}'. The public API is routed on a host outside this "
                f"environment's own hostnames, so the registry's `api` surface "
                f"(https://api{web_suffix}) reaches no router at all — and on a shared apex "
                f"that host may well belong to the OTHER environment"
            )
            continue
        subs.add(api_host[: -len(web_suffix)])
    if len(subs) > 1:
        bad(f"the environments disagree about the public API's subdomain: {sorted(subs)}. "
            f"`api` is a registry row and every bundle composes it from the registry, so it "
            f"cannot be one name here and another there")
        return None
    return next(iter(subs), None)


def estate_services():
    """Every top-level service name in the estate compose file."""
    if not ESTATE.exists():
        bad(f"{ESTATE} does not exist — the API-router check cannot run")
        return set()
    names, in_services = set(), False
    for line in ESTATE.read_text().splitlines():
        if line.startswith("services:"):
            in_services = True
            continue
        if in_services and re.match(r"^[a-z]", line):
            break
        m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
        if in_services and m:
            names.add(m.group(1))
    return names


# `cf-api-hub`, `cf-web-explorer`, `cf-svc-indexer` — the three prefixes this
# directory names a router or a service with. Middleware names (`cf-cors`,
# `cf-web-headers`, `cf-request-id`) are deliberately NOT matched: they are
# defined across two files and applied from a compose flag, so "defined in this
# directory" is not the right test for them.
CF_NAME_RE = re.compile(r"\b(cf-(?:api|web|svc)-[a-z0-9-]+)\b")
DEFINITION_RE = re.compile(r"^    ([a-z0-9-]+):\s*$")

# ── the one way to mention a router that is gone ─────────────────────────────
#
# Check 6 below refuses any `cf-…` name in a comment that is not defined in this
# directory, because a router described in prose answers "is it routed?" with a
# yes. That is right for a router someone MEANT to add and never did, and wrong
# for one that was deliberately deleted — three of those landed in one day
# (`cf-api-catchall`, `cf-api-unrouted`, `cf-api-worlds-api`) and every one of
# them left behind a tombstone that is worth more than the silence would be.
# `cf-api-worlds-api` is the case that proves it: it routed `worlds-api.<apex>`,
# a hostname with NO DNS RECORD, and its presence in this file is what made a
# re-check conclude the dead host was fine. The note saying so must survive.
#
# So a name is exempt only when the directory ALSO carries an explicit burial:
#
#     # REMOVED: cf-api-worlds-api — folded into api.; worlds-api. has no DNS record
#
# That is a deliberate line someone has to write. Prose about a router the author
# believes exists never contains it, which is the whole distinction — the check
# keeps its teeth and stops punishing the one comment that tells the truth.
REMOVED_RE = re.compile(r"^\s*#\s*REMOVED:\s+(cf-(?:api|web|svc)-[a-z0-9-]+)\b")


def described_but_undefined():
    """Every cf-api/web/svc name in a COMMENT must be defined here, or explicitly buried.

    THE POINT. A router that exists only as prose answers "is it routed?" with a
    yes, in the file that would know, and nothing else in this script looks at
    prose at all. Checks 1-3 all passed over `cf-api-explorer` because the HOST
    was routed by the bundle; this one reads the sentence that made the claim.

    Deliberately dumb, and that is the property worth keeping: it needs no
    registry, no compose file and no idea what a surface is for, so it cannot
    stop running for an environmental reason. It reads YAML by line rather than
    by parser because the file provider renders Go template actions BEFORE the
    YAML is parsed, so on disk this is a template and not YAML at all.

    THE ONE EXEMPTION is a `# REMOVED: <name> — <why>` line, which records a
    router that was deleted on purpose. See `REMOVED_RE` for why that is not a
    hole: a deletion note is the opposite of the claim this check exists to
    catch, and refusing it was pushing people to delete the note instead.
    """
    directory = WEB_MAP.parent
    if not directory.is_dir():
        bad(f"{directory} is not a directory — the described-but-undefined check cannot run")
        return
    defined, mentioned, buried = set(), {}, {}
    for path in sorted(directory.glob("*.yml")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                m = REMOVED_RE.match(line)
                if m:
                    buried.setdefault(m.group(1), []).append(f"{path.name}:{lineno}")
                for name in CF_NAME_RE.findall(line):
                    mentioned.setdefault(name, []).append(f"{path.name}:{lineno}")
                continue
            m = DEFINITION_RE.match(line)
            if m:
                defined.add(m.group(1))

    # A burial for a router that IS defined is the more dangerous direction of the
    # same lie: the tombstone says "gone" while the router is live above it, and a
    # reader who trusts the comment stops looking for the thing that is routing.
    for name, sites in sorted(buried.items()):
        if name in defined:
            bad(
                f"'{name}' is buried by a REMOVED: line at {', '.join(sites)} and is DEFINED in "
                f"{directory.name}/ anyway. The tombstone contradicts the router — delete one"
            )

    for name, sites in sorted(mentioned.items()):
        if name in defined or name in buried:
            continue
        bad(
            f"'{name}' is written in a comment at {', '.join(sites)} and is DEFINED NOWHERE in "
            f"{directory.name}/. A router or service that exists only in prose reads like one "
            f"that exists — define the thing it describes, delete the sentence, or, if it was "
            f"deliberately deleted, bury it with a '# REMOVED: {name} — <why>' line"
        )


SECTION_RE = re.compile(r"^([a-z]+):\s*$")
SUBSECTION_RE = re.compile(r"^  ([a-zA-Z]+):\s*$")


def defined_twice():
    """── 7: no name is DEFINED TWICE in this directory ─────────────────────────

    THE FAILURE IS THAT THERE IS NO FAILURE. Two routers of one name do not
    conflict and do not merge: `pkg/provider/file/file.go` walks the directory in
    sorted filename order and, for a name already present, logs one WARN and moves
    on. The second definition is discarded in full — rule, priority, middlewares,
    upstream — and everything downstream of it behaves exactly as if it had never
    been written. See the module docstring for the instance that cost the public
    API four resources.

    Which of the two survives is decided by FILENAME ORDER, so the same directory
    can route differently after a file is renamed, and nothing in the diff would
    say so. That is the property this check exists to remove: not "a duplicate is
    wrong" but "a duplicate makes the routing order-dependent".

    Namespaced by `<section>.<subsection>` — `http.routers`, `http.services`,
    `http.middlewares`, `tcp.routers`, `tls.stores` — because Traefik keys each
    map separately and a router MAY share a name with its own service. It reads
    the files by line rather than with a YAML parser for the reason check 4 gives:
    the file provider renders Go template actions BEFORE parsing, so on disk these
    are templates and not YAML. Line-reading also means a router inside an
    `{{ if env … }}` is counted, which is correct — a conditional does not make a
    name safe to reuse, it makes the collision depend on the environment too.
    """
    directory = WEB_MAP.parent
    if not directory.is_dir():
        bad(f"{directory} is not a directory — the duplicate-definition check cannot run")
        return
    seen = {}
    for path in sorted(directory.glob("*.yml")):
        section = subsection = None
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            m = SECTION_RE.match(line)
            if m:
                section, subsection = m.group(1), None
                continue
            m = SUBSECTION_RE.match(line)
            if m:
                subsection = m.group(1)
                continue
            m = DEFINITION_RE.match(line)
            if m and section and subsection:
                key = (f"{section}.{subsection}", m.group(1))
                seen.setdefault(key, []).append(f"{path.name}:{lineno}")
    if not seen:
        bad(f"no definition found anywhere in {directory.name}/ — this check reads router, "
            f"service and middleware names, and finding none means it is asserting nothing")
        return
    for (namespace, name), sites in sorted(seen.items()):
        if len(sites) < 2:
            continue
        kept, dropped = sites[0], sites[1:]
        bad(
            f"'{name}' is defined {len(sites)} times under `{namespace}` — {', '.join(sites)}. "
            f"Traefik's file provider keeps the FIRST by sorted filename ({kept}) and SILENTLY "
            f"DROPS the rest ({', '.join(dropped)}), logging one WARN at startup and nothing "
            f"afterwards. Everything the dropped definition routes is unreachable, and which one "
            f"survives depends on what the files are called. Rename one of them"
        )


# ── THIS USED TO REQUIRE `env "X"` TO BE THE WHOLE ACTION ─────────────────────
#
# It was `\{\{\s*(?:if\s+)?env\s+"([A-Z0-9_]+)"\s*\}\}` — the variable had to be
# the entire template action, optionally behind a bare `if`. That covered the two
# shapes the directory had at the time and NOTHING ELSE, so the first conditional
# to compare a value instead of testing for emptiness became invisible to check
# 6 below:
#
#     {{ if eq (env "CF_EMBER_NETWORK") "testnet" }}
#
# That is the router that decides whether an estate publishes a faucet. Under the
# old pattern the variable it reads could have been absent from one environment's
# env file, or from both, and this check — the one written specifically to stop a
# router existing in one of two estates — would have reported nothing.
#
# So the anchor is the `env "X"` CALL, wherever it appears in a line. `{{` is no
# longer required on the same line either: a nested action can be broken across
# lines, and a variable that goes unseen because of where somebody put a newline
# is the same blindness in a smaller form.
TEMPLATE_ENV_RE = re.compile(r'\benv\s+"([A-Z0-9_]+)"')
ENV_DIR = ROOT / "compose" / "env"


# ── the variables that are SET IN ONE ENVIRONMENT ON PURPOSE ─────────────────
#
# Check 6's rule is "every variable this directory reads is set in EVERY gateway
# env file", and its reason is a good one: a variable added to a template and to
# one environment is a router that exists in one of the two estates, which is the
# hardest kind of difference to see.
#
# This table is for the case where that difference is the POINT, and it does not
# weaken the check — it inverts it. An entry does not mean "stop looking"; it
# means the variable must be set in the named file AND ABSENT FROM EVERY OTHER
# ONE, which is a stronger claim than check 6 makes about anything else. It is
# checked in both directions like every other table here: an entry for a variable
# `gateway/dynamic/` no longer reads is a stale exemption, and it fails too.
#
# Keep it at one or two entries. Every line here is an environment difference
# somebody has to hold in their head, and the reason has to be worth that.
ENV_VARS_SET_IN_ONE_FILE = {
    "CF_VIEW_ORIGIN_SUFFIX": (
        "traefik.testnet.env",
        "it grants ANOTHER environment's frontends a credentialed cross-origin read of this "
        "one, and the direction is the security property. micro-org#459 retired the testnet "
        "FRONTENDS and kept the testnet ESTATE, so the mainnet bundles read testnet in place "
        "and testnet must allow them; the reverse — a page on a worthless-coin hostname "
        "reading a credentialed mainnet response — moves real value and has no product reason "
        "to exist. Setting it in traefik.env would open that direction in one line, in a file "
        "both gateways mount",
    ),
}


def env_vars_are_set():
    """── 6: every variable this directory READS is SET in every gateway env file ──

    THE FAILURE THIS CLOSES IS THE ONE THIS ESTATE HAS ALREADY PAID FOR TWICE, and
    both times the symptom was a hostname that resolved and answered nothing.

      * `CF_API_HOST` was undefined in the env_file the gateway actually loads, so
        every router in public-api.yml rendered as ``Host(``) && PathPrefix(...)``
        — a VALID rule matching no request ever sent. Traefik logged nothing. The
        whole public API was dead and the only symptom was a 404 from the
        catch-all. `compose/env/traefik.env` records it at length.
      * The same shape is now DELIBERATE for `CF_WEB_APEX` and for the two chain
        upstreams: estate-web.yml wraps its routers in `{{ if env ... }}` so that
        an unset variable produces NO ROUTER rather than a broken one. That is the
        right failure — but it is SILENT, and check 1 above cannot see it, because
        check 1 reads the FILE and the file always contains the rule.

    So the two halves are checked from opposite ends. Check 1 asserts the router is
    written; this asserts the variable that decides whether it exists is set, in
    EVERY environment's env file rather than in the one somebody was looking at.

    A new `{{ env "X" }}` anywhere in gateway/dynamic/ therefore fails until X is
    given a value in each `compose/env/traefik*.env`. That is the intended cost: a
    variable added to a template and to one environment is a router that exists in
    one of the two estates, which is the hardest kind of difference to see.

    THE ONE EXCEPTION IS ASSERTED, NOT WAIVED. `ENV_VARS_SET_IN_ONE_FILE` names
    the variables whose whole purpose is to differ between environments, and for
    those this check runs the OTHER WAY ROUND: set in the named file, absent from
    every other. See that table for why one line in the wrong file is a grant.
    """
    directory = WEB_MAP.parent
    if not directory.is_dir():
        bad(f"{directory} is not a directory — the template-variable check cannot run")
        return
    wanted = {}
    for path in sorted(directory.glob("*.yml")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            # Comments are skipped, as check 5 already does, and the widened
            # pattern above is what made it necessary: this directory ARGUES
            # about its own templating in prose, and a variable NAMED in a
            # comment explaining why it was not used is not a variable Traefik
            # reads. Demanding a value for it would fail a check on the strength
            # of a sentence, which is how a suite teaches people to delete
            # explanations.
            if line.lstrip().startswith("#"):
                continue
            for name in TEMPLATE_ENV_RE.findall(line):
                wanted.setdefault(name, f"{path.name}:{lineno}")
    if not wanted:
        bad(f"no `{{{{ env \"...\" }}}}` reference found anywhere in {directory.name}/ — this "
            f"check reads templates, and finding none means it is asserting nothing")
        return
    files = sorted(ENV_DIR.glob("traefik*.env"))
    if not files:
        bad(f"no traefik*.env in {ENV_DIR} — the gateway's environment cannot be checked, and "
            f"every conditional router in {directory.name}/ would go unverified")
        return
    # A per-environment entry for a variable this directory has stopped reading is
    # a waiver granting an asymmetry nothing needs, and it would go on passing.
    for name, (owner, _why) in sorted(ENV_VARS_SET_IN_ONE_FILE.items()):
        if name not in wanted:
            bad(
                f"ENV_VARS_SET_IN_ONE_FILE names {name} as set only in {owner}, and nothing in "
                f"{directory.name}/ reads it any more. The entry is stale — delete it, and delete "
                f"the line in {owner} with it"
            )
        elif not (ENV_DIR / owner).exists():
            bad(
                f"ENV_VARS_SET_IN_ONE_FILE says {name} lives in {owner}, which does not exist in "
                f"{ENV_DIR}. The variable is then set NOWHERE and the block it guards renders "
                f"nothing, silently"
            )

    for path in files:
        text = path.read_text()
        for name, site in sorted(wanted.items()):
            m = re.search(rf"^{re.escape(name)}=(.*)$", text, re.M)
            owner = ENV_VARS_SET_IN_ONE_FILE.get(name, (None, None))[0]
            if owner is not None:
                # Inverted on purpose: this variable must be in its own file and in
                # no other. Both halves are failures, and the second is the one that
                # matters — a value in the wrong file is a live grant.
                if path.name == owner:
                    if m is None or not m.group(1).strip():
                        why = ENV_VARS_SET_IN_ONE_FILE[name][1]
                        bad(
                            f"{path.name} does not set {name}, and it is the ONE file that must: "
                            f"{why}. {site} reads it, and an unset variable renders that block "
                            f"empty with nothing logged"
                        )
                elif m is not None and m.group(1).strip():
                    why = ENV_VARS_SET_IN_ONE_FILE[name][1]
                    bad(
                        f"{path.name} sets {name}, which belongs in {owner} and NOWHERE ELSE: "
                        f"{why}. Delete the line"
                    )
                continue
            if m is None:
                bad(
                    f"{path.name} does not set {name}, which {site} reads. Traefik's file "
                    f"provider renders `{{{{ env \"{name}\" }}}}` to the EMPTY STRING for an "
                    f"unset variable, so that router either matches nothing or is dropped by its "
                    f"own conditional — and neither failure logs anything"
                )
            elif not m.group(1).strip():
                bad(
                    f"{path.name} sets {name} to an empty value, which {site} reads. An empty "
                    f"value is INDISTINGUISHABLE FROM UNSET to the file provider, so this is the "
                    f"same failure as omitting the line and is reported the same way. An "
                    f"environment that genuinely should not carry that router changes the ROUTER, "
                    f"where the reason can be written down — not this file, where its absence "
                    f"looks like an oversight"
                )


CORS_ENTRY_RE = re.compile(
    r'^\s*-\s*https://(?:([a-z0-9-]+)\{\{\s*env\s+"CF_WEB_SUFFIX"\s*\}\}'
    r'|\{\{\s*env\s+"CF_SITE_HOST"\s*\}\})\s*$'
)


def cors_allowlist():
    """Subdomains in `cf-cors`, in policy.yml. Same two forms as HOST_RE above.

    THERE IS ONLY ONE LIST NOW, AND THAT IS A CHANGE THIS CHECK GOT FOR FREE.
    This used to read only the templated block and skip fifteen hard-coded
    `https://<sub>.cloudsforge.online` entries above it, on the argument that
    they were "a DIFFERENT list about a different deployment". They had stopped
    being one: `traefik.env` sets the mainnet values, so both halves rendered the
    same fifteen origins — and the TESTNET gateway, which mounts this same
    directory, carried the mainnet fifteen in a list that sets
    `allowCredentials: true`. On a shared apex that is a live cross-environment
    read. The literal block is deleted; this reads the whole allowlist now, and
    what it checks is therefore the whole of it.
    """
    if not POLICY.exists():
        bad(f"{POLICY} does not exist — the CORS allowlist cannot be checked")
        return None
    return {m.group(1) or "" for line in POLICY.read_text().splitlines()
            if (m := CORS_ENTRY_RE.match(line))}


def cors_drift(surfaces):
    """── 5: every surface a BROWSER loads has a CORS origin, and vice versa ────

    THE FOURTH COPY OF THE SAME DEFECT, AND THE ONE STILL UNCHECKED.

    `cf-cors` in policy.yml carries a hand-written list of eighteen origins under
    `{{ if env "CF_WEB_APEX" }}`. Every entry is `https://<sub>.<apex>`, and the
    set of subdomains is exactly `servesUi === true` in the registry — eighteen
    of them, derivable in one line, written out by hand and maintained by nobody.

    That file's own comments record it drifting FOUR TIMES, each found by a human
    noticing a broken page rather than by a check:

      * `mint` was allowlisted; the registry subdomain is `create`, and
        `mint.<apex>` is a host nothing serves.
      * `devportal` was allowlisted, written from the repository name
        micro-devportal-web; the registry subdomain is `developers`.
      * `network` and `foresight` were MISSING — "the only two registry products
        absent from this list, found when micro-network-site's chain panel could
        fetch nothing".
      * `emberkin`, `aetherholm`, `tessera` and `foresight-admin` were missing,
        added only when someone opened the file.

    policy.yml says of each of these, correctly and four times over: "An allowlist
    that omits an origin FAILS CLOSED AND SILENTLY: the browser refuses the
    response and nothing server-side records that anything was refused." That is
    the worst possible failure shape — no log, no status code, no trace — and it
    is why this is checked rather than trusted.

    The list is still hand-written, for the same reason `estate-web.yml` is: it
    is interleaved with the argument for each entry. So, like that file, it is
    made impossible for it to be wrong quietly.

    `servesUi` is the right predicate and not an approximation. Every one of these
    origins is here because `consumeAuthCallback` POSTs to
    `nimbus.<apex>/auth/handoff/redeem` from whatever origin the page is on
    (ui/packages/ui/src/index.tsx), so an origin missing here cannot complete a
    sign-in. A surface that serves no UI has no page and no origin; the six API
    hosts are correctly absent, and requiring them would be requiring a CORS entry
    for a browser tab that never exists.
    """
    allowed = cors_allowlist()
    if allowed is None:
        return
    needed = {s["subdomain"] for s in surfaces if not s["basePath"] and s["servesUi"]}
    for sub in sorted(needed - allowed):
        bad(
            f"surface '{sub or '<apex>'}' serves a UI and has NO entry in the cf-cors allowlist "
            f"(gateway/dynamic/policy.yml). Every bundle posts to nimbus cross-origin on boot, so "
            f"a missing origin means sign-in cannot complete there — and it fails closed and "
            f"silently: the browser refuses the response and nothing server-side records it"
        )
    for sub in sorted(allowed - needed):
        bad(
            f"the cf-cors allowlist names origin 'https://{sub or ''}.<apex>', which no registry "
            f"surface serves a UI on. That is the `mint`/`devportal` defect — an entry written "
            f"from a repository name rather than from the registry — and it grants an origin "
            f"nothing needs"
        )


CORS_HEADER_RE = re.compile(r"^\s*-\s*([a-z][a-z0-9-]*)\s*$")


def cors_allowed_headers():
    """The `accessControlAllowHeaders` list in `cf-cors`, lower-cased."""
    if not POLICY.exists():
        bad(f"{POLICY} does not exist — the CORS header list cannot be checked")
        return None
    text = POLICY.read_text().splitlines()
    try:
        start = next(i for i, l in enumerate(text) if "accessControlAllowHeaders:" in l)
    except StopIteration:
        bad("cf-cors declares no accessControlAllowHeaders at all, so every cross-origin request "
            "carrying a non-safelisted header is refused by the browser before it is sent")
        return None
    found = set()
    for line in text[start + 1:]:
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue
        m = CORS_HEADER_RE.match(line)
        if not m:
            break
        found.add(m.group(1).lower())
    return found


# ── request headers a bundle sends cross-origin, and what breaks without each ──
#
# Every entry is a CLAIM about a real client, cited, and is checked in one
# direction only: a header a bundle sends MUST be allowlisted. The reverse is
# deliberately not asserted — an allowlisted header nobody sends grants nothing
# and costs nothing, unlike a spare ORIGIN, which grants a whole page access.
REQUIRED_CORS_HEADERS = {
    "authorization": "every authenticated cross-origin call in the estate; without it no bundle "
                     "can present a bearer token to a service on another host",
    "content-type": "every cross-origin POST/PATCH with a JSON body; `application/json` is not a "
                    "safelisted value, so this is needed even though the header name looks common",
    "idempotency-key": "admin-web's Foresight deploy control (`POST /markets/:id/deploy`), which "
                       "foresight REQUIRES the header on (foresight/src/server.ts:1033-1040) and "
                       "which admin-web calls cross-origin from `admin.<apex>` "
                       "(admin-web/src/lib/foresight.ts, `deployMarket`)",
}


def cors_headers_drift():
    """── 8: every header a bundle sends cross-origin is allowlisted ───────────"""
    allowed = cors_allowed_headers()
    if allowed is None:
        return
    for header, why in sorted(REQUIRED_CORS_HEADERS.items()):
        if header in allowed:
            continue
        bad(
            f"the cf-cors allowlist does not name the request header '{header}', which is sent by "
            f"{why}. A header outside the browser's CORS safelist forces an OPTIONS preflight, and "
            f"a preflight that does not echo the header name makes the browser REFUSE the request "
            f"before it is sent — so nothing reaches Traefik, nothing reaches the service, and "
            f"nothing is logged anywhere. It fails closed and silently, exactly like a missing "
            f"origin"
        )


ENTRYPOINT_CHAIN_RE = re.compile(
    r"--entrypoints\.(?P<entrypoint>[a-z]+)\.http\.middlewares=(?P<chain>\S+)"
)

# The entrypoints that must carry the same middleware chain, and why each is in
# the pair. Not "every entrypoint": `web` is a 301 to `websecure` and carries no
# chain at all, and `metrics` is an internal listener on :8082.
PAIRED_ENTRYPOINTS = {
    "websecure": ":443, the path every check in this repository drives, because every check "
                 "runs on the host",
    "tunnel": ":81 through cloudflared, THE ONLY PATH A BROWSER ON THE INTERNET TAKES, and the "
              "one no check drives",
}


def entrypoint_chains_match():
    """── 9: `websecure` and `tunnel` carry the SAME middleware chain ───────────

    An entrypoint's middleware chain is PER ENTRYPOINT: Traefik splits a router
    listed on two entrypoints into one runtime router each and applies the model of
    ITS OWN entrypoint to each half. So these two flags are two independent lists
    of one intent, and the compose file's own comment — which named this check
    before it existed — says what happens when they diverge: "the tunnel path,
    WHICH IS THE ONLY PATH REAL USERS TRAVERSE, silently loses request-id, the
    security headers and the CORS allowlist, while :443 keeps all three and every
    local check stays green, because every local check drives :443."

    Order is compared as well as membership. `cf-request-id@file` first is what
    puts a request id on the security headers and the CORS response of the SAME
    request; a chain with the same names in another order is a different chain.
    """
    if not GATEWAY_COMPOSE.exists():
        bad(f"{GATEWAY_COMPOSE} does not exist — the entrypoint-chain check cannot run")
        return
    chains = {}
    for lineno, line in enumerate(GATEWAY_COMPOSE.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = ENTRYPOINT_CHAIN_RE.search(line)
        if m and m.group("entrypoint") in PAIRED_ENTRYPOINTS:
            chains[m.group("entrypoint")] = (m.group("chain").split(","), lineno)
    for name, what in sorted(PAIRED_ENTRYPOINTS.items()):
        if name not in chains:
            bad(
                f"the `{name}` entrypoint ({what}) has no `--entrypoints.{name}.http.middlewares` "
                f"flag in {GATEWAY_COMPOSE.name}. An entrypoint with no chain applies NO "
                f"middleware — no request id, no security headers and no CORS allowlist — to "
                f"every request that arrives on it"
            )
    if len(chains) < len(PAIRED_ENTRYPOINTS):
        return
    (a, (chain_a, line_a)), (b, (chain_b, line_b)) = sorted(chains.items())
    if chain_a != chain_b:
        bad(
            f"the `{a}` and `{b}` entrypoints carry DIFFERENT middleware chains "
            f"({GATEWAY_COMPOSE.name}:{line_a} and :{line_b}) —\n"
            f"           {a}: {','.join(chain_a)}\n"
            f"           {b}: {','.join(chain_b)}\n"
            f"       and only one of them is reachable from the internet. `tunnel` is the path "
            f"cloudflared uses and nothing local drives it, so whatever it is missing is missing "
            f"for every real visitor while every check on this host stays green"
        )


VIEW_ORIGIN_RE = re.compile(
    r'^\s*-\s*https://([a-z0-9-]+)\{\{\s*env\s+"CF_VIEW_ORIGIN_SUFFIX"\s*\}\}\s*$'
)

# ── the bundles that can view ANOTHER network in place, and the file that proves it ──
#
# Every other surface switches network by NAVIGATING (`NetworkSwitcher` with no
# `onSelect`), so its reads are same-origin on whichever hostname it lands and a
# cross-environment origin would grant a read nothing performs. These three
# re-point their reads at the sibling estate instead, and each one has a module
# that does it. The witness is that module: a claim about a bundle, checked
# against the bundle, rather than three names in a list nobody revisits.
VIEWING_BUNDLES = {
    "hub": "hub-web/src/lib/viewed.ts",
    "explorer": "explorer-web/src/lib/viewed.ts",
    "network": "network-site/src/lib/viewed.ts",
}


def view_origin_drift(surfaces):
    """── 10: every cross-environment origin is a surface here and a viewer there ─

    THE ONLY GRANT IN THIS REPOSITORY POINTED AT HOSTNAMES THIS ESTATE DOES NOT
    SERVE, and it sits beside `allowCredentials: true`. See the module docstring
    for the failure it was written for. What is asserted, and why each half:

      * The grant list equals `VIEWING_BUNDLES` exactly. A name here that cannot
        view another network in place grants a credentialed cross-environment read
        that nothing makes; a viewing bundle NOT here is the original bug — its
        preflight is answered 200 with no `access-control-allow-origin` and its
        page says "cannot reach the server" while the service is healthy.
      * Each is a `servesUi` host surface in the registry, for the reason check 5
        gives: an origin written from a repository name rather than the registry
        is the `mint`/`devportal` defect, and it is worse here.
      * Each is ALREADY in the main allowlist, and the two lists are not equal.
        That makes this block strictly weaker than the one above it — it can only
        re-grant a surface this estate already serves, on the other environment's
        hostname — so a new surface can never enter the estate through it.

    ── THE WITNESS HALF IS BEST-EFFORT, AND SAYS SO OUT LOUD ────────────────────

    `src/lib/viewed.ts` is checked in the sibling checkouts that are PRESENT. CI
    checks out `deploy`, `ui`, `foresight` and `billing`, and a deploy host clones
    no frontend at all (`scripts/provision-siblings.sh`), so in both of those the
    witness cannot be read — and the run prints which corroboration it did not
    perform rather than reporting a check it did not make. The three assertions
    above need nothing but `policy.yml` and the registry, and they always run.

    In a full checkout the witness runs in BOTH directions, and the second is the
    one that ends this class of bug: a fourth bundle that gains `viewed.ts` and no
    entry here fails, before anybody opens it in a browser.
    """
    if not POLICY.exists():
        bad(f"{POLICY} does not exist — the cross-environment origins cannot be checked")
        return
    granted = {m.group(1) for line in POLICY.read_text().splitlines()
               if (m := VIEW_ORIGIN_RE.match(line))}
    declared = set(VIEWING_BUNDLES)

    for sub in sorted(declared - granted):
        bad(
            f"'{sub}' views another network IN PLACE ({VIEWING_BUNDLES[sub]}) and has NO origin "
            f"on CF_VIEW_ORIGIN_SUFFIX in {POLICY.name}. Its cross-environment reads are answered "
            f"200 with no `access-control-allow-origin`, so the browser refuses them and the page "
            f"reads 'cannot reach the server' with the service behind it healthy — and nothing "
            f"server-side records that anything was refused"
        )
    for sub in sorted(granted - declared):
        bad(
            f"the cf-cors allowlist grants 'https://{sub}<CF_VIEW_ORIGIN_SUFFIX>' — a CREDENTIALED "
            f"cross-origin read from ANOTHER environment's hostname — and '{sub}' is not in "
            f"VIEWING_BUNDLES, so no bundle of that name reads across environments at all. Either "
            f"it gained a src/lib/viewed.ts and belongs in the table, or the grant is unearned"
        )

    if granted:
        ui_hosts = {s["subdomain"] for s in surfaces if not s["basePath"] and s["servesUi"]}
        for sub in sorted(granted - ui_hosts):
            bad(
                f"the cross-environment origin 'https://{sub}<CF_VIEW_ORIGIN_SUFFIX>' names '{sub}', "
                f"which is not a registry surface that serves a UI. There is no page on that "
                f"hostname in EITHER environment, so the entry grants an origin nothing loads"
            )
        allowed = cors_allowlist()
        if allowed is not None:
            for sub in sorted(granted - allowed):
                bad(
                    f"'{sub}' is granted on CF_VIEW_ORIGIN_SUFFIX but is NOT in this environment's "
                    f"own CORS allowlist. The cross-environment block may only re-grant a surface "
                    f"this estate already serves; a name that appears in one list and not the "
                    f"other lets a hostname in through the weaker door"
                )
            if allowed and granted >= allowed:
                bad(
                    f"the cross-environment origins are not a STRICT subset of the CORS allowlist "
                    f"({len(granted)} of {len(allowed)}). Every surface in the estate would accept "
                    f"credentialed reads from the other environment, which is not what the "
                    f"combined view needs — three bundles view in place and the rest navigate"
                )

    # The witness, where it can be read. Absence of a checkout is REPORTED, not
    # passed over: this file's rule is that a check which cannot run says so.
    unread = []
    for sub, witness in sorted(VIEWING_BUNDLES.items()):
        repo = MICRO / witness.split("/", 1)[0]
        if not repo.is_dir():
            unread.append(repo.name)
            continue
        if not (MICRO / witness).exists():
            bad(
                f"VIEWING_BUNDLES claims '{sub}' views another network in place via {witness}, "
                f"and that file does not exist. Either the bundle stopped viewing in place — in "
                f"which case its cross-environment origin is an unearned credentialed grant and "
                f"goes with it — or the module moved and this table has stopped being checkable"
            )
    for path in sorted(MICRO.glob("*/src/lib/viewed.ts")):
        witness = f"{path.parent.parent.parent.name}/src/lib/viewed.ts"
        if witness not in VIEWING_BUNDLES.values():
            bad(
                f"{witness} exists, so that bundle re-points its reads at the sibling estate, and "
                f"it is not in VIEWING_BUNDLES. Every read it makes across environments will be "
                f"refused by the browser at the preflight — the exact failure micro-org#459 shipped "
                f"— unless it is added here AND granted an origin in {POLICY.name}"
            )
    if unread:
        print(f"  note check 10's witness files were not read for {', '.join(unread)} — not "
              f"checked out here. The allowlist, registry and subset assertions all ran.")


RETIRED_ROUTER = "cf-retired-web-sub"
RETIRED_SPARED_RE = re.compile(r'!HostRegexp\(`\^\(\?:([a-z0-9|-]+)\)-testnet\\\.')


def retirement_spares_services(surfaces):
    """── 11: the retirement redirect catches PAGES, and nothing but pages ───────

    THE DEFECT, MEASURED. `cf-retired-web-sub` matched `^[a-z0-9-]+-testnet\\.` at
    priority 550, over the 500 that most routers carry. It therefore did not
    retire the testnet FRONTENDS; it retired every testnet hostname that had not
    been given a higher number, chain endpoints included:

        GET  https://rpc-testnet.cloudsforge.online/   -> 302 rpc.cloudsforge.online
        POST (following) {"method":"eth_chainId"}      -> {"result":"0x1cf3"}

    `0x1cf3` is 7411 — MAINNET. Chain 7412 had no public JSON-RPC for the whole
    life of the retirement, and anything pointed at the testnet RPC was answered
    200 with mainnet state. `p2p-testnet` was redirected the same way, which a
    WebSocket cannot survive. Nothing 5xx'd, nothing was logged as refused, and
    every probe in this repository stayed green: the estate was answering, just
    for the other network.

    WHY THE EXISTING NEGATIVE MISSED IT. `!PathPrefix(`/v1`)` spares the estate's
    HTTP APIs because those are versioned. The chain endpoints are not: hearth's
    `jsonrpc/server.js` has no path dispatch at all and serves JSON-RPC at `/`.
    A path negative cannot spare a service that serves the root.

    WHAT IS ASSERTED. The rule's second negative — its alternation of spared
    hostnames — EQUALS the registry's `servesUi: false` subdomains, both
    directions:

      * A non-UI subdomain missing from the alternation is the bug above,
        recurring: that hostname answers as the other network, invisibly.
      * A name in the alternation whose registry row DOES serve a UI is a
        frontend that quietly escaped the retirement — it keeps serving its own
        testnet bundle at a hostname micro-org#459 said would redirect.

    `servesUi` is the right predicate rather than a proxy for one. The redirect's
    whole message is "the PAGE you wanted is served on mainnet now"; a hostname
    with no page has no such answer to give, whatever else it serves. It is also
    the same predicate checks 5 and 10 key on, so the three cannot disagree about
    what a surface is.

    THE CHECK IS SKIPPED, LOUDLY, IF THE RULE STOPS BEING PARSEABLE, because a
    silently-zero comparison here would restore exactly the state this was
    written for.
    """
    if not WEB_MAP.exists():
        bad(f"{WEB_MAP} does not exist — the retirement rule cannot be checked")
        return
    lines = WEB_MAP.read_text().splitlines()
    rule = None
    for i, line in enumerate(lines):
        if line.strip() == f"{RETIRED_ROUTER}:":
            for follow in lines[i + 1: i + 4]:
                m = RULE_RE.match(follow)
                if m:
                    rule = m.group("rule")
            break
    if rule is None:
        # Not a failure: mainnet renders no retirement router, and the block is
        # inside `{{ if eq (env "CF_WEB_RETIRED") "true" }}` — but the FILE always
        # contains it, so absence here means the router was renamed or removed.
        print(f"  note check 11 found no '{RETIRED_ROUTER}' rule in {WEB_MAP.name} — "
              f"if the retirement was lifted, delete this check with it")
        return
    m = RETIRED_SPARED_RE.search(rule)
    if m is None:
        bad(
            f"'{RETIRED_ROUTER}' has no `!HostRegexp(...)` alternation sparing the estate's "
            f"non-UI hostnames. Its `^[a-z0-9-]+-testnet\\.` matches EVERY testnet hostname at "
            f"priority 550, so `rpc-testnet` 302s to the mainnet RPC and a caller reading chain "
            f"7412 is answered chain 7411 with a 200 — measured, and the reason this check exists"
        )
        return
    spared = set(m.group(1).split("|"))
    services = {
        s["subdomain"] for s in surfaces
        if s["subdomain"] and not s["basePath"] and not s["servesUi"]
    }

    for sub in sorted(services - spared):
        bad(
            f"'{sub}' serves no UI (registry `servesUi: false`) and is NOT spared by "
            f"'{RETIRED_ROUTER}'. Every request to '{sub}-testnet.<apex>' outside `/v1` is 302'd "
            f"to the MAINNET hostname of the same name, so that endpoint answers with the wrong "
            f"network's state and returns 200 doing it — no error, no log line, nothing red"
        )
    for sub in sorted(spared - services):
        row = next((s for s in surfaces if s["subdomain"] == sub and not s["basePath"]), None)
        if row is None:
            bad(
                f"'{RETIRED_ROUTER}' spares '{sub}-testnet.<apex>' and NO registry surface "
                f"declares subdomain '{sub}'. Nothing composes that address, so the exclusion "
                f"protects a hostname that does not exist — the same dead-configuration failure "
                f"check 2 catches on the other side"
            )
        else:
            bad(
                f"'{RETIRED_ROUTER}' spares '{sub}-testnet.<apex>', but surface '{row['key']}' "
                f"SERVES A UI there. micro-org#459 retired the testnet frontends; this one still "
                f"serves its own testnet bundle at its own hostname, which is the state the "
                f"retirement was supposed to end"
            )


def main():
    surfaces = registry_surfaces()
    routers = gateway_routers()
    api_sub = api_host_subdomain()
    services = estate_services()

    # public-api.yml routes one more subdomain, on its own variable.
    if api_sub is not None:
        routers.setdefault(api_sub, []).append(("public-api.yml", True))

    declared = {s["subdomain"] for s in surfaces}

    # ── 1 & 3: every host surface has a router, and an API one where it can ────
    for s in surfaces:
        sub, key = s["subdomain"], s["key"]
        if s["basePath"]:
            # A route on another surface's host. Its host must be routed; the
            # surface itself never gets one.
            if sub not in routers:
                bad(
                    f"surface '{key}' is a path on '{sub or '<apex>'}.<apex>' and that HOST has "
                    f"no router — the page it deep-links to is unreachable"
                )
            continue
        if sub not in routers:
            why = EXPECTED_UNROUTED.get(key)
            if why:
                print(f"  ok   {key:<16} intentionally unrouted — {why}")
            else:
                bad(
                    f"surface '{key}' declares host '{sub or '<apex>'}.<apex>' and NO ROUTER "
                    f"matches it: every bundle in the estate composes that address from the "
                    f"registry, so every call to it 404s at the gateway"
                )
            continue
        if key in EXPECTED_UNROUTED:
            bad(
                f"'{key}' is listed in EXPECTED_UNROUTED as intentionally having no router, "
                f"and it HAS one now ({routers[sub][0][0]}). The comment has stopped being "
                f"true — delete the entry."
            )

    # ── 3: a surface whose backend is deployed should have an API router ──────
    #
    # Resolved by NAME: a compose service whose name equals the surface's
    # subdomain is that surface's backend, OR the mapping in
    # `BACKEND_BY_SUBDOMAIN` says which service it is when the two names differ.
    #
    # That second half used to be a COMMENT asserting the mismatched pairs were
    # "already routed" rather than a lookup that checked it, and `explorer`/
    # `indexer` was a pair the comment did not name and the estate did not route.
    # A claim in prose beside a check is not covered by the check.
    for s in surfaces:
        sub = s["subdomain"]
        if s["basePath"] or not sub or sub not in routers:
            continue
        backend = BACKEND_BY_SUBDOMAIN.get(sub, sub)
        if backend not in services:
            continue
        if not any(serves_api for _, serves_api in routers[sub]):
            named = f" (its backend service is '{backend}')" if backend != sub else ""
            bad(
                f"'{sub}' is a service in docker-compose.estate.yml AND a routed surface{named}, "
                f"but no router on its host points at a cf-svc-* upstream: the bundle answers its "
                f"own API calls with its own index.html, which is a 200 carrying HTML where JSON "
                f"was expected"
            )

    # A mapping that names a service the estate no longer runs is a stale claim,
    # and this file's whole record is that stale copies are the thing that costs.
    for sub, backend in sorted(BACKEND_BY_SUBDOMAIN.items()):
        if services and backend not in services:
            bad(
                f"BACKEND_BY_SUBDOMAIN maps '{sub}' to compose service '{backend}', which is not "
                f"in docker-compose.estate.yml — the mapping has stopped being true, so check 3 "
                f"silently stopped covering that surface"
            )

    # ── 2: no router for a host the registry does not declare ─────────────────
    for sub, entries in sorted(routers.items()):
        if sub in declared:
            continue
        bad(
            f"routers {[n for n, _ in entries]} match host '{sub}.<apex>', which NO surface in "
            f"the registry declares — nothing composes that address, so it is dead "
            f"configuration (or the registry is missing a row, which is how foresight-admin "
            f"was fixed)"
        )

    # ── 4: no cf-* name written in a comment that this directory never defines ─
    described_but_undefined()

    # ── 5: the CORS allowlist and the registry agree ──────────────────────────
    cors_drift(surfaces)

    # ── 6: every template variable the gateway reads is set in every env file ─
    env_vars_are_set()

    # ── 7: no name defined twice — a dropped router is not a failed one ───────
    defined_twice()

    # ── 8: every header a bundle sends cross-origin is allowlisted ────────────
    cors_headers_drift()

    # ── 9: the tunnel entrypoint carries what websecure carries ───────────────
    entrypoint_chains_match()

    # ── 10: the cross-environment origins are earned, and strictly narrower ───
    view_origin_drift(surfaces)

    # ── 11: the retirement redirect catches pages, not chain endpoints ────────
    retirement_spares_services(surfaces)

    routed = sum(1 for s in surfaces if not s["basePath"] and s["subdomain"] in routers)
    if fails:
        print()
        for f in fails:
            print(f"  FAIL {f}")
        print(f"\n{len(fails)} disagreement(s) between the surface registry and the gateway.")
        return 1
    print(f"\nok — {routed} registry surface(s) routed, {len(routers)} gateway host(s), no drift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
