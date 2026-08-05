#!/usr/bin/env python3
"""Rule 6, made mechanical: a service that stores a person may not be unregistered.

    scripts/check-erasure-register.py                 # against the sibling checkouts
    scripts/check-erasure-register.py --root ~/dev/cloudsforge-micro

WHY THIS EXISTS
---------------
`org/README.md` lists ten rules and says which are checked. Rule 6 — "services
storing `user_id` subscribe to `identity.user.deleted`" — was in the column
marked "Beacon conformance (AD-04), not CI", which in practice meant nobody
checked it at all. It was true of two services out of sixteen. Fourteen more
stored a reference to a person with no subscriber, so a deletion request
succeeded in identity and left personal data across the estate, and every
individual part of the system reported itself healthy while that was true.

A rule that lives in a table in a README is a rule that is enforced by whoever
last read the README. This is the same rule, expressed as a script that fails.

WHAT IT ASSERTS
---------------
Every service whose schema declares a column referencing a person must either

  * have a row in `erasure/register.psv` — which means it is subscribed at
    deploy AND covered by `scripts/erasure-drill.sh`, because both read that one
    file — or
  * appear in EXEMPT below, with a reason that is about the DATA and not about
    the schedule. "Not done yet" is not a reason and will not be accepted here;
    that is what a tracker issue is for.

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It does not decide whether a service's erasure handler is CORRECT. Grep cannot
tell a delete from a de-identification from a no-op that returns success —
`devplatform`'s handler returned `{revoked: 0}` and looked exactly like a working
one. That question is answered by driving a real deletion through the real bus,
which is `scripts/erasure-drill.sh`, and this check is its bookkeeping: it makes
sure the drill's coverage cannot silently fall behind the estate's schemas.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Column names that mean "a person". Anchored to a column DECLARATION — name then
# type — so a mention in a comment or an index does not count. `subject` is the
# ledger spelling `user:<uuid>` and is as much a reference to a person as a uuid.
COLUMN = re.compile(
    r"^\s*("
    r"user_id|subject|subject_id|owner_subject|author_subject|seller_subject|"
    r"visitor_subject|challenger_subject|custody_user_id|attacker_user_id|"
    r"defender_user_id|placed_by|booked_by|lit_by|beneficiary"
    r")\s+(uuid|text)\b",
    re.MULTILINE,
)

# A service is exempt only because of what its data IS. Each entry is the
# sentence a regulator would be given, and it has to survive being read out.
EXEMPT: dict[str, str] = {
    "identity": (
        "the controller of the erasure itself. It publishes the event; subscribing to its own "
        "tombstone would be a service erasing itself in response to having erased itself. Its "
        "own path is `src/deletion.ts` and it is genuinely complete"
    ),
    "beacon": (
        "`subject` here is a probe, journey or SLO name — `src/migrations.ts:212,405`, where '*' is "
        "a permitted value. It has never referred to a person"
    ),
}

# Repositories that are not services, or that hold no database at all.
NOT_A_SERVICE = {"contracts", "sdk", "ui", "org", "docs", "deploy", "conformance", "brand"}


def user_columns(migrations: Path) -> set[str]:
    text = migrations.read_text(encoding="utf-8")
    return {m.group(1) for m in COLUMN.finditer(text)}


def registered(register: Path) -> set[str]:
    names: set[str] = set()
    for line in register.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        names.add(stripped.split("|", 1)[0].strip())
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        # The deploy repository sits beside its siblings in one checkout tree.
        default=Path(__file__).resolve().parents[2],
        help="the directory holding every service checkout",
    )
    parser.add_argument(
        "--register",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "erasure" / "register.psv",
    )
    args = parser.parse_args()

    if not args.register.is_file():
        print(f"FAIL  no erasure register at {args.register}", file=sys.stderr)
        return 2

    covered = registered(args.register)
    failures: list[str] = []
    holders = 0

    for migrations in sorted(args.root.glob("*/src/migrations.ts")):
        service = migrations.parent.parent.name
        if service in NOT_A_SERVICE:
            continue
        columns = user_columns(migrations)
        if not columns:
            continue
        holders += 1
        shown = ", ".join(sorted(columns))
        if service in covered:
            print(f"ok    {service}: registered ({shown})")
        elif service in EXEMPT:
            print(f"ok    {service}: exempt — {EXEMPT[service]}")
        else:
            failures.append(
                f"{service} declares {shown} and is neither in the erasure register "
                f"nor exempt. A deletion request would leave its rows in place."
            )

    print()
    print(f"{holders} service(s) store a reference to a person; {len(covered)} registered.")
    if failures:
        for failure in failures:
            print(f"FAIL  {failure}", file=sys.stderr)
        return 1
    print("ok: rule 6 holds — every service holding a person is covered by the erasure drill.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
