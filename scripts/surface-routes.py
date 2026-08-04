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
  5. Every surface a browser loads a page from has a CORS origin, and no origin
     is allowlisted that no surface serves.
  6. Every `{{ env "X" }}` that `gateway/dynamic/` reads is SET in every
     `compose/env/traefik*.env`. Checks 1-3 read the FILE, and a router wrapped
     in `{{ if env … }}` is present in the file whether or not it exists at
     runtime — so without this, a conditional router is a route the check
     believes in and the gateway does not.
  7. No router, service or middleware is DEFINED TWICE in `gateway/dynamic/`.
     Traefik's file provider merges a directory into one map per section and
     keeps the FIRST definition of a name, so a second one does not conflict,
     does not error and does not override — it is DROPPED. See below.

TWO ROUTERS OF ONE NAME IS ONE ROUTER, AND NOBODY IS TOLD WHICH
---------------------------------------------------------------
Check 7 was added the same way check 4 was: after this script passed clean over
the defect it should have been the thing to catch.

`cf-api-worlds` was a router in `public-api.yml` — `api.<apex>` with the four
worlds prefixes — and, since `worlds-api.<apex>` was routed, a DIFFERENT router
of the same name in `estate-web.yml`. The file provider iterates the directory
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


TEMPLATE_ENV_RE = re.compile(r'\{\{\s*(?:if\s+)?env\s+"([A-Z0-9_]+)"\s*\}\}')
ENV_DIR = ROOT / "compose" / "env"


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
    """
    directory = WEB_MAP.parent
    if not directory.is_dir():
        bad(f"{directory} is not a directory — the template-variable check cannot run")
        return
    wanted = {}
    for path in sorted(directory.glob("*.yml")):
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
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
    for path in files:
        text = path.read_text()
        for name, site in sorted(wanted.items()):
            m = re.search(rf"^{re.escape(name)}=(.*)$", text, re.M)
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
    r'^\s*-\s*https://(?:([a-z0-9-]+)\.)?\{\{\s*env\s+"CF_WEB_APEX"\s*\}\}\s*$'
)


def cors_allowlist():
    """Subdomains in the templated half of `cf-cors`, in policy.yml.

    Only the `{{ if env "CF_WEB_APEX" }}` block is read. The literal
    `cloudsforge.online` entries above it are a DIFFERENT list about a different
    deployment and are deliberately not checked here: policy.yml argues that an
    allowlist entry for a production origin nothing serves is its own defect
    (`mint.cloudsforge.online`), so the two halves cannot be required to match.
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
