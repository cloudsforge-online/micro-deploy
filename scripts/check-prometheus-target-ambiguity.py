#!/usr/bin/env python3
"""No scrape target is a bare service name (micro-org#437).

WHAT WENT WRONG, ONCE, SO IT IS WORTH A CHECK
=============================================

`indexer:4000` looks like an address and is not one. It is a question put to
Docker's embedded DNS, and the answer depends on which networks the Prometheus
container happens to be attached to at the time.

micro-org#398 attached it to a second one. The `cf-indexer-testnet` job needed
to reach exactly one container in the testnet estate, and the only way to reach
a container is to join its network — so `docker-compose.telemetry.yml` joined
`cf-testnet_default`. Prometheus went from two networks to three:

    cf-micro-app=172.22.0.3  cf-testnet_default=172.27.0.33  cloudsforge-estate_default=172.20.0.3

Docker resolves a bare name against those in name order. `cf-testnet_default`
sorts before `cloudsforge-estate_default`. From that moment every bare-name
target — all 26 generated ones, plus `beacon`, `analytics`, `lantern` and
`gateway` — was answered by the TESTNET container, and the samples were stored
under the mainnet job's labels. Measured in the mainnet Prometheus: three
mainnet chain series stop and testnet starts in the SAME 15s sample, at
2026-08-11T23:59:45Z.

Every estate service name exists in both projects — 78 of them, checked by
container name on 2026-08-12 — so there was no bare name that was safe. The
three `401 Unauthorized` targets were not a token problem either: the mainnet
token was being presented to the testnet service, which refused it correctly.

Nothing about this looked broken. The targets were `up`, the numbers were
plausible, and the config file for the testnet job says in capital letters that
the testnet estate is not scraped. It was right about the intent and had no way
to be right about the effect.

WHAT THIS REFUSES
=================

A scrape target whose host is a bare service name, when that name is ambiguous
across the projects this host runs. The fix is always the same: name the
container. A container name is unique per host across projects, which is the
one property a scrape address needs and a service name does not have.

Allowed, and why each is not a bare service name:

  * `<project>-<service>-<n>` for either estate project — a container name.
  * a service of the telemetry stack itself (`prometheus`, `grafana`, `loki`,
    `tempo`, `alertmanager`, `otel-collector`). These live in project `cfmicro`
    and in no other project on this host, so they resolve to one container. The
    list is READ from `docker-compose.telemetry.yml`, not typed here, so a new
    telemetry sibling is allowed the day it is added and an estate service can
    never be allowed by pretending to be one.
  * `localhost`, which Prometheus uses to scrape itself.

The project names are read from the `external:` network names in
`docker-compose.telemetry.yml` (`${CF_PROJECT:-cloudsforge-estate}_default` and
`${CF_TESTNET_PROJECT:-cf-testnet}_default`) so that this check and the
attachment it guards cannot disagree about what the projects are called.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TELEMETRY = ROOT / "compose" / "docker-compose.telemetry.yml"
PROM_YML = ROOT / "prometheus" / "prometheus.yml"
TARGETS_DIR = ROOT / "prometheus" / "targets"

problems = []


def fail(message):
    print(f"FAIL   {message}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# What the projects are called, and what Prometheus's own siblings are called.
# ---------------------------------------------------------------------------
if not TELEMETRY.exists():
    fail(f"no telemetry compose at {TELEMETRY}; the project names cannot be derived.")
telemetry_text = TELEMETRY.read_text()

projects = set()
for match in re.finditer(r"^\s*name:\s*\$\{([A-Z_]+):-([a-z0-9-]+)\}_default\s*$", telemetry_text, re.M):
    projects.add(match.group(2))
if not projects:
    fail(
        f"{TELEMETRY.name} declares no `${{CF_*:-<project>}}_default` external network.\n"
        "       That parse is how this check learns which projects exist; finding none means\n"
        "       it stopped matching, and an unmatched project name would make every container\n"
        "       name below look like a bare service name."
    )

services_block = re.search(r"^services:\n(.*?)(?=^[a-z])", telemetry_text, re.S | re.M)
telemetry_services = set(re.findall(r"^  ([a-z][a-z0-9-]*):\s*$", services_block.group(1), re.M)) if services_block else set()
if not telemetry_services:
    fail(f"{TELEMETRY.name} yielded no service names; the allowlist would be empty.")

CONTAINER = re.compile(r"^(" + "|".join(re.escape(p) for p in sorted(projects)) + r")-[a-z0-9-]+-\d+$")


def judge(host, where, line_no):
    if host == "localhost" or CONTAINER.match(host):
        return
    if host in telemetry_services:
        return
    problems.append(
        f"{where}:{line_no}: `{host}` is a bare service name.\n"
        f"    Every estate service name exists in more than one compose project on this\n"
        f"    host, so this resolves to whichever container Docker's DNS reaches first —\n"
        f"    which is the testnet one, because `cf-testnet_default` sorts first.\n"
        f"    Name the container instead: `<project>-{host}-1`, and pin\n"
        f"    `instance: {host}:<port>` so the series identity does not move."
    )


# ---------------------------------------------------------------------------
# Every static target in the scrape config, and every generated one beside it.
# ---------------------------------------------------------------------------
files = [PROM_YML] + (sorted(TARGETS_DIR.glob("*.yaml")) if TARGETS_DIR.exists() else [])
if not PROM_YML.exists():
    fail(f"no scrape config at {PROM_YML}.")

seen_any = False
for path in files:
    for line_no, line in enumerate(path.read_text().split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#") or "targets:" not in stripped:
            continue
        inside = re.search(r"targets:\s*\[(.*)\]", stripped)
        if not inside:
            continue
        for entry in inside.group(1).split(","):
            host = entry.strip().strip("\"'").split(":")[0]
            if not host:
                continue
            seen_any = True
            judge(host, path.relative_to(ROOT), line_no)

if not seen_any:
    fail(
        "no scrape targets were found in any of "
        + ", ".join(str(p.relative_to(ROOT)) for p in files)
        + ".\n       A check that examines nothing passes for the wrong reason."
    )

if problems:
    print("Ambiguous scrape targets (micro-org#437):\n", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}\n", file=sys.stderr)
    sys.exit(1)

print(
    f"  ok — every scrape target names a container in {'/'.join(sorted(projects))} "
    f"or a telemetry sibling ({len(telemetry_services)} of those)"
)
