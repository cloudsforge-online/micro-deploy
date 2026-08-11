#!/usr/bin/env python3
"""Every EMBER miner in the estate runs one hearth build, and this is what makes that checkable.

THE DEFECT THIS GUARDS, AND WHY A COMMENT COULD NOT
---------------------------------------------------
The EMBER miners are pinned by commit SHA — never by a moving tag — for the
reason `docker-compose.miners.yml` gives at length: a miner that follows `main`
changes consensus behaviour on a restart nobody asked for.

But the pins live in TWO files, because the miners live on two machines:

    compose/docker-compose.miners.yml           chain host: miner-mainnet, miner-testnet
    compose/docker-compose.miners-apphost.yml   app host:   miner-mainnet-apphost

Nothing links them. Not a project name, not an anchor, not an include. They are
two files that happen to name the same image, and a person bumping "the miner
pin" edits the one they opened.

That is not hypothetical. micro-deploy#71 shipped hearth 0.3.0 — the emergency
difficulty rule, a HARD FORK activating at height 20,000 — by bumping
`docker-compose.miners.yml`, and the header it added to that very file said:

    "Every hearth process in the estate has to be on a094dba or newer before the
     tip reaches 20,000: these two miners, `cf-miner-mainnet-apphost` on the app
     host, and the two seeds on the chain host"

...and then did not touch the line that governs `cf-miner-mainnet-apphost`,
because that line is in the other file. The author knew the invariant, wrote the
invariant down, and broke it in the same commit. A comment cannot enforce a
property that spans a file it is not in.

WHY THE FAILURE IS SILENT, WHICH IS WHY THIS IS A CI CHECK AND NOT A RUNBOOK
---------------------------------------------------------------------------
A miner left on the old build past an activation height does not slow down, warn,
or fall behind in any way an operator would see. It rejects the first eased block
as `wrong difficulty target`, stops following the chain, and keeps hashing a fork
of one — printing `hashing #N`, the same line a healthy miner prints. `docker ps`
says `Up`. The health check passes. The hashrate is nominal. The only symptom is
that the estate's EMBER income quietly stops, on an address that is separately
booked (micro-org#363), and is noticed whenever somebody next totals it up.

WHAT IT CHECKS
--------------
Every `ghcr.io/cloudsforge-online/hearth-node:<ref>` in compose/ resolves to the
same `<ref>`, and that ref is a `sha-<40 hex>` pin rather than a moving tag.

It deliberately does NOT check the seeds. The two `cf-hearth-seed*` containers on
the chain host build LOCALLY from a hearth checkout and carry no `image:` pin at
all, so there is nothing here to compare — they are upgraded by `git pull` and
`up -d --build`. That asymmetry is the thing most likely to be forgotten next, so
the failure message names it rather than leaving it to be rediscovered.

USAGE
-----
    python3 scripts/check-hearth-pins-agree.py            # scan compose/
    python3 scripts/check-hearth-pins-agree.py path ...   # scan the given files

Exit 0 when every pin agrees and is a SHA; exit 1 with the disagreement named.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IMAGE = re.compile(r"ghcr\.io/cloudsforge-online/hearth-node:(\S+)")
SHA_PIN = re.compile(r"^sha-[0-9a-f]{40}$")

# The locally-built seeds, named so a failure message can say what this does not
# cover instead of implying the estate is fully described by these files.
LOCALLY_BUILT = [
    ("cf-hearth-seed", "project `hearth`, image `hearth-hearth-testnet-seed`"),
    ("cf-hearth-seed-testnet", "project `cf-testnet-chain`, image `cf-testnet-chain-hearth-testnet-seed`"),
]


def scan(paths):
    """Return [(path, lineno, ref)] for every hearth-node image reference found."""
    found = []
    for p in paths:
        try:
            text = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            # Only `image:` keys, not the prose above them — the headers in these
            # files quote old pins on purpose, to say what changed between them.
            if not re.match(r"\s*image:\s", line):
                continue
            m = IMAGE.search(line)
            if m:
                found.append((p, lineno, m.group(1)))
    return found


def main(argv):
    if argv:
        paths = [Path(a) for a in argv]
    else:
        paths = sorted((REPO / "compose").glob("*.yml"))

    found = scan(paths)
    if not found:
        print("check-hearth-pins-agree: no hearth-node image pins found — nothing to compare.")
        print("  If the miners were just renamed or moved, this check has stopped measuring")
        print("  anything and needs its paths updated. Silence here is not a pass.")
        return 1

    fails = []

    moving = [(p, n, r) for p, n, r in found if not SHA_PIN.match(r)]
    for p, n, ref in moving:
        fails.append(
            f"{p.relative_to(REPO) if REPO in p.resolve().parents or p.is_absolute() else p}:{n}: "
            f"hearth-node is pinned to `{ref}`, which is not a `sha-<40 hex>` commit pin.\n"
            f"    A moving tag makes a miner's consensus behaviour change on a restart\n"
            f"    nobody asked for. Pin the commit."
        )

    refs = {r for _, _, r in found}
    if len(refs) > 1:
        lines = [
            "the estate's hearth-node pins DISAGREE, so the EMBER miners are not all",
            "running one consensus build:",
            "",
        ]
        for p, n, ref in sorted(found, key=lambda f: (str(f[0]), f[1])):
            try:
                shown = p.resolve().relative_to(REPO)
            except ValueError:
                shown = p
            lines.append(f"      {shown}:{n}  {ref}")
        lines += [
            "",
            "    These files are not linked to each other. Bumping one does not bump the",
            "    other, and `docker compose up` against one cannot touch the other.",
            "",
            "    A miner on the older build past a fork's activation height rejects the",
            "    first forked block as `wrong difficulty target` and silently mines a",
            "    fork of one, while still printing `hashing #N` and passing its health",
            "    check. Bring them to one ref before that height, not after.",
        ]
        fails.append("\n".join(lines))

    if fails:
        print("check-hearth-pins-agree: FAIL\n")
        for f in fails:
            print(f"  {f}\n")
        return 1

    (ref,) = refs
    print(f"check-hearth-pins-agree: ok — {len(found)} pins, all {ref}")
    print("  NOT covered, because they carry no image pin to compare:")
    for name, where in LOCALLY_BUILT:
        print(f"    {name} ({where})")
    print("  Those build locally from the hearth checkout on the chain host and are")
    print("  upgraded by `git pull` + `up -d --build`. This check cannot see them.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
