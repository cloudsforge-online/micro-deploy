#!/usr/bin/env python3
"""No command in this repository pairs one estate's env file with the other's tokens.

WHAT THIS GUARDS (micro-org#238)
--------------------------------
Bringing an environment up takes TWO `--env-file` paths — the estate's own env
file and its tokens file — and every entry point treats them as independent
values. Nothing compared them, so a testnet bring-up accepted the MAINNET tokens
file without a word.

The result is not a failure. It is an estate that comes up under testnet's
project name, prints testnet on every line — `release-deploy.sh` derives the
environment from the estate file ALONE — and holds mainnet's service
credentials, mainnet's operator password and mainnet's custody keyring
selection. The credentials are real; they belong to the other estate. The best
case is testnet identity answering 401 to callers that look entirely correct.
The worst case is a component that accepts them.

`estate-bootstrap.sh` has the mirror image and says so in its own header about a
different variable: a half-retargeted bootstrap "writes one estate's admin row
and credentials into the other's database".

TWO PLACES THIS CAN GO WRONG, AND THEY NEED DIFFERENT CHECKS
------------------------------------------------------------
  * AT RUNTIME, from a variable an operator sets. `ESTATE_ENV` and `TOKENS_FILE`
    are overridable on both entry points, and no static check can see what
    somebody types. That is `check-env-files-agree.sh`, exercised here against
    both crossed pairs and both correct ones.
  * IN A TRACKED FILE, where the pair is written out literally. The Makefile
    alone spells a pairing out four times. Those are checked by reading every
    tracked file that invokes compose and pairing up the `--env-file` arguments
    in each command.

WHAT IT CHECKS
--------------
  1. `check-env-files-agree.sh` refuses both crossed pairs, accepts both correct
     ones, and passes over a pair naming neither environment — a fixture or a
     dev estate must not be refused, or the check becomes a thing people
     work around.
  2. Every `--env-file` pair written literally in a tracked file names one
     estate. Both directions, in the Makefile and in every script.
  3. Both entry points that accept the two paths as variables — `release-deploy.sh`
     and `estate-bootstrap.sh` — actually call the refusal. A guard nothing
     invokes is a guard nothing runs, and this repository has shipped one before:
     `surface-routes.py` existed for weeks with no CI step, which is how the
     thing it guards went wrong in the first place.
  4. The refusal is reachable and its verdicts differ — asserted by running it,
     not by grepping it.

Exit non-zero on failure, print nothing but the verdict on success.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AGREE = ROOT / "scripts" / "check-env-files-agree.sh"

MAINNET_ENV = "compose/mainnet.env"
MAINNET_TOKENS = "compose/estate/tokens.env"
TESTNET_ENV = "compose/testnet.env"
TESTNET_TOKENS = "compose/estate/tokens.testnet.env"

# The entry points that take both paths as overridable variables. Named rather
# than discovered: what is being asserted is that THESE call the refusal, and a
# discovered list would shrink silently to nothing the day the naming changed.
CALLERS = ("scripts/release-deploy.sh", "scripts/estate-bootstrap.sh")

# `--env-file <path>` and `--env-file=<path>`, both accepted by compose.
ENV_FILE = re.compile(r"--env-file[= ]+([^\s\\'\"]+)")

# A line-continuation backslash and any leading whitespace folded away, so a
# command spread over four lines is read as the one command it is. Without this,
# the Makefile's `ESTATE :=` — which is exactly where a pair would be crossed —
# reads as two separate one-file commands and nothing is compared.
CONTINUED = re.compile(r"\\\s*\n\s*")


def environment_of(path):
    """The same rule `check-env-files-agree.sh` applies, and for the same reason.

    `testnet` first: the mainnet tokens file is the unadorned name, so a suffix
    test has to come before any test that could match it.
    """
    if "testnet" in path:
        return "testnet"
    if "mainnet" in path or path.endswith("/tokens.env") or path == "tokens.env":
        return "mainnet"
    return None


def agree(estate_env, tokens):
    proc = subprocess.run(
        ["bash", str(AGREE), estate_env, tokens], capture_output=True, text=True
    )
    return proc.returncode, proc.stdout + proc.stderr


def main():
    bad = []

    # ── 1. THE REFUSAL ITSELF ────────────────────────────────────────────────
    if not AGREE.exists():
        sys.exit(f"FAIL: {AGREE} does not exist, so nothing enforces the pairing at runtime.")

    for estate_env, tokens in (
        (TESTNET_ENV, MAINNET_TOKENS),
        (MAINNET_ENV, TESTNET_TOKENS),
    ):
        code, out = agree(estate_env, tokens)
        if code == 0:
            bad.append(
                f"`{estate_env}` paired with `{tokens}` was ACCEPTED. That estate comes up "
                f"under one environment's project name holding the other's credentials, and "
                f"every line of output names the environment that was right."
            )
        elif "testnet" not in out or "mainnet" not in out:
            bad.append(
                f"the refusal for `{estate_env}` + `{tokens}` does not name both environments, "
                f"so the operator is told something is wrong and not which half."
            )

    for estate_env, tokens in (
        (MAINNET_ENV, MAINNET_TOKENS),
        (TESTNET_ENV, TESTNET_TOKENS),
    ):
        code, out = agree(estate_env, tokens)
        if code != 0:
            bad.append(
                f"the correct pair `{estate_env}` + `{tokens}` was REFUSED (exit {code}). "
                f"This is the pairing every deploy of that estate uses:\n       {out.strip()}"
            )

    # A pair naming neither environment must pass. A fixture, a dev estate or a
    # third environment nobody has built yet would otherwise be refused, and a
    # guard people routinely work around guards nothing.
    code, out = agree("compose/fixture.env", "compose/tokens.fixture.env")
    if code != 0:
        bad.append(
            f"a pair naming neither environment was refused (exit {code}). Only a pair that "
            f"names two DIFFERENT estates has no legitimate reading; everything else is a "
            f"fixture or a dev estate:\n       {out.strip()}"
        )

    # ── 2. EVERY PAIR WRITTEN OUT IN A TRACKED FILE ──────────────────────────
    files = [ROOT / "Makefile"] + sorted(ROOT.glob("*.sh")) + sorted((ROOT / "scripts").glob("*.sh"))
    inspected = 0
    pairs_found = 0
    for path in files:
        if not path.exists():
            continue
        inspected += 1
        text = CONTINUED.sub(" ", path.read_text())
        for line in text.splitlines():
            paths = ENV_FILE.findall(line)
            if len(paths) < 2:
                continue
            environments = {p: environment_of(p) for p in paths}
            named = {env for env in environments.values() if env}
            if len(named) < 2:
                continue
            pairs_found += 1
            bad.append(
                f"{path.name}: one command names both estates — "
                + ", ".join(f"`{p}` ({env})" for p, env in environments.items() if env)
                + ". Compose merges repeated --env-file flags in order and complains about "
                "nothing; the result is one estate's project holding the other's credentials."
            )

    # ── 3. THE ENTRY POINTS ACTUALLY CALL IT ─────────────────────────────────
    for caller in CALLERS:
        path = ROOT / caller
        if not path.exists():
            bad.append(f"{caller} does not exist, so the caller list here is stale.")
            continue
        if AGREE.name not in path.read_text():
            bad.append(
                f"{caller} takes both paths as overridable variables and never calls "
                f"{AGREE.name}. No static check can see what an operator types, so this is the "
                f"only place the crossed pair can be caught — and a guard nothing invokes is a "
                f"guard nothing runs."
            )

    if bad:
        print("FAIL: env-file pairing", file=sys.stderr)
        for line in bad:
            print(f"  - {line}", file=sys.stderr)
        return 1

    print(
        f"ok: crossed env-file pairs are refused and correct ones are not, {inspected} tracked "
        f"file(s)\n    write no command naming both estates, and both entry points call the "
        f"refusal"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
