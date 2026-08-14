#!/usr/bin/env python3
"""A deploy that cycles the gateway must first prove the gateway carries its env file.

── WHY THIS IS A CI CHECK AND NOT A COMMENT ─────────────────────────────────────

`release-deploy.sh` cycles the gateway on every deploy, for a real reason
(micro-org#428: Traefik pooling a connection to a container that had swapped
addresses, serving one surface's application under another surface's hostname).
It cycled it with `docker restart`.

`docker restart` does not re-read `env_file`. The gateway is the one container
where that is load-bearing, because `gateway/dynamic/*.yml` are Go templates
rendered from its own environment and `env "X"` on an unset name renders the
empty string — so a `{{ if env "X" }}` block is silently absent from the served
config, with no error in any log.

On 2026-08-14 that cost a whole release. `CF_VIEW_ORIGIN_SUFFIX` was added to
compose/env/traefik.testnet.env to grant the combined view's origins; the release
was cut, deployed, and reported "cycled cf-testnet-gateway-1"; and the testnet
API kept answering preflights with no `Access-Control-Allow-Origin`, which is a
refusal to a browser. The fix was merged, released and deployed, and the reader's
bug was still live.

So the two halves are checked here: the comparison exists, and the deploy path
consults it before choosing how to bring the gateway back.

── AND THE COMPARISON READS NAMES, NEVER VALUES ─────────────────────────────────

The gateway env file holds no secret today. This check exists so that stays
irrelevant: a script that prints what a container's environment CONTAINS is one
refactor away from being the thing that leaks it, and this estate has leaked a
credential twice through code that meant to be helpful about values.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check-gateway-env.sh"
DEPLOY = ROOT / "scripts" / "release-deploy.sh"

failures = []

if not CHECK.exists():
    failures.append(
        f"{CHECK.relative_to(ROOT)} does not exist. Without it a deploy cannot tell a\n"
        "  gateway that carries its env file from one that was created before the file\n"
        "  changed, and the difference is invisible in every log."
    )
else:
    if not CHECK.stat().st_mode & 0o111:
        failures.append(f"{CHECK.relative_to(ROOT)} is not executable.")

    text = CHECK.read_text()

    # The comparison must be over names. `cut -d= -f1` is a name; anything that
    # keeps the right-hand side is a value, and values are not this script's
    # business at any point in its future.
    for pattern, why in (
        (r"cut\s+-d=\s+-f2", "cuts the VALUE side of an env line"),
        (r"-f2-", "keeps everything after the first `=`, which is the value"),
    ):
        if re.search(pattern, text):
            failures.append(
                f"{CHECK.relative_to(ROOT)} {why}. It compares variable NAMES; a value\n"
                "  never needs to be read, printed or held in a variable to answer the\n"
                "  question it asks."
            )

    if "docker inspect" in text and "cut -d= -f1" not in text:
        failures.append(
            f"{CHECK.relative_to(ROOT)} inspects the container without reducing the\n"
            "  environment to names (`cut -d= -f1`)."
        )

if not DEPLOY.exists():
    failures.append(f"{DEPLOY.relative_to(ROOT)} does not exist.")
else:
    deploy_text = DEPLOY.read_text()
    if "check-gateway-env.sh" not in deploy_text:
        failures.append(
            f"{DEPLOY.relative_to(ROOT)} never runs check-gateway-env.sh.\n"
            "  It cycles the gateway with `docker restart`, which keeps the environment\n"
            "  the container was created with. A variable added to the gateway's env file\n"
            "  and released will not be in the served config, and nothing will say so —\n"
            "  the deploy will print `cycled <gateway>` and be telling the truth."
        )
    else:
        # The order matters: consult, then choose. A check that runs after the
        # restart reports a fact nobody acts on.
        consult = deploy_text.index("check-gateway-env.sh")
        restart = deploy_text.find('docker restart "$gateway_container"')
        if restart != -1 and restart < consult:
            failures.append(
                f"{DEPLOY.relative_to(ROOT)} restarts the gateway before consulting\n"
                "  check-gateway-env.sh. The comparison has to decide between a restart and\n"
                "  a recreate, which means it runs first."
            )

if failures:
    print("FATAL: the gateway environment guard is not in place.\n", file=sys.stderr)
    for f in failures:
        print(f"  - {f}\n", file=sys.stderr)
    sys.exit(1)

print("ok: release-deploy.sh compares the gateway's env file to the running gateway,")
print("    by variable name, before deciding whether a restart is enough")
