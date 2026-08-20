#!/usr/bin/env python3
"""A surface that moved took its API with it, or its own bundle cannot reach it.

WHY THIS EXISTS
---------------
Twelve of the fourteen surfaces in `docs/apex-consolidation.md` have a service on
their own hostname. Their bundles issue RELATIVE requests — `/v1/titles`, or on
`foresight` an unversioned `/markets` — which is precisely what lets a bundle not
know its own hostname.

Move the bundle to `/market` and a relative `/v1/titles` still resolves to
`/v1/titles` **at the apex root**, which is micro-site's. So decision 4 moves the
API with the surface, to `/<surface>/v1`, and `stripPrefix` takes `/<surface>`
back off before the service sees it — the service is unchanged and does not know
it moved.

That arrangement has three parts and no two of them are in the same file:

    1. the gateway ROUTER      `Host(apex) && PathPrefix('/market/v1')`
    2. the gateway MIDDLEWARE  `stripPrefix: prefixes: ["/market"]`, on that router
    3. the bundle's API BASE   `${BASE}/v1` rather than `/v1`

EACH MISSING PART FAILS DIFFERENTLY, AND ONE OF THEM FAILS SILENTLY
-------------------------------------------------------------------
    1 missing   every call from the bundle 404s at the gateway. Loud, and the
                surface is visibly dead — which is the good case.
    2 missing   the router matches and the service receives `/market/v1/titles`,
                a path it has never served. It answers its own 404 for every
                route. The gateway reports a healthy backend; the surface is dead
                and Traefik says it is fine.
    3 missing   the BUNDLE still calls `/v1/titles` on the apex, which reaches
                **micro-site** — and micro-site answers its SPA shell. So the
                bundle receives 200 with an HTML body where JSON was expected,
                and what the reader sees is every panel in a failure state with a
                perfectly healthy network tab. This is the one nothing else in
                the estate can see.

THE MIDDLEWARE IS THE PART THAT CANNOT FAIL LOUDLY
---------------------------------------------------
`stripPrefix` is invisible to the service. A service that composed an absolute
path — a `Location:` header, a cookie `Path`, a URL in a JSON body — would keep
answering 200 while handing the browser an address on the apex root. That is not
checkable from here, so it was AUDITED instead, across all twelve services, and
the audit is recorded in decision 4 with the three greps that produced it. Re-run
them before adding a thirteenth surface.

WHAT THIS FILE CHECKS
---------------------
For every registry surface mounted at a path that ALSO has a service on the
gateway: parts 1 and 2 above, plus that the router's path is exactly the
surface's own base path with the API prefix appended — not a hand-written string
that happens to look like one.

Part 3 lives in the frontend and is checked by `check-base-paths-agree.py`, which
already reads that repository.

Exit 0 when every remounted API is routed and stripped. Exit 1 otherwise.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
UI = ROOT.parent / "ui" / "packages" / "ui"
WEB_MAP = ROOT / "gateway" / "dynamic" / "estate-web.yml"

fails = []


def bad(msg):
    fails.append(msg)


SUBSECTION_RE = re.compile(r"^  ([a-zA-Z]+):\s*$")
ROUTER_RE = re.compile(r"^    ([a-z0-9-]+):\s*$")
RULE_RE = re.compile(r"^\s*rule:\s*(?P<q>['\"])(?P<rule>.*)(?P=q)\s*$")
SERVICE_RE = re.compile(r"^\s*service:\s*([a-z0-9-]+)\s*$")
MIDDLEWARES_RE = re.compile(r"^\s*middlewares:\s*\[(?P<list>[^\]]*)\]\s*$")
PREFIX_RE = re.compile(r"PathPrefix\(`([^`]+)`\)")
STRIP_RE = re.compile(r'^\s*-\s*"?([^"\s]+)"?\s*$')


def registry_surfaces():
    if not UI.is_dir():
        print(f"FAIL: micro-ui is not checked out at {UI} — the registry cannot be read.")
        print("      This is a failure, not a skip: a remounted API would go unchecked.")
        sys.exit(1)
    script = (
        "import {SURFACES, servesOwnBundle} from './src/surfaces.ts';"
        "console.log(JSON.stringify(SURFACES.map(s=>"
        "({key:s.key,basePath:s.basePath ?? null,ownBundle:servesOwnBundle(s)}))))"
    )
    out = subprocess.run(["node", "--import", "tsx", "-e", script],
                         cwd=UI, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        print(f"FAIL: micro-ui's registry exited {out.returncode}.")
        print(out.stderr.strip()[-2000:])
        sys.exit(1)
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("[")), None)
    if line is None:
        print("FAIL: micro-ui's registry produced no surface list.")
        sys.exit(1)
    return json.loads(line)


def gateway():
    """Routers and stripPrefix middlewares, read in one pass.

    Both live in `estate-web.yml` under sibling subsections, and a router names
    its middleware by name — so the two have to be read together or the link
    between them cannot be followed.
    """
    if not WEB_MAP.exists():
        print(f"FAIL: {WEB_MAP} does not exist.")
        sys.exit(1)
    routers, strips = [], {}
    section = name = rule = svc = None
    mws = []
    # ── HOW DEEP INSIDE A `CF_WEB_RETIRED` GATE THIS LINE IS ─────────────────
    #
    # The file is a Go template before it is YAML, and `{{ if ne (env
    # "CF_WEB_RETIRED") "true" }}` deletes whole router blocks on testnet. Every
    # other reader in this repository skips template lines as noise. That is
    # what let the 2026-08-19 defect through: `cf-api-market-apex` sat inside
    # such a gate, so on testnet it did not exist, and the surface's API fell
    # through to the retirement redirect and answered 302 to MAINNET — which a
    # cross-origin fetch follows, so the combined view showed the wrong estate's
    # data with "Testnet" selected.
    #
    # Counted rather than flagged, because these gates nest and a boolean would
    # be reset by the first `{{ end }}` of an inner one.
    retired_gate = 0
    cur_mw, in_strip, prefixes = None, False, []
    gate_at_open = 0

    def flush_router():
        if section == "routers" and name and rule:
            routers.append({"name": name, "rule": rule, "service": svc,
                            "middlewares": list(mws), "web_retired_gated": gate_at_open})

    def flush_mw():
        if cur_mw and prefixes:
            strips[cur_mw] = list(prefixes)

    for line in WEB_MAP.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("{{") and "CF_WEB_RETIRED" in stripped:
            retired_gate += 1
            continue
        if stripped == "{{ end }}" and retired_gate:
            retired_gate -= 1
            continue
        s = SUBSECTION_RE.match(line)
        if s:
            flush_router(); flush_mw()
            section = s.group(1)
            name = rule = svc = cur_mw = None; mws = []; in_strip = False; prefixes = []
            continue
        if line.lstrip().startswith("#"):
            continue
        m = ROUTER_RE.match(line)
        if m:
            flush_router(); flush_mw()
            name = cur_mw = m.group(1)
            # Sampled at the router's OPENING line, not at flush: a `{{ end }}`
            # between the name and the last field would otherwise read as
            # ungated and the check would pass on the arrangement it exists for.
            gate_at_open = retired_gate
            rule = svc = None; mws = []; in_strip = False; prefixes = []
            continue
        if section == "routers":
            r = RULE_RE.match(line)
            if r: rule = r.group("rule"); continue
            v = SERVICE_RE.match(line)
            if v: svc = v.group(1); continue
            w = MIDDLEWARES_RE.match(line)
            if w:
                mws = [x.strip() for x in w.group("list").split(",") if x.strip()]
        elif section == "middlewares":
            if re.match(r"^\s*stripPrefix:\s*$", line): in_strip = True; continue
            if in_strip and re.match(r"^\s*prefixes:\s*$", line): continue
            if in_strip:
                p = STRIP_RE.match(line)
                if p: prefixes.append(p.group(1)); continue
                if line.strip() and not line.startswith("        "): in_strip = False
    flush_router(); flush_mw()
    return routers, strips


# ── SURFACES WHOSE BUNDLE CALLS SOMEBODY ELSE'S API ──────────────────────────
#
# Decision 4 remounts a surface's API under its mount because a MOUNTED BUNDLE'S
# RELATIVE REQUEST resolves at the apex root. A bundle that makes no relative
# request has nothing to remount, and forcing one on it would publish a second
# address for a service nobody reaches that way.
#
# `worlds` is the only member and the registry says why in two rows rather than
# one: `worlds` is the product and `api` is "the public, versioned surface" that
# micro-worlds' routes are actually served on. `worlds-web/src/lib/hosts.ts`
# argues the same at length and its header is worth reading before adding to this
# table — the bar for membership is that the bundle's API base is ANOTHER
# surface's host, not merely that a remount looks inconvenient.
CALLS_ANOTHER_SURFACES_API = {"worlds"}


def main():
    surfaces = [s for s in registry_surfaces() if s["basePath"] and s["ownBundle"]]
    routers, strips = gateway()
    mounted = {s["key"]: s["basePath"] for s in surfaces}

    # ── A ROUTER BELONGS TO THE LONGEST MOUNT IT IS UNDER, NOT TO EVERY MOUNT ──
    #
    # Wave 3f nested the three Forge Worlds titles at `/worlds/emberkin` and its
    # two siblings, and `/worlds/emberkin/v1` starts with `/worlds/` — so a plain
    # `startswith` attributed all three title routers to WORLDS as well as to the
    # title. Every one of them then failed twice over, and both messages were
    # wrong in the same way: they described the title's own strip as the wrong
    # strip for a surface that has nothing to do with it.
    #
    # This is the same fact the gateway resolves with a priority band and micro-ui
    # pins in `surfaces.test.ts`: a nested mount is STRICTLY DEEPER than its
    # parent, and depth is what decides ownership. So a prefix is attributed once,
    # to the longest mounted basePath it sits under, and a router counts as a
    # surface's API only if at least one of its prefixes is attributed to it.
    def owner_of(prefix):
        """The key whose mount most specifically contains `prefix`, or None."""
        best = None
        for k, b in mounted.items():
            if prefix == b or prefix.startswith(b + "/"):
                if best is None or len(b) > len(mounted[best]):
                    best = k
        return best

    def api_routers_for(key, base):
        return [r for r in routers
                if (r["service"] or "").startswith("cf-svc-")
                and any(owner_of(p) == key for p in PREFIX_RE.findall(r["rule"]))]

    for key, base in sorted(mounted.items()):
        # An API router for this surface is one that serves a `cf-svc-*` upstream
        # and constrains itself to a path under the mount. Read by UPSTREAM, which
        # is the discriminator `surface-routes.py` uses and the one that catches
        # `foresight` — whose API is six unversioned prefixes and says `/v1`
        # nowhere.
        api = api_routers_for(key, base)
        if not api and key in CALLS_ANOTHER_SURFACES_API:
            # ── A THIRD CASE, AND IT IS NOT "NO API" ──────────────────────────
            #
            # `worlds` HAS a service and HAS a router for it on the old hostname,
            # and still needs no remount — because its bundle never called that
            # router. `worlds-web`'s `API_SURFACE` is `api`, not `worlds`, so its
            # reads are absolute to `api.<apex>` and were cross-origin long before
            # the mount. The failure decision 4 exists for — a relative `/v1`
            # resolving at the apex root — cannot happen on a bundle that issues
            # no relative `/v1`.
            #
            # Named rather than inferred, because the fact lives in a file this
            # script cannot count on having: CI checks out `deploy` and `ui`, and
            # a deploy host clones no frontend at all. An exemption that silently
            # skipped when the repo was absent would be worse than one written
            # down with its argument. Checked in both directions below, so a
            # surface that starts calling its own API cannot keep the exemption.
            continue

        if not api:
            # Not every path-mounted surface has an API — `journal` and `exchange`
            # have none, which is why they were waves 1 and 2. Silence is correct
            # for them, and the surface is only reported when it HAS a service
            # somewhere that no longer has a route under its mount.
            orphan = [r for r in routers
                      if (r["service"] or "").startswith(f"cf-svc-{key}")
                      and not any(p.startswith(base) for p in PREFIX_RE.findall(r["rule"]))]
            for r in orphan:
                bad(
                    f"'{key}' is mounted at '{base}' and its service is still routed by "
                    f"'{r['name']}' on a path outside that mount ({r['rule'][:80]}). Its bundle "
                    f"issues RELATIVE requests, so every one of them now resolves at the apex root "
                    f"— which is micro-site's, and micro-site answers its SPA shell with a 200 and "
                    f"an HTML body where JSON was expected"
                )
            continue

        for r in api:
            # ── AND IT MUST SURVIVE `CF_WEB_RETIRED`, WHICH IS THE COMBINED VIEW ────────────
            #
            # Found live on 2026-08-19, hours after wave 3a shipped, by probing testnet rather
            # than by any check — which is why there is one now.
            #
            # `cf-api-market-apex` sat inside `{{ if ne (env "CF_WEB_RETIRED") "true" }}`
            # alongside the bundle it serves. That reads as tidy and is wrong: on testnet the
            # gate is false, so the router did not exist, and `testnet.<apex>/market/v1/…`
            # fell through to `cf-retired-web-apex` at 550 — which answered **302 to
            # mainnet**.
            #
            # A cross-origin fetch FOLLOWS a 302. So a reader on `<apex>/market` who pressed
            # Testnet got a 200 full of MAINNET data with "Testnet" still selected. Nothing
            # errored, nothing was logged, and the surface looked like it was working.
            #
            # THE BUNDLE IS RETIRED ON TESTNET AND THE API IS NOT. That split is not new —
            # `cf-retired-web-sub` has carried `!PathPrefix(`/v1`)` since the frontends were
            # retired, for exactly this reason. The consolidation just moved `/v1` to
            # `/<mount>/v1`, where that negation no longer reaches it.
            if r["web_retired_gated"]:
                bad(
                    f"'{key}'s API router '{r['name']}' is inside a CF_WEB_RETIRED gate, so it "
                    f"does not exist on testnet — where the surface's own reads then fall "
                    f"through to the retirement redirect and answer 302 TO MAINNET. A "
                    f"cross-origin fetch follows that, so the combined view shows the wrong "
                    f"estate's data with 'Testnet' selected, with no error anywhere. The BUNDLE "
                    f"is retired on testnet; its API is not. Move this router outside the gate — "
                    f"its priority already outranks the retirement band"
                )
            strip_mws = [m for m in r["middlewares"] if m in strips]
            if not strip_mws:
                bad(
                    f"router '{r['name']}' serves '{key}'s API under '{base}' and carries NO "
                    f"stripPrefix middleware. The service will receive '{base}/v1/…', a path it has "
                    f"never served, and answer its own 404 for every route — while Traefik reports "
                    f"a healthy backend. Add a `cf-api-strip-{key}` with prefixes: [\"{base}\"]"
                )
                continue
            for m in strip_mws:
                if base not in strips[m]:
                    bad(
                        f"router '{r['name']}' serves '{key}'s API under '{base}' and its "
                        f"stripPrefix '{m}' removes {strips[m]}, which does not include '{base}'. "
                        f"The service receives a path with the mount still on it"
                    )

    # THE OTHER DIRECTION. A name in the table that IS remounted has either started
    # calling its own API — in which case the exemption is now a lie and the entry
    # belongs deleted — or somebody added the router anyway, which is the second
    # address this exemption exists to prevent.
    for key in sorted(CALLS_ANOTHER_SURFACES_API):
        base = mounted.get(key)
        if base is None:
            bad(f"CALLS_ANOTHER_SURFACES_API names '{key}', which is not a path-mounted surface. "
                f"Either it moved back to a subdomain or the key is stale")
            continue
        # Longest-mount attribution here too. Without it `worlds`'s exemption reads
        # the three NESTED title routers — `/worlds/emberkin/v1` and its siblings —
        # as remounts of ITSELF, and reports the exemption violated by routers that
        # belong to emberkin, aetherholm and tessera. The exemption is about what
        # `worlds-web` calls, and it calls `api.<apex>`; a title's API router says
        # nothing about that either way.
        remounted = api_routers_for(key, base)
        for r in remounted:
            bad(f"'{key}' is exempt from the remount because its bundle calls another surface's "
                f"API, and '{r['name']}' remounts it under '{base}' anyway. Either the bundle "
                f"changed — delete the exemption — or this router publishes a second address for "
                f"a service nobody reaches that way")

    for f in fails:
        print(f"FAIL {f}")
    if fails:
        print(f"\n{len(fails)} remounted API problem(s).")
        return 1
    # Attributed the same way as everything above, so the count agrees with what was
    # actually checked rather than counting a nested title's router twice.
    remounted = sum(1 for k, b in mounted.items() if api_routers_for(k, b))
    print(f"ok — {len(mounted)} path-mounted surface(s), {remounted} with an API remounted under "
          f"the mount and stripped before the service sees it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
