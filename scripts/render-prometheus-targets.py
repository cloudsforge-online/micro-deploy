#!/usr/bin/env python3
"""Render Prometheus's `file_sd` target list from the release manifest.

    printf '%s' "$config_json" | ./scripts/render-prometheus-targets.py \\
        ../org/releases/2.5.8.yaml --compose-json - --out prometheus/targets/services.yaml

WHY THIS EXISTS
---------------
`prometheus/targets/services.yaml` was the literal string `[]` from the day the
telemetry plane was deployed until 2026-08-09, so the `cf-services` job scraped
nothing and every alert rule that reads an estate metric evaluated against no
data (micro-org#308). Measured on mainnet that morning: 8 active targets, of
which 7 were the monitoring stack watching itself and 1 was the gateway. Not one
was a `micro/` service, while 48 were deployed and pinned by digest.

The file itself named the fix and then nobody did it:

    GENERATED, eventually, from stack/releases/<version>.yaml — the release
    manifest of AD-03, which is the only file that names which image of each
    service is deployed. A hand-maintained scrape list is a second answer to
    "what is running", and the estate already lost that argument once with the
    API_PREFIXES array.

That reasoning is kept whole. This is that generator, and it runs from the same
script, off the same manifest, at the same moment `release-render.py` renders the
pinned compose overlay. Both answer "what is running" from one file. Prometheus
re-reads `file_sd` every 30s, so a release costs no scraper restart and no gap.

WHICH SERVICES, AND WHY IT IS NOT `kind: service`
-------------------------------------------------
The manifest's 48 entries are not 48 scrape targets, and a target that cannot be
scraped is worse than no target: it sits `down` forever, it trains whoever reads
the target page to expect red, and it is indistinguishable from a service that
has actually stopped.

The obvious filter — the manifest's own `kind: service` — is wrong in both
directions, measured against mainnet on 2026-08-09:

  * `lantern` and `beacon` are `kind: ops` and both serve `/metrics`.
  * `analytics` is `kind: service` and answers 401, deliberately: its `/metrics`
    "publishes which producers are being refused and at what rate, which is a map
    of where the estate's privacy discipline is weakest" (analytics/src/server.ts).
  * `foresight` and `tessera` are `kind: service` and serve nothing on 4000 —
    they bind 4021 and 4022, because 4022 sits below the derived 4100+ host-port
    block and 4021 likewise. Assuming a uniform in-container 4000 would have
    produced two permanently-down targets for two entirely healthy services.

So the rule is a PROPERTY OF THE SERVICE, read from the rendered compose model:

    A service is scraped at the port its own health check probes `/readyz` on.

That is derived, it is already in the file, and it is exactly the right set for a
reason rather than by coincidence. Rule 4 of docs/ecosystem/03 §2 is "`/livez`,
`/readyz` and `/metrics` on every service, or it does not pass CI" — the three
are one obligation, so a container the estate already asserts answers `/readyz`
on a port is a container that answers `/metrics` on that port. The static front
ends fall out on their own: every `*-web` and every site is nginx probing
`/healthz` on 8080, so none of them matches, and none of them is hand-excluded.

Verified against the live mainnet estate on 2026-08-09 before this was written —
every one of the 26 services this emits answered `GET /metrics` with `200` and a
Prometheus exposition body, and every one of the 18 web deployables answered
nothing at all on any port.

WHY NOT PROBE `/metrics` AT RENDER TIME
---------------------------------------
Because a probe makes the target list depend on liveness, and the failure that
produces is the one this whole issue is about: a service that happens to be
restarting during a deploy would be dropped from the scrape list, and a service
that is down would silently stop being monitored at exactly the moment monitoring
matters. A new service would also never enter the list, because the render runs
before `up -d` and the container does not exist yet. The predicate has to be a
statement about the configuration, not about the weather.

THE ONES WITH A CREDENTIAL ON /metrics
--------------------------------------
`analytics`, `lantern` and `beacon` gate `/metrics` behind a static header token,
each on purpose and each saying so in its own source: an open `/metrics` on those
three publishes the shape of the estate, the map of which services are failing,
and the map of where privacy enforcement is weakest. Prometheus attaches
credentials per SCRAPE JOB and not per target, so they cannot ride in a
`file_sd` list at all — they have their own jobs in `prometheus.yml`, with their
token read from a file.

They are therefore excluded here, and the exclusion is READ FROM `prometheus.yml`
rather than typed: any manifest service that already appears as a `static_configs`
target in the scrape config is skipped, because something else is already
scraping it. Adding a fourth credentialed job needs no edit to this file, and
deleting one puts the service back into the generated list automatically. A
hand-typed exclusion list here would be the second answer to "what is scraped"
that the paragraph at the top of this docstring refuses.

THE `tier` LABEL, WHICH IS NOT DECORATION
-----------------------------------------
`prometheus/rules/slo.yaml` computes a different objective for Tier 1 (money,
99.95%) than for Tier 2 (product, 99.5%). It used to select Tier 1 with a
hardcoded `service=~"ledger|wallet|settlement|custody|indexer|pricing|billing"`,
which had already drifted: 13-operational-model.md §8 lists `billing` under
Tier 2 in as many words, so `billing` was being held to twenty-one minutes of
budget a month by a regex nobody re-read. It now reads the `tier` label this
file attaches, and `prometheus/tiers.yaml` is the one place the membership lives.

See `prometheus/tiers.yaml` for why the map is there and not in the manifest.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

parser = argparse.ArgumentParser(
    description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
)
parser.add_argument("manifest", help="path to a release manifest (org/releases/<version>.yaml)")
parser.add_argument(
    "--compose-json",
    metavar="PATH",
    help="`docker compose config --format json` for THIS deploy, or `-` for stdin. "
    "Omit and this runs the command itself from --base/--overlay/--env-file.",
)
parser.add_argument("--base", default="compose/docker-compose.estate.yml")
parser.add_argument("--overlay", default="compose/docker-compose.release.yml")
parser.add_argument("--env-file", action="append", default=[], dest="env_file", metavar="PATH")
parser.add_argument(
    "--prometheus-yml",
    default=str(ROOT / "prometheus" / "prometheus.yml"),
    help="read the already-scraped hostnames from here, so a credentialed job is "
    "not also emitted as an anonymous file_sd target",
)
parser.add_argument("--tiers", default=str(ROOT / "prometheus" / "tiers.yaml"))
parser.add_argument("--out", help="write here instead of stdout")
parser.add_argument(
    "--check",
    action="store_true",
    help="validate and report, write nothing. This is what the deploy runs BEFORE it "
    "touches a container, so an untiered service fails the release rather than the estate.",
)
args = parser.parse_args()


def fail(message):
    sys.exit(f"FAIL: {message}")


# ---------------------------------------------------------------------------
# The manifest. Parsed to exactly the shape `cfctl release` emits and no other,
# mirroring release-render.py's parser and its reasoning: "a manifest that is not
# exactly this shape was not generated by cfctl and should not be deployed." A
# tolerant parser here would accept a hand-written file, and a hand-written
# manifest is the drift the format exists to prevent.
# ---------------------------------------------------------------------------
manifest_path = pathlib.Path(args.manifest)
if not manifest_path.exists():
    fail(f"no manifest at {manifest_path}")

version = ""
manifest_services = []
section = None
current = None
for raw in manifest_path.read_text().split("\n"):
    line = raw.rstrip()
    if not line or line.lstrip().startswith("#"):
        continue
    if line.startswith("version:"):
        version = line[len("version:"):].strip().strip('"')
        continue
    if line == "services:":
        if current:
            manifest_services.append(current)
            current = None
        section = "services"
        continue
    if line == "absent:":
        if current:
            manifest_services.append(current)
            current = None
        section = "absent"
        continue
    if section != "services":
        continue
    if line.startswith("  - "):
        if current:
            manifest_services.append(current)
        current = {}
    body = re.sub(r"^ {2}(- )?", "", line)
    body = re.sub(r"^ {2}", "", body)
    if ":" in body and current is not None:
        key, _, value = body.partition(":")
        current[key.strip()] = value.strip().strip('"')
if current:
    manifest_services.append(current)

if not version:
    fail(f"{manifest_path} names no version. Refusing to describe a release that cannot be named.")
if not manifest_services:
    fail(f"{manifest_path} names no services. A manifest that deploys nothing is not a release.")

# ---------------------------------------------------------------------------
# The rendered compose model. Passed IN by the deploy rather than re-rendered
# here, on purpose: release-deploy.sh already computes this document to check the
# hand-off allowlist and to decide the pull set, and its header explains why —
# "rendering it twice would let the allowlist and the pull set be computed from
# two different resolutions of the same files". The scrape list is a third
# consumer of the same document and gets the same treatment.
# ---------------------------------------------------------------------------
if args.compose_json == "-":
    raw_json = sys.stdin.read()
elif args.compose_json:
    raw_json = pathlib.Path(args.compose_json).read_text()
else:
    cmd = ["docker", "compose"]
    for env_file in args.env_file:
        cmd += ["--env-file", env_file]
    cmd += ["-f", args.base]
    if pathlib.Path(args.overlay).exists():
        cmd += ["-f", args.overlay]
    cmd += ["config", "--format", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        fail(
            "`docker compose config` failed, so what this environment actually defines is\n"
            "       unknown. Refusing to guess a scrape list.\n"
            f"       {proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else ''}"
        )
    raw_json = proc.stdout

try:
    compose_model = json.loads(raw_json)
except Exception as err:  # noqa: BLE001 — any parse failure is the same refusal
    fail(f"the compose model is not JSON ({err}). Refusing to guess a scrape list.")

compose_services = compose_model.get("services") or {}
if not compose_services:
    fail("the compose model defines no services. Refusing to write an empty scrape list.")

# ---------------------------------------------------------------------------
# THE ADDRESS IS THE CONTAINER NAME, NOT THE SERVICE NAME (micro-org#437).
#
# `indexer:4000` is not an address on this host. It is a QUESTION, and since
# 2026-08-11T23:59:45Z it has had two answers: Prometheus is attached to
# `cloudsforge-estate_default` AND `cf-testnet_default`, because reaching one
# testnet container for the `cf-indexer-testnet` job (micro-org#398) meant
# joining a whole network. Docker's embedded DNS resolves a bare name against
# the container's networks in name order, `cf-testnet_default` sorts first, and
# every one of these targets silently became the TESTNET container — while the
# series kept the mainnet job's labels. Measured: three mainnet chains stop and
# testnet starts in the SAME 15s sample, and ten consecutive probes of
# `http://indexer:4000/metrics` from inside Prometheus answered testnet ten
# times. Deterministic, which is worse than flapping: nothing looked broken.
#
# Container names are unique per host across projects, so they are the one form
# of this address that cannot acquire a second answer. `cf-indexer-testnet` in
# `prometheus.yml` has always named `cf-testnet-indexer-1` for this reason; the
# generated list is now consistent with the job beside it.
#
# The project is read off the compose model — the same document the deploy uses
# to decide what to bring up — and never typed. A hand-written project name here
# would be a second answer to "what is running" of exactly the kind this file's
# docstring exists to refuse.
# ---------------------------------------------------------------------------
project = str(compose_model.get("name") or "").strip()
if not project:
    fail(
        "the compose model carries no project `name`, so a container name cannot be\n"
        "       derived. `docker compose config --format json` has emitted one since v2;\n"
        "       a model without it is not the document this expects, and guessing the\n"
        "       project is how a scrape target acquires a second answer (micro-org#437)."
    )


def container_names(name, spec):
    """The container(s) compose will create for this service, in scrape order.

    `container_name:` wins when a service pins one, because then compose creates
    exactly that and the numbered form would not resolve. Otherwise it is
    `<project>-<service>-<n>`, which is compose's own naming and the reason
    `docker ps` reads the way it does.

    Replicas are handled rather than assumed away: AD-17 makes `deploy.replicas`
    legal, and a service with three of them has three containers, each with its
    own /metrics. Measured on mainnet 2026-08-12 — every container is `-1`, so
    this returns a single name today and the loop below is not speculative
    machinery, it is the reason a second replica would be scraped instead of
    dropped.
    """
    pinned = spec.get("container_name")
    if pinned:
        return [str(pinned)]
    replicas = ((spec.get("deploy") or {}).get("replicas")) or 1
    try:
        replicas = max(1, int(replicas))
    except (TypeError, ValueError):
        replicas = 1
    return [f"{project}-{name}-{index}" for index in range(1, replicas + 1)]


def environment(spec):
    """Compose renders `environment` as a map or a list depending on how it was written."""
    env = spec.get("environment") or {}
    if isinstance(env, list):
        return dict(item.split("=", 1) for item in env if "=" in item)
    return env


READYZ = re.compile(r"https?://[^/\s\"']+:(\d+)/readyz")


def readyz_port(spec):
    """The port this service's own health check probes `/readyz` on, or None.

    This is the whole inclusion rule. See the docstring: `/livez`, `/readyz` and
    `/metrics` are one obligation in this estate, so the port the compose file
    already asserts answers the second is the port that answers the third.

    Returns None for anything that probes a different path — every `*-web` and
    every static site is `wget http://127.0.0.1:8080/healthz`, so they fall out
    here rather than being named in an exclusion list that would go stale the day
    a nineteenth front end lands.
    """
    test = (spec.get("healthcheck") or {}).get("test")
    if not test:
        return None
    text = " ".join(test) if isinstance(test, list) else str(test)
    match = READYZ.search(text)
    return int(match.group(1)) if match else None


# ---------------------------------------------------------------------------
# Hostnames something in prometheus.yml already scrapes by hand. See the
# docstring: these are the three services that gate /metrics behind a header
# token, which a file_sd entry cannot carry, and reading them out of the scrape
# config is what keeps this file from holding a second copy of that decision.
# ---------------------------------------------------------------------------
prom_path = pathlib.Path(args.prometheus_yml)
if not prom_path.exists():
    fail(f"no scrape config at {prom_path}, so which services are already scraped is unknown.")

already_scraped = set()
for line in prom_path.read_text().split("\n"):
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
        # Those jobs name CONTAINERS now, for the reason argued above, and this
        # set is compared against MANIFEST SERVICE NAMES. Without this the match
        # stops working the moment `prometheus.yml` is pinned — and the failure
        # is not loud: `beacon` would fall through into the generated list and
        # be scraped a second time, anonymously, 401ing forever beside the
        # credentialed job that works. That is the exact outcome the `fail()`
        # below was written to prevent, so the normalisation lives here with it.
        stem = re.sub(rf"^{re.escape(project)}-", "", host)
        stem = re.sub(r"-\d+$", "", stem)
        already_scraped.add(host)
        already_scraped.add(stem)
if not already_scraped:
    # Not a pass. The three credentialed jobs are in that file today; finding
    # none means the parse stopped matching, and the consequence is an anonymous
    # duplicate target that 401s forever beside a working credentialed one.
    fail(
        f"{prom_path} yielded no static_configs targets. It has always had several, so this\n"
        "       is a parse that stopped working, not a scrape config that emptied."
    )

# ---------------------------------------------------------------------------
# The tier map.
# ---------------------------------------------------------------------------
tiers_path = pathlib.Path(args.tiers)
if not tiers_path.exists():
    fail(f"no tier map at {tiers_path}. The SLO rules read `tier` and cannot be given one.")

tiers = {}
TIER_LINE = re.compile(r"^([a-z][a-z0-9-]*):\s*\"?([123])\"?\s*(?:#.*)?$")
for line in tiers_path.read_text().split("\n"):
    if not line or line.lstrip().startswith("#"):
        continue
    match = TIER_LINE.match(line.rstrip())
    if match:
        tiers[match.group(1)] = match.group(2)
if not tiers:
    fail(f"{tiers_path} names no service tiers, so every target below would be untiered.")

# ---------------------------------------------------------------------------
# Decide.
# ---------------------------------------------------------------------------
emitted = []
skipped_not_in_environment = []
skipped_no_readyz = []
skipped_own_job = []
untiered = []
port_disagreements = []

for entry in manifest_services:
    name = entry.get("name")
    if not name:
        continue
    spec = compose_services.get(name)
    if spec is None:
        # Profile-gated somewhere else, or defined on the other network. `faucet`
        # is testnet-only in its own type system; it is not missing, it is not here.
        skipped_not_in_environment.append(name)
        continue
    if name in already_scraped:
        skipped_own_job.append(name)
        continue
    port = readyz_port(spec)
    if port is None:
        skipped_no_readyz.append(name)
        continue

    # PORT and the health check are two independent statements about the same
    # number and they are allowed to be checked against each other. A service
    # whose health check probes a port it does not bind is a real defect — it
    # would report healthy on somebody else's listener — and it would also send
    # this scrape somewhere wrong, so it stops the render rather than being
    # quietly resolved in one direction.
    declared = environment(spec).get("PORT")
    if declared and str(declared).strip() != str(port):
        port_disagreements.append(f"{name}: PORT={declared} but the health check probes :{port}")
        continue

    tier = tiers.get(name)
    if tier is None:
        untiered.append(name)
        continue
    emitted.append((name, port, tier))

if port_disagreements:
    fail(
        "a service's PORT and its health check name different ports:\n         "
        + "\n         ".join(port_disagreements)
        + "\n       One of the two is wrong, and both a health check and a scrape would be\n"
        "       pointed at a listener that is not this service's."
    )

if untiered:
    fail(
        "these services are scrapable and have no tier in "
        f"{tiers_path.name}:\n         " + ", ".join(sorted(untiered)) + "\n"
        "       Add a line each. Defaulting them to Tier 2 would hold a money service to\n"
        "       99.5% instead of 99.95% — the SLO stops meaning anything and nothing says so,\n"
        "       which is exactly the drift the `tier` label exists to prevent. This is a\n"
        "       pre-flight failure: no container has been touched."
    )

if not emitted:
    fail(
        "the release names no scrapable service. Refusing to write an empty target list —\n"
        "       `[]` is the state micro-org#308 exists about, and writing it silently is how\n"
        "       it lasted from the telemetry plane's first deploy until 2026-08-09."
    )

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------
lines = [
    "# GENERATED by scripts/render-prometheus-targets.py — do not hand-edit.",
    f"# Release:  {version}",
    f"# Manifest: {manifest_path}",
    "#",
    "# Rewritten by scripts/release-deploy.sh on every deploy and every rollback, from",
    "# the same manifest that renders the pinned compose overlay. Prometheus re-reads",
    "# this file every 30s (`refresh_interval` on the `cf-services` job), so it costs",
    "# no restart and there is no window in which the scrape list and the running",
    "# estate disagree by more than half a minute.",
    "#",
    "# Each target is a CONTAINER NAME, not a service name, and carries an explicit",
    "# `instance` that keeps the old `<service>:<port>` series identity. A bare service",
    "# name resolves to whichever project's container Docker's DNS reaches first, and on",
    "# this host that is the testnet one — see micro-org#437 and the generator.",
    "#",
    "# A service is here because ITS OWN HEALTH CHECK probes /readyz on this port, and",
    "# rule 4 of docs/ecosystem/03 §2 makes /livez, /readyz and /metrics one obligation.",
    "# Nothing below is hand-typed and nothing is hand-excluded; see the generator.",
    "#",
    f"# In this release and not scraped here ({len(skipped_no_readyz)} static front ends, "
    f"{len(skipped_own_job)} with their own credentialed job,",
    f"# {len(skipped_not_in_environment)} not defined in this environment):",
]
for label, names in (
    ("no /readyz health check — nginx on 8080, nothing to scrape", skipped_no_readyz),
    ("scraped by its own job in prometheus.yml, /metrics needs a token", skipped_own_job),
    ("not defined in this environment", skipped_not_in_environment),
):
    if names:
        lines.append(f"#   {label}:")
        lines.append(f"#     {', '.join(names)}")
lines.append("")

for name, port, tier in emitted:
    hosts = container_names(name, compose_services[name])
    lines.append("- targets: [" + ", ".join(f'"{host}:{port}"' for host in hosts) + "]")
    lines.append("  labels:")
    # `instance` is PINNED to the old `<service>:<port>` rather than left to
    # default to the address. The address had to change (micro-org#437); the
    # series identity must not. Every recording rule, every dashboard panel and
    # every alert annotation built on these series keys on labels that include
    # `instance`, and letting it become the container name would orphan all of
    # them to fix a resolution bug they have nothing to do with. It is also the
    # stable value: a container name carries a replica ordinal that changes when
    # a replica is rescheduled, which is the churn the `cf-services` relabel
    # block below already argues against.
    #
    # With replicas the ordinal is exactly what distinguishes the targets, so a
    # single pinned `instance` would collapse them into one series. Pin only
    # when there is one container, and let the address be the identity when
    # there is more than one.
    if len(hosts) == 1:
        lines.append(f"    instance: {name}:{port}")
    lines.append(f"    __meta_cf_service: {name}")
    # The manifest records no owning team, so the team IS the service until it
    # does. That is the shape the file's original worked example used
    # (`__meta_cf_team: ledger` for `ledger`), and Alertmanager's routes match
    # `team =~ "ledger|settlement|security"` with a catch-all behind them, so a
    # per-service value routes rather than falling off the end. When `cfctl
    # release` learns to carry ownership, this is the one line that changes.
    lines.append(f"    __meta_cf_team: {name}")
    lines.append(f'    tier: "{tier}"')

rendered = "\n".join(lines) + "\n"

summary = (
    f"prometheus targets: {len(emitted)} scraped, "
    f"{len(skipped_no_readyz)} static front ends, "
    f"{len(skipped_own_job)} credentialed elsewhere, "
    f"{len(skipped_not_in_environment)} not in this environment "
    f"(release {version})"
)

if args.check:
    print(f"  {summary}")
    sys.exit(0)

if args.out:
    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(rendered)
    print(f"  wrote {out} — {summary}")
else:
    sys.stdout.write(rendered)
