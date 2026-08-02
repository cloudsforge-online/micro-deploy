#!/usr/bin/env python3
"""Compare the gateway's public route map against what the services ACTUALLY serve.

THE GAP THIS CLOSES
-------------------
`gateway/dynamic/public-api.yml` says so itself, in the comment above the worlds
router: `/v1/seasons` was missing from the route map AND from micro-sdk's route
table, so the drift check in micro-sdk — which verifies that every resource in
the SDK's table has a router here — could not see it. Two artefacts agreeing with
each other is not the same as either agreeing with the services. The result was
that no title could be paid a season reward through the public host.

That comment ends: "nothing in this estate yet compares this file against what
the services actually serve. Recorded as the real gap." This is that comparison.

It reads the routers out of public-api.yml, resolves each to an upstream service
via the `services:` block, and then reads that service's OWN source to find the
routes it defines. A router whose prefix matches no real route is a public path
that 404s from the service; a service route that no router mounts is invisible
from the public host. The first is a lie, the second is a gap, and this reports
both.

Deliberately dependency-free — regex, not PyYAML — for the reason
check-runbooks.py gives: a check that only runs where a library happens to be
installed is a check that stops running.

Exit 0 if every router resolves to a real route. Exit 1 otherwise, and NEVER
skips: a check that cannot run reports failure rather than success it did not
establish.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAP = ROOT / "gateway" / "dynamic" / "public-api.yml"
# The sibling checkouts. deploy/ is micro/deploy, so the services are its siblings.
MICRO = ROOT.parent

if not MAP.exists():
    sys.exit(f"FAIL: {MAP} does not exist. The public API route map is the thing being checked.")

text = MAP.read_text()

# ---------------------------------------------------------------------------
# 1. the route map: routers, their path prefixes, and the upstream each names
# ---------------------------------------------------------------------------

# `servers: [{ url: "http://pricing:4000" }]` — the host is the service.
upstream_of = {}
for name, host in re.findall(
    r"^    ([a-z0-9-]+):\n      loadBalancer:\n        servers: \[\{ url: \"http://([a-z0-9.-]+):\d+\" \}\]",
    text,
    flags=re.M,
):
    upstream_of[name] = host

routers = []
# Each router is a `    <name>:` block under `routers:` carrying a `rule:` line.
for block in re.split(r"^    (?=[a-z0-9-]+:\n      rule:)", text, flags=re.M)[1:]:
    name = block.split(":", 1)[0].strip()
    rule = re.search(r"rule: \"(.*)\"", block)
    service = re.search(r"service: ([a-z0-9-]+)", block)
    middlewares = re.search(r"middlewares: \[([^\]]*)\]", block)
    if not rule or not service:
        continue
    prefixes = re.findall(r"PathPrefix\(`([^`]+)`\)", rule.group(1))
    routers.append(
        {
            "name": name,
            "prefixes": prefixes,
            "service": service.group(1),
            "strips_version": "cf-api-strip-version" in (middlewares.group(1) if middlewares else ""),
        }
    )

if not routers:
    sys.exit(f"FAIL: no routers parsed out of {MAP}. Either the file changed shape or this check is broken; either way it is not passing.")

# ---------------------------------------------------------------------------
# 2. what each service actually serves
# ---------------------------------------------------------------------------

# Three dialects, because the estate has three. identity/market/mint/worlds use
# `define('GET', '/path'`; wallet uses `route('GET', '/path'`; activity uses an
# object literal with `method:` and `path:` on separate lines. A checker that
# knew only one dialect would report "no routes" and read as a pass if the
# comparison were written the lazy way round.
CALL = re.compile(r"\b(?:define|route)\(\s*'(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)'\s*,\s*'([^']+)'")
OBJ = re.compile(r"method:\s*'(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)'\s*,\s*\n\s*path:\s*'([^']+)'")


def routes_of(host):
    """Every (method, path) the service's source defines, or None if unreadable."""
    src = MICRO / host / "src" / "server.ts"
    if not src.exists():
        return None
    body = src.read_text()
    found = set(CALL.findall(body)) | set(OBJ.findall(body))
    return found


# ---------------------------------------------------------------------------
# 3. the comparison
# ---------------------------------------------------------------------------

failures = []
notes = []
mounted = {}  # host -> set of upstream prefixes the gateway mounts

for r in routers:
    if not r["prefixes"]:
        # The catch-all. It deliberately matches the host and nothing else.
        continue
    host = upstream_of.get(r["service"])
    if host is None:
        failures.append(f"router {r['name']} names service {r['service']}, which has no `services:` entry")
        continue
    real = routes_of(host)
    if real is None:
        notes.append(f"{r['name']}: no checkout at {MICRO / host}/src/server.ts — cannot verify, not counted as passing")
        failures.append(f"router {r['name']} could not be checked: {host} is not checked out")
        continue
    for prefix in r["prefixes"]:
        upstream_prefix = prefix[len("/v1"):] if r["strips_version"] and prefix.startswith("/v1") else prefix
        mounted.setdefault(host, set()).add(upstream_prefix)
        # A route matches if it IS the prefix or sits under it. `/rates` must
        # match `/rates/:asset`, and must not match `/ratesomething`.
        hit = [
            (m, p)
            for (m, p) in real
            if p == upstream_prefix or p.startswith(upstream_prefix + "/")
        ]
        if not hit:
            failures.append(
                f"{r['name']}: public {prefix} -> {host}{upstream_prefix}, which {host} does not serve. "
                f"That path 404s from behind the gateway."
            )

# The other direction: a service route that no router mounts. Reported, not
# failed — plenty of routes are internal on purpose (ledger has no public
# surface at all, by design). The point is that the gap is VISIBLE, which is
# exactly what /v1/seasons was not.
INTERNAL = ("/livez", "/readyz", "/metrics", "/internal", "/events", "/ingest", "/.well-known")
for host in sorted(mounted):
    real = routes_of(host) or set()
    prefixes = mounted[host]
    unmounted = sorted(
        {
            p
            for (_m, p) in real
            if not p.startswith(INTERNAL)
            and not any(p == q or p.startswith(q + "/") for q in prefixes)
        }
    )
    if unmounted:
        notes.append(f"{host}: {len(unmounted)} route(s) served but not mounted publicly: {', '.join(unmounted[:8])}" + (" ..." if len(unmounted) > 8 else ""))

# Collisions: two routers for different services claiming the same public prefix.
claimed = {}
for r in routers:
    for prefix in r["prefixes"]:
        claimed.setdefault(prefix, []).append(r["service"])
for prefix, owners in sorted(claimed.items()):
    if len(set(owners)) > 1:
        failures.append(f"public prefix {prefix} is claimed by {len(set(owners))} services: {', '.join(sorted(set(owners)))}")

# ---------------------------------------------------------------------------

print(f"checked {len(routers)} routers against {len(mounted)} service checkouts")
for n in notes:
    print(f"  note  {n}")
if failures:
    for f in failures:
        print(f"  FAIL  {f}")
    print(f"\n{len(failures)} problem(s). The public route map does not match what the services serve.")
    sys.exit(1)
print("ok: every mounted public path resolves to a route the service actually serves")
