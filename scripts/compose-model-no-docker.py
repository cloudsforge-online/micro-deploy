#!/usr/bin/env python3
"""Emit the compose model as JSON, on a machine that deliberately has no Docker.

    ./scripts/compose-model-no-docker.py --env-file compose/mainnet.env \
      | ./scripts/render-prometheus-targets.py <manifest> --compose-json - ...

`render-prometheus-targets.py` takes `--compose-json` precisely so the document
can come from somewhere other than a `docker compose config` subprocess — the
compose deploy feeds it the model release-deploy.sh already rendered, so that
"the allowlist and the pull set" cannot be computed from two different
resolutions of the same files. This script is the third such source, for the
Kubernetes side.

── WHY THIS EXISTS AT ALL ───────────────────────────────────────────────────

The k3s VM has no Docker and is never going to. That is the entire point of the
migration: WSL and Docker Desktop cost 11GB on the Windows host for a Linux VM
that Kubernetes needs anyway. Installing the Docker CLI back onto the VM purely
so one script can run `docker compose config` would reintroduce the dependency
at the exact moment we are removing it — and `compose config` is pure
client-side rendering, so it would be a package installed for a string
substitution.

── WHAT THIS IS, AND WHAT IT IS NOT ─────────────────────────────────────────

It is NOT a general `docker compose config` replacement, and it must not grow
into one. Compose's merge semantics across multiple `-f` files are per-key and
not uniform (some keys replace, some append), its profile handling drops
services, and reimplementing either from memory is how a rendering acquires a
second opinion. So:

  * ONE compose file. Passing an overlay is refused rather than half-merged.
    The one overlay in this repo, `docker-compose.release.yml`, pins `image:`
    by digest — and no field read below is `image:`.

  * Profiles ARE filtered, because absence from this document is load-bearing
    information rather than an omission. `render-prometheus-targets.py` looks
    each manifest service up here and treats a miss as "not defined in this
    environment" — its own comment names the example:

        # Profile-gated somewhere else, or defined on the other network.
        # `faucet` is testnet-only in its own type system; it is not
        # missing, it is not here.

    An earlier version of this script skipped the filtering on the theory that
    extra services could never be reached, since the manifest drives the loop.
    That was wrong in the one direction that mattered: `faucet` carries
    `profiles: ["ember-testnet"]`, mainnet sets `COMPOSE_PROFILES=pool`, and
    leaving it in produced a mainnet scrape target for a service mainnet
    deliberately does not run — measured, a permanently DOWN target that looks
    exactly like an outage. Filtering is therefore part of the contract, not a
    nicety.

  * Interpolation is applied where it resolves, and left as literal text where
    it does not. Compose would substitute an empty string for an unset
    `${VAR}` with no default; leaving `${VAR}` visible is a deliberate
    departure, because an unresolved reference that still looks like one can be
    caught, and an empty string cannot.

── THE GUARD IS THE POINT ───────────────────────────────────────────────────

That last departure is only safe because every field the consumer actually
reads is checked for a surviving `${` and refused. Measured on this compose
file: of the five, four carry no interpolation at all, and the fifth is

    name: ${CF_PROJECT:-cloudsforge-estate}

which is exactly the field whose silent failure would be worst. `name` is what
strips the project prefix off the hosts already named in `prometheus.yml`, so
an unresolved one turns `cloudsforge-estate-beacon-1` into a stem that matches
no manifest service — and `beacon` falls through into the generated file_sd
list to be scraped a SECOND time, anonymously, 401ing forever beside the
credentialed job that works. Silent, permanent, and invisible in a diff. Hence
a refusal rather than a best effort.

`CF_PROJECT` is unset in `compose/mainnet.env` (so the default stands) and set
to `cf-testnet` in `compose/testnet.env` — which is where the estate's two
Kubernetes namespaces got their names, and why the container-to-FQDN rewrite is
mechanical instead of a lookup table.
"""

import argparse
import importlib.util
import json
import pathlib
import re
import sys

try:
    import yaml  # noqa: F401 — imported for the error message, used via k8s-render
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so the compose file cannot be read.\n"
        "       python3 -m pip install pyyaml"
    )

ROOT = pathlib.Path(__file__).resolve().parent.parent


def fail(message):
    sys.exit(f"FAIL: {message}")


# ── ONE LOADER, NOT TWO ──────────────────────────────────────────────────────
#
# `k8s-render.py` already teaches a SafeLoader the `!reset` and `!override`
# tags, and already parses the env files. Redefining either here would be a
# second copy of a parser, which is the same failure mode as a second copy of a
# config: it does not disagree today, it disagrees on the day it matters.
#
# Imported by path because the filename has a hyphen and is therefore not a
# legal module name. Everything in it is behind `def` or `if __name__`, so this
# executes no work.
def _load_k8s_render():
    path = ROOT / "scripts" / "k8s-render.py"
    if not path.exists():
        fail(f"{path} is missing, and this script borrows its compose loader rather than copying it")
    spec = importlib.util.spec_from_file_location("cf_k8s_render", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_render = _load_k8s_render()
ComposeLoader = _render.ComposeLoader
parse_env_file = _render.parse_env_file

# Compose's own interpolation grammar, same expression k8s-render.py resolves
# with: `${NAME}`, and the `:-` `-` `:+` `+` `:?` `?` operators.
INTERP = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-+?])?([^}]*)\}")

parser = argparse.ArgumentParser(
    description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
)
parser.add_argument("--compose", default=str(ROOT / "compose" / "docker-compose.estate.yml"))
parser.add_argument(
    "--env-file",
    action="append",
    default=[],
    dest="env_file",
    metavar="PATH",
    help="repeatable; later files win, exactly as compose resolves them",
)
parser.add_argument(
    "--profile",
    action="append",
    default=[],
    dest="profile",
    metavar="NAME",
    help="activate a profile; adds to COMPOSE_PROFILES from the env files",
)
parser.add_argument("--out", help="write here instead of stdout")
args = parser.parse_args()

compose_path = pathlib.Path(args.compose)
if not compose_path.exists():
    fail(f"no compose file at {compose_path}")

config = {}
for name in args.env_file:
    env_path = pathlib.Path(name)
    if not env_path.exists():
        fail(f"--env-file {env_path} does not exist, so the values it holds would silently default")
    config.update(parse_env_file(env_path))


def substitute(match):
    """Compose's rules, with one deliberate departure: unresolvable stays literal."""
    name, op, arg = match.group(1), match.group(2) or "", match.group(3)
    present = name in config and config[name] != ""
    if "+" in op:
        return arg if present else ""
    if present:
        return config[name]
    if op in ("-", ":-"):
        return arg
    # `${VAR}` unset, or `${VAR:?msg}` unset. Compose would give "" or abort.
    # Neither is this script's call to make: it is not rendering a deploy, it
    # is describing one. Left visible for the guard below to judge.
    return match.group(0)


def resolve(value):
    if isinstance(value, str):
        return INTERP.sub(substitute, value)
    if isinstance(value, list):
        return [resolve(item) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    return value


# `yaml.load` with an explicit Loader, and this is NOT the unsafe call it
# resembles: `ComposeLoader` subclasses `yaml.SafeLoader`, so the
# `!!python/object` family is still unregistered and still refused. See its
# definition in `k8s-render.py` — it adds exactly two constructors, `!reset`
# (yields None) and `!override` (yields a plain scalar), neither of which can
# construct a Python type. `yaml.safe_load` would not be safer here, it would
# simply fail on `!reset`.
document = yaml.load(compose_path.read_text(), Loader=ComposeLoader)
if not isinstance(document, dict):
    fail(f"{compose_path} did not parse as a mapping")

model = resolve(document)
services = model.get("services") or {}
if not services:
    fail(f"{compose_path} defines no services")

# ── PROFILES ─────────────────────────────────────────────────────────────────
#
# Compose's rule exactly: a service with no `profiles:` key is always active; a
# service that declares them is active only if one of them is switched on. The
# active set is `COMPOSE_PROFILES` from the env files plus any `--profile`,
# which is the same union the CLI forms.
#
# Two profiles exist in this estate — `pool` (mainnet) and `ember-testnet`
# (testnet) — and each network's env file names exactly one.
active_profiles = set(args.profile)
for chunk in str(config.get("COMPOSE_PROFILES", "")).split(","):
    chunk = chunk.strip()
    if chunk:
        active_profiles.add(chunk)

dropped = []
for name in sorted(services):
    declared = (services[name] or {}).get("profiles") or []
    if isinstance(declared, str):
        declared = [declared]
    if declared and not (set(declared) & active_profiles):
        dropped.append(f"{name} (profiles: {', '.join(sorted(declared))})")
        del services[name]

if dropped:
    print(
        f"profiles active: {', '.join(sorted(active_profiles)) or '<none>'} — "
        f"dropped {len(dropped)}: {'; '.join(dropped)}",
        file=sys.stderr,
    )

# ── EVERY FIELD THE CONSUMER READS, CHECKED FOR A SURVIVING ${ ───────────────
#
# This list is not decorative: it is the contract between this script and
# `render-prometheus-targets.py`, and it was derived by reading that file for
# every access into the compose model. If a consumer starts reading a sixth
# field, it belongs here, or this script quietly stops guaranteeing anything.
unresolved = []

project = str(model.get("name") or "").strip()
if not project:
    fail(f"{compose_path} carries no top-level `name:`, so the compose project cannot be named")
if "${" in project:
    unresolved.append(f"name: {project}")

for name, spec in sorted(services.items()):
    spec = spec or {}
    checks = {
        "container_name": spec.get("container_name"),
        "deploy.replicas": (spec.get("deploy") or {}).get("replicas"),
        "healthcheck.test": (spec.get("healthcheck") or {}).get("test"),
    }
    env = spec.get("environment") or {}
    if isinstance(env, list):
        env = dict(item.split("=", 1) for item in env if "=" in item)
    checks["environment.PORT"] = env.get("PORT")

    for field, value in checks.items():
        if value is None:
            continue
        text = " ".join(str(v) for v in value) if isinstance(value, list) else str(value)
        if "${" in text:
            unresolved.append(f"services.{name}.{field}")

if unresolved:
    fail(
        "these fields still hold an unresolved `${...}` after interpolation, and every one\n"
        "       of them is read to decide what gets scraped and on which port:\n"
        + "".join(f"         {entry}\n" for entry in unresolved)
        + "       Pass the env file that defines them with --env-file. Emitting the document\n"
        "       anyway would produce a scrape list that is wrong in a way nothing reports:\n"
        "       an unresolved project name makes `beacon` fall through into the generated\n"
        "       targets and 401 forever beside the credentialed job that already works."
    )

output = json.dumps(model, indent=2, sort_keys=True, default=str) + "\n"
if args.out:
    pathlib.Path(args.out).write_text(output)
    print(f"wrote {args.out}: project {project}, {len(services)} services", file=sys.stderr)
else:
    sys.stdout.write(output)
