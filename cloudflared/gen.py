#!/usr/bin/env python3
"""Generate — and then CHECK — the cloudflared ingress for both environments.

WHY THIS FILE EXISTS AT ALL
---------------------------
Three files in this repository refer to `deploy/cloudflared/config.example.yml`
as though it were a thing you could open:

  * `README.md:406`               — "asserted by a CI job that parses that"
  * `gateway/dynamic/policy.yml:13` — "Today this is a path rule in
                                    deploy/cloudflared/config.example.yml and a
                                    CI job (.github/workflows/ci.yml:155)"
  * `compose/docker-compose.gateway.yml:17` — "today: a hand-written path rule
                                    in deploy/cloudflared/"

It did not exist. Neither did the CI job: `.github/workflows/ci.yml` has exactly
one job in it, and it runs `scripts/surface-routes.py`. So the estate's own
record of where the `/internal` refusal lives named a file that was absent and a
check that was never written — which is precisely the failure mode
`surface-routes.py`'s check 4 was added for ("A ROUTER DESCRIBED IN PROSE IS NOT
A ROUTER"), reappearing one directory over in a form that check could not see,
because check 4 only reads `gateway/dynamic/*.yml`.

The refusal is real today — `policy.yml:200`, `cf-internal-refusal`, a
`PathRegexp` router at priority 100000 pointed at an unreachable service. This
directory does not replace it. It restores the SECOND copy the prose has been
promising, at the edge, where it costs one rule and is the only one of the two
that applies before a request enters the host at all.

WHAT IS DERIVED, AND WHAT IS NOT
--------------------------------
Everything derivable is derived. The estate has paid four times for a
hand-maintained list of hostnames — sixteen identical `obs.ts` files posting to a
dead path, fifteen gateway hosts drifted from the registry, seven bespoke
footers, and a compose alias list that omitted the bare apex because every entry
was prefixed — and a hand-typed cloudflared ingress would be the fifth.

  DERIVED from `ui/packages/ui/src/surfaces.ts`, by running micro-ui's own
  module exactly as `scripts/surface-routes.py` does:

    * WHICH hostnames exist       — every surface with no `basePath` is a host.
    * WHICH TUNNEL each belongs to — and this is the part worth reading twice,
      because it is not a judgement this script makes. The registry already
      carries the two booleans that separate the three classes:

          operator  =  adminOnly is true          -> admin, foresight-admin,
                                                     lantern, beacon      (4)
          api       =  servesUi is false          -> nimbus, account, api,
                                                     worlds-api, pay, vault,
                                                     rpc, p2p               (8)
          public    =  everything else            -> the apex + 13         (14)

      14 / 4 / 8. Those are the counts the deployment brief arrived at by
      hand — 14 / 4 / 6 then — reproduced here without a list, from fields that
      already existed for another purpose entirely (`adminOnly` hides a surface
      from the product switcher unless the viewer holds the `admin` role —
      index.tsx:368). A seventh product, or a fifth console, is a registry row
      and nothing else.

      `rpc` and `p2p` ARE THE TWO THAT MADE THAT LAST SENTENCE TRUE OF THIS FILE
      TOO. `rpc.<apex>` used to be the one hostname here that was not derived: a
      hand-written rule appended after the loop, pointing PAST the gateway
      straight at the node, with an `RPC_PORT` constant beside GATEWAY_PORT to
      support it. The owner's instruction was that "rpc should be behind traefik
      like everything else", and once it is, it is an ordinary API-class surface
      — so the flag, the constant and the special case are gone, and the two
      chain hostnames arrive here the way the other twenty do. The registry rows
      argue their own case (`ui/packages/ui/src/surfaces.ts`, the `rpc` and `p2p`
      entries).

  DERIVED from `compose/docker-compose.telemetry.yml`: the loopback port each
  utility publishes. They are not routed (see NOT_ROUTED below), but the check
  asserts that they are not, and it cannot assert that against a port it has
  guessed.

  NOT DERIVABLE, and declared here with a reason each: the origin port of the
  gateway, and the port offset that separates the two environments. There is no
  registry of those; there is this table, and the check reads it. The chain's
  RPC port WAS in this paragraph and is not any more — every rule in every file
  below now ends at the gateway, so the only origin port this generator knows is
  the gateway's.

THE FILE IS GENERATED, SO THE CHECK IS A DIFF
---------------------------------------------
`surface-routes.py` argues at length for why `estate-web.yml` stays hand-written
and is CHECKED rather than generated: that file is an argument, not a mapping,
and a generator would either discard the prose or grow a per-surface exception
table, "which is the same hand-written list again, one level less visible".

That argument does not transfer, and the difference is worth stating rather than
assumed. A cloudflared ingress carries no reasoning — it is `hostname` ->
`service`, four times thirty. There is nothing in it to lose. So it is generated,
the generated file is COMMITTED (an operator must be able to read what the tunnel
will do without running Python), and `--check` regenerates in memory and diffs.
Drift fails CI. That is the same guarantee by the opposite mechanism.

  ./gen.py            write the four config files
  ./gen.py --check    exit 1 if what is on disk is not what this would write

NEVER SKIPS. A check that cannot run reports failure rather than a success it did
not establish — the rule `surface-routes.py` ends on, for the same reason.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
UI = MICRO / "ui" / "packages" / "ui"
TELEMETRY = ROOT / "compose" / "docker-compose.telemetry.yml"
HERE = pathlib.Path(__file__).resolve().parent

# ── the two environments ──────────────────────────────────────────────────────
#
# One host, two compose projects, two apexes. `offset` is the single number that
# separates every published port in the testnet project from its mainnet twin,
# and it is 10000 because that keeps every shifted port readable as its original
# with a `1` in front (443 -> 10443, 8545 -> 18545) and every one below 65535.
#
# It is the ONLY thing here that has a twin elsewhere: `compose/testnet.env` sets
# the same shift for the compose project, expressed as leading digits
# (CF_PORT_BASE=5, CF_GATEWAY_PORT=10443) because compose cannot do arithmetic.
# The two must agree — this file's `offset` decides where the TUNNEL sends a
# request, testnet.env decides where the gateway LISTENS, and a disagreement is a
# tunnel pointed at a closed port on a box nobody can reach yet. So it is
# CHECKED, by `gateway_port_agrees()` below, rather than left to the go-live
# checklist: neither side can be RUN on the machine this was written on, but both
# sides are text in this repository and a mismatch between two texts is exactly
# the class of defect this estate keeps paying for.
ENVIRONMENTS = {
    "mainnet": {"apex": "cloudsforge.online", "offset": 0, "project": "cloudsforge-estate"},
    "testnet": {"apex": "testnet.cloudsforge.online", "offset": 10000, "project": "cf-testnet"},
}

# ── the one origin that is not in any registry, and why its port is what it is ─
#
# ONE, not two. `RPC_PORT = 8545` stood here and was the chain's own port, because
# `rpc.<apex>` was routed past the gateway directly to hearth. It is behind Traefik
# now like every other hostname, so the port that reaches the chain is a gateway
# concern (`CF_RPC_UPSTREAM`, gateway/dynamic/estate-web.yml) and not a tunnel one.
# Nothing in this file needs to know what a chain is any more.
GATEWAY_PORT = 443   # compose/docker-compose.estate-gateway.yml:55, loopback only

# ── hostnames deliberately NOT routed, and the argument for each ─────────────
#
# Every entry is a CLAIM, and the check tests it in both directions: an entry
# here that HAS gained a route is a comment that has stopped being true, which is
# this estate's most expensive recurring defect.
NOT_ROUTED = {
    "account": (
        "nothing serves it. The registry row reserves the hostname and says so in as many "
        "words, `surface-routes.py`'s EXPECTED_UNROUTED repeats it, and identity binds 4001 "
        "while rendering no HTML at all (identity/src/server.ts §3 forbids it). Routing it "
        "would publish a hostname that resolves, terminates TLS, and returns nothing — and "
        "this is the address every `Sign in` button in the estate USED to point at, so a "
        "live-but-empty `account.<apex>` is not merely useless, it is the exact shape a "
        "phishing page wants to occupy. The address a person is actually sent to is "
        "`hub.<apex>/account`."
    ),
    "grafana": "utility — see the block comment below",
    "prometheus": "utility — see the block comment below",
    "tempo": "utility — see the block comment below",
    "loki": "utility — see the block comment below",
    "alertmanager": "utility — see the block comment below",
}

# ── THE UTILITY DECISION, WHICH IS A SECURITY DECISION ────────────────────────
#
# Grafana, Prometheus, Tempo, Loki and Alertmanager are NOT routed through any
# tunnel, in either environment. This was the closest call in the whole ingress
# and it is decided against exposure, for a reason that is about the software
# rather than about the tunnel:
#
#   FOUR OF THE FIVE HAVE NO AUTHENTICATION AT ALL. Not weak authentication —
#   none. Prometheus has no concept of a user; Loki in single-binary mode has
#   none; Tempo has none; Alertmanager has none. Only Grafana has a login, and
#   `.env.example` already says of it: "only reachable on loopback is not a
#   password policy."
#
# Put those behind a tunnel and Cloudflare Access is not A gate, it is the ONLY
# gate. One misconfigured Access policy — an application left in bypass, a rule
# scoped to the wrong path, a tunnel hostname added without a matching policy —
# and the failure is total rather than partial:
#
#   * Prometheus serves the estate's entire topology to anyone who asks. Every
#     service, every target, every label. It is a map of the box.
#   * Alertmanager's `/api/v2/silences` takes a POST. Anyone who reaches it can
#     silence every alert in the estate and then take their time.
#   * Loki holds the logs, which is where anything the estate has ever
#     accidentally logged now lives.
#
# The estate's own posture already points this way and says so: the gateway binds
# 9095/9096/9097 to loopback and calls public exposure "the tunnel's job"
# (docker-compose.estate-gateway.yml), and `.env.example` writes secret FILES
# rather than environment variables "because a credential in an environment
# variable is a credential in `docker inspect`". This is that same instinct
# applied to the observability plane.
#
# WHAT AN OPERATOR DOES INSTEAD. They are already published on 127.0.0.1 and
# they stay there. Reaching them off-box is `ssh -L 9091:127.0.0.1:9091` to the
# MicroServer, or Cloudflare WARP with the tunnel in private-network mode, which
# routes IPs rather than hostnames and never terminates HTTP on a public
# hostname. Both put the authentication decision on the SSH/WARP layer, which
# has one, instead of on five services that do not.
#
# THE COST, STATED. `grafana.<apex>` is then not a link an operator can send
# someone, and a dashboard cannot be opened from a phone during an incident
# without WARP. That is a real loss and it is accepted: the runbooks in
# `runbooks/` are written against `docker` and `psql` on the host, not against a
# browser, so the incident path does not depend on this.
UTILITY_SERVICES = ["grafana", "prometheus", "tempo", "loki", "alertmanager"]


TESTNET_ENV = ROOT / "compose" / "testnet.env"


def gateway_port_agrees():
    """`compose/testnet.env`'s gateway port must equal GATEWAY_PORT + offset.

    Two files hold the same number in different notations. This one writes the
    tunnel's origin as `https://127.0.0.1:{GATEWAY_PORT + offset}`; testnet.env
    writes what the gateway BINDS, as a literal, because compose cannot do
    arithmetic. If they disagree the tunnel terminates TLS at Cloudflare and then
    connects to a closed port, and every hostname on that environment returns a
    502 that names nothing.
    """
    if not TESTNET_ENV.exists():
        return [f"{TESTNET_ENV} does not exist — the testnet project's gateway port cannot "
                f"be checked against this file's offset"]
    text = TESTNET_ENV.read_text()
    m = re.search(r"^CF_GATEWAY_PORT=(\d+)", text, re.M)
    if not m:
        return [f"{TESTNET_ENV.name} defines no CF_GATEWAY_PORT, so the gateway would bind the "
                f"default 443 and collide with mainnet"]
    bound = int(m.group(1))
    expected = GATEWAY_PORT + ENVIRONMENTS["testnet"]["offset"]
    if bound != expected:
        return [
            f"{TESTNET_ENV.name} binds the testnet gateway on {bound}, but this file sends the "
            f"testnet tunnel to {expected} (GATEWAY_PORT {GATEWAY_PORT} + offset "
            f"{ENVIRONMENTS['testnet']['offset']}). The tunnel would connect to a closed port "
            f"and every testnet hostname would 502"
        ]
    return []


def die(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def registry_surfaces():
    """Read `SURFACES` by running micro-ui's own module. Never re-parsed here.

    The same approach, and the same refusal to skip, as `scripts/surface-routes.py`.
    """
    if not UI.is_dir():
        die(f"micro-ui is not checked out at {UI} — the registry cannot be read.\n"
            "      This is a failure, not a skip: every hostname below would go unchecked.")
    script = (
        "import {SURFACES} from './src/surfaces.ts';"
        "console.log(JSON.stringify(SURFACES.map(s=>"
        "({key:s.key,subdomain:s.subdomain,basePath:s.basePath ?? null,"
        "servesUi:s.servesUi,adminOnly:s.adminOnly ?? false}))))"
    )
    try:
        out = subprocess.run(["node", "--import", "tsx", "-e", script],
                             cwd=UI, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        die(f"could not run micro-ui's registry: {exc}")
    if out.returncode != 0:
        die(f"micro-ui's registry exited {out.returncode}.\n{out.stderr.strip()[-2000:]}")
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("[")), None)
    if line is None:
        die("micro-ui's registry produced no surface list.")
    import json
    return json.loads(line)


def utility_ports():
    """{service: host port} for the telemetry plane, read from the compose file.

    Not routed, but the check asserts they are not routed, and it cannot assert
    that about a port it has guessed. Parsed by line rather than with a YAML
    parser for the same reason `surface-routes.py` does it: this repository's
    compose and gateway files are read in contexts where a parser is not
    guaranteed, and the shape being matched is unambiguous.
    """
    if not TELEMETRY.exists():
        die(f"{TELEMETRY} does not exist — the utility ports cannot be read")
    ports, svc = {}, None
    for line in TELEMETRY.read_text().splitlines():
        m = re.match(r"^  ([a-z0-9-]+):\s*$", line)
        if m:
            svc = m.group(1)
            continue
        p = re.match(r'^\s+- "127\.0\.0\.1:(\d+):', line)
        if p and svc in UTILITY_SERVICES and svc not in ports:
            ports[svc] = int(p.group(1))
    missing = [s for s in UTILITY_SERVICES if s not in ports]
    if missing:
        die(f"no loopback port found in {TELEMETRY.name} for: {', '.join(missing)}. "
            "The utility block in this file names services that the telemetry plane no "
            "longer publishes, so the claim that they are unrouted covers nothing.")
    return ports


def classify(surfaces):
    """The three tunnel classes, derived from the registry's own two booleans."""
    hosts = [s for s in surfaces if not s["basePath"]]
    operator = [s for s in hosts if s["adminOnly"]]
    api = [s for s in hosts if not s["adminOnly"] and not s["servesUi"]]
    public = [s for s in hosts if not s["adminOnly"] and s["servesUi"]]
    return public, operator, api


def ingress_rules(subdomains, apex, origin):
    """`hostname` -> `service`, sorted, with the apex written bare.

    EVERY RULE ENDS AT THE GATEWAY. There is no second origin and no exception:
    the `rpc=True` flag that appended one hand-written rule pointing at the chain
    is deleted, so this function can no longer produce a rule that skips Traefik
    even if someone asks it to.
    """
    return [(f"{sub}.{apex}" if sub else apex, origin)
            for sub in sorted(subdomains, key=lambda s: (s != "", s))]


HEADER = """\
# GENERATED BY cloudflared/gen.py — DO NOT EDIT BY HAND.
#
# `gen.py --check` regenerates this in memory and fails if it differs from what
# is on disk, so an edit here is reverted by CI rather than deployed. Change the
# registry (ui/packages/ui/src/surfaces.ts) or gen.py's tables instead.
#
#   environment : {env}
#   apex        : {apex}
#   tunnel      : {tunnel}
#   hostnames   : {count}
#
# Fill in `tunnel:` and `credentials-file:` from `cloudflared tunnel create`.
# They are the only two values in this file that are not derived, because they
# are issued by Cloudflare and cannot be known until the tunnel exists.
"""


def render(env, tunnel_name, rules, *, note):
    cfg = ENVIRONMENTS[env]
    lines = [HEADER.format(env=env, apex=cfg["apex"], tunnel=tunnel_name, count=len(rules))]
    lines.append(note.rstrip() + "\n")
    lines.append(f"tunnel: {tunnel_name}")
    lines.append(f"credentials-file: /etc/cloudflared/{tunnel_name}.json")
    lines.append("")
    lines.append("ingress:")
    lines.append("""\
  # ── THE /internal REFUSAL, AT THE EDGE ────────────────────────────────────
  #
  # First rule, no `hostname` key, so it matches EVERY hostname in this file.
  # cloudflared takes the first matching rule, which is the property this
  # depends on.
  #
  # Pay's `/internal` routes take a `userId` as a PARAMETER rather than reading
  # it from an authenticated session (`billing/src/server.ts:505`), so reaching
  # one from off the box is an act-as-anyone primitive. `policy.yml:200` already
  # refuses it inside the host at priority 100000; this is the second copy that
  # three files in this repository have spent months claiming already existed.
  #
  # Case-insensitive and tolerant of leading-slash duplication, because
  # `//Internal/x` and `/%2finternal` are the shapes a path filter is bypassed
  # with. Matched here BEFORE the request reaches the origin at all.
  - path: '(?i)^/+internal(/|$)'
    service: http_status:404
""")
    for hostname, service in rules:
        lines.append(f"  - hostname: {hostname}")
        lines.append(f"    service: {service}")
        if service.startswith("https://"):
            lines.append("    originRequest:")
            # Traefik serves its self-signed default on loopback (estate-gateway.yml
            # says so and calls shipping it wrong). The public certificate is
            # Cloudflare's; this leg never leaves the host.
            lines.append("      noTLSVerify: true")
    lines.append("""\
  # cloudflared REQUIRES a catch-all and refuses to start without one. 404 rather
  # than a redirect: a hostname that is not in this file is not one this estate
  # serves, and answering it with anything else invents a surface.
  - service: http_status:404""")
    return "\n".join(lines) + "\n"


PUBLIC_NOTE = """\
# THE PUBLIC TUNNEL. Everything on it is reachable by anyone, with no Cloudflare
# Access policy in front, because every one of these hostnames is a page meant for
# the public, an API a first-party browser calls cross-origin, or one of the two
# chain endpoints below.
#
# `rpc` AND `p2p` ARE THE TWO THAT ARE NEITHER, and they are the newest entries
# here. Both are Hearth — the Ethereum JSON-RPC a wallet or an exchange points at,
# and the WebSocket peer transport, which exists because a tunnel carries HTTP and
# cannot carry the raw TCP peer socket at all. They answer strangers by design and
# hold no session, so Access would be the wrong control; what they have instead is
# a rate limit at the gateway, keyed on `Cf-Connecting-Ip` because the node's own
# per-address limiter cannot see past the tunnel. `gateway/dynamic/estate-web.yml`
# argues both at length.
#
# UNTIL 2026-08-04 `rpc.<apex>` WAS NOT ON THIS TUNNEL'S GATEWAY AT ALL: its rule
# pointed straight at the node's port, the only one of these that skipped Traefik,
# and therefore the only one with no throttle, no request id, no `/internal`
# refusal and no access-log line. It is an ordinary derived rule now.
#
# `pay` and `vault` are on it and that deserves a sentence, because `vault` is
# the custodial key service and the name is alarming. They cannot be anywhere
# else: withdrawal and key-export are authorised against the USER'S OWN token —
# custody's export ceremony reads `amr` and `auth_time` off it
# (custody/src/exports.ts, gates 4 and 6) — so the caller is a first-party
# browser on `hub.<apex>` and needs the app CORS allowlist, which `api.<apex>`
# deliberately does not carry. `gateway/dynamic/estate-web.yml:669` argues this
# at length. Their protection is the token, the CORS allowlist, and the
# `/internal` refusal above — not obscurity."""

OPERATOR_NOTE = """\
# THE OPERATOR TUNNEL — A SEPARATE TUNNEL, AND THE REASON IS THE SEPARATION.
#
# Four consoles: admin, beacon, lantern, foresight-admin. Every one is
# `adminOnly` in the registry, which is where this list comes from.
#
# WHY A SECOND TUNNEL RATHER THAN FOUR MORE RULES IN THE PUBLIC FILE. A tunnel is
# a credential. `credentials-file` is a token that authorises a process to
# receive traffic for every hostname its config names, and a single tunnel means
# a single credential whose compromise reaches the operator consoles as well as
# the shop front. Two tunnels means the public one can be rotated, revoked, or
# handed to a less careful deployment without that being true.
#
# EVERY HOSTNAME HERE REQUIRES A CLOUDFLARE ACCESS POLICY, and unlike the utility
# hosts — which are not exposed at all, because four of the five have no
# authentication whatsoever — Access is the SECOND gate here rather than the
# only one. All four consoles authenticate against Nimbus and check roles; the
# bundles are `adminOnly` and render a sign-in panel to a stranger. So an Access
# policy left in bypass is a serious misconfiguration and not an immediate
# compromise, which is the property that makes exposing these defensible and
# exposing Prometheus not.
#
# WHY EXPOSE THEM AT ALL. An operator console you cannot reach during an incident
# is a runbook you cannot execute. `beacon` is the estate's own incident record
# and the fallback receiver for every alert when `CF_PAGE_WEBHOOK_URL` is unset
# (.env.example), so it is the one surface most needed at the moment the host is
# least healthy.
#
# ── NOT SET UP AUTOMATICALLY, AND THIS FILE CANNOT DO IT ──────────────────────
# Access policies are Cloudflare-side configuration; nothing in this repository
# creates one. Routing a hostname here without creating its policy publishes an
# operator console to the internet with only its own login in front. The go-live
# checklist gates on this being verified by hand, per hostname."""


def validate_yaml(paths, strict):
    """Parse what was generated and assert cloudflared's own structural rules.

    THE GENERATOR IS NOT ITS OWN PROOF. It emits YAML by string concatenation, so
    "gen.py ran" says nothing about whether the result parses — and the one
    property cloudflared enforces at startup, that the LAST rule is a catch-all
    with no `hostname`, is exactly the kind of thing a template edit breaks
    silently. A tunnel that refuses to start takes both environments down.

    `--strict` makes a missing PyYAML a FAILURE rather than a skip, and CI passes
    it. Locally it is a skip, because the machine this was written on has neither
    PyYAML nor a `cloudflared` binary and a check that cannot run there would
    just train someone to ignore the warning. CI has both available and is the
    place the guarantee actually has to hold.
    """
    try:
        import yaml
    except ImportError:
        if strict:
            print("FAIL: --strict was passed and PyYAML is not installed, so the generated "
                  "ingress was never parsed. A config that does not parse stops the tunnel.")
            return ["PyYAML missing under --strict"]
        print("  note pyyaml not installed — generated YAML was NOT parsed "
              "(pass --strict in CI, where it is)")
        return []
    problems = []
    for path in paths:
        try:
            doc = yaml.safe_load(path.read_text())
        except yaml.YAMLError as exc:
            problems.append(f"{path.name} is not valid YAML: {exc}")
            continue
        rules = doc.get("ingress")
        if not rules:
            problems.append(f"{path.name} has no ingress rules")
            continue
        if "hostname" in rules[-1]:
            problems.append(
                f"{path.name}'s last ingress rule has a `hostname`. cloudflared REFUSES TO "
                f"START without a catch-all as the final rule, so this file would take the "
                f"whole tunnel down rather than mis-route one host"
            )
        hosts = [r["hostname"] for r in rules if "hostname" in r]
        dupes = {h for h in hosts if hosts.count(h) > 1}
        if dupes:
            problems.append(f"{path.name} lists {sorted(dupes)} more than once — the first "
                            f"match wins and the second rule is dead")
    return problems


def main():
    check = "--check" in sys.argv
    strict = "--strict" in sys.argv
    surfaces = registry_surfaces()
    public, operator, api = classify(surfaces)
    uports = utility_ports()

    fails = []
    declared = {s["subdomain"] for s in surfaces if not s["basePath"]}

    # A NOT_ROUTED entry naming a subdomain the registry never declares, and that
    # is not a utility, is a stale claim about a surface that no longer exists.
    for sub in NOT_ROUTED:
        if sub not in declared and sub not in UTILITY_SERVICES:
            fails.append(
                f"NOT_ROUTED names '{sub}', which is neither a registry subdomain nor a "
                f"telemetry service — the exemption covers nothing and has stopped being true"
            )

    # The utility block is a security argument about five named services. If the
    # telemetry plane grows a sixth, the argument has not been made about it.
    for sub in UTILITY_SERVICES:
        if sub not in NOT_ROUTED:
            fails.append(f"utility '{sub}' has no NOT_ROUTED entry stating why it is unexposed")

    written = []
    all_hostnames = []
    for env in ENVIRONMENTS:
        cfg = ENVIRONMENTS[env]
        apex, offset = cfg["apex"], cfg["offset"]
        origin = f"https://127.0.0.1:{GATEWAY_PORT + offset}"

        pub_subs = [s["subdomain"] for s in public + api if s["subdomain"] not in NOT_ROUTED]
        op_subs = [s["subdomain"] for s in operator if s["subdomain"] not in NOT_ROUTED]

        files = [
            (f"config.{env}.public.yml", f"cf-{env}-public",
             ingress_rules(pub_subs, apex, origin), PUBLIC_NOTE),
            (f"config.{env}.operator.yml", f"cf-{env}-operator",
             ingress_rules(op_subs, apex, origin), OPERATOR_NOTE),
        ]
        for name, tunnel, rules, note in files:
            # No hostname may appear in two tunnels: two ingresses claiming one
            # hostname is a race decided by whichever connector Cloudflare picked.
            body = render(env, tunnel, rules, note=note)
            path = HERE / name
            if check:
                if not path.exists():
                    fails.append(f"{name} does not exist — run cloudflared/gen.py")
                elif path.read_text() != body:
                    fails.append(
                        f"{name} on disk is not what gen.py generates. Either the registry "
                        f"gained or lost a surface and this was not regenerated, or the file "
                        f"was hand-edited. Run `cloudflared/gen.py` and commit the result."
                    )
            else:
                path.write_text(body)
            written.append((name, len(rules)))
            all_hostnames.extend((h, tunnel) for h, _ in rules)

        # A utility hostname must not appear in either file, in either direction.
        for name, _, rules, _ in files:
            for hostname, _svc in rules:
                sub = hostname[: -(len(apex) + 1)] if hostname != apex else ""
                if sub in UTILITY_SERVICES or sub in NOT_ROUTED:
                    fails.append(
                        f"{name} routes '{hostname}', which NOT_ROUTED says is deliberately "
                        f"unexposed. One of the two is wrong and neither is safe to guess"
                    )

    # A hostname must not appear in TWO tunnels. Cloudflare resolves a hostname to
    # one tunnel, so the second claim does not load-balance — it silently loses, or
    # wins, depending on which connector registered last. For these files that
    # would mean an operator console sometimes answered by the PUBLIC tunnel,
    # which has no Access policy in front of it. Checked across every generated
    # file rather than within each one.
    owner = {}
    for hostname, tunnel in all_hostnames:
        if hostname in owner and owner[hostname] != tunnel:
            fails.append(
                f"'{hostname}' is claimed by both the '{owner[hostname]}' and '{tunnel}' "
                f"tunnels. Cloudflare binds a hostname to ONE tunnel, so which one answers is "
                f"decided by registration order — and for an operator console that is the "
                f"difference between Access being in front of it and not"
            )
        owner[hostname] = tunnel

    fails.extend(gateway_port_agrees())
    fails.extend(validate_yaml([HERE / n for n, _ in written], strict))

    if fails:
        print()
        for f in fails:
            print(f"  FAIL {f}")
        print(f"\n{len(fails)} problem(s) with the tunnel ingress.")
        return 1

    total = sum(n for _, n in written)
    verb = "checked" if check else "wrote"
    for name, n in written:
        print(f"  ok   {name:<30} {n} hostname(s)")
    print(f"\nok — {verb} {len(written)} config(s), {total} routed hostname(s), "
          f"{len(NOT_ROUTED)} deliberately unrouted, no drift.")
    print(f"     utility ports read from {TELEMETRY.name}: " +
          ", ".join(f"{k}={v}" for k, v in sorted(uports.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
