#!/usr/bin/env python3
"""When two routers can match one URL, only the priority decides — so read it.

WHY THIS EXISTS
---------------
Mounting a surface at a subfolder of the apex means DELIBERATELY creating an
overlap. Before the consolidation every router owned a hostname outright and no
two rules could both match a request. Now:

    cf-web-site      Host(`cloudsforge.online`)                        → the site
    cf-web-journal   Host(`cloudsforge.online`) && (Path(`/journal`)
                                            || PathPrefix(`/journal/`)) → journal

BOTH of those match `https://cloudsforge.online/journal/2026/08/a-post`. Traefik
does not error, does not warn, and does not pick the more specific one. It sorts
by `priority` and takes the first, and where priority is not set it computes one
from the RULE LENGTH — a tiebreak that depends on how a hostname happens to be
spelled. Get the order wrong and the request goes to the site's bundle, which
answers 200 with its own index.html and its own JavaScript. Not a 404. Not an
error page. THE WRONG PAGE, at the right address, with a success status — which
also means every uptime probe and every synthetic check stays green.

THE SECOND OVERLAP, WHICH IS THE ONE THAT WILL ACTUALLY BITE
------------------------------------------------------------
The apex catch-all is the obvious contender and the easy one to remember. The
one that gets missed is a path mounted UNDER another path:

    cf-web-worlds    … (Path(`/worlds`)  || PathPrefix(`/worlds/`))
    cf-web-emberkin  … (Path(`/worlds/emberkin`) || PathPrefix(`/worlds/emberkin/`))

`PathPrefix(`/worlds/`)` matches `/worlds/emberkin` perfectly well. These two
rules are equally correct in isolation, they were written in different waves of
the same migration, and if `emberkin` does not outrank `worlds` then Forge Worlds
serves the Emberkin URLs and nobody finds out from a status page. This check
exists mostly for that case: it compares every pair of path-mounted routers on a
host, not just each one against the catch-all.

WHAT IT ASSERTS
---------------
For every surface the registry mounts at a path, on the router that serves it:

    1. it exists, and carries an EXPLICIT numeric priority — never Traefik's
       rule-length default, which would make the outcome depend on the length of
       a templated hostname
    2. it strictly outranks every host-only router on the same host (the
       catch-all bundle, and any redirect router parked on that hostname)
    3. it strictly outranks every path router on the same host whose path is a
       PREFIX of its own — the `/worlds/emberkin` case above
    4. it sits in the estate's band for a path-mounted bundle: above the
       retirement redirects at 550, so a retirement rule sharing the host cannot
       swallow it

`check-base-paths-agree.py` asserts the SHAPE of the same rule — the exact-or-
slash alternation rather than a bare `PathPrefix`, which is a separate hazard
with a separate failure. Shape decides which URLs a rule claims; priority decides
who wins when two rules claim the same one. This file owns the second.

Exit 0 when the ordering holds. Exit 1 otherwise.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
UI = ROOT.parent / "ui" / "packages" / "ui"
WEB_MAP = ROOT / "gateway" / "dynamic" / "estate-web.yml"

# The band a path-mounted bundle must sit in. estate-web.yml's own header states
# the convention: bundles 500, retirement redirects 550, APIs 600. A bundle that
# has moved onto a shared host is no longer in the 500 case — it has to beat both
# the host's bundle AND any retirement rule on that host, so it belongs at 600.
RETIREMENT_BAND = 550

fails = []


def bad(msg):
    fails.append(msg)


ROUTER_RE = re.compile(r"^    (?P<name>[a-z0-9-]+):\s*$")
RULE_RE = re.compile(r"^\s*rule:\s*(?P<q>['\"])(?P<rule>.*)(?P=q)\s*$")
PRIORITY_RE = re.compile(r"^\s*priority:\s*(?P<n>\d+)\s*$")
SUBSECTION_RE = re.compile(r"^  ([a-zA-Z]+):\s*$")
# The whole `Host(`…`)` term, kept VERBATIM including the Go template inside it.
# Two routers are "on the same host" here when this text is identical, and that
# is deliberate: the hostnames are `{{ env "CF_SITE_HOST" }}` and
# `market{{ env "CF_WEB_SUFFIX" }}`, so resolving them would mean evaluating a Go
# template against an environment this script does not have. Textual identity is
# both exact and honest for the question being asked.
HOST_TERM_RE = re.compile(r"Host\(`[^`]*`\)")
# Every path term a rule constrains itself with, in either form.
PATH_TERM_RE = re.compile(r"Path(?:Prefix)?\(`(?P<p>[^`]*)`\)")


def registry_surfaces():
    if not UI.is_dir():
        print(f"FAIL: micro-ui is not checked out at {UI} — the registry cannot be read.")
        print("      This is a failure, not a skip: the router ordering would go unchecked.")
        sys.exit(1)
    script = (
        "import {SURFACES, servesOwnBundle} from './src/surfaces.ts';"
        "console.log(JSON.stringify(SURFACES.map(s=>"
        "({key:s.key,basePath:s.basePath ?? null,ownBundle:servesOwnBundle(s)}))))"
    )
    out = subprocess.run(
        ["node", "--import", "tsx", "-e", script],
        cwd=UI, capture_output=True, text=True, timeout=120,
    )
    if out.returncode != 0:
        print(f"FAIL: micro-ui's registry exited {out.returncode}.")
        print(out.stderr.strip()[-2000:])
        sys.exit(1)
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("[")), None)
    if line is None:
        print("FAIL: micro-ui's registry produced no surface list.")
        sys.exit(1)
    return json.loads(line)


def gateway_routers():
    """[(name, rule, priority-or-None)] for every router in estate-web.yml.

    Scoped to the `routers:` subsection. `middlewares:` and `services:` also hold
    four-space keys, and a middleware collected as a router would be compared for
    priority against rules it has nothing to do with.

    Commented-out lines are skipped, and this file has real ones: the wrong forms
    of these very rules are quoted in the prose that explains why they are wrong.
    """
    if not WEB_MAP.exists():
        print(f"FAIL: {WEB_MAP} does not exist.")
        sys.exit(1)
    out, section, name, rule, prio = [], None, None, None, None

    def flush():
        if name is not None and rule is not None:
            out.append((name, rule, prio))

    for line in WEB_MAP.read_text().splitlines():
        s = SUBSECTION_RE.match(line)
        if s:
            flush()
            section, name, rule, prio = s.group(1), None, None, None
            continue
        if section != "routers" or line.lstrip().startswith("#"):
            continue
        m = ROUTER_RE.match(line)
        if m:
            flush()
            name, rule, prio = m.group("name"), None, None
            continue
        if name is None:
            continue
        r = RULE_RE.match(line)
        if r:
            rule = r.group("rule")
            continue
        p = PRIORITY_RE.match(line)
        if p:
            prio = int(p.group("n"))
    flush()
    return out


def contends(mine_paths, other_paths):
    """Can a router constrained to `other_paths` also match a URL under mine?

    A host-only router (no path term at all) matches everything on the host, so it
    contends with anything. Otherwise it contends when one of its paths is a
    PREFIX of one of mine — `/worlds/` covering `/worlds/emberkin`. Compared on
    segment boundaries, because `/journal` does not contain `/journalism` and a
    plain `startswith` would say it does.
    """
    if not other_paths:
        return True
    for o in other_paths:
        o = o.rstrip("/")
        for mine in mine_paths:
            mine = mine.rstrip("/")
            if o and mine != o and (mine == o or mine.startswith(o + "/")):
                return True
    return False


def main():
    surfaces = [s for s in registry_surfaces() if s["basePath"] and s["ownBundle"]]
    routers = gateway_routers()

    parsed = [
        (n, r, p, HOST_TERM_RE.findall(r), PATH_TERM_RE.findall(r))
        for n, r, p in routers
    ]

    # ── WHAT THIS COMPARISON CANNOT SEE, STATED RATHER THAN ASSUMED ──────────
    #
    # Two boundaries, both reported below with the routers that fall inside them
    # so a reader can judge them rather than trust them:
    #
    #   * a HostRegexp router has no literal host to compare. Today that is the
    #     retirement rule for `*-testnet.cloudsforge.online`.
    #   * hosts are compared AS WRITTEN, and `{{ env "CF_SITE_HOST" }}` is a
    #     different host in each render. A router that hard-codes
    #     `testnet.cloudsforge.online` is therefore textually distinct from the
    #     apex here, yet IS the apex in the testnet render. That render is also
    #     the one where `CF_WEB_RETIRED=true` gates the path-mounted routers out
    #     of the file entirely — so the overlap it would create does not exist —
    #     but the reason is the gate, not this comparison, and the two should not
    #     be confused.
    #
    # This file is read as its MAINNET rendering: `{{ if }}` gates are not
    # evaluated, so every router in it is treated as present. For an ordering
    # check that is the conservative direction — it compares routers that a given
    # render might omit, never fewer.
    regex_hosted = [n for n, r, _, hosts, _ in parsed if not hosts and "HostRegexp" in r]
    apex_hosts = {h for s in surfaces
                  for _, _, _, hs, ps in parsed if s["basePath"] in [x.rstrip("/") for x in ps]
                  for h in hs}
    net_literal = [n for n, _, _, hosts, _ in parsed
                   if hosts and not set(hosts) & apex_hosts
                   and any("testnet.cloudsforge.online" in h for h in hosts)]

    for s in surfaces:
        base = s["basePath"]
        mine = [(n, r, p, hosts, paths) for n, r, p, hosts, paths in parsed
                if base in [x.rstrip("/") for x in paths]]
        if not mine:
            bad(f"'{s['key']}' is mounted at '{base}' and no router in {WEB_MAP.name} constrains "
                f"itself to that path — nothing to order, and nothing serving it")
            continue
        for name, rule, prio, hosts, paths in mine:
            if prio is None:
                bad(
                    f"router '{name}' serves '{s['key']}' at '{base}' and sets NO priority. Traefik "
                    f"then computes one from the RULE LENGTH, so whether this router or the host's "
                    f"catch-all wins depends on how many characters the hostname happens to be — "
                    f"and the loser's URLs return the winner's page with a 200"
                )
                continue
            if prio <= RETIREMENT_BAND:
                bad(
                    f"router '{name}' serves '{s['key']}' at '{base}' at priority {prio}, which is "
                    f"not above the retirement band ({RETIREMENT_BAND}). A retirement redirect "
                    f"parked on this host would outrank it and bounce the surface's own URLs away"
                )
            for oname, orule, oprio, ohosts, opaths in parsed:
                if oname == name or ohosts != hosts or not hosts:
                    continue
                if not contends([base], [p.rstrip("/") for p in opaths]):
                    continue
                if oprio is None:
                    bad(
                        f"router '{oname}' shares a host with '{name}' (which serves '{s['key']}' at "
                        f"'{base}') and can match the same URLs, but sets no priority — so the order "
                        f"between them is Traefik's rule-length default and not a decision anyone made"
                    )
                elif oprio >= prio:
                    where = ("the host's catch-all" if not opaths
                             else f"mounted at '{opaths[0]}', which contains '{base}'")
                    bad(
                        f"router '{oname}' ({where}) has priority {oprio} and '{name}', which serves "
                        f"'{s['key']}' at '{base}', has {prio}. The higher number wins, so every URL "
                        f"under '{base}' is answered by '{oname}' — with a 200 and the wrong bundle, "
                        f"which no status page and no uptime probe will ever report"
                    )

    for f in fails:
        print(f"FAIL {f}")
    if regex_hosted:
        print(f"  note not compared, host matched by regex: {', '.join(regex_hosted)} — a literal "
              f"host cannot be tested against a regex here.")
    if net_literal:
        print(f"  note hard-codes a testnet hostname: {', '.join(net_literal)} — a different host "
              f"from the apex AS WRITTEN. In the testnet render it is the same host; what keeps "
              f"them apart there is CF_WEB_RETIRED gating the path-mounted routers out, not this "
              f"comparison.")
    if fails:
        print(f"\n{len(fails)} ordering problem(s).")
        return 1
    print(f"ok — {len(surfaces)} path-mounted surface(s), each outranking every router that "
          f"contends for its URLs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
