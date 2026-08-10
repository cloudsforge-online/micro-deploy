#!/usr/bin/env python3
"""THE RUNBOOK RULE, as a check that fails a build.

"Every alert rule carries a runbook_url annotation, and CI fails the alert-rules
build if any rule lacks one or points at a 404." An alert without a runbook is
deleted, not silenced, because an unactionable page teaches the on-call to ignore
pages — and the pages here are about somebody's money.

2026-08-10: it now checks a SECOND class of reference. Until today this file only
looked at `runbook_url` annotations, so the two `BEACON_TOKEN` lines in
`compose/docker-compose.estate.yml` that say "see runbooks/runbook-beacon-token.md"
pointed at nothing for as long as Beacon has existed, and passed every build. A
rule that only covers the place it was born in is a rule with a hole in it: the
reference an operator actually follows during an incident is whichever one is in
front of them, and a compose file's `:?` message is in front of them precisely
when the estate will not start.

Deliberately dependency-free: it parses the rules file with a regex rather than
with PyYAML. A check that only runs where a library happens to be installed is a
check that stops running, and this one has to survive being copied into a CI
image nobody curates.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = ROOT / "prometheus" / "rules" / "alerts.yaml"
RUNBOOKS = ROOT / "runbooks"

text = RULES.read_text()

# Split on each `- alert:` so an annotation cannot be credited to its neighbour.
chunks = re.split(r"^\s*- alert:\s*", text, flags=re.M)[1:]
if not chunks:
    sys.exit(f"no alert rules found in {RULES} — that is itself a failure")

missing, dangling = [], []
for chunk in chunks:
    name = chunk.splitlines()[0].strip()
    match = re.search(r"runbook_url:\s*(\S+)", chunk)
    if not match:
        missing.append(name)
        continue
    filename = match.group(1).rsplit("/", 1)[-1]
    if not (RUNBOOKS / filename).exists():
        dangling.append(f"{name} -> runbooks/{filename}")

if missing:
    print("alerts with no runbook_url:", *missing, sep="\n  ")
if dangling:
    print("runbook_url pointing at a file that does not exist:", *dangling, sep="\n  ")

# Second pass: every OTHER mention of a runbook, wherever it is written. Compose
# `:?` messages, scripts, docs and the runbooks' own cross-references all send an
# operator to a filename, and each of those is a promise the repository makes.
SKIP_DIRS = {".git", "node_modules", ".pnpm-store", "secrets", "estate"}
SKIP_SUFFIXES = {".png", ".jpg", ".gz", ".zip", ".pdf", ".ico", ".woff", ".woff2"}
MENTION = re.compile(r"runbooks?/(runbook-[a-z0-9-]+\.md)")

broken, scanned = {}, 0
for path in sorted(ROOT.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
        continue
    if path.suffix in SKIP_SUFFIXES or path == pathlib.Path(__file__).resolve():
        continue
    try:
        body = path.read_text()
    except (UnicodeDecodeError, OSError):
        continue  # a binary or unreadable file cannot be citing a runbook
    scanned += 1
    for filename in set(MENTION.findall(body)):
        if not (RUNBOOKS / filename).exists():
            broken.setdefault(filename, set()).add(str(path.relative_to(ROOT)))

if broken:
    print("references to a runbook that does not exist:")
    for filename, where in sorted(broken.items()):
        print(f"  runbooks/{filename} <- {', '.join(sorted(where))}")

if missing or dangling or broken:
    sys.exit(1)

print(
    f"ok: {len(chunks)} alerts, every one with a runbook, every runbook present; "
    f"{scanned} other file(s) scanned, every runbook they name is on disk"
)
