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
    # Resolved by NAME rather than guessed: a compose service whose name equals
    # the surface's subdomain is that surface's backend. That covers every case
    # this check exists for (emberkin, aetherholm, foresight, tessera) and
    # deliberately does not try to be clever about the ones where the names
    # differ — hub/hub-api, admin/admin-api, network/faucet, pay/wallet — which
    # are argued individually in estate-web.yml and are already routed.
    for s in surfaces:
        sub = s["subdomain"]
        if s["basePath"] or not sub or sub not in services or sub not in routers:
            continue
        if not any(serves_api for _, serves_api in routers[sub]):
            bad(
                f"'{sub}' is a service in docker-compose.estate.yml AND a routed surface, but no "
                f"router on its host points at a cf-svc-* upstream: the bundle answers its own "
                f"API calls with its own index.html, which is a 200 carrying HTML where JSON was "
                f"expected"
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
