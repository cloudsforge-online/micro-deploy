#!/usr/bin/env python3
"""Every top-level API path a service DEFINES is routed on the host that serves it.

WHY THIS EXISTS
---------------
`surface-routes.py` next door checks that every registry surface has a router. It
cannot see the failure this file is about, because the host in question is routed
perfectly: the bundle is served, the API is served, the check passes, and one
resource is quietly missing from the API router's list.

That resource does not 404. On a shared host — an SPA and its API behind ONE
hostname — the SPA router is the catch-all, so a path no API router matches is
answered by the app shell: `200 OK`, `content-type: text/html`, a page of
JavaScript where a caller asked for JSON. Every layer downstream reports success.
`fetch` resolves. The status is 200. Only `response.json()` fails, deep inside a
client that usually treats a failed parse as "no data" and renders nothing.

It has now happened twice on the same hostname:

  * **#195 — `/image-config` on `foresight`.** Market images silently stopped
    rendering. Diagnosed from the wrong end, because the browser shows a 200.
  * **2026-08 — `/stake-assets` on `foresight`.** Worse: `custodialstake.tsx`
    catches the failure and returns `null`, so the entire CUSTODIAL staking path
    disappeared from every market page on both estates from the day it shipped.
    A reader with no browser wallet was shown "Connect a wallet to go on" and no
    second option, because the second option's panel had erased itself. Nobody
    could have found that from the outside: the product path was not broken, it
    was ABSENT, and absence leaves no error anywhere.

Both were one missing `PathPrefix` in a list of four. Neither was findable by
reading the gateway, because a list of four looks exactly like a list of five.
This check reads the list from the side that cannot drift — the service's own
route table — and compares.

WHAT A "SHARED HOST" IS, AND WHY THE CHECK FINDS THEM ITSELF
------------------------------------------------------------
A subdomain is shared when estate-web.yml gives it BOTH:

  * a catch-all router — a rule with a `Host(...)` and no path condition, which
    answers everything not claimed by a more specific rule; and
  * at least one `cf-svc-*` router carrying path conditions, which claims the
    API's paths out of that catch-all.

Only on such a host can a path be swallowed. Where the catch-all IS the service
(nimbus, vault, studio — `Host(x) -> cf-svc-*` with no prefix at all) nothing can
be swallowed and there is nothing here to check; those hosts are skipped by the
shape of the rule, not by a name in a list.

Because the set is DISCOVERED, a new shared host cannot appear without this file
noticing: every discovered subdomain must be claimed by exactly one table below,
and a table entry naming a subdomain that is no longer shared fails as a stale
claim. Both tables are read in both directions, the same discipline
`EXPECTED_UNROUTED` follows next door.

THE TWO TABLES
--------------
`CHECKED` — hosts where the API router ENUMERATES named resources. These are the
dangerous ones, and the only ones a service can outgrow: add a route to the
service and the gateway does not know. Each entry names the source file that
defines the routes and an allowlist of top-level segments that are deliberately
NOT public, each with its reason.

`NOT_CHECKED` — hosts where the routed set is a fixed vocabulary that a new route
cannot escape (`PathPrefix(/v1)` covers every future `/v1/...`), or where the
upstream is not a `define()` service at all. Each entry declares the EXACT set of
path terms routed for that host, and the check fails when the real set differs.
That is what keeps the excuse honest: the day someone adds `PathPrefix(/reports)`
beside `/v1`, the host has silently become enumerable and this file says so.

Exit 0 when the gateway and the services agree. Exit 1 otherwise, and NEVER skips
— a source file that cannot be read is reported as a failure, not as agreement
nobody established.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
WEB_MAP = ROOT / "gateway" / "dynamic" / "estate-web.yml"

fails = []


def bad(msg):
    fails.append(msg)


# ── hosts whose API router enumerates named resources ────────────────────────
#
# `sources` are the files that define the service's routes; `unrouted` is every
# top-level segment they define that must NOT be reachable from the public
# hostname, with the reason. An entry in `unrouted` is a claim like any other: if
# the gateway starts routing it, the entry has stopped being true and fails.
CHECKED = {
    "foresight": {
        "sources": ["foresight/src/server.ts"],
        "unrouted": {
            "/livez": "liveness is for the container runtime and the estate's own probes, "
                      "not for the internet; beacon reads it on the docker network",
            "/readyz": "same — readiness is an orchestration signal, and publishing it "
                       "publishes the dependency list in its body",
            "/metrics": "the Prometheus scrape. It carries per-route timing and error "
                        "counts for the whole service and is scraped in-network",
        },
    },
    "pay": {
        # `pay.<apex>` is the WALLET's host: `cf-web-pay` routes the whole host to
        # cf-svc-wallet, and billing is grafted onto it by four named prefixes.
        # Same shape as foresight, same exposure — a fifth billing resource would
        # be answered by the wallet service, which knows nothing about it.
        "sources": ["billing/src/server.ts"],
        "unrouted": {
            "/livez": "an orchestration probe, read on the docker network",
            "/readyz": "an orchestration probe, read on the docker network",
            "/metrics": "the Prometheus scrape, taken in-network",
            "/internal": "`/internal/entitlements/:userId` answers OTHER SERVICES asking "
                         "what a user has bought. Routing it publicly would let anyone "
                         "read anyone's entitlements by id",
            "/v1": "`POST /v1/events` is the event relay's inbound webhook, delivered "
                   "service-to-service on the docker network and signed; the public "
                   "hostname has no business carrying it",
        },
    },
}


# ── hosts where a new route cannot escape the routed set ─────────────────────
#
# `terms` is the EXACT set of path conditions estate-web.yml routes to cf-svc-*
# services on that host, written the way the rule writes them. The check compares
# sets, so an added, removed or retyped term fails and forces the classification
# to be made again.
VERSIONED_TERMS = ["PathPrefix(/v1)"]
VERSIONED_WHY = (
    "the API router is `PathPrefix(/v1)` and every route the service defines lives "
    "under `/v1`, so a new resource is routed the day it is written — there is no "
    "list here to fall out of date"
)

NOT_CHECKED = {
    "hub": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "market": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "create": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "trade": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "worlds": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "explorer": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "developers": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "admin": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "network": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "emberkin": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "tessera": {"terms": VERSIONED_TERMS, "why": VERSIONED_WHY},
    "aetherholm": {
        "terms": ["PathPrefix(/v1)", "Path(/readyz)"],
        "why": "versioned like the rest, plus ONE exact `/readyz` — an exact `Path`, "
               "not a prefix, so it exposes that single route and cannot grow",
    },
    "status": {
        "terms": ["Path(/api/status/public)"],
        "why": "the status page reads ONE beacon route and the rule is an exact `Path`. "
               "Beacon's own hostname carries the rest",
    },
    "beacon": {
        "terms": [
            "PathPrefix(/v1)", "PathPrefix(/api)", "PathPrefix(/metrics)",
            "PathPrefix(/livez)", "PathPrefix(/readyz)",
        ],
        "why": "beacon IS the estate's status surface: `/v1` and `/api` cover its whole "
               "API, and the three operational paths are published ON PURPOSE here — a "
               "monitor that cannot be checked from outside checks nothing",
    },
    "lantern": {
        "terms": [
            "PathPrefix(/v1)", "PathPrefix(/otlp)", "PathPrefix(/ingest)",
            "PathPrefix(/metrics)", "PathPrefix(/livez)", "PathPrefix(/readyz)",
        ],
        "why": "`/v1` covers the API; `/otlp` and `/ingest` are the two telemetry intake "
               "prefixes, whose paths are fixed by the OTLP spec and by the agents that "
               "post to them, not by lantern",
    },
    "pool": {
        "terms": ["PathPrefix(/v1)", "PathPrefix(/livez)", "PathPrefix(/readyz)"],
        "why": "`/v1` covers the API; the two probes are published so miners can tell a "
               "dead pool from a dead network before pointing hashrate at it",
    },
    "rpc": {
        "terms": [
            "Path(/mining/template)", "Path(/mining/submit)", "Path(/events)",
            "Path(/api)", "Path(/verify)", "Path(/contracts)", "Path(/compilers)",
            "PathPrefix(/contract/)",
        ],
        "why": "three upstreams share this hostname and NONE of them is a `define()` "
               "service — hearth's node (Go), and hearth's explorer index and verifier "
               "(`tools/`, plain node http servers). Every term but one is an EXACT "
               "`Path`, which is what carries the claim: each names one route, so the "
               "routed set cannot grow when a service does. The first three peel the "
               "MINING listener off the JSON-RPC catch-all and are fixed by the miner "
               "protocol; the next four are the chain's read surfaces, and `/api` is "
               "exact rather than a prefix BECAUSE of this row — the Etherscan grammar "
               "it serves is entirely in the query string. The exception is "
               "`/contract/`, and it cannot grow either: the verifier serves exactly "
               "`/contract/0x…` and `/contract/0x…/abi`, where the ADDRESS is the path, "
               "so no exact term can name them. The trailing slash is load-bearing — it "
               "excludes `/contracts` above, which is a different route on the same "
               "upstream",
    },
}


ROUTER_RE = re.compile(r"^    (?P<name>[a-z0-9-]+):\s*$")
RULE_RE = re.compile(r"^\s*rule:\s*'(?P<rule>.+)'\s*$")
SERVICE_RE = re.compile(r"^\s*service:\s*(?P<svc>[a-z0-9-]+)\s*$")
# Only the `CF_WEB_SUFFIX` shape: the apex site and the retired `*-testnet`
# regexp hosts serve no API and have no subdomain to key on.
HOST_RE = re.compile(r'Host\(`([a-z0-9-]+)\{\{\s*env\s+"CF_WEB_SUFFIX"\s*\}\}`\)')
PATH_TERM_RE = re.compile(r"(?P<neg>!?)(?P<kind>PathPrefix|Path)\(`(?P<path>[^`]+)`\)")
DEFINE_RE = re.compile(r"define\(\s*'(?P<method>[A-Z]+)'\s*,\s*'(?P<path>/[^']*)'")


def term(kind, path):
    """The one spelling of a path condition both tables and rules are read in."""
    return f"{kind}({path})"


def gateway_hosts():
    """{subdomain: {"catch_all": [names], "api": {term: router}}} from estate-web.yml.

    A router counts toward `api` only when its upstream is `cf-svc-*` AND it carries
    at least one path condition. A router counts as `catch_all` when it carries none:
    that is the one that answers a swallowed path, whatever it serves.
    """
    if not WEB_MAP.exists():
        print(f"FAIL: {WEB_MAP} does not exist — there is no gateway to check.")
        sys.exit(1)
    hosts = {}
    name = rule = None
    for line in WEB_MAP.read_text().splitlines():
        m = ROUTER_RE.match(line)
        if m:
            name, rule = m.group("name"), None
            continue
        r = RULE_RE.match(line)
        if r and name is not None:
            rule = r.group("rule")
            continue
        s = SERVICE_RE.match(line)
        if s and name is not None and rule is not None:
            subs = HOST_RE.findall(rule)
            terms = [
                term(t.group("kind"), t.group("path"))
                for t in PATH_TERM_RE.finditer(rule)
                if not t.group("neg")
            ]
            for sub in subs:
                h = hosts.setdefault(sub, {"catch_all": [], "api": {}})
                if not terms:
                    h["catch_all"].append(name)
                elif s.group("svc").startswith("cf-svc-"):
                    for t in terms:
                        h["api"][t] = name
            name = rule = None
    return hosts


def defined_paths(sub, sources):
    """Every `define('METHOD', '/path')` in the named files, as {top-segment: [paths]}.

    Reading the SERVICE's route table is the whole point: it is the copy that cannot
    be forgotten, because forgetting it means the route does not exist at all.
    """
    by_segment = {}
    total = 0
    for rel in sources:
        path = MICRO / rel
        if not path.exists():
            print(f"FAIL: '{sub}' names {rel} as its route table and it is not checked out.")
            print("      This is a failure, not a skip: the host would go unchecked while")
            print("      reporting agreement, which is the exact shape of defect this file")
            print("      exists to catch.")
            sys.exit(1)
        found = DEFINE_RE.findall(path.read_text())
        if not found:
            print(f"FAIL: {rel} defines no routes this file can read.")
            print("      Either the route table moved or `define('METHOD', '/path')` is no")
            print("      longer how routes are written. Fix this check before trusting it.")
            sys.exit(1)
        for _method, route in found:
            total += 1
            by_segment.setdefault("/" + route.split("/")[1], set()).add(route)
    print(f"  read {total} route(s) from {', '.join(sources)}")
    return by_segment


def covers(routed, segment, routes):
    """Is `segment` reachable through the routed terms?

    A `PathPrefix` on the segment covers every route under it. An exact `Path` covers
    only itself, so it counts only when it names a defined route with no parameters —
    which is how `status` reaches one beacon route without opening the rest.
    """
    if term("PathPrefix", segment) in routed:
        return True
    return any(term("Path", r) in routed for r in routes)


def main():
    hosts = gateway_hosts()
    shared = {
        sub: h for sub, h in hosts.items() if h["catch_all"] and h["api"]
    }

    # ── 1: every shared host is claimed by exactly one table ──────────────────
    for sub in sorted(shared):
        in_checked, in_not = sub in CHECKED, sub in NOT_CHECKED
        if in_checked and in_not:
            bad(
                f"'{sub}' is in BOTH CHECKED and NOT_CHECKED. One of the two is a leftover "
                f"and the check would read the wrong one — decide which it is"
            )
        elif not in_checked and not in_not:
            bad(
                f"'{sub}.<apex>' serves a bundle and an API behind one hostname "
                f"(catch-all {shared[sub]['catch_all'][0]}, API terms "
                f"{sorted(shared[sub]['api'])}) and this file has no entry for it. A path "
                f"no API router matches on that host is answered by the catch-all with a "
                f"200 and an HTML body — add it to CHECKED with its route table, or to "
                f"NOT_CHECKED with the reason a new route cannot escape the routed set"
            )

    # ── 2: a table entry for a host that is no longer shared is stale ─────────
    for sub in sorted(set(CHECKED) | set(NOT_CHECKED)):
        if sub in shared:
            continue
        where = "CHECKED" if sub in CHECKED else "NOT_CHECKED"
        if sub not in hosts:
            bad(f"{where} names '{sub}' and estate-web.yml routes no such host — delete it")
        elif not hosts[sub]["api"]:
            bad(
                f"{where} names '{sub}' and that host has no cf-svc-* router with path "
                f"conditions any more — the claim has stopped being true, delete it"
            )
        else:
            bad(
                f"{where} names '{sub}' and that host has no catch-all router any more, so "
                f"nothing can swallow a path there. Delete the entry rather than leaving a "
                f"reason nobody can check"
            )

    # ── 3: a NOT_CHECKED host's routed terms are exactly what it declares ─────
    for sub, claim in sorted(NOT_CHECKED.items()):
        if sub not in shared:
            continue
        actual, declared = set(shared[sub]["api"]), set(claim["terms"])
        if actual == declared:
            print(f"  ok   {sub:<12} {', '.join(sorted(actual))}")
            continue
        for extra in sorted(actual - declared):
            bad(
                f"'{sub}' routes {extra}, which NOT_CHECKED does not declare. Its excuse — "
                f"\"{claim['why']}\" — may no longer hold: a host that enumerates paths can "
                f"outgrow the list. Move it to CHECKED, or declare the term and say why it "
                f"cannot grow"
            )
        for gone in sorted(declared - actual):
            bad(
                f"NOT_CHECKED says '{sub}' routes {gone} and no rule does. Either a router "
                f"was dropped — in which case that path is being served the catch-all's body "
                f"right now — or the claim is stale"
            )

    # ── 4 & 5: a CHECKED host routes every resource its service defines ───────
    for sub, claim in sorted(CHECKED.items()):
        if sub not in shared:
            continue
        routed = shared[sub]["api"]
        by_segment = defined_paths(sub, claim["sources"])
        for segment in sorted(by_segment):
            routes = sorted(by_segment[segment])
            if covers(routed, segment, routes):
                if segment in claim["unrouted"]:
                    bad(
                        f"'{sub}' lists {segment} in `unrouted` — \"{claim['unrouted'][segment]}\" "
                        f"— and the gateway routes it now. The reason has stopped being true: "
                        f"either the exposure is a mistake, or the entry is"
                    )
                else:
                    print(f"  ok   {sub:<12} {segment:<16} {len(routes)} route(s) routed")
                continue
            if segment in claim["unrouted"]:
                print(f"  ok   {sub:<12} {segment:<16} deliberately unrouted")
                continue
            bad(
                f"{claim['sources'][0]} defines {segment} ({', '.join(routes)}) and no router "
                f"on '{sub}.<apex>' matches it. It will NOT 404: {shared[sub]['catch_all'][0]} "
                f"answers it with 200 and an HTML body, so the caller sees a successful fetch "
                f"and a failed parse, and a client that treats that as 'no data' renders "
                f"nothing at all. This is how /image-config (#195) and /stake-assets were both "
                f"lost. Add PathPrefix(`{segment}`) to the API rule, or list it in `unrouted` "
                f"with the reason it must stay off the public hostname"
            )
        # The other direction: a routed prefix the service does not define.
        for t, router in sorted(routed.items()):
            kind, _, rest = t.partition("(")
            path = rest.rstrip(")")
            segment = "/" + path.split("/")[1]
            if segment in by_segment and (kind == "PathPrefix" or path in by_segment[segment]):
                continue
            bad(
                f"router '{router}' routes {t} on '{sub}.<apex>' and {claim['sources'][0]} "
                f"defines nothing there. Every call is a 404 from the service instead of the "
                f"page the reader expected — a route was renamed and the gateway kept the old "
                f"name, or the rule is dead configuration"
            )

    if fails:
        print()
        for f in fails:
            print(f"  FAIL {f}")
        print(f"\n{len(fails)} path(s) where the gateway and a service disagree.")
        return 1
    print(
        f"\nok — {len(shared)} shared host(s): {len(CHECKED)} checked against their route "
        f"tables, {len(NOT_CHECKED)} declared closed, nothing swallowed."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
