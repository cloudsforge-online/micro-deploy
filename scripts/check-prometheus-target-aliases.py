#!/usr/bin/env python3
"""No two scrape targets may resolve to the same workload (micro-org#541).

WHAT WENT WRONG
===============

On 2026-09-01 one failing route — `POST /v1/events/tessera` — fired TWENTY-FOUR
SLO alerts naming twenty services, three of them at severity `page`. Nineteen of
the twenty services had done nothing. The measurement that gave it away was that
twenty services reported the same request rate to five decimal places:

    activity  2.840314   market  2.839640   mint  2.840496   wallet  2.840395
    ...twenty of them, and `agora` among them at 2.839627...

Twenty services with one number is not twenty services. It was one pod's
`/metrics` page, scraped twenty times through twenty different names, and stored
twenty times under twenty different `service` labels.

The names all resolve. That is the whole difficulty: after the service merge,
`market`, `wallet`, `notify` and seventeen others are ExternalName Services —
DNS CNAMEs onto `agora.cloudsforge-estate.svc.cluster.local` — kept precisely so
that in-estate callers did not have to change on cutover day. A scrape target
pointed at one of them is `up`, answers in milliseconds, and returns a valid
exposition page. Nothing about it looks wrong.

WHY IT MATTERS MORE THAN A DUPLICATE COUNT
==========================================

`rules/slo.yaml` aggregates `http_requests_total` by `(network, service, tier)`.
One process arriving under twenty service names is twenty burn rates computed
from identical numerators and identical denominators, so:

  * one broken route pages nineteen services that cannot fix it, and the operator
    who is paged for `pricing` reads `pricing`, finds nothing, and learns to
    scroll past the next one;
  * `tier` is asserted twenty times about one process, and the copies disagree —
    `wallet` said Tier 1 and `agora` said Tier 2 about the same series, so the
    money objective and the product objective were being computed over the same
    traffic;
  * and it is unfalsifiable from the alert. Working this out took reading the raw
    series, not the alert page.

HOW IT SURVIVED FOURTEEN DAYS
=============================

`targets/services.yaml` is generated from the release manifest and was never
wrong: rendered against release 2026.8.109 it emits SEVEN targets, because an
absorbed service leaves the manifest and stops being rendered. The deployed
ConfigMap held TWENTY-SEVEN. It was rendered on 2026-08-19 and never refreshed,
because `release-deploy.sh` rendered the scrape list on every compose deploy and
`k8s-deploy.sh` — which replaced it — did not render it at all. The generator was
right and nobody ran it.

So this check does NOT read the repository's idea of what runs. It asks the
cluster, which is the only thing that knows (`k8s-migration-dropped-the-compose-
only-workloads`): it resolves every scrape target through the live Service
objects and refuses when two land on one workload.

WHAT IT REFUSES
===============

  * two targets whose hosts resolve, through any chain of ExternalName Services,
    to the same in-cluster Service;
  * a target naming a Service that does not exist at all.

WHAT IT ALLOWS
==============

  * two targets on the same Service at DIFFERENT PORTS. `gateway:8082` and a
    future `gateway:9100` are two exporters on one workload, which is a real
    thing and not this defect — the collision is one exposition page counted
    twice, and two ports are two pages.
  * hosts outside the estate namespaces (the telemetry plane's own members,
    `localhost`), which this check does not resolve and does not judge.

USAGE
=====

    ./scripts/check-prometheus-target-aliases.py [--namespace cloudsforge-estate]

Needs a working `kubectl` against the estate's cluster. It is a LIVE check: it
belongs in `k8s-estate-verify.sh`, not in CI, for the same reason the defect
existed — a checkout cannot see which of its services still have a process.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fail(message):
    print(f"check-prometheus-target-aliases: {message}", file=sys.stderr)
    sys.exit(1)


def kubectl(*args):
    proc = subprocess.run(
        ["kubectl", *args], capture_output=True, text=True, timeout=60
    )
    if proc.returncode != 0:
        fail(f"`kubectl {' '.join(args)}` failed:\n       {proc.stderr.strip()}")
    return proc.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--namespace", default="cloudsforge-estate")
    ap.add_argument(
        "--targets",
        help="the rendered targets file. Omitted: read the live prometheus-targets ConfigMap.",
    )
    ap.add_argument("--telemetry-namespace", default="cf-telemetry")
    args = ap.parse_args()

    # ── the scrape list, as deployed ─────────────────────────────────────────
    # Both halves of it: the generated file AND the hand-written jobs in
    # prometheus.yml, because the alias that caused micro-org#541 was in BOTH —
    # nineteen generated ones and a hand-written `lantern` job that had outlived
    # its pod. A check that read only the generated half would have passed.
    if args.targets:
        rendered = Path(args.targets).read_text()
    else:
        rendered = kubectl(
            "-n", args.telemetry_namespace, "get", "cm", "prometheus-targets",
            "-o", r"jsonpath={.data.services\.yaml}",
        )
    static = kubectl(
        "-n", args.telemetry_namespace, "get", "cm", "prometheus-config",
        "-o", r"jsonpath={.data.prometheus\.yml}",
    )

    addresses = []
    for text in (rendered, static):
        for group in re.findall(r"^\s*- targets:\s*\[(.*)\]\s*$", text, re.M):
            for quoted in re.findall(r"\"([^\"]+)\"|'([^']+)'", group):
                addresses.append(quoted[0] or quoted[1])
    if not addresses:
        fail(
            "found no scrape targets at all in the deployed ConfigMaps.\n"
            "       That is not a pass. Either the telemetry plane is not deployed or\n"
            "       these are not the ConfigMaps it reads, and an empty target list is\n"
            "       exactly the silent-green micro-org#308 was."
        )

    # ── the Services, and what each ultimately points at ─────────────────────
    # EVERY namespace, not the two this script was given. A scrape target is
    # allowed to name any namespace — `backup-runner.cf-testnet...` was in the
    # deployed config on 2026-09-02 — and loading only two would report a Service
    # in a third as missing, which is a false accusation in the same words as the
    # true one.
    services = {}
    listing = json.loads(kubectl("get", "svc", "--all-namespaces", "-o", "json"))
    for item in listing["items"]:
        name = item["metadata"]["name"]
        ns = item["metadata"]["namespace"]
        services[f"{name}.{ns}.svc.cluster.local"] = item["spec"].get("externalName")

    def resolve(host):
        """Follow ExternalName hops to the Service that actually has endpoints."""
        seen = []
        while host in services and services[host]:
            if host in seen:
                fail(f"ExternalName cycle: {' -> '.join([*seen, host])}")
            seen.append(host)
            host = services[host]
        return host

    unknown = []
    landed = {}
    for address in sorted(set(addresses)):
        host, _, port = address.rpartition(":")
        if not host.endswith(".svc.cluster.local"):
            continue  # the telemetry plane's own members and localhost
        final = resolve(host)
        if final not in services:
            unknown.append(address)
            continue
        landed.setdefault((final, port), []).append(address)

    collisions = {k: v for k, v in landed.items() if len(v) > 1}

    problems = []

    if unknown:
        problems.append(
            "scrape target(s) name a Service that does not exist:\n       "
            + "\n       ".join(unknown)
            + "\n\n       A target pointing at nothing joins the list as one more permanently\n"
            "       down service, which is how micro-org#308 hid for four months."
        )

    if collisions:
        lines = []
        for (final, port), names in sorted(collisions.items()):
            lines.append(f"{final}:{port} is scraped {len(names)} times, as:")
            lines.extend(f"    {n}" for n in sorted(names))
        problems.append(
            "two or more scrape targets resolve to ONE workload:\n\n       "
            + "\n       ".join(lines)
            + "\n\n       Each of those names will carry its own `service` label onto the SAME\n"
            "       exposition page, and rules/slo.yaml aggregates http_requests_total by\n"
            "       (network, service, tier). One failing route then burns every one of\n"
            "       those services' error budgets at once — twenty-four alerts for one\n"
            "       route, on 2026-09-01 (micro-org#541).\n\n"
            "       The usual cause is an absorbed service: its ExternalName CNAME is kept\n"
            "       so callers need not change, and something is still scraping the alias.\n"
            "       Fix it where the target is declared — regenerate targets/services.yaml\n"
            "       from the current release, or delete the hand-written job."
        )

    if problems:
        fail("\n\n       ".join(problems))

    scraped = sorted({f"{final}:{port}" for (final, port) in landed})
    print(
        f"check-prometheus-target-aliases: ok — {len(addresses)} scrape target(s) resolve to "
        f"{len(scraped)} distinct workload endpoint(s), none of them twice."
    )


if __name__ == "__main__":
    main()
