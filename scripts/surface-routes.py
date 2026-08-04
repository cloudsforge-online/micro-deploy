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
    it from its own repository.
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
TRAEFIK_ENV = ROOT / "compose" / "env" / "traefik.env"
ESTATE = ROOT / "compose" / "docker-compose.estate.yml"

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
        "({key:s.key,kind:s.kind,subdomain:s.subdomain,basePath:s.basePath ?? null}))))"
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


# `Host(`sub.{{ env "CF_WEB_APEX" }}`)` and `Host(`{{ env "CF_WEB_APEX" }}`)`.
# The apex form has no leading label and means the bare apex — the `site` row,
# whose subdomain is the empty string.
HOST_RE = re.compile(r'Host\(`(?:([a-z0-9-]+)\.)?\{\{\s*env\s+"CF_WEB_APEX"\s*\}\}`\)')
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
        bundle is served at all — nimbus, lantern, pay, vault, worlds-api. estate-web.yml
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
    """The subdomain `CF_API_HOST` resolves to under `CF_WEB_APEX`, or None."""
    if not TRAEFIK_ENV.exists():
        bad(f"{TRAEFIK_ENV} does not exist — CF_API_HOST cannot be checked")
        return None
    text = TRAEFIK_ENV.read_text()
    api = re.search(r"^CF_API_HOST=(\S+)", text, re.M)
    apex = re.search(r"^CF_WEB_APEX=(\S+)", text, re.M)
    if not api or not apex:
        bad("traefik.env does not define both CF_API_HOST and CF_WEB_APEX")
        return None
    api_host, web_apex = api.group(1), apex.group(1)
    if not api_host.endswith("." + web_apex):
        # THE DEFECT THIS FUNCTION EXISTS FOR. `public-api.yml` routes on
        # CF_API_HOST; the registry composes `api.<CF_WEB_APEX>`. When the two
        # apexes differ, every router in that file is live on a hostname the
        # estate does not resolve, and `api.<apex>` — a declared surface — 404s.
        bad(
            f"CF_API_HOST is '{api_host}' but CF_WEB_APEX is '{web_apex}': the public API is "
            f"routed on a host outside this estate's apex, so the registry's `api` surface "
            f"(https://api.{web_apex}) reaches no router at all"
        )
        return None
    return api_host[: -(len(web_apex) + 1)]


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


def described_but_undefined():
    """Every cf-api/web/svc name in a COMMENT must be defined somewhere in this directory.

    THE POINT. A router that exists only as prose answers "is it routed?" with a
    yes, in the file that would know, and nothing else in this script looks at
    prose at all. Checks 1-3 all passed over `cf-api-explorer` because the HOST
    was routed by the bundle; this one reads the sentence that made the claim.

    Deliberately dumb, and that is the property worth keeping: it needs no
    registry, no compose file and no idea what a surface is for, so it cannot
    stop running for an environmental reason. It reads YAML by line rather than
    by parser because the file provider renders Go template actions BEFORE the
    YAML is parsed, so on disk this is a template and not YAML at all.
    """
    directory = WEB_MAP.parent
    if not directory.is_dir():
        bad(f"{directory} is not a directory — the described-but-undefined check cannot run")
        return
    defined, mentioned = set(), {}
    for path in sorted(directory.glob("*.yml")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                for name in CF_NAME_RE.findall(line):
                    mentioned.setdefault(name, []).append(f"{path.name}:{lineno}")
                continue
            m = DEFINITION_RE.match(line)
            if m:
                defined.add(m.group(1))
    for name, sites in sorted(mentioned.items()):
        if name in defined:
            continue
        bad(
            f"'{name}' is written in a comment at {', '.join(sites)} and is DEFINED NOWHERE in "
            f"{directory.name}/. A router or service that exists only in prose reads like one "
            f"that exists — delete the sentence or define the thing it describes"
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
