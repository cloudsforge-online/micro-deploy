#!/usr/bin/env python3
"""The gateway does not log client IP addresses, and this is what makes that a RULE.

THE GAP THIS CLOSES
-------------------
cloudsforge-online/micro-org#163 records that Traefik logs no client IP here —
and then says the important part: it is true "by accident of topology, not by an
explicit rule, and nothing tests it".

Both halves of the accident are real, and both are one edit away from ending:

  1. HEADERS ARE DROPPED BY DEFAULT, NOT BY DECISION.
     `compose/docker-compose.gateway.yml` names four headers explicitly —
     X-Request-Id and Traceparent kept, Authorization and Cookie dropped — and
     says nothing about the rest. Traefik's default for
     `accesslog.fields.headers.defaultMode` is `drop`, so `X-Forwarded-For` and
     `Cf-Connecting-Ip` are absent from every log line because of a default
     nobody wrote down. One `--accesslog.fields.headers.defaultMode=keep`, or one
     `...names.Cf-Connecting-Ip=keep` added while debugging a rate limit, puts
     the true client address of every request in this estate into a JSON log that
     ships to Loki. Nothing would fail. Nothing would say anything.

  2. `ClientHost` IS LOOPBACK BECAUSE OF WHERE cloudflared SITS.
     `accesslog.fields.defaultMode` defaults to `keep`, and `ClientHost` is a
     CORE field — it is in every line right now. It is harmless only because the
     immediate peer is cloudflared, reached over loopback or the docker bridge,
     since every published gateway port is bound to 127.0.0.1. Publish one port
     on 0.0.0.0, or trust a forwarded header at an entrypoint
     (`forwardedHeaders.trustedIPs`, `forwardedHeaders.insecure`,
     `proxyProtocol`), and that same field silently becomes the real client's
     address — with no flag named "log client IPs" anywhere in the diff.

So this asserts the two properties the current good state rests on, rather than
asserting the good state itself. It passes today and it is meant to: the point is
that it stops passing the moment either accident is undone.

WHAT IT CHECKS
--------------
  --config  (default) Read `compose/*.yml` as text and assert:

              * no IP-bearing header is kept or redacted in the access log
              * `accesslog.fields.headers.defaultMode` is unset (Traefik's
                `drop`) or explicitly `drop`
              * no entrypoint trusts a forwarded header or PROXY protocol, so
                `ClientHost` stays the peer's address and not a claimed one
              * every gateway port is published on loopback, so the peer is
                always cloudflared and never a stranger
              * Authorization and Cookie stay dropped — same log line, same
                class of finding, and the file already promises it

            Every compose file is scanned, not just the gateway's: an overlay
            that turns header logging on is the same defect in a different file,
            and `release-render.py` generates overlays that CI never reads.

  --live    Read the access log of a RUNNING gateway and assert that no
            `ClientHost` in it is a public address. This is the half a config
            check cannot do, and #163's complaint that "nothing tests it" is
            about exactly this: it observes the bytes rather than the intent, so
            a topology change nobody described in a file is still caught.

IT NEVER PRINTS AN ADDRESS. Findings name the FIELD, the FILE and the LINE, and
counts. A report that quoted the client IP it was warning about would have
written the personal data it exists to keep out of a log into a second file that
is by construction kept and read — which is `check-secret-hygiene.py`'s rule
about secrets, for the same reason.

Deliberately dependency-free — re, json, subprocess, ipaddress, all stdlib. Same
rule as check-runbooks.py: a check that only runs where a library happens to be
installed is a check that stops running.

Exit 0 if the estate cannot log a client IP. Exit 1 otherwise, and NEVER skips: a
check that cannot run reports failure rather than success it did not establish.
"""
import argparse
import ipaddress
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "compose"

# ── THE HEADERS THAT CARRY A CLIENT ADDRESS ───────────────────────────────────
#
# Lower-cased, because Traefik's flag names are case-insensitive on the header
# and somebody will write `X-Forwarded-for`. This list is deliberately wider than
# what this estate uses: `Cf-Connecting-Ip` is the one in play today, and the
# check is worth nothing if it only refuses the header that is already refused.
# The failure being guarded is somebody ADDING one while debugging.
IP_HEADERS = {
    "x-forwarded-for": "the standard forwarded-client chain; its first entry is the client",
    "x-original-forwarded-for": "the same chain under the name an ingress rewrites it to",
    "x-real-ip": "nginx's single-value spelling of the same thing",
    "x-client-ip": "a common single-value spelling",
    "x-cluster-client-ip": "the same, from a load balancer",
    "forwarded": "RFC 7239, whose `for=` parameter is the client address",
    "cf-connecting-ip": "Cloudflare's, and the ONE that is true here — the tunnel sets it",
    "cf-pseudo-ipv4": "Cloudflare's derived IPv4 for an IPv6 client; still identifies them",
    "true-client-ip": "Cloudflare Enterprise / Akamai",
    "fastly-client-ip": "Fastly's",
    "x-appengine-user-ip": "App Engine's",
}

# Credentials, not addresses — but the same log line, and the file already
# promises both are dropped. A promise nothing checks is the pattern this whole
# script is about, so they are checked here rather than nowhere.
MUST_DROP = {
    "authorization": "the gateway sees every bearer token in the estate",
    "cookie": "a session cookie is a credential that needs no decoding",
}

# A mode that puts the header's value in the line. `redact` is included and that
# is not pedantry: Traefik's `redact` replaces the value with `REDACTED`, which
# is safe — but it is safe only for the VALUE, and it still records that the
# header was present. It is accepted for a credential and refused for an address
# because the presence of `Cf-Connecting-Ip` tells nobody anything, so a `redact`
# on it is a change somebody made intending to log it and then softened.
LOGGING_MODES = {"keep", "redact"}

ARG = re.compile(r"^\s*-\s*(?:'|\")?--(?P<flag>[A-Za-z0-9_.\-]+)=(?P<value>[^'\"\s]*)")


def compose_files():
    files = sorted(COMPOSE.glob("*.yml")) + sorted(COMPOSE.glob("*.yaml"))
    if not files:
        sys.exit(f"FAIL: no compose files under {COMPOSE}. There is nothing to check, "
                 f"which is not the same as nothing being wrong.")
    return files


def flags_in(path):
    """Every `- --flag=value` line in a file, as (lineno, flag, value)."""
    out = []
    for lineno, line in enumerate(path.read_text().split("\n"), 1):
        m = ARG.match(line)
        if m:
            out.append((lineno, m.group("flag").lower(), m.group("value").strip().lower()))
    return out


def check_headers(path, flags, bad):
    """No header that carries a client address may be kept, and none may be defaulted in."""
    for lineno, flag, value in flags:
        if flag == "accesslog.fields.headers.defaultmode":
            if value != "drop":
                bad.append(
                    f"{path.name}:{lineno}: accesslog.fields.headers.defaultMode is `{value}`. "
                    f"That logs EVERY request header, including Cf-Connecting-Ip, which behind "
                    f"this tunnel is the true client address. Traefik's own default is `drop`; "
                    f"the only accepted values here are `drop` or the flag being absent."
                )
            continue
        m = re.fullmatch(r"accesslog\.fields\.headers\.names\.(.+)", flag)
        if not m:
            continue
        header = m.group(1)
        if header in IP_HEADERS and value in LOGGING_MODES:
            bad.append(
                f"{path.name}:{lineno}: `{header}` is set to `{value}` in the access log — "
                f"{IP_HEADERS[header]}. An IP address is personal data (micro-org#163); it must "
                f"be `drop`, or the flag removed so Traefik's default drop applies."
            )
        if header in MUST_DROP and value != "drop":
            bad.append(
                f"{path.name}:{lineno}: `{header}` is set to `{value}` rather than `drop` — "
                f"{MUST_DROP[header]}."
            )


def check_client_host(path, flags, bad):
    """Nothing may turn `ClientHost` from the peer's address into the client's."""
    for lineno, flag, value in flags:
        if ".forwardedheaders.trustedips" in flag or ".forwardedheaders.insecure" in flag:
            bad.append(
                f"{path.name}:{lineno}: `--{flag}` makes Traefik trust a forwarded header, so "
                f"`ClientHost` — a CORE access-log field, kept by default and present in every "
                f"line today — becomes the CLIENT's address instead of cloudflared's. That turns "
                f"client-IP logging on with no flag in the diff that says so."
            )
        if ".proxyprotocol." in flag:
            bad.append(
                f"{path.name}:{lineno}: `--{flag}` accepts the PROXY protocol, which replaces the "
                f"peer address with the one the proxy claims. Same consequence as trusting a "
                f"forwarded header: `ClientHost` starts naming real clients."
            )
        # `ClientHost` explicitly re-kept is not itself a fault — it is the
        # default — but `ClientHost=drop` would be a stronger state than this
        # estate is in, and turning it back on is worth a line in the report.
        if flag == "accesslog.fields.names.clienthost" and value in LOGGING_MODES:
            bad.append(
                f"{path.name}:{lineno}: `ClientHost` is explicitly set to `{value}`. It is kept "
                f"by default anyway, so this changes nothing today — but an explicit keep is what "
                f"somebody writes when they have decided they WANT the address, and the topology "
                f"that makes it harmless is not stated anywhere it would be read."
            )


SERVICE = re.compile(r"^  (?P<name>[A-Za-z0-9._-]+):\s*(?:#.*)?$")
KEY = re.compile(r"^    (?P<key>[A-Za-z0-9._-]+):")
ENTRY = re.compile(r"^      -\s*(?P<value>.+?)\s*$")
LOOPBACK = ("127.0.0.1", "localhost", "::1", "[::1]")


def split_port(entry):
    """
    Split a compose short-form port into (bind, rest), tolerating `${VAR:-default}`.

    Parsed by masking each `${...}` to a single token FIRST. Splitting on ':'
    without that gets `${CF_GATEWAY_PORT:-443}` wrong — the colon inside the
    default makes a two-part mapping look like a three-part one, so a port
    published on 0.0.0.0 reads as a bind address of `0.0.0.0` on host port
    `${CF_GATEWAY_PORT`. That is not a hypothetical: it is what the first version
    of this function did, and it silently passed a deliberately broken fixture.
    """
    masked = re.sub(r"\$\{[^}]*\}", "V", entry.strip().strip("\"'"))
    if masked.startswith("["):  # an IPv6 bind address, `[::1]:443:443`
        close = masked.find("]")
        if close > 0:
            return masked[: close + 1], masked[close + 2:]
    parts = masked.split("/")[0].split(":")
    return (parts[0], ":".join(parts[1:])) if len(parts) >= 3 else (None, masked)


def check_ports(path, bad):
    """
    Every gateway port on loopback, so the peer is always cloudflared.

    This is what makes `ClientHost` harmless, and it is the property most likely
    to be undone by accident: `- "443:443"` instead of `- "127.0.0.1:443:443"`
    is a two-token edit that exposes the gateway to the network AND starts
    logging the addresses of whoever finds it.

    Only the `gateway` service is examined. The rest of the estate publishes on
    loopback too and `check-restart-policy.py`'s live mode is where that belongs;
    here the question is narrower and is about one container's log.
    """
    service = None
    key = None
    for lineno, line in enumerate(path.read_text().split("\n"), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = SERVICE.match(line)
        if m:
            service, key = m.group("name"), None
            continue
        m = KEY.match(line)
        if m:
            key = m.group("key")
            continue
        if service != "gateway" or key != "ports":
            continue
        m = ENTRY.match(line)
        if not m:
            continue
        bind, _ = split_port(m.group("value").split("#")[0])
        if bind is None:
            bad.append(
                f"{path.name}:{lineno}: the gateway publishes a port with no bind address, which "
                f"Docker binds to 0.0.0.0. A client that reaches this port directly IS the peer, "
                f"so its address becomes the `ClientHost` in every access-log line it produces."
            )
        elif bind not in LOOPBACK:
            bad.append(
                f"{path.name}:{lineno}: the gateway publishes a port on `{bind}` rather than "
                f"127.0.0.1. Same consequence as above: a direct client's address becomes the "
                f"`ClientHost` in the access log, and no flag in the diff says so."
            )


def check_config():
    bad = []
    scanned = 0
    gateway_seen = False
    for path in compose_files():
        flags = flags_in(path)
        scanned += 1
        # The ENABLE flag specifically, not any `accesslog.*` flag. A file that
        # still carries the field settings but no longer turns access logging on
        # is a file this script would report a clean scan of while proving
        # nothing about where the log now comes from.
        if any(flag == "accesslog" and value not in ("false", "0") for _, flag, value in flags):
            gateway_seen = True
        check_headers(path, flags, bad)
        check_client_host(path, flags, bad)
        check_ports(path, bad)

    if not gateway_seen:
        # The vacuous pass, refused. If the accesslog flags have been moved to a
        # static traefik.yml or an env file, this script is reading the wrong
        # thing and must say so rather than report a clean scan of nothing.
        bad.append(
            "no compose file under compose/ turns access logging on with `--accesslog=true`. "
            "Either it has moved somewhere this script does not read — a static traefik.yml, a "
            "TRAEFIK_ACCESSLOG_* env var, a generated release overlay — or it is off. Both mean "
            "this check proved nothing, so it fails rather than reporting a pass it did not "
            "establish. If access logging is genuinely gone, delete this check with it."
        )

    if bad:
        print("client-IP logging failures:", *bad, sep="\n  ")
        print(f"\n{len(bad)} way(s) the gateway could log a client address. "
              f"An IP address is personal data; see cloudsforge-online/micro-org#163.")
        return 1

    print(f"ok: {scanned} compose file(s) — no IP-bearing header is logged, "
          f"headers default to drop, no entrypoint trusts a forwarded address or PROXY "
          f"protocol, and every gateway port is on loopback so ClientHost is cloudflared's")
    return 0


# ── the live half ─────────────────────────────────────────────────────────────

def is_internal(host):
    """True if this address could not identify a person outside this estate."""
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return True  # not an address at all — a hostname, an empty field, a dash
    return addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_unspecified


def check_live(project, lines):
    """
    Read a running gateway's access log and assert no line names a public client.

    This is the assertion a config check cannot make. It reads what was actually
    written, so a topology change nobody put in a compose file — a port opened by
    hand, a second proxy in front, an entrypoint reconfigured on a live container
    — is caught by its OUTPUT rather than by its description.
    """
    ids = subprocess.run(
        ["docker", "ps", "-q", "--filter", f"label=com.docker.compose.project={project}",
         "--filter", "label=com.docker.compose.service=gateway"],
        capture_output=True, text=True,
    ).stdout.split()
    if not ids:
        sys.exit(f"FAIL: no running `gateway` container in compose project `{project}`. "
                 f"A live check with nothing to check is the vacuous case this file is about.")

    proc = subprocess.run(["docker", "logs", "--tail", str(lines), ids[0]],
                          capture_output=True, text=True)
    body = proc.stdout + proc.stderr

    parsed = 0
    public = 0
    header_fields = set()
    for line in body.split("\n"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if "ClientHost" not in record:
            continue
        parsed += 1
        if not is_internal(str(record["ClientHost"])):
            public += 1
        # Any IP-bearing header that made it into the record at all. Traefik
        # prefixes kept request headers with `request_`.
        for key in record:
            if key.lower().removeprefix("request_").removeprefix("downstream_") in IP_HEADERS:
                header_fields.add(key)

    if parsed == 0:
        sys.exit(f"FAIL: read {lines} log line(s) from the gateway in `{project}` and found no "
                 f"JSON access-log record with a ClientHost. Either --accesslog.format is no "
                 f"longer json, or the log is going to a file rather than stdout, or nothing has "
                 f"been requested. This check establishes nothing in that state, so it fails.")

    findings = []
    if public:
        findings.append(
            f"{public} of {parsed} access-log line(s) carry a PUBLIC address in `ClientHost`. "
            f"The peer is supposed to be cloudflared over loopback. Something is reaching this "
            f"gateway directly, or an entrypoint has begun trusting a forwarded address."
        )
    if header_fields:
        findings.append(
            f"the access log contains {len(header_fields)} field(s) named for a header that "
            f"carries a client address: {', '.join(sorted(header_fields))}. The values are not "
            f"shown here and must not be."
        )
    if findings:
        print(f"client-IP logging failures in the running project `{project}`:", *findings, sep="\n  ")
        print("\nNo address is printed above, deliberately — resolve this against the running "
              "container, and treat the existing log as containing personal data until it rotates.")
        return 1

    print(f"ok: {parsed} access-log line(s) from `{project}` — every ClientHost is loopback, "
          f"private or link-local, and no IP-bearing header appears as a field")
    return 0


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--live", metavar="PROJECT",
                    help="read a RUNNING gateway's access log instead of the compose files")
parser.add_argument("--lines", type=int, default=2000,
                    help="how many log lines --live reads (default 2000)")
args = parser.parse_args()

sys.exit(check_live(args.live, args.lines) if args.live else check_config())
