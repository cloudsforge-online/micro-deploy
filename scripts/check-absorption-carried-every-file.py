#!/usr/bin/env python3
"""A merge that leaves a file behind leaves a feature behind (micro-org#543).

WHAT WENT WRONG
===============

`worlds` had a GDPR erasure handler. It was written for micro-org#491, reviewed,
closed, and corrected as recently as 2026-09-01 — the fix that day was a leak of
the user id into `reward_grants.idempotency_key`, which the handler's own test
suite had caught.

Then the service merge absorbed worlds into agora. Commit `078e799` copied
**twenty-seven** files out of `worlds/src` into `agora/src/worlds/` and copied
neither `erasure.ts` nor `erasure.test.ts`.

Measured on mainnet 2026-09-02, after the subscription was repaired and 101
historical erasures were replayed:

    http://agora:4000/v1/events/worlds     101 delivered, 0 failed
    worlds.inbox                             0 rows
    worlds_testnet.inbox                     0 rows

Every delivery succeeded. Every one took the `202 {status: 'ignored'}` branch,
because the topic dispatch that would have handled it went with the file.

WHY NOTHING CAUGHT IT
=====================

`check-erasure-register.py` globs every service's `src/migrations.ts` under the
ESTATE ROOT, so it reads the **standalone checkout** — which still has the
handler, because absorbing a service does not delete its repository. The register
said worlds erases; the standalone code did erase; the running module did not.
Three artefacts, two of them right, and the one that runs was the odd one out.

The same shape appears elsewhere in this estate under different names: a scrape
target aimed at an absorbed service's CNAME (micro-org#541), an erasure
subscription pointed at a path the merge retired (micro-org#474), a sweep that
reads a repository twice because the merge left the checkout in place. The
common cause is that **an absorbed service exists in two directories and only one
of them runs**.

WHAT THIS REFUSES
=================

An absorbed service whose module directory is missing a `.ts` file that its
standalone checkout has. Absorption discovery is the same two-round algorithm
`derive-grants.mjs` uses, so a service the merge renames on the way in
(`hub-api` -> `agora/src/hub`) is still found, and `looksLikeACopy` still has to
agree before anything is judged.

WHAT IT ALLOWS, AND WHY EACH
============================

  * `index.ts`, `migrator.ts`, `main.ts` — the process entry point and its
    migrator CLI. An absorbed module does not boot itself; the absorber does.
  * `module.ts` — the wrapper the absorber adds. It exists in the module and not
    in the checkout, which is the opposite direction and never a finding.
  * `kernel.ts`, `migratortargets.ts` — dropped in favour of the host's, which
    `agora/src/emberkin/mergedroutes.test.ts` records as a deliberate widening.

Everything else is a file somebody wrote for that service, and a merge is not a
place to decide it is no longer wanted. If one genuinely should go, delete it
from the standalone checkout too — then the two directories agree and this check
has nothing to say.

USAGE
=====

    ./scripts/check-absorption-carried-every-file.py [--root ~/dev/cloudsforge-micro]
"""

import argparse
import os
import sys
from pathlib import Path

# Files a merge legitimately does not carry. Each is here because the ABSORBER
# supplies it, never because the file stopped mattering.
BOOT = {"index.ts", "migrator.ts", "main.ts", "module.ts"}
HOSTED = {"kernel.ts", "migratortargets.ts"}
SKIP_DIRS = {"node_modules", "dist", "build", "coverage", ".git"}
NOT_A_SERVICE = {"contracts", "sdk", "ui", "org", "docs", "deploy", "conformance", "brand"}


def fail(message):
    print(f"check-absorption-carried-every-file: {message}", file=sys.stderr)
    sys.exit(1)


def ts_names(directory: Path, tests: bool) -> set[str]:
    try:
        entries = os.listdir(directory)
    except OSError:
        return set()
    return {
        n for n in entries
        if n.endswith(".ts") and (tests or not n.endswith(".test.ts"))
    }


def looks_like_a_copy(standalone_src: Path, module_dir: Path) -> bool:
    """A majority of the standalone repository's own top-level sources, by name, in the module.

    Names and not contents: a merge edits what it copies — imports change, a network selector is
    threaded through — so equality would find nothing. The majority rule is what stops a module
    that merely shares a `server.ts` from being called a copy of a service.
    """
    standalone = ts_names(standalone_src, tests=False)
    if len(standalone) < 3:
        return False
    module = ts_names(module_dir, tests=False)
    return len(standalone & module) * 2 > len(standalone)


def discover(root: Path, repos: set[str], absorbers: list[str]) -> list[tuple[str, str, Path]]:
    found: list[tuple[str, str, Path]] = []
    for absorber in absorbers:
        def descend(rel: Path, depth: int) -> None:
            if depth > 3:
                return
            try:
                entries = sorted(os.listdir(root / absorber / rel))
            except OSError:
                return
            for entry in entries:
                if entry in SKIP_DIRS:
                    continue
                rel_module = rel / entry
                directory = root / absorber / rel_module
                if not directory.is_dir():
                    continue
                # `hub-api` is `agora/src/hub`: the repository name carries a suffix the module
                # directory does not. Tried as well as the exact name, never instead of it.
                for service in (entry, f"{entry}-api"):
                    if (
                        service != absorber
                        and service in repos
                        and not any(e[0] == service for e in found)
                        and looks_like_a_copy(root / service / "src", directory)
                    ):
                        found.append((service, absorber, directory))
                        break
                descend(rel_module, depth + 1)
        descend(Path("src"), 1)
    return found


def self_test() -> int:
    """Build a fixture where a file was left behind, and refuse to pass on it.

    A CANARY, and it is here rather than as a CI step that moves a real file for the reason
    `estate-ci` learned three times over: a check that has quietly stopped looking reports the same
    green as a check that looked and found nothing. Three of estate-ci's five canaries planted at a
    hard-coded path and accused the CHECKER the day the layout moved, so this one plants nothing on
    disk that a later step could trip over — it builds its own tree in a temp directory, asserts the
    check FAILS on it, and asserts it PASSES once the missing file is put back.
    """
    import contextlib
    import io
    import tempfile

    def quietly(target: Path) -> int:
        """Run the check with its output swallowed.

        A passing self-test that prints the word FAIL is a passing self-test somebody learns to
        skim past, and the deliberate failure below is not news.
        """
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            return check(target)

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        # A standalone checkout with four sources, and an absorber carrying three of them. Four is
        # above `looks_like_a_copy`'s floor of three, and three shared of four is a majority, so the
        # absorption is discovered and `erasure.ts` is the one left behind.
        (root / "widget" / "src").mkdir(parents=True)
        (root / "absorber" / "src" / "widget").mkdir(parents=True)
        for name in ("server.ts", "store.ts", "outbox.ts", "erasure.ts"):
            (root / "widget" / "src" / name).write_text("//\n")
        for name in ("server.ts", "store.ts", "outbox.ts"):
            (root / "absorber" / "src" / "widget" / name).write_text("//\n")

        if quietly(root) == 0:
            print(
                "check-absorption-carried-every-file: SELF-TEST FAILED — the check passed a tree\n"
                "       whose absorbed module is missing a file it had. It is not looking.",
                file=sys.stderr,
            )
            return 1
        (root / "absorber" / "src" / "widget" / "erasure.ts").write_text("//\n")
        if quietly(root) != 0:
            print(
                "check-absorption-carried-every-file: SELF-TEST FAILED — the check refused a tree\n"
                "       that carries every file. It fails on something other than what it claims.",
                file=sys.stderr,
            )
            return 1

    print("check-absorption-carried-every-file: self-test ok — it fails on a dropped file and passes without one.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument(
        "--self-test",
        action="store_true",
        help="prove the check can fail, on a fixture, before believing it about the estate",
    )
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    return check(args.root)


def check(root: Path) -> int:

    repos = {
        d for d in os.listdir(root)
        if (root / d / "src").is_dir() and d not in NOT_A_SERVICE
    }
    if not repos:
        fail(f"no service checkouts under {root}, so this check would pass over nothing.")

    # TWO ROUNDS, because absorption nests: `notify` lives in `activity`, and `activity` lives in
    # `agora`. A single round would look for notify inside a repository that is itself absorbed and
    # miss it. Round one finds who is absorbed; round two searches only the absorbers that are not.
    absorbed_anywhere = {e[0] for e in discover(root, repos, sorted(repos))}
    absorptions = discover(root, repos, sorted(r for r in repos if r not in absorbed_anywhere))

    if not absorptions:
        print("check-absorption-carried-every-file: no absorbed services found — nothing to check.")
        return 0

    findings = []
    for service, absorber, directory in sorted(absorptions):
        standalone = ts_names(root / service / "src", tests=True) - BOOT - HOSTED
        module = ts_names(directory, tests=True)
        missing = sorted(standalone - module)
        rel = directory.relative_to(root)
        if missing:
            findings.append(f"{service} -> {rel} is missing: {' '.join(missing)}")
        else:
            print(f"ok    {service}: every file carried into {rel}")

    if findings:
        print()
        for finding in findings:
            print(f"FAIL  {finding}", file=sys.stderr)
        print(
            "\n       A merge that leaves a file behind leaves a feature behind, and the\n"
            "       standalone checkout keeps making it look present: worlds' erasure handler\n"
            "       was written, reviewed and corrected, then not copied, and the register, the\n"
            "       checker and the standalone code all went on agreeing it existed\n"
            "       (micro-org#543). Carry the file, or delete it from the checkout too.",
            file=sys.stderr,
        )
        return 1

    print(f"\n{len(absorptions)} absorbed service(s); every one carried every file it had.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
