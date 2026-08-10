#!/usr/bin/env python3
"""Every sibling repository this repo reads is named in the prerequisite table.

── WHAT THIS PREVENTS (micro-org#350) ───────────────────────────────────────

`deploy` reads files out of sibling repositories, under directory names that are
NOT the repository names — `micro-contracts` must be checked out as `contracts`,
`micro-ui` as `ui`. Nothing said so, and on a fresh host the only signal that a
whole repository was missing was a Python traceback from the middle of a
bootstrap that had already started changing things:

    FileNotFoundError: '../contracts/packages/events/src/audit.ts'

`provision-siblings.sh` now carries the table that clones them and that
`estate-bootstrap.sh` preflights against. A hand-maintained prerequisite list is
accurate on the day it is written and silently wrong afterwards, and the failure
only ever appears on a FRESH host — the one machine nobody is testing on. So the
table is not trusted to be complete; it is checked.

── WHAT IT ASSERTS ──────────────────────────────────────────────────────────

  1. NO UNDECLARED READ. Every `../<name>/` in this repository's scripts, its
     Makefile and its compose files either resolves inside this repository or is
     a row in the table. A script that grows a read of a new sibling fails here
     rather than on somebody's fresh host in six months.
  2. NO STALE ROW. Every REQUIRED or DEGRADED row is actually read by something.
     A prerequisite nobody needs is a repository somebody clones for no reason,
     and it makes the rows that DO matter cheaper to ignore.

The OPTIONAL rows are exempt from (2) on purpose: the asset repositories are
referenced by seed data as bare paths (`brand/review/sheet-og.png`) rather than
as `../brand/`, because `seed/images.mjs` resolves them against the monorepo
root. They are still prerequisites and they are still worth listing.

Exit non-zero on failure, print nothing but the verdict on success.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
TABLE_SCRIPT = HERE / "provision-siblings.sh"

# A path is read relative to a different directory depending on who reads it —
# `scripts/*` run with the repo root as cwd, compose files resolve against
# `compose/`, and `scripts/seed/*.mjs` against their own directory. Rather than
# model three rules, every run of `../` is collapsed and the NAME that follows is
# taken: a name that belongs to this repository is in-repo wherever it was
# written, and one that does not is a sibling wherever it was written.
IN_REPO = {p.name for p in ROOT.iterdir() if p.is_dir() and not p.name.startswith(".")}

SOURCES = [
    *sorted(ROOT.glob("scripts/*.sh")),
    *sorted(ROOT.glob("scripts/*.py")),
    *sorted(ROOT.glob("scripts/*.mjs")),
    *sorted(ROOT.glob("scripts/seed/*.mjs")),
    *sorted(ROOT.glob("compose/*.yml")),
    ROOT / "Makefile",
]

REFERENCE = re.compile(r"(?:\.\./)+([A-Za-z0-9_-]+)/")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


if not TABLE_SCRIPT.exists():
    fail(f"{TABLE_SCRIPT} does not exist, so there is no prerequisite table to check.")

table_text = TABLE_SCRIPT.read_text()
match = re.search(r'SIBLING_TABLE="\\\n(.*?)"\n', table_text, re.S)
if not match:
    fail(
        f"could not find SIBLING_TABLE in {TABLE_SCRIPT.name}. This check reads the table\n"
        "       the provisioning script actually uses rather than a second copy of it, so a\n"
        "       table it cannot parse is a table it cannot hold to anything."
    )

rows = {}
for line in match.group(1).splitlines():
    if not line.strip():
        continue
    parts = line.split("|")
    if len(parts) < 5:
        fail(f"malformed row in SIBLING_TABLE (want dir|repo|witness|tier|why): {line!r}")
    rows[parts[0]] = {"repo": parts[1], "witness": parts[2], "tier": parts[3]}

if not rows:
    fail("SIBLING_TABLE parsed to no rows at all, so every assertion below would pass.")

# ── 1. every sibling that is read is declared ────────────────────────────────
undeclared = {}
for source in SOURCES:
    if not source.exists():
        continue
    for lineno, line in enumerate(source.read_text().splitlines(), 1):
        stripped = line.strip()
        # Prose mentions a path constantly in this repository — the comments are
        # where the reasoning lives. A comment cannot open a file, so only code
        # can create a prerequisite.
        if stripped.startswith("#") or stripped.startswith("//") or stripped.startswith("*"):
            continue
        for name in REFERENCE.findall(line):
            if name in IN_REPO or name in rows:
                continue
            undeclared.setdefault(name, f"{source.relative_to(ROOT)}: {stripped[:90]}")

if undeclared:
    detail = "\n".join(f"         ../{n}/  — {where}" for n, where in sorted(undeclared.items()))
    fail(
        "a sibling repository is read and is not in the prerequisite table:\n"
        f"{detail}\n"
        "       On a fresh host this is a traceback naming a path inside a repository the\n"
        "       operator has never heard of. Add a row to SIBLING_TABLE in\n"
        "       scripts/provision-siblings.sh naming the directory, the repository it is\n"
        "       cloned FROM, the file that proves the clone is usable, and what breaks."
    )

# ── 2. and every declared prerequisite is really needed ──────────────────────
haystack = "\n".join(s.read_text() for s in SOURCES if s.exists())
unread = [
    name
    for name, row in rows.items()
    if row["tier"] in ("REQUIRED", "DEGRADED")
    and not re.search(r"(?:\.\./)+" + re.escape(name) + "/", haystack)
]
if unread:
    fail(
        f"the table requires {', '.join(sorted(unread))} and nothing in this repository\n"
        "       reads it. A prerequisite nobody needs is a repository somebody clones for\n"
        "       no reason, and it makes the rows that DO matter cheaper to ignore."
    )

# ── 3. AND THE PREFLIGHT ACTUALLY REFUSES A BARE HOST ────────────────────────
#
# The two assertions above are about the table's CONTENTS. This one is about the
# table being enforced: `--check` is run against an empty directory — a host with
# nothing beside the estate checkout, which is precisely the machine micro-org#350
# was filed from — and it must fail, name every required repository, and give the
# directory name to clone it under.
#
# The last of those is the one worth asserting explicitly. Cloning with git's
# default name leaves `micro-contracts` next door and the bootstrap failing at the
# identical traceback, so a message that names the repository and not the
# DIRECTORY has not helped anybody.
with tempfile.TemporaryDirectory() as bare:
    probe = subprocess.run(
        ["bash", str(TABLE_SCRIPT), "--check"],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        env={**os.environ, "SIBLINGS": bare},
    )
    output = probe.stdout + probe.stderr
    if probe.returncode == 0:
        fail(
            "`provision-siblings.sh --check` passed against a directory containing NOTHING.\n"
            "       That is the fresh host this whole change exists for, and a preflight that\n"
            f"       cannot fail is worse than none.\n\n{output}"
        )
    for name, row in rows.items():
        if row["tier"] != "REQUIRED":
            continue
        if name not in output or row["repo"] not in output:
            fail(
                f"the bare-host preflight did not name the required prerequisite '{name}'\n"
                f"       ({row['repo']}). Reporting one missing repository per run turns standing\n"
                "       up a host into clone-rerun-clone-rerun, against a half-provisioned\n"
                f"       estate each time.\n\n{output}"
            )
        if f"AS '{name}'" not in output:
            fail(
                f"the preflight names {row['repo']} without saying it must be checked out as\n"
                f"       '{name}'. Cloning it with git's default name leaves the tooling failing\n"
                "       at exactly the same traceback, which is the trap micro-org#350 calls the\n"
                f"       part most likely to catch someone out.\n\n{output}"
            )

print(
    f"ok: {len(rows)} sibling checkout(s) declared, every one of them read, nothing this\n"
    "    repository reads is left for a fresh host to discover as a traceback, and the\n"
    "    preflight refuses a bare host by name rather than by traceback"
)
