#!/usr/bin/env python3
"""No registry subdomain may collide with an environment's apex prefix.

THE DEFECT THIS EXISTS TO PREVENT, WHICH HAS NOT HAPPENED YET
-------------------------------------------------------------
Two environments share one apex by prefixing it:

    mainnet   cloudsforge.online
    testnet   testnet.cloudsforge.online

Every browser bundle resolves its sibling hostnames through `cloudsforgeHosts()`
(ui/packages/ui/src/index.tsx:154-162), which does not read an environment
variable. It derives the apex from `window.location.hostname` by stripping the
first label — but ONLY when that label is a known registry subdomain:

    const apex = parts.length > 2 && KNOWN_SUBS.has(first) ? parts.slice(1).join('.') : host

That conditional is the entire reason a `testnet.` prefix needs no code change,
and it is also the entire risk. `KNOWN_SUBS` is every subdomain in the registry
plus `www` (surfaces.ts). Today it contains no `testnet`, so:

    hub.testnet.cloudsforge.online  ->  first='hub'      in KNOWN_SUBS  -> apex=testnet.cloudsforge.online   CORRECT
    testnet.cloudsforge.online      ->  first='testnet'  NOT in it      -> apex=testnet.cloudsforge.online   CORRECT

Add one registry row with `subdomain: 'testnet'` — a testnet dashboard, say, or a
faucet given its own host — and the second line silently becomes:

    testnet.cloudsforge.online      ->  first='testnet'  IN KNOWN_SUBS  -> apex=cloudsforge.online           WRONG

The bare testnet apex would then resolve EVERY sibling link, every sign-in
redirect, every API base and every telemetry post to **mainnet**. A test
environment quietly handing its users to production is the worst shape this class
of defect can take: nothing errors, every page loads, and the addresses are all
real. It would be found by a person noticing that a testnet button logged them
into the live estate.

The same is true of any other prefix an environment is ever given — `staging.`,
`preview.`, `dev.` — so this checks the whole set rather than `testnet` alone.

WHY A CHECK AND NOT A CODE CHANGE
---------------------------------
Making `cloudsforgeHosts()` aware of environment prefixes was considered and
refused. It would mean passing the apex in rather than deriving it, which is a
build-time variable per environment — and the single most valuable property this
estate's frontends have is that ONE build works everywhere because the browser
tells it where it is (index.tsx:143-152 argues this). Trading that away to
prevent a collision that has not happened is a bad trade. A check costs nothing
and fails loudly on the day it would matter.

Exit 0 when no collision exists. Exit 1 otherwise. NEVER skips — a check that
cannot run reports failure rather than a success it did not establish.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
UI = MICRO / "ui" / "packages" / "ui"

# ── the labels an environment prefixes the shared apex with ──────────────────
#
# `testnet` is deployed (compose/env/traefik.testnet.env). The rest are reserved:
# they cost nothing to forbid now and each one is a hostname somebody will
# eventually want for an environment rather than for a product.
ENV_PREFIXES = {
    "testnet": "the second environment on the MicroServer — compose/env/traefik.testnet.env",
    "staging": "reserved for an environment; forbidding it now costs nothing",
    "preview": "reserved for an environment; forbidding it now costs nothing",
    "dev": "reserved for an environment; forbidding it now costs nothing",
    "mainnet": "reserved: symmetrical with `testnet`, should the apex ever be prefixed both ways",
}


def registry_subdomains():
    if not UI.is_dir():
        print(f"FAIL: micro-ui is not checked out at {UI} — the registry cannot be read.")
        print("      This is a failure, not a skip: the collision would go unchecked.")
        sys.exit(1)
    script = (
        "import {SURFACES} from './src/surfaces.ts';"
        "console.log(JSON.stringify(SURFACES.map(s=>({key:s.key,subdomain:s.subdomain}))))"
    )
    try:
        out = subprocess.run(["node", "--import", "tsx", "-e", script],
                             cwd=UI, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"FAIL: could not run micro-ui's registry: {exc}")
        sys.exit(1)
    if out.returncode != 0:
        print(f"FAIL: micro-ui's registry exited {out.returncode}.")
        print(out.stderr.strip()[-2000:])
        sys.exit(1)
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("[")), None)
    if line is None:
        print("FAIL: micro-ui's registry produced no surface list.")
        sys.exit(1)
    return json.loads(line)


def main():
    surfaces = registry_subdomains()
    fails = []
    for s in surfaces:
        sub = s["subdomain"]
        if sub in ENV_PREFIXES:
            fails.append(
                f"registry surface '{s['key']}' takes the subdomain '{sub}', which is an "
                f"ENVIRONMENT PREFIX ({ENV_PREFIXES[sub]}).\n"
                f"       `KNOWN_SUBS` now contains '{sub}', so `cloudsforgeHosts()` strips it "
                f"from the bare apex `{sub}.cloudsforge.online` and resolves every sibling "
                f"link, sign-in redirect and API base on that environment to "
                f"`cloudsforge.online` — MAINNET. Nothing errors and every address is real.\n"
                f"       Give the surface a different subdomain, or drop '{sub}' from "
                f"ENV_PREFIXES if that environment no longer exists."
            )

    if fails:
        print()
        for f in fails:
            print(f"  FAIL {f}")
        print(f"\n{len(fails)} environment-prefix collision(s).")
        return 1
    print(f"ok — {len(surfaces)} registry surface(s), none collides with the "
          f"{len(ENV_PREFIXES)} environment prefix(es): {', '.join(sorted(ENV_PREFIXES))}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
