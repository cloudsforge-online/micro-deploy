#!/usr/bin/env python3
"""Compare every host port this repository pins against micro-org's derivation.

THE GAP THIS CLOSES
-------------------
`compose/docker-compose.estate.yml` said, above the sixteen frontends, that host
ports are derived — `4100 + the repository's index in deployableRepos()` — and
then said this, verbatim:

    `scripts/web-check.py` fails when this file and the registry disagree, so
    the drift cannot be silent.

THAT SCRIPT DID NOT EXIST. `scripts/` held nine files and none of them was it.
So the estate carried a comment naming a guard nobody had written, sitting
directly above the thing it claimed to guard — and when micro-org's REGISTRY was
swept from 46 rows to 70, the drift was in fact silent. The sweep INSERTED rows
mid-list instead of appending: four services ahead of the frontend block and five
frontends ahead of ops. Because the port is the INDEX, every row below an
insertion moved. `tessera` derived to 4125 against the 4140 pinned here, all
eleven original frontends slid +4, and the four hand-chosen surfaces were
reordered. Sixteen of this file's thirty-nine pins were wrong, and nothing said
so.

`tessera-web` landed on 4141 both ways. That is arithmetic coincidence, not
health, and it is the reason "two ports look fine" was never evidence: adopting
only the numbers somebody noticed would have left fourteen others wrong in a
shape that reads as fixed.

WHAT IT CHECKS
--------------
1. Every `127.0.0.1:<host>:<container>` in the estate compose file, keyed by the
   service that declares it, equals `4100 + index in deployableRepos()`.
2. The same for the host ports `scripts/estate-verify.sh` drives, because a
   verifier probing a port that has moved ONTO ANOTHER SERVICE does not fail —
   it passes, against the wrong container. That is the failure this estate is
   actually exposed to, and it is worse than a refused connection.
3. No two services share a host port.
4. A host port in the 4100+ block belonging to a name the registry does not
   carry is an error. Hand-chosen ports in the derived block are what put
   `tessera` on 4140 in the first place.

Registry rows with no container here (`emberkin`, `foresight`, `aetherholm`, and
the three ops services) are REPORTED, not failed: this compose file is not
obliged to serve every deployable, and a check that is permanently red for a
reason nobody intends to fix is a check that gets ignored — the same disease in
a different coat.

The order is read out of the registry by EXECUTING it, never by parsing it. A
regex over `registry.ts` would be a second, private copy of the very list whose
drift is the bug.

Deliberately dependency-free — regex, not PyYAML — for the reason
check-runbooks.py gives: a check that only runs where a library happens to be
installed is a check that stops running.

Exit 0 if every pin matches. Exit 1 otherwise, and NEVER skips: if micro-org
cannot be reached or the derivation will not run, that is a failure, not a pass.
A check that cannot run reports failure rather than success it did not establish.

    CF_ORG_DIR=/path/to/micro-org   override the sibling checkout (used to prove
                                    this script goes red when a row moves)
"""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
ORG = pathlib.Path(os.environ.get("CF_ORG_DIR") or (MICRO / "org"))

COMPOSE = ROOT / "compose" / "docker-compose.estate.yml"
VERIFY = ROOT / "scripts" / "estate-verify.sh"

BASE_PORT = 4100

# `estate-verify.sh` names its service URLs after the SURFACE, not always after the
# repository. Three do not lowercase to a registry row, and rather than let that be a
# private second naming scheme, every variable is resolved through here and an
# unresolvable one is an ERROR — so this table cannot rot quietly either.
VAR_ALIASES = {
    "HUB": "hub-api",
    "ADMIN": "admin-api",
    "GW": None,  # gateway, not a registry row
}

fails = []
notes = []


def bad(msg):
    fails.append(msg)


def derived_ports():
    """`4100 + index` for every deployable, read by running micro-org's own registry."""
    if not ORG.is_dir():
        print(f"FAIL: micro-org is not checked out at {ORG} — the derivation cannot be read.")
        print("      This is a failure, not a skip: the ports below would go unchecked.")
        sys.exit(1)

    script = (
        "import {deployableRepos} from './tools/registry.ts';"
        "console.log(JSON.stringify(deployableRepos().map(r=>r.name)))"
    )
    try:
        out = subprocess.run(
            ["node", "--import", "tsx", "-e", script],
            cwd=ORG, capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: could not run micro-org's registry derivation: {exc}")
        sys.exit(1)

    if out.returncode != 0:
        print(f"FAIL: micro-org's registry derivation exited {out.returncode}.")
        print(out.stderr.strip()[-2000:])
        sys.exit(1)

    # The registry prints one JSON line; anything else on stdout is tsx noise.
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("[")), None)
    if line is None:
        print("FAIL: micro-org's registry derivation produced no repository list.")
        print(out.stdout.strip()[-2000:])
        sys.exit(1)

    names = json.loads(line)
    return {name: BASE_PORT + i for i, name in enumerate(names)}


def compose_pins():
    """{service: (host_port, line_no)} for every 127.0.0.1 mapping in the estate file."""
    if not COMPOSE.exists():
        print(f"FAIL: {COMPOSE} does not exist.")
        sys.exit(1)

    pins = {}
    section = None   # the top-level key we are under
    service = None   # the 2-space key under `services:`

    for n, raw in enumerate(COMPOSE.read_text().splitlines(), 1):
        if re.match(r"^[A-Za-z_][\w-]*:", raw):
            section = raw.split(":", 1)[0]
            service = None
            continue
        if section != "services":
            continue
        m = re.match(r"^  ([a-z0-9][a-z0-9-]*):\s*$", raw)
        if m:
            service = m.group(1)
            continue
        # ── THIS REGEX USED TO BE `127\.0\.0\.1:(\d+):(\d+)` AND MATCHED NOTHING ──────────
        #
        # Not one of the forty-one pins in the estate file is written as a bare number. They are
        # all `127.0.0.1:${CF_PORT_BASE:-4}140:8080` — the leading digit is an environment
        # variable so a second estate can be brought up beside the first on 5xxx. `(\d+)` does not
        # match `${CF_PORT_BASE:-4}140`, so `compose_pins()` returned an EMPTY dict and this
        # script reported, in its own success line, "ok — all 0 compose pins ... match".
        #
        # So check 1 — the check this file was written for, the one whose absence let sixteen
        # ports drift silently during the 46→70 sweep — has been asserting nothing since the
        # `CF_PORT_BASE` templating was introduced. Checks 3 and 4 read the same dict and were
        # equally vacuous. The header above describes a guard that existed and did not run.
        #
        # A check that cannot fail is worse than no check, because the "ok" is read as evidence.
        # `zero_pins_is_a_failure()` below now makes emptiness itself a red, so this cannot
        # silently stop matching a third time.
        m = re.search(r'127\.0\.0\.1:(?:\$\{CF_PORT_BASE:-(\d+)\})?(\d+):(\d+)', raw)
        if m and service:
            # The base digit and the rest are concatenated the way compose interpolates them, so
            # `${CF_PORT_BASE:-4}` + `140` is 4140 — the number the registry derivation produces.
            host = f"{m.group(1) or ''}{m.group(2)}"
            pins[service] = (int(host), n)

    return pins


def zero_pins_is_a_failure(pins):
    """Finding no pins at all is a RED, not a clean run.

    The failure this exists for is the one recorded beside the regex above: the pattern stopped
    matching, every check that reads this dict quietly became a no-op, and the script kept printing
    a success line with a zero in it that nobody read as a problem. The estate compose file has had
    dozens of published ports for its whole life; zero is not a state it can legitimately be in.
    """
    if pins:
        return False
    print(
        "FAIL: no `127.0.0.1:<host>:<container>` mapping was found anywhere in the estate compose "
        "file. That is not a file with no pins — it is this script's pattern having stopped "
        "matching, which is what silently disabled checks 1, 3 and 4 once already. Fix the pattern "
        "rather than the expectation."
    )
    return True


def verify_pins():
    """{name: [(port, line_no), ...]} for the host ports estate-verify.sh drives.

    Two shapes, both carrying the name beside the number:
      NAME=${NAME:-http://127.0.0.1:4100}
      "hub-web 4126 /portfolio"
    """
    if not VERIFY.exists():
        print(f"FAIL: {VERIFY} does not exist.")
        sys.exit(1)

    pins = {}
    for n, raw in enumerate(VERIFY.read_text().splitlines(), 1):
        line = raw.strip()
        if line.startswith("#"):
            continue

        # THE `${PB}` FORM IS THE ONLY ONE ESTATE-VERIFY WRITES ANY MORE, AND THIS
        # PARSER MATCHED NONE OF IT.
        #
        # The pattern below wants a literal `127.0.0.1:4110`. estate-verify.sh moved
        # its 26 backend URLs to `127.0.0.1:${PB}110`, where `PB` is the port base,
        # and the regex stopped matching every one of them — while this script went
        # on printing "ok — all 42 compose pins and 15 driven ports match". The 15
        # were the surface-table lines below, which still use the bare-number shape.
        #
        # So a check that exists to prove estate-verify drives the ports the registry
        # derives was proving it for 15 of 41 lines and reporting success. Measured
        # 2026-08-28: 26 `${PB}` lines, 0 literal ones. A parser that silently matches
        # nothing is this repository's named defect, and it had it.
        #
        # Both shapes are accepted now. `zero_pins_is_a_failure` guards the compose
        # side against exactly this; the equivalent guard for THIS side is the count
        # assertion in main(), added with this fix.
        m = re.match(r'^([A-Z][A-Z0-9_]*)=\$\{\1:-https?://127\.0\.0\.1:\$\{PB\}(\d{3})\}', line)
        if m:
            var, port = m.group(1), int(f"{BASE_PORT // 1000}{m.group(2)}")
            if var in VAR_ALIASES:
                name = VAR_ALIASES[var]
                if name is None:
                    continue
            else:
                name = var.lower().replace("_", "-")
            pins.setdefault(name, []).append((port, n))
            continue

        m = re.match(r'^([A-Z][A-Z0-9_]*)=\$\{\1:-https?://127\.0\.0\.1:(\d+)\}', line)
        if m:
            var, port = m.group(1), int(m.group(2))
            if var in VAR_ALIASES:
                name = VAR_ALIASES[var]
                if name is None:
                    continue
            else:
                name = var.lower().replace("_", "-")
            pins.setdefault(name, []).append((port, n))
            continue

        m = re.match(r'^"([a-z0-9][a-z0-9-]*) (\d{4}) /', line)
        if m:
            pins.setdefault(m.group(1), []).append((int(m.group(2)), n))

    return pins


def main():
    derived = derived_ports()
    print(f"registry: {len(derived)} deployables, {BASE_PORT}–{BASE_PORT + len(derived) - 1}"
          f"  ({ORG})")

    compose = compose_pins()
    # Before anything reads it: an empty dict means the pattern stopped matching, not that the
    # file is clean. See the note in `compose_pins`.
    if zero_pins_is_a_failure(compose):
        return 1
    verify = verify_pins()
    driven = sum(len(v) for v in verify.values())
    # THE SAME GUARD THE COMPOSE SIDE ALREADY HAS, FOR THE SIDE THAT DID NOT HAVE IT.
    #
    # `zero_pins_is_a_failure` was written because the compose regex once stopped
    # matching and every check downstream became a silent no-op. The verify side had
    # no such guard and then suffered a subtler version of it: the pattern matched
    # the 15 surface-table lines and NONE of the 26 backend URLs, so this script
    # reported "15 driven ports match" and looked healthy while checking 37% of the
    # file. A floor rather than a zero-check, because 15 is exactly the number that
    # looked fine.
    #
    # The floor is deliberately below the current 41 so that legitimately deleting a
    # service does not fail the build, and far above 15 so that losing a whole shape
    # cannot pass again.
    if driven < 30:
        print(f"FAIL: only {driven} driven port(s) parsed out of {VERIFY.name}. Both shapes "
              f"together have matched 41; a number this low means a pattern stopped matching "
              f"and the checks below are reading an almost-empty dict.")
        return 1
    print(f"pinned:   {len(compose)} in {COMPOSE.name}, "
          f"{driven} in {VERIFY.name}\n")

    # ── 1 & 4. every compose pin against the derivation ──────────────────────
    for service, (port, line) in sorted(compose.items(), key=lambda kv: kv[1][0]):
        want = derived.get(service)
        if want is None:
            bad(f"{COMPOSE.name}:{line}: '{service}' pins {port} in the derived 4100+ block "
                f"but micro-org's registry has no row for it — this port is CHOSEN, and a chosen "
                f"port in a derived block is how 'tessera' ended up on 4140. Add the row.")
        elif port != want:
            bad(f"{COMPOSE.name}:{line}: '{service}' pins {port}, registry derives {want} "
                f"(index {want - BASE_PORT}). Recompute — a row was inserted ahead of it.")

    # ── 3. collisions ────────────────────────────────────────────────────────
    seen = {}
    for service, (port, line) in compose.items():
        if port in seen:
            bad(f"{COMPOSE.name}:{line}: '{service}' and '{seen[port][0]}' "
                f"(line {seen[port][1]}) both bind host port {port}.")
        else:
            seen[port] = (service, line)

    # ── 2. what estate-verify.sh actually drives ─────────────────────────────
    for name, hits in sorted(verify.items()):
        want = derived.get(name)
        for port, line in hits:
            if want is None:
                bad(f"{VERIFY.name}:{line}: drives 127.0.0.1:{port} for '{name}', which "
                    f"micro-org's registry does not carry — the name cannot be resolved to a port, "
                    f"so nothing can say whether {port} is right.")
            elif port != want:
                owner = next((s for s, p in derived.items() if p == port), None)
                whose = (f" — {port} now derives to '{owner}', so this check would pass against "
                         f"THE WRONG CONTAINER" if owner and owner != name else "")
                bad(f"{VERIFY.name}:{line}: drives {port} for '{name}', registry derives "
                    f"{want}{whose}.")

    # ── rows with no container here ──────────────────────────────────────────
    absent = [n for n in derived if n not in compose]
    if absent:
        notes.append("registry rows with no container in this compose file (not a failure — "
                     "this file is not obliged to serve every deployable):")
        for name in absent:
            notes.append(f"  {derived[name]}  {name}")

    for note in notes:
        print(note)
    if notes:
        print()

    if fails:
        for f in fails:
            print(f"FAIL  {f}")
        print(f"\n{len(fails)} port(s) disagree with micro-org's registry.")
        print("Recompute, do not adopt individual numbers: the ports are positional, so "
              "everything below an inserted row moves together.")
        return 1

    print(f"ok — all {len(compose)} compose pins and "
          f"{sum(len(v) for v in verify.values())} driven ports match the registry's derivation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
