#!/usr/bin/env python3
"""A secret that is guessable, or that has been printed into a log, is already spent.

THE TWO DEFECTS THIS GUARDS, AND WHY THE EXISTING CHECKS MISSED BOTH
--------------------------------------------------------------------
CI already refuses a secret that is COMMITTED (micro-org's `secret-hygiene.yml`).
Neither of the failures below is a commit, so neither was ever visible to it.

  1. A PLACEHOLDER THAT PASSES THE PLACEHOLDER CHECK.

     Every service rejects a placeholder secret at boot, and each does it with an
     exact-match set of eight strings — `notify/src/env.ts:44` is the canonical
     copy, and beacon, faucet, custody and market carry their own. An exact-match
     set only rejects the placeholders somebody thought of.

     `estate-only-outbox-secret-` + fourteen zeros was in the ACCEPT list of six
     variables — OUTBOX_ACCEPT_SECRETS, ACTIVITY_INGEST_SECRETS,
     ANALYTICS_DELIVERY_SECRETS, COMMUNITY_INGEST_SECRETS,
     DEVPLATFORM_INGEST_SECRETS, NOTIFY_INGEST_SIGNING_SECRET — on BOTH mainnet
     and testnet, across 44 running containers. It is forty characters long, so
     it cleared every length gate, and it was not one of the eight strings, so it
     cleared every placeholder gate.

     `contracts/packages/events/src/index.ts` says what that list is for: it is
     "the check that stands between an unauthenticated POST and a handler that
     credits money". Anyone who could guess the string could sign an event that
     the money tier would accept. Guessing it required knowing the estate's
     naming convention and that the padding was zeros.

     So this check is SHAPE-BASED, not membership-based. A placeholder does not
     become safe by being one nobody has enumerated yet.

  2. A SECRET PRINTED INTO AN AGENT TRANSCRIPT.

     `docker inspect`, `printenv`, `env`, and `docker compose config` all print
     EVERY variable in an environment, including the ones the operator was not
     looking at. Agent transcripts are plaintext JSONL on disk and they are kept.
     Three of four custody keyrings leaked exactly this way (micro-org#144).

     `--transcripts` re-runs that sweep for every secret currently deployed, so
     "has anything else leaked" is a command rather than an investigation.

WHAT IT NEVER DOES
------------------
IT NEVER PRINTS A SECRET VALUE. Not a match, not a prefix, not a truncation, not
a "first four characters so you can tell which one it was". A report that quotes
the secret it is warning about has reproduced the leak it is reporting, into a
file that is by construction kept and read. Findings name the VARIABLE and the
LOCATION; identifying which value is the reader's job, done against the source.

That constraint is the reason `_fingerprint` exists: when two findings need to be
correlated ("this is the same value in both networks") they are correlated by a
truncated SHA-256, which is stable, comparable, and not reversible.

USAGE
-----
  check-secret-hygiene.py --files compose/secrets/*.env compose/estate/tokens.env
  check-secret-hygiene.py --live cloudsforge-estate cf-testnet
  check-secret-hygiene.py --transcripts ~/.claude/projects /private/tmp \
                          --against compose/secrets/*.env

Exit 1 on any finding, so it can gate a deploy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# ── WHAT COUNTS AS A SECRET-BEARING VARIABLE ───────────────────────────────────
# Name-based, because the value alone cannot tell you whether a 32-character
# string is a token or a build hash. A false positive here costs a line of
# output; a false negative costs a credential.
SECRET_NAME = re.compile(
    r"(SECRET|TOKEN|PASSWORD|PASSWD|_PASS$|_PASS_|CREDENTIAL|PRIVATE_KEY|"
    r"API_KEY|APIKEY|_KEY$|MNEMONIC|SEED|DSN|SIGNING)",
    re.IGNORECASE,
)

# Names that match the pattern above but are not secrets. Kept short and
# explicit: an allow-list that grows without argument is how a real secret ends
# up on it.
NOT_A_SECRET = {
    "CUSTODY_KEY_VERSION",   # an integer
    "SMTP_SECURE",           # a boolean
    "GF_AUTH_ANONYMOUS_ENABLED",
}

# ── WHAT MAKES A VALUE UNFIT ───────────────────────────────────────────────────
# Shape, not membership. Each of these describes a class of string that nobody
# generates from a CSPRNG, which is the only thing a signing key should be.
PLACEHOLDER_SHAPE = [
    (re.compile(r"placeholder|changeme|change[-_]me|replace[-_ ]?with|"
                r"example|dummy|sample|test[-_]?secret|dev[-_]secret|"
                r"estate[-_]only|not[-_]a[-_]real|todo|fixme|xxxx", re.I),
     "reads as a placeholder"),
    (re.compile(r"(.)\1{7,}"),
     "contains a run of 8+ identical characters"),
    (re.compile(r"^(?:0+|1+|a+|x+|z+)$", re.I),
     "is a single repeated character"),
    (re.compile(r"^(?:secret|password|admin|token|key)\b", re.I),
     "begins with the word for what it is"),
]

MIN_LENGTH = 24  # matches the floor the services already enforce at boot


def _fingerprint(value: str) -> str:
    """A stable, non-reversible handle for a value, so findings can be correlated.

    Truncated to twelve hex characters: long enough that two distinct secrets in
    one estate will not collide, short enough to read. It is a SHA-256 of the
    value, so it discloses nothing about it.
    """
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def _split_candidates(value: str) -> list[str]:
    """Multi-key variables are comma-separated lists and every entry is live.

    `verifyDelivery` (contracts/packages/events/src/index.ts) tries every
    candidate, so a list is exactly as weak as its weakest member. Checking the
    joined string instead of each entry is how `<placeholder>,<real secret>`
    passes a length check on the strength of the real one — the same mistake
    notify/src/env.ts:196 calls out and splits before checking.
    """
    return [p.strip() for p in value.split(",") if p.strip()]


def judge(name: str, value: str) -> list[str]:
    """Return the reasons this variable's value is unfit. Empty means fit."""
    if name in NOT_A_SECRET or not SECRET_NAME.search(name):
        return []
    problems = []
    for candidate in _split_candidates(value):
        for pattern, why in PLACEHOLDER_SHAPE:
            if pattern.search(candidate):
                problems.append(f"a candidate {why}")
                break
        else:
            if len(candidate) < MIN_LENGTH:
                problems.append(
                    f"a candidate is {len(candidate)} chars, under the {MIN_LENGTH} floor"
                )
    return sorted(set(problems))


def parse_env_file(path: Path) -> list[tuple[str, str]]:
    pairs = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        pairs.append((name.strip(), value.strip().strip('"').strip("'")))
    return pairs


def check_files(paths: list[str]) -> int:
    findings = 0
    for raw in paths:
        path = Path(raw)
        if not path.is_file():
            print(f"  skip: {path} (not present)")
            continue
        for name, value in parse_env_file(path):
            for problem in judge(name, value):
                print(f"::error::{path}: {name} — {problem} [{_fingerprint(value)}]")
                findings += 1
    return findings


def _container_env(container: str) -> list[tuple[str, str]]:
    out = subprocess.run(
        ["docker", "inspect", container, "--format",
         "{{range .Config.Env}}{{println .}}{{end}}"],
        capture_output=True, text=True,
    )
    pairs = []
    for line in out.stdout.splitlines():
        if "=" in line:
            name, value = line.split("=", 1)
            pairs.append((name, value))
    return pairs


def check_live(projects: list[str]) -> int:
    """Inspect what is ACTUALLY RUNNING, which is the only environment that signs.

    A file check cannot see a container still running an older definition, and
    the release overlays are generated and gitignored — the same two blind spots
    check-restart-policy.py documents for `--config`.
    """
    findings = 0
    listing = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True
    )
    names = [n for n in listing.stdout.split() if n]
    for container in names:
        if projects and not any(container.startswith(p) for p in projects):
            continue
        for name, value in _container_env(container):
            for problem in judge(name, value):
                print(f"::error::{container}: {name} — {problem} [{_fingerprint(value)}]")
                findings += 1
    return findings


def check_transcripts(roots: list[str], against: list[str]) -> int:
    """Has any currently-deployed secret been printed into an agent transcript?

    Reads the live values only to use them as needles. They are held in memory,
    never written anywhere, and never printed — the report names the variable and
    the file, and stops there.
    """
    needles: dict[str, set[str]] = {}
    for raw in against:
        path = Path(raw)
        if not path.is_file():
            continue
        for name, value in parse_env_file(path):
            if name in NOT_A_SECRET or not SECRET_NAME.search(name):
                continue
            for candidate in _split_candidates(value):
                if len(candidate) >= 16:
                    needles.setdefault(candidate, set()).add(name)

    if not needles:
        print("  no deployed secrets to search for — pass --against")
        return 0
    print(f"  searching for {len(needles)} deployed secret values "
          f"across {len(roots)} root(s)")

    findings = 0
    hits: dict[tuple[str, str], int] = {}
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for fname in files:
                fpath = Path(dirpath) / fname
                try:
                    if fpath.stat().st_size > 400 * 1024 * 1024:
                        continue
                    blob = fpath.read_text(encoding="utf-8", errors="ignore")
                except (OSError, UnicodeError):
                    continue
                for needle, names in needles.items():
                    count = blob.count(needle)
                    if count:
                        key = (str(fpath), ",".join(sorted(names)))
                        hits[key] = hits.get(key, 0) + count

    for (fpath, names), count in sorted(hits.items(), key=lambda kv: -kv[1]):
        print(f"::error::{names} appears {count}x in {fpath}")
        findings += 1
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--files", nargs="*", metavar="ENV")
    ap.add_argument("--live", nargs="*", metavar="PROJECT")
    ap.add_argument("--transcripts", nargs="*", metavar="DIR")
    ap.add_argument("--against", nargs="*", default=[], metavar="ENV")
    args = ap.parse_args()

    if args.files is None and args.live is None and args.transcripts is None:
        ap.error("choose at least one of --files, --live, --transcripts")

    total = 0
    if args.files is not None:
        print("── env files ──")
        total += check_files(args.files)
    if args.live is not None:
        print("── running containers ──")
        total += check_live(args.live)
    if args.transcripts is not None:
        print("── agent transcripts ──")
        total += check_transcripts(args.transcripts, args.against)

    if total:
        print(f"\n{total} finding(s). NOTHING ABOVE QUOTES A SECRET; resolve each "
              f"against the source file, and rotate rather than reason about "
              f"whether the exposure mattered.")
        return 1
    print("\nok: no placeholder-shaped, short, or leaked secrets found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
