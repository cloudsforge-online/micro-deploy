#!/usr/bin/env python3
"""`SETTLEMENT_RPC_URLS` renders to valid JSON however many chains are configured.

── WHAT IS BEING GUARDED ────────────────────────────────────────────────────

`x-settlement-rpc-urls` in `docker-compose.estate.yml` is a JSON object built by
STRING CONCATENATION out of shell interpolations:

    '{"ember":"${EMBER_RPC_URL:-…}"${LTC_RPC_URL:+,"ltc":"$LTC_RPC_URL"}…}'

Every optional chain is a `${VAR:+,"key":"$VAR"}` fragment that contributes its
comma, its key and its value together or contributes nothing at all. That form is
load-bearing and it is one character from being wrong in three different ways —
a comma outside the `:+`, a `:-` where a `:+` was meant, a missing brace — and
every one of them is invisible in the compose file and fatal on the host.

FATAL, NOT DEGRADED. `settlement/src/env.ts` is eager and parses this at import:

  * not JSON at all      -> `SETTLEMENT_RPC_URLS must be a JSON object`
  * an entry with `""`   -> `SETTLEMENT_RPC_URLS.doge must be a non-empty string`

Both are thrown before the service has a server, on `settlement-migrate` as well
as `settlement`, so an unconfigured chain would take settlement down for the
chains that ARE configured — under `restart: unless-stopped`, forever. The whole
reason micro-settlement#8 made an absent endpoint a `no_endpoint` STATUS rather
than a boot failure was to keep one chain's absence off the other six, and a
malformed render here hands that property straight back.

── AND THE SECOND SOURCE OF TRUTH THAT MUST NOT APPEAR ──────────────────────

micro-settlement#8 deliberately added NO new variable names: DOGE and ETC are
optional keys on this one map. `settlement/.env.example` states it — "THIS IS THE
ONLY PLACE A CHAIN IS TURNED ON, AND THERE IS NO PER-CHAIN VARIABLE TO ADD" —
because rule 9 of docs/ecosystem/03 §2 says a repo declares the variables it
needs and the deploy provides exactly those. A `SETTLEMENT_DOGE_RPC_URL` in this
repository would be a second answer to a question the map already answers, read
by nothing, and it would disagree with the map the first time somebody edited
one of them. So a per-chain variable in any compose file is a failure here.

── HOW THIS AVOIDS BEING A CHECK THAT CANNOT FAIL ───────────────────────────

The anchor is not copied into this file. It is READ OUT of the estate compose and
rendered by REAL `docker compose` in all eight combinations of the three optional
variables, so the string under test is the one the estate deploys and an edit to
it is exercised the moment it is made. Every combination is then parsed with a
real JSON parser rather than pattern-matched.

An assertion that "the render is valid JSON" passes against an anchor that names
only `ember`, so the presence of each optional key is asserted BOTH WAYS: set the
variable and the key must appear carrying exactly that value, leave it unset and
the key must be absent. A fragment written `${DOGE_RPC_URL:-…}` instead of `:+`
fails the second half; a fragment with its comma outside the expansion fails the
first combination that omits it.

NO VALUE IS EVER PRINTED. On every UTXO chain this variable carries an HTTP Basic
password in the URL, which is why `settlement/src/env.ts` redacts before it
truncates. The fixture values here are invented, and the failure messages still
name keys and never values, because a check that leaks on the day it goes red is
a check nobody can run on the live file.

Exit 0 only if every combination holds.
"""
import itertools
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so the anchor cannot be read out of the estate compose "
        "file.\n"
        "       This is a failure and not a skip: every combination below would go unchecked, and "
        "a check that reports a pass it did not establish is worse than no check.\n"
        "       python3 -m pip install pyyaml"
    )

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE_DIR = ROOT / "compose"
ESTATE = COMPOSE_DIR / "docker-compose.estate.yml"

ANCHOR_KEY = "x-settlement-rpc-urls"
VARIABLE = "SETTLEMENT_RPC_URLS"

# The chains micro-settlement#8 leaves optional on this map, and the estate variable each is
# supplied by. `ember` is not here: it has a default in the anchor and is always present.
OPTIONAL = {
    "ltc": "LTC_RPC_URL",
    "doge": "DOGE_RPC_URL",
    "etc": "ETC_RPC_URL",
}

# Invented, and shaped like the real thing on purpose. Every Bitcoin-family node authenticates
# JSON-RPC with HTTP Basic and nothing else, so the endpoint carries userinfo and the `@`, `:` and
# `/` in it are exactly the characters a hand-rolled parser gets wrong. Never printed.
FIXTURE = {
    "LTC_RPC_URL": "http://fixture-user:fixture-pass@127.0.0.1:50002",
    "DOGE_RPC_URL": "http://fixture-user:fixture-pass@127.0.0.1:9332",
    "ETC_RPC_URL": "http://127.0.0.1:8555",
}

# Rule 9. Any of these in a compose file is the second source of truth micro-settlement#8 refused.
FORBIDDEN_SHAPE = "_RPC_URL"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


if shutil.which("docker") is None:
    fail("docker is not available, so the anchor cannot be rendered. Refusing to guess it.")

try:
    estate = yaml.safe_load(ESTATE.read_text())
except yaml.YAMLError as exc:
    fail(f"{ESTATE.name} is not parseable, so nothing in it was checked:\n{exc}")

anchor = estate.get(ANCHOR_KEY)
if not isinstance(anchor, str) or not anchor.strip():
    fail(
        f"{ESTATE.name} defines no `{ANCHOR_KEY}` string. Either the anchor was renamed and this "
        f"check is now guarding nothing, or settlement has stopped being given endpoints at all."
    )
anchor = anchor.strip()

# ── THE ANCHOR REACHES THE SERVICES, WHICH IS WHAT MAKES ANY OF THIS MATTER ──
#
# An anchor nothing aliases is a well-formed string in a file. `settlement/src/env.ts` is eager and
# `src/migrator.ts` imports it, so BOTH containers parse this — a migrator left off the anchor is a
# release that stops at the migration step.
users = sorted(
    name
    for name, spec in (estate.get("services") or {}).items()
    if isinstance(spec, dict)
    and isinstance(spec.get("environment"), dict)
    and spec["environment"].get(VARIABLE) == anchor
)
for required in ("settlement", "settlement-migrate"):
    if required not in users:
        fail(
            f"`{required}` does not take {VARIABLE} from the `{ANCHOR_KEY}` anchor. Both the "
            f"service and its migrator run settlement's eager `env.ts`, so both parse this value "
            f"at import; a container left off the anchor either boots with no endpoints at all or "
            f"reads a second, drifting copy of the map."
        )

# ── RULE 9: NO PER-CHAIN VARIABLE, ANYWHERE ──────────────────────────────────
offenders = []
for path in sorted(COMPOSE_DIR.glob("*.yml")) + sorted(COMPOSE_DIR.glob("*.yaml")):
    for line_text in path.read_text().split("\n"):
        stripped = line_text.strip()
        if stripped.startswith("#"):
            continue
        for chain in OPTIONAL:
            name = f"SETTLEMENT_{chain.upper()}{FORBIDDEN_SHAPE}"
            if name in stripped:
                offenders.append(f"{path.name}: {name}")
if offenders:
    fail(
        "a per-chain settlement endpoint variable is supplied by a compose file:\n       "
        + "\n       ".join(sorted(set(offenders)))
        + f"\n       micro-settlement#8 added no such variable — DOGE and ETC are optional keys on "
        f"{VARIABLE} and nothing else. A variable the service never reads is configuration that "
        f"looks real, does nothing, and disagrees with the map the first time either is edited "
        f"(rule 9, docs/ecosystem/03 §2)."
    )

# ── THE ANCHOR ITSELF, RENDERED BY REAL COMPOSE, IN EVERY COMBINATION ────────
if "'" in anchor:
    fail(
        f"the `{ANCHOR_KEY}` value contains a single quote, so this check cannot embed it in a "
        f"fixture compose file without changing it. Rewrite the fixture emitter rather than "
        f"weakening what is under test."
    )

with tempfile.TemporaryDirectory() as tmp:
    tmpdir = pathlib.Path(tmp)
    fixture = tmpdir / "docker-compose.fixture.yml"
    fixture.write_text(
        "services:\n"
        "  probe:\n"
        "    image: example.invalid/probe:latest\n"
        "    environment:\n"
        f"      {VARIABLE}: '{anchor}'\n"
    )

    def render(setvars):
        """`docker compose config` over the real anchor with exactly these variables set."""
        env_file = tmpdir / "render.env"
        env_file.write_text("".join(f"{name}={FIXTURE[name]}\n" for name in setvars))
        proc = subprocess.run(
            ["docker", "compose", "--env-file", str(env_file), "-f", str(fixture),
             "config", "--format", "json"],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            # stderr can quote the interpolated value, so it is not echoed.
            fail(
                f"`docker compose config` could not render {VARIABLE} with "
                f"{sorted(setvars) or 'no optional chain'} set. The anchor does not interpolate."
            )
        return json.loads(proc.stdout)["services"]["probe"]["environment"][VARIABLE]

    combinations = 0
    for count in range(len(OPTIONAL) + 1):
        for chains in itertools.combinations(sorted(OPTIONAL), count):
            setvars = [OPTIONAL[chain] for chain in chains]
            rendered = render(setvars)
            combinations += 1
            where = f"with {', '.join(chains) if chains else 'no optional chain'} configured"

            try:
                parsed = json.loads(rendered)
            except json.JSONDecodeError as exc:
                fail(
                    f"{VARIABLE} {where} is not JSON ({exc.msg} at position {exc.pos}).\n"
                    f"       `settlement/src/env.ts` parses this at import, so it is a boot "
                    f"failure on `settlement` AND `settlement-migrate` — the estate would stop at "
                    f"the migration step of the release. A stray comma outside a `${{VAR:+…}}` "
                    f"expansion is the usual cause. The value is not printed: it carries an HTTP "
                    f"Basic password on every UTXO chain."
                )
            if not isinstance(parsed, dict):
                fail(f"{VARIABLE} {where} is not a JSON object.")

            if parsed.get("ember", "") == "":
                fail(
                    f"{VARIABLE} {where} carries no `ember` endpoint. EMBER is this estate's own "
                    f"chain and is the one entry with a default; without it every EMBER withdrawal "
                    f"is classified `endpoint` and refunded at the deadline."
                )

            for chain, value in parsed.items():
                if not isinstance(value, str) or value == "":
                    fail(
                        f"{VARIABLE} {where} carries an empty endpoint for `{chain}`. "
                        f"`jsonMap` refuses that with `{VARIABLE}.{chain} must be a non-empty "
                        f"string` at import, which is a crash loop and not a disabled chain — the "
                        f"`${{VAR:+,\"{chain}\":\"$VAR\"}}` form exists so that an unset variable "
                        f"contributes NOTHING rather than an empty entry."
                    )

            expected = set(chains) | {"ember"}
            if set(parsed) != expected:
                fail(
                    f"{VARIABLE} {where} names {sorted(parsed)} and should name {sorted(expected)}. "
                    f"A chain whose variable is unset must be ABSENT from the map: settlement then "
                    f"reports it `no_endpoint` and refuses each request by name, which is a "
                    f"permanent operator-actionable classification. A key pointed at nothing turns "
                    f"that into an `unclassified` connection failure, a round trip per tick, "
                    f"telling nobody."
                )
            for chain in chains:
                if parsed[chain] != FIXTURE[OPTIONAL[chain]]:
                    fail(
                        f"{VARIABLE} {where} carries a `{chain}` endpoint that is not the value "
                        f"`{OPTIONAL[chain]}` was set to. The fragment for that chain interpolates "
                        f"the wrong variable, or quotes it in a way that mangles it."
                    )

    # ── THE FIXTURE, CHECKED AGAINST ITSELF ──────────────────────────────────
    #
    # Everything above is satisfied by an anchor that names `ember` and nothing else: with no
    # optional key wired, every "unset means absent" assertion holds vacuously. So the wiring is
    # asserted last, and it is the assertion that fails if DOGE or ETC is ever quietly dropped.
    full = json.loads(render(list(FIXTURE)))
    missing = [chain for chain in OPTIONAL if chain not in full]
    if missing:
        fail(
            f"{VARIABLE} cannot express {', '.join(sorted(missing))} at all — the anchor has no "
            f"fragment for it, so every assertion above passed against a chain that is not wired. "
            f"micro-settlement#8 accepts these as optional keys on this map and there is no other "
            f"way to supply one."
        )

print(
    f"ok: {VARIABLE} renders to valid JSON in all {combinations} combinations of "
    f"{', '.join(sorted(OPTIONAL))} — each chain present with exactly its endpoint when its "
    f"variable is set, absent when it is not, never empty; both settlement containers take the "
    f"anchor, and no per-chain endpoint variable exists to disagree with it"
)
