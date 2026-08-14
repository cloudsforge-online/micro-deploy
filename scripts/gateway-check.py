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
# 0. the two ways a route map can be dead without being wrong
# ---------------------------------------------------------------------------
# Both of these actually happened here, and neither was visible from the file.
#
# (a) Traefik runs a dynamic file through Go's text/template BEFORE parsing it as
#     YAML. So `rule: "Host(`{{ env \"CF_API_HOST\" }}`)"` — correct YAML —
#     reaches the template engine with literal backslashes and fails to parse.
#     A template failure REJECTS THE WHOLE DIRECTORY: not this router, not this
#     file, everything, including policy.yml's /internal refusal. Single-quoted
#     YAML scalars avoid the escape entirely.
#
# (b) An `{{ env "X" }}` whose X is undefined renders EMPTY and silently. The
#     router still loads; its rule is `Host(``)`, which matches no request ever
#     sent. Traefik logs nothing. The public API is dead and looks configured.
#
# Both are checked statically here so that neither needs a running Traefik to
# catch — though `make check-gateway` is not a substitute for booting one.
# ── EVERY GATEWAY ENV FILE, NOT `traefik.env` ALONE ─────────────────────────
#
# This read mainnet's file only, which made "is the variable defined?" a question
# about ONE ENVIRONMENT while the directory it is asked about is mounted by both.
# It broke on the first variable that is per-environment BY DESIGN:
# `CF_VIEW_ORIGIN_SUFFIX` is set in `traefik.testnet.env` and deliberately absent
# from `traefik.env`, because it grants the mainnet frontends a credentialed
# cross-origin read of testnet and the reverse must not exist. This script
# reported that correct configuration as a dead route.
#
# WHICH file each variable belongs in is `surface-routes.py` check 6's question,
# and it answers it in both directions — every variable in every file, except the
# ones in `ENV_VARS_SET_IN_ONE_FILE`, which must be in their own file and in no
# other. That is a stronger claim than this script makes and there is no reason to
# keep a second, weaker copy of it here. So this asks only what its own failure
# mode needs: is the variable defined ANYWHERE in this estate's gateway
# environment? A variable defined nowhere renders empty in every environment,
# which is the `Host(``)` defect described above.
GATEWAY_ENV_DIR = ROOT / "compose" / "env"
GATEWAY_ENVS = sorted(GATEWAY_ENV_DIR.glob("traefik*.env"))
preflight = []

for path in sorted((ROOT / "gateway" / "dynamic").glob("*.yml")):
    body = path.read_text()
    for lineno, line in enumerate(body.split("\n"), 1):
        if "{{" in line and '\\"' in line:
            preflight.append(
                f"{path.name}:{lineno}: a templated line is double-quoted YAML with escaped quotes. "
                "Go's text/template sees the backslashes and rejects THE WHOLE DIRECTORY. "
                "Use a single-quoted YAML scalar."
            )

declared = set()
if GATEWAY_ENVS:
    for env_path in GATEWAY_ENVS:
        for line in env_path.read_text().split("\n"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                declared.add(line.split("=", 1)[0].strip())
else:
    preflight.append(
        f"no traefik*.env in {GATEWAY_ENV_DIR}, so no templated variable can be shown to be defined."
    )

referenced = set()
for path in sorted((ROOT / "gateway" / "dynamic").glob("*.yml")):
    referenced |= set(re.findall(r'\{\{\s*env\s+\\?"([A-Z0-9_]+)\\?"\s*\}\}', path.read_text()))
for name in sorted(referenced - declared):
    preflight.append(
        f"{name} is templated into a gateway rule and is set in NONE of "
        f"{', '.join(p.name for p in GATEWAY_ENVS)}. It renders empty in every environment, the "
        "rule becomes Host(``), and the route matches nothing — silently. "
        "(WHICH file it belongs in is surface-routes.py check 6's question, and it is stricter.)"
    )

if preflight:
    print(f"checked {len(referenced)} templated variable(s) across gateway/dynamic/")
    for p in preflight:
        print(f"  FAIL  {p}")
    print(f"\n{len(preflight)} problem(s) that would make the route map load empty or not at all.")
    sys.exit(1)

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
    # Either quote style. The file moved to single-quoted scalars because the
    # double-quoted form broke Go templating (see the preflight above), so a
    # parser that knew only one style would report "no routers" — which is why
    # the no-routers case above is a hard failure and not a skip.
    rule = re.search(r"rule: \"(.*)\"|rule: '(.*)'", block)
    service = re.search(r"service: ([a-z0-9-]+)", block)
    middlewares = re.search(r"middlewares: \[([^\]]*)\]", block)
    if not rule or not service:
        continue
    prefixes = re.findall(r"PathPrefix\(`([^`]+)`\)", rule.group(1) or rule.group(2))
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
