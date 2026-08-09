#!/usr/bin/env python3
"""The pool's WebSocket configuration is coherent, or this estate does not ship.

WHAT THIS GUARDS
----------------
micro-org#289 gave micro-pool a second Stratum transport: a WebSocket on
`/v1/pool/stratum/<chain>`, attached to the HTTP server it already runs, gated by
a single-use ticket that `POST /v1/pool/ticket` mints against an estate access
token. Three environment variables came with it and no others —
`IDENTITY_JWKS_URL`, `IDENTITY_ISSUER`, `POOL_WEBSOCKET_PUBLIC_ORIGIN` — and the
service refuses to boot on two combinations of them:

  * `IDENTITY_JWKS_URL` and `IDENTITY_ISSUER` are BOTH-OR-NEITHER. Half of a
    trust anchor cannot verify anything, and a service that started on half of
    one would answer 401 to tokens that are perfectly valid.
  * `POOL_WEBSOCKET_PUBLIC_ORIGIN` SET WHILE IDENTITY IS UNSET is a refusal, not
    a warning. `GET /v1/pool` would otherwise publish a `websocketEndpoint` that
    every browser can dial and none can authenticate to — micro-org#285's defect
    with the sign flipped, an address that is real and useless.

Both refusals are correct in the service and both are a CRASH LOOP in a deploy.
That is the asymmetry this file exists for: micro-pool discovers the mistake at
boot, on the host, in a container that then restarts forever under
`restart: unless-stopped` — and it ships behind `profiles: ["pool"]`, so it is
started by hand, days after the commit, by whoever finally wants a miner. The
compose file is where the mistake would be MADE, so the compose file is where it
should be caught. This is the same argument `check-release-render-pins-profiles.py`
makes about the pin nobody sees drop.

RULE 9 IS CHECKED HERE TOO. The deploy supplies exactly the variables the service
reads. The contract names three and explicitly refuses a WS port variable, a
ticket TTL, a keepalive interval and a CORS origin list, because every one of
those is an in-service constant — the keepalive numbers are matched to
Cloudflare's edge window, and an origin list here would be a second, drifting
copy of `cf-cors` in `gateway/dynamic/policy.yml`. A variable compose supplies
and the service never reads is a promise nothing keeps, and it reads as
configuration to the next person who tries to change it.

WHAT IT CHECKS
--------------
Every compose file under `compose/`, service by service, after YAML merge keys
are resolved — the estate file supplies the identity pair through the
`*identity-trust` anchor rather than as literals, so a check that read the two
key names off the raw text would see nothing at all and pass:

  1. Any service supplying `POOL_WEBSOCKET_PUBLIC_ORIGIN` supplies both identity
     variables. This is the crash loop.
  2. Any service supplying ANY `POOL_*` variable — that is, any service running
     micro-pool's eager `env.ts`, service and migrator alike — has both identity
     variables or neither.
  3. No service supplies a WebSocket variable the contract does not name.
  4. The advertised origin is one micro-pool will accept at boot: scheme `ws:` or
     `wss:`, no path, query, fragment or userinfo.
  5. THE ANCHOR, so that this cannot pass by finding nothing: a service named
     `pool` exists and supplies the origin. If browser mining is ever
     deliberately withdrawn from this estate, this check fails and must be
     deleted along with it — which is a decision someone makes, rather than a
     guard that quietly stops guarding.

An interpolation with an EMPTY DEFAULT counts as unset — `${FOO:-}` is how this
repository writes "no value unless an operator supplies one", and
`POOL_STRATUM_PUBLIC_HOST` beside the origin is written exactly that way. Any
other interpolation counts as supplied; what it renders to is the render checks'
question, not this one's.

WHY PyYAML RATHER THAN STDLIB. `check-client-ip-logging.py` argues for
dependency-free checks and is right for its own question, which it can answer
with a line regex. This one cannot: the property is which environment keys a
service ends up with, and in `docker-compose.estate.yml` that is decided by
`<<: [*common-env, *identity-trust]` against anchors defined four thousand lines
away. A hand-rolled merge resolver would be a second YAML implementation whose
bugs all look like passes. A missing PyYAML is therefore a FAILURE and never a
skip, the same call `cloudflared/gen.py --strict` makes, and CI installs it in
the step that runs this.

Exit 0 only if every rule above holds. Prints no value that could be a secret —
these five variables are hostnames and URLs, and are printed.
"""
import pathlib
import re
import sys
from urllib.parse import urlsplit

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so the merge keys that carry the identity "
        "pair onto micro-pool cannot be resolved.\n"
        "       This is a failure and not a skip: every rule below would go "
        "unchecked, and a check that reports a pass it did not establish is worse "
        "than no check.\n"
        "       python3 -m pip install pyyaml"
    )

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "compose"

ORIGIN = "POOL_WEBSOCKET_PUBLIC_ORIGIN"
IDENTITY = ("IDENTITY_JWKS_URL", "IDENTITY_ISSUER")

# The three the contract names, and nothing else may be added beside them. The
# pattern is deliberately wider than the names that exist: what is being guarded
# is somebody ADDING `POOL_WEBSOCKET_PORT` or `POOL_TICKET_TTL_SECONDS` here
# because it looks like the sort of thing a deploy decides. It is not — see the
# rule 9 note above.
WS_SHAPED = re.compile(r"^POOL_(WEBSOCKET|WS|TICKET|STRATUM_WS)_[A-Z0-9_]+$")

# How this repository writes "unset unless an operator says otherwise".
# `${FOO:-}` and `${FOO-}` both render to the empty string, which every
# `env.ts` in the estate reads as absent.
EMPTY_INTERPOLATION = re.compile(r"^\$\{[A-Za-z_][A-Za-z0-9_]*:?-\}$")

# `${...}` masked to one opaque token before a URL is parsed. Without this,
# `wss://pool${CF_WEB_SUFFIX:-.cloudsforge.localtest.me}` splits on the `:` inside
# the default and reads as a port — the same trap `check-client-ip-logging.py`
# documents for port mappings, in a different parser.
INTERPOLATION = re.compile(r"\$\{[^}]*\}")


def unknown_tag(loader, suffix, node):
    """Tolerate `!reset` and friends.

    `release-render.py` generates `compose/docker-compose.release.yml` with
    `build: !reset null`, and that file is a compose file this check must read
    like any other — an overlay is exactly where a variable would be added to a
    service without touching the base. Unknown tags resolve to None because
    nothing below reads a tagged value.
    """
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return None


class Loader(yaml.SafeLoader):
    """SafeLoader, extended only to IGNORE unknown tags — never to construct one.

    Subclassed rather than passed to `yaml.load` bare: this stays exactly as safe
    as `yaml.safe_load`, because SafeLoader has no constructor for
    `!!python/object` and this class adds none. The one addition maps every `!`
    tag to plain data.
    """


Loader.add_multi_constructor("!", unknown_tag)


def environments(path):
    """Every service in a compose file as (name, {VAR: value}), merges resolved."""
    try:
        doc = yaml.load(path.read_text(), Loader=Loader)
    except yaml.YAMLError as exc:
        sys.exit(f"FAIL: {path.name} is not parseable, so nothing in it was checked:\n{exc}")
    if not isinstance(doc, dict):
        return
    services = doc.get("services")
    if not isinstance(services, dict):
        return
    for name, spec in services.items():
        if not isinstance(spec, dict):
            continue
        env = spec.get("environment")
        if isinstance(env, dict):
            yield name, {str(k): v for k, v in env.items()}
        elif isinstance(env, list):
            # The `- KEY=value` form. Docker accepts both and nothing stops a
            # future service using it; a check that only understood the mapping
            # form would read such a service as having no environment at all.
            pairs = {}
            for item in env:
                key, _, value = str(item).partition("=")
                pairs[key.strip()] = value
            yield name, pairs
        else:
            yield name, {}


def supplied(env, key):
    """Present with a value the service will actually see."""
    if key not in env:
        return False
    value = env[key]
    if value is None:
        return False
    text = str(value).strip()
    return bool(text) and not EMPTY_INTERPOLATION.match(text)


def check_origin_shape(where, value, bad):
    """Mirror micro-pool's own boot validation, so a refusal is caught here first."""
    masked = INTERPOLATION.sub("V", str(value).strip())
    parsed = urlsplit(masked)
    if parsed.scheme not in ("ws", "wss"):
        bad.append(
            f"{where}: {ORIGIN} is `{value}` — scheme `{parsed.scheme or '(none)'}`. micro-pool "
            f"accepts `ws:` or `wss:` only and refuses to start otherwise; on this estate the only "
            f"way in is the Cloudflare Tunnel, which is TLS, so the answer is `wss:`."
        )
    if parsed.path or parsed.query or parsed.fragment or "@" in parsed.netloc:
        bad.append(
            f"{where}: {ORIGIN} is `{value}`, which is not a bare ORIGIN. The served path is the "
            f"service's to append (`/v1/pool/stratum/<chain>`); a path, query, fragment or "
            f"userinfo here is refused at boot rather than trimmed."
        )


def main():
    files = sorted(COMPOSE.glob("*.yml")) + sorted(COMPOSE.glob("*.yaml"))
    if not files:
        sys.exit(f"FAIL: no compose files under {COMPOSE}. Nothing was checked, which is not the "
                 f"same as nothing being wrong.")

    bad = []
    advertising = []
    pool_services = []
    scanned = 0

    for path in files:
        for name, env in environments(path):
            scanned += 1
            where = f"{path.name}: service `{name}`"
            has_identity = [key for key in IDENTITY if supplied(env, key)]
            pool_vars = sorted(key for key in env if key.startswith("POOL_"))

            # 1 — THE CRASH LOOP.
            if supplied(env, ORIGIN):
                advertising.append((path.name, name, str(env[ORIGIN]).strip()))
                missing = [key for key in IDENTITY if key not in has_identity]
                if missing:
                    bad.append(
                        f"{where} advertises {ORIGIN} but does not supply {' and '.join(missing)}. "
                        f"micro-pool REFUSES TO START in exactly this state, so this compose ships "
                        f"a crash loop: the container restarts forever and the endpoint it would "
                        f"have advertised is one no browser could have authenticated to anyway "
                        f"(micro-org#285, micro-org#289). On this estate the pair arrives through "
                        f"the `*identity-trust` anchor — if it is gone from this service, put the "
                        f"anchor back rather than writing the two URLs out again."
                    )
                check_origin_shape(where, env[ORIGIN], bad)

            # 2 — BOTH-OR-NEITHER, on anything that runs micro-pool's env.ts.
            # Scoped to `POOL_*` deliberately: `identity` itself supplies
            # IDENTITY_ISSUER without a JWKS URL, correctly — it PUBLISHES the
            # keys rather than verifying against them — and a blanket rule would
            # fail the one service that is allowed to be asymmetric.
            if pool_vars:
                pool_services.append((path.name, name))
                if len(has_identity) == 1:
                    bad.append(
                        f"{where} supplies {has_identity[0]} without "
                        f"{[k for k in IDENTITY if k != has_identity[0]][0]}. micro-pool reads the "
                        f"pair as both-or-neither and refuses to start on half of it: half a trust "
                        f"anchor verifies nothing, and a service that started anyway would answer "
                        f"401 to tokens that are valid."
                    )

            # 3 — RULE 9.
            for key in pool_vars:
                if key != ORIGIN and WS_SHAPED.match(key):
                    bad.append(
                        f"{where} supplies `{key}`, which micro-pool does not read. The WebSocket "
                        f"contract names three variables and refuses a port, a ticket TTL, a "
                        f"keepalive interval and an origin allowlist on purpose — the listener "
                        f"attaches to the HTTP server's existing PORT, the keepalive numbers are "
                        f"matched to Cloudflare's edge idle window, and the origin list is "
                        f"`cf-cors` in gateway/dynamic/policy.yml, which must not have a second "
                        f"copy here to drift from. A variable the service never reads is "
                        f"configuration that looks real and does nothing."
                    )

    # 5 — THE ANCHOR. Everything above is satisfied by a file with no pool in it.
    if not any(name == "pool" for _, name in pool_services):
        bad.append(
            "no service named `pool` supplies any POOL_* variable in any compose file. Either "
            "micro-pool has left this estate or this check is reading the wrong files, and in "
            "both cases every rule above passed against nothing. If the pool is genuinely gone, "
            "delete this check with it."
        )
    elif not any(name == "pool" for _, name, _ in advertising):
        bad.append(
            f"the `pool` service does not supply {ORIGIN}, so browser mining is not published on "
            f"this estate and the rules above have nothing to hold. That is a supported mode in "
            f"the SERVICE — the transport is simply not attached — but it is not the mode this "
            f"deploy is in, and a guard that passes because the thing it guards is absent is the "
            f"vacuous check this repository keeps paying for. Publish it, or withdraw browser "
            f"mining and delete this check deliberately."
        )

    if bad:
        print("pool WebSocket configuration failures:", *bad, sep="\n  ")
        print(f"\n{len(bad)} incoherence(s). micro-pool refuses to boot on the first two shapes, "
              f"and it ships behind `profiles: [\"pool\"]` — so the crash loop is found by hand, "
              f"days later, by whoever finally starts it. See cloudsforge-online/micro-org#289.")
        return 1

    listed = ", ".join(f"{service} -> {origin}" for _, service, origin in advertising)
    print(f"ok: {scanned} service(s) across {len(files)} compose file(s) — "
          f"{len(pool_services)} run micro-pool's environment and every one of them carries the "
          f"identity pair whole; {len(advertising)} advertise a WebSocket origin ({listed}); no "
          f"variable outside the three the contract names")
    return 0


sys.exit(main())
