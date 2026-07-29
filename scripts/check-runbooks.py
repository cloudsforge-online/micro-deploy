#!/usr/bin/env python3
"""THE RUNBOOK RULE, as a check that fails a build.

"Every alert rule carries a runbook_url annotation, and CI fails the alert-rules
build if any rule lacks one or points at a 404." An alert without a runbook is
deleted, not silenced, because an unactionable page teaches the on-call to ignore
pages — and the pages here are about somebody's money.

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
if missing or dangling:
    sys.exit(1)

print(f"ok: {len(chunks)} alerts, every one with a runbook, every runbook present")
