#!/usr/bin/env python3
"""Ask every public hostname, from outside the estate, whether it answers at all.

WHY THIS EXISTS, AND WHY IT IS NOT A CONTAINER
----------------------------------------------
On 2026-08-11 the app host rebooted at 03:54. Docker Desktop is a desktop
application: it needs an interactive Windows session, there was none, and the
engine never came back. Every service on `cloudsforge.online` answered 502 for
thirty-five minutes.

Nothing told anyone. It was found by a CI subtest in an unrelated release build
— `site`'s "answers on the public internet" — and the reason nothing else could
have found it is worth stating plainly, because it is a property of the design
rather than a gap in the configuration:

    Prometheus, Alertmanager, blackbox and beacon ALL RUN AS CONTAINERS ON THE
    HOST THEY MONITOR.

A monitor inside the thing it monitors reports "up" or reports nothing, and
"nothing" is indistinguishable from "quiet". The whole alerting plane died in
the same instant as its subject, and stayed dead until the subject came back —
at which point there was nothing left to alert about. That is micro-org#431,
item 2, and this file is the answer to it: a prober that is NOT inside the
estate, whose failure is loud somewhere the estate does not reach.

It runs as a scheduled GitHub Actions workflow (`.github/workflows/uptime.yml`).
The alert is the SCHEDULED RUN'S OWN FAILURE — GitHub emails the owner when a
scheduled workflow fails, which needs no PAT, no webhook, no secret, and no
component that shares a power supply with the thing being watched.

WHAT IT ASKS, AND THE ONE THING IT REFUSES TO ASK
-------------------------------------------------
It asks one question per hostname: DID SOMETHING ANSWER. A response with a
status below 500 counts as an answer, including 401, 403 and 404 —

  * `api-testnet.cloudsforge.online/v1/rates` may well want a token, and a 401
    is the public API working exactly as designed;
  * `rpc.cloudsforge.online` is JSON-RPC over POST, so a GET is a 405 from a
    healthy node;
  * a 404 from Traefik means the gateway is alive and no router matched, which
    is a routing question and not an availability one.

A 5xx, a refused connection, a TLS failure or a timeout is a FAILURE, because
each is what the estate looked like at 04:00 on 2026-08-11: Cloudflare up, DNS
up, tunnel gone, 502 on everything.

It deliberately does NOT assert content. `estate-verify.sh` already asserts what
each surface says, it runs beside the estate where it can see the containers,
and it takes minutes. This takes seconds, knows nothing, and answers the only
question that matters when a host is gone. A prober that checks too much is a
prober that goes red for reasons nobody reads.

WHERE THE HOSTNAMES COME FROM, WHICH IS THE POINT
--------------------------------------------------
Not from a list in this file. A hand-written list of hostnames is a fourth copy
of the registry and would rot exactly the way `surface-routes.py`'s header
records the first three rotting.

They are derived from `gateway/dynamic/*.yml` — the router rules — with the Go
template actions resolved against each `compose/env/traefik*.env`. That is the
same file pair the gateway itself reads, so a surface added to the estate is
probed the day its router is written, and a surface removed stops being probed
the day its router goes. `surface-routes.py` already fails CI when those rules
and the UI registry disagree, so deriving from the rules IS deriving from the
registry, with one fewer checkout and no Node.

The environment is read from the env file's NAME: `traefik.env` is mainnet,
`traefik.testnet.env` is testnet. Both are probed by default, because the
outage this exists for takes both at once.

WHAT `--list` IS FOR
--------------------
`--list` resolves the hostnames and prints them without touching the network, so
CI can prove the derivation still works on every push. A parser that quietly
stops matching would leave a green scheduled run probing zero hosts, which is
the same failure this file was written about: silence read as health. Hence also
MIN_HOSTS below — deriving too few hosts is an error, not a short list.

Exit 0 when every hostname answered. Exit 1 otherwise, and never exit 0 on a
run that could not be made.
"""
import argparse
import pathlib
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DYNAMIC = ROOT / "gateway" / "dynamic"
ENV_DIR = ROOT / "compose" / "env"

# Deriving fewer than this many hostnames from a directory that has never had
# fewer than twenty-four means the PARSER broke, not that the estate shrank.
MIN_HOSTS = 20

# ── hostnames that are routed but are not expected to answer, and why ─────────
#
# Every entry is a CLAIM, keyed by (environment, hostname-without-suffix), and
# the run FAILS ON A STALE ONE: an entry here whose host has started answering
# is a comment that has stopped being true. The estate's whole record is that
# the stale copy is the thing that costs.
#
# It is EMPTY, and the first entry written into it was wrong. `("testnet",
# "pool")` was added on the belief that testnet runs no pool container; the
# first run answered HTTP 200 and this mechanism said so, which is the whole
# argument for keeping the dictionary rather than deleting it. Every one of the
# fifty hostnames across both environments answered on 2026-08-12.
EXPECTED_SILENT = {}

RULE_RE = re.compile(r"^\s*rule:\s*'(?P<rule>.+)'\s*$")
HOST_RE = re.compile(r"Host\(`(?P<host>[^`]+)`\)")
PATH_RE = re.compile(r"Path(?:Prefix)?\(`(?P<path>/[^`]*)`\)")
TEMPLATE_RE = re.compile(r'\{\{\s*env\s+"(?P<var>[A-Z0-9_]+)"\s*\}\}')
# A rule with one of these is matched by more than a hostname and a path, so a
# plain GET would not reach it. Such a rule can still NAME a host; it just
# cannot be the rule that decides which path to probe.
NARROW_RE = re.compile(r"HeaderRegexp\(|Headers\(|Method\(|Query\(|ClientIP\(")


def environments():
    """{name: {VAR: value}} for every `compose/env/traefik*.env`.

    `traefik.env` is mainnet — the unadorned form, as everywhere else in this
    repository — and `traefik.<label>.env` is the environment `<label>` names.
    """
    files = sorted(ENV_DIR.glob("traefik*.env"))
    if not files:
        sys.exit(f"FAIL: no traefik*.env in {ENV_DIR} — no environment to probe.")
    envs = {}
    for path in files:
        middle = path.name[len("traefik."):-len(".env")]
        name = middle or "mainnet"
        values = {}
        for line in path.read_text().splitlines():
            m = re.match(r"^([A-Z0-9_]+)=(\S*)$", line)
            if m:
                values[m.group(1)] = m.group(2)
        envs[name] = values
    return envs


def rules():
    """Every router rule in `gateway/dynamic/`, as written, templates and all."""
    files = sorted(DYNAMIC.glob("*.yml"))
    if not files:
        sys.exit(f"FAIL: no router files in {DYNAMIC} — nothing to derive.")
    found = []
    for path in files:
        for line in path.read_text().splitlines():
            m = RULE_RE.match(line)
            if m:
                found.append(m.group("rule"))
    return found


def resolve(text, values, source):
    """Substitute `{{ env "X" }}` from one environment's env file.

    An UNSET variable is fatal rather than skipped. `surface-routes.py` check 6
    already forbids it, so reaching it here means that check has been removed or
    has stopped working — and probing a hostname with a hole in it would fail
    for a reason that has nothing to do with the estate.
    """
    def sub(m):
        var = m.group("var")
        if var not in values:
            sys.exit(f"FAIL: {source} does not set {var}, which a router rule reads.")
        return values[var]
    return TEMPLATE_RE.sub(sub, text)


def targets(env_name, values):
    """{hostname: path} — every public hostname this environment serves.

    The path is `/` for any host with a rule that constrains nothing but the
    host. Where no such rule exists — `api.<apex>`, whose bare catch-all router
    was deliberately removed — the shortest path any of its rules matches is
    used instead, so the probe reaches a real router rather than the gateway's
    404.
    """
    best = {}
    for rule in rules():
        rule = resolve(rule, values, f"traefik env for {env_name}")
        hosts = [m.group("host") for m in HOST_RE.finditer(rule)]
        if not hosts:
            continue
        if NARROW_RE.search(rule):
            paths = []
        else:
            paths = [m.group("path") for m in PATH_RE.finditer(rule)]
        # No path constraint at all is the strongest candidate there is: the
        # root of that host is routed.
        path = min(paths, key=len) if paths else "/"
        for host in hosts:
            if "{{" in host or not host.strip("."):
                # A templated host that survived resolution, or the empty-host
                # bug `estate-web.yml` warns about in its header. Neither is a
                # hostname; both are configuration defects that belong to
                # `surface-routes.py`, not to an availability check.
                continue
            if host not in best or len(path) < len(best[host]):
                best[host] = path
    return dict(sorted(best.items()))


def probe(host, path, attempts, timeout, verbose=False):
    """(ok, detail). True the first time anything below 500 comes back.

    Retried before it is believed. A single failed request from a GitHub runner
    is a normal event on the public internet; three in a row, spaced, is the
    estate.
    """
    url = f"https://{host}{path}"
    ctx = ssl.create_default_context()
    last = "no attempt was made"
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(
            url,
            method="GET",
            headers={"User-Agent": "cloudsforge-uptime-probe/1 (micro-deploy)"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
                return True, f"HTTP {r.status}"
        except urllib.error.HTTPError as e:
            # An HTTP status IS an answer. Only 5xx is not.
            if e.code < 500:
                return True, f"HTTP {e.code}"
            last = f"HTTP {e.code}"
        except urllib.error.URLError as e:
            # NEVER print the exception object here beyond its reason: these
            # URLs carry no credentials today, and the rule that keeps it that
            # way is that a URL never reaches a log by accident.
            last = f"{type(e.reason).__name__ if hasattr(e, 'reason') else 'URLError'}: {e.reason}"
        except Exception as e:  # noqa: BLE001 — a probe may not crash the run
            last = f"{type(e).__name__}"
        if verbose:
            print(f"    attempt {attempt}/{attempts} on {url}: {last}", flush=True)
        if attempt < attempts:
            time.sleep(3)
    return False, last


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--env", action="append", metavar="NAME",
                    help="probe only this environment (repeatable). Default: all of them.")
    ap.add_argument("--list", action="store_true",
                    help="print the derived hostnames and exit, without touching the network")
    ap.add_argument("--attempts", type=int, default=3)
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    envs = environments()
    if args.env:
        unknown = [e for e in args.env if e not in envs]
        if unknown:
            sys.exit(f"FAIL: no traefik env file for {unknown} (have {sorted(envs)}).")
        envs = {k: v for k, v in envs.items() if k in args.env}

    failures, silent_but_answering = [], []
    for env_name, values in envs.items():
        derived = targets(env_name, values)
        if len(derived) < MIN_HOSTS:
            sys.exit(
                f"FAIL: derived only {len(derived)} hostnames for {env_name}, and this "
                f"estate has never had fewer than {MIN_HOSTS}. The rule parser has "
                f"stopped matching; a probe of an empty list would pass silently."
            )
        suffix = values.get("CF_WEB_SUFFIX", "")
        print(f"\n{env_name}: {len(derived)} public hostnames")
        if args.list:
            for host, path in derived.items():
                print(f"  {host:<44} {path}")
            continue
        for host, path in derived.items():
            short = host[: -len(suffix)] if suffix and host.endswith(suffix) else host
            excuse = EXPECTED_SILENT.get((env_name, short))
            ok, detail = probe(host, path, args.attempts, args.timeout)
            if ok and excuse:
                silent_but_answering.append((env_name, host, excuse))
                mark = "OK*"
            elif ok:
                mark = "OK "
            elif excuse:
                mark = "-- "
            else:
                mark = "DEAD"
                failures.append((env_name, host, path, detail))
            print(f"  {mark} {host:<44} {path:<24} {detail}", flush=True)

    if args.list:
        return 0

    for env_name, host, excuse in silent_but_answering:
        print(f"\nSTALE EXPECTATION: {host} ({env_name}) answered, but EXPECTED_SILENT says "
              f"it would not: {excuse}. Remove the entry.")
    if failures:
        print("\nTHE PUBLIC ESTATE IS NOT ANSWERING ON:")
        for env_name, host, path, detail in failures:
            print(f"  {env_name}  https://{host}{path}  — {detail}")
        print("\nEvery one of these was tried from outside the estate, so the fault is the "
              "estate, Cloudflare, or the tunnel between them. If it is ALL of them, it is the "
              "app host: runbooks/runbook-app-host-down.md.")
    if failures or silent_but_answering:
        return 1
    print("\nEvery public hostname answered.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
