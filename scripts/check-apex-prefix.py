#!/usr/bin/env python3
"""No registry subdomain may collide with the way an environment names itself.

WHAT CHANGED ON 2026-08-05, AND WHY THE CHECK MOVED WITH IT
-----------------------------------------------------------
This file used to guard an APEX PREFIX. Two environments shared one apex by
prefixing it:

    mainnet   cloudsforge.online
    testnet   testnet.cloudsforge.online       hub.testnet.cloudsforge.online

That shape was configured and UNREACHABLE. Cloudflare's Universal SSL is
`*.cloudsforge.online` plus the apex; a wildcard matches exactly ONE label; so
every two-label testnet hostname failed the TLS handshake at Cloudflare's edge
before a request reached this estate. Advanced Certificate Manager covers a
two-label wildcard, is paid, and is not bought.

So the environment moved INSIDE the first label, where one wildcard covers it:

    mainnet   hub.cloudsforge.online           the unadorned form
    testnet   hub-testnet.cloudsforge.online   the label `testnet`, suffixed
              testnet.cloudsforge.online       the apex surface, which has no
                                               subdomain to suffix, so the
                                               environment label stands alone

THE DEFECT THIS EXISTS TO PREVENT, WHICH HAS NOT HAPPENED YET
-------------------------------------------------------------
Every browser bundle resolves its sibling hostnames through `cloudsforgeHosts()`
(ui/packages/ui/src/index.tsx). It does not read an environment variable — it
reads `window.location.hostname` and splits the first label into a surface and
an environment, through `splitEnvLabel()` (ui/packages/ui/src/surfaces.ts).

That split is unambiguous only while no registry subdomain can be mistaken for
one half of it. There are now TWO ways to break it, where the prefix scheme had
one, and they fail in OPPOSITE directions:

  1. A SURFACE WHOSE SUBDOMAIN IS AN ENVIRONMENT LABEL — say a testnet dashboard
     given `subdomain: 'testnet'`. Then

         testnet.cloudsforge.online  ->  splitEnvLabel('testnet') = env testnet

     and the page served at that MAINNET surface resolves every sibling link,
     every sign-in redirect and every API base onto TESTNET. It is also the
     address the testnet apex page itself is served on, so the two surfaces are
     the same hostname and one of them cannot be routed at all.

  2. A SURFACE WHOSE SUBDOMAIN ENDS IN `-<label>` — say `hub-testnet`. Then

         hub-testnet.cloudsforge.online -> splitEnvLabel = surface hub, env testnet

     and the mainnet surface `hub-testnet` resolves every sibling onto testnet;
     or, read the other way, testnet's Hub is indistinguishable from a mainnet
     surface that happens to be called `hub-testnet`.

Either one is silent. Nothing errors, every page loads, and every address is
real — with real balances on the other side of them. It would be found by a
person noticing that a button on one environment logged them into the other.

The same is true of any other label an environment is ever given — `staging`,
`preview`, `dev` — so this checks the whole set rather than `testnet` alone.

WHERE THE SET OF LABELS LIVES, AND WHY NOT HERE
-----------------------------------------------
`ENV_LABELS`, exported from `ui/packages/ui/src/surfaces.ts` and read by running
that module — the same way `surface-routes.py` and `cloudflared/gen.py` read
`SURFACES`. It used to be a table in this file, and a table here would be a
SECOND copy of a list that `cloudsforgeHosts()` already has to hold in order to
resolve anything at all. This estate has paid four times for a hand-maintained
copy of a list the registry already carried; a fifth would be this one.

WHY A CHECK AND NOT A CODE CHANGE — WHICH IS NOW ONLY HALF TRUE
---------------------------------------------------------------
The version of this file that guarded the prefix argued that making
`cloudsforgeHosts()` aware of environments was refused, because it would mean
passing the apex in as a build-time variable and losing the property that ONE
build works everywhere.

Half of that survived and half of it did not, and the difference is worth
stating rather than quietly dropping. `cloudsforgeHosts()` IS environment-aware
now — it has to be, because both environments share an apex and the first label
is the only thing that separates them. What it still does not do is read a
build-time variable: the browser's own hostname still tells the bundle where it
is, and one build still works on mainnet, on testnet, on a preview deployment
and on localhost. That was the property worth keeping, and it was kept.

So this check is no longer a substitute for a code change. It guards the code
change's one assumption: that a first label splits into a surface and an
environment exactly one way.

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


def read_registry():
    """`(surfaces, env_labels)`, by running micro-ui's own module.

    Both come from the same run. Reading the labels from one source and the
    surfaces from another is how the two would come to disagree about which
    words are environments, which is the exact defect below.
    """
    if not UI.is_dir():
        print(f"FAIL: micro-ui is not checked out at {UI} — the registry cannot be read.")
        print("      This is a failure, not a skip: the collision would go unchecked.")
        sys.exit(1)
    script = (
        "import {SURFACES, ENV_LABELS} from './src/surfaces.ts';"
        "console.log(JSON.stringify({"
        "surfaces: SURFACES.map(s=>({key:s.key,subdomain:s.subdomain})),"
        "envLabels: [...ENV_LABELS]}))"
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
    line = next((l for l in reversed(out.stdout.splitlines()) if l.startswith("{")), None)
    if line is None:
        print("FAIL: micro-ui's registry produced no surface list.")
        print("      `ENV_LABELS` may have been renamed or removed — if it has, the labels this "
              "check guards are no longer declared anywhere and `cloudsforgeHosts()` cannot be "
              "splitting hostnames the way this file describes.")
        sys.exit(1)
    doc = json.loads(line)
    if not doc.get("envLabels"):
        print("FAIL: micro-ui exports ENV_LABELS, and it is empty.")
        print("      An empty set makes this check pass by covering nothing, and makes "
              "`splitEnvLabel()` recognise no environment at all.")
        sys.exit(1)
    return doc["surfaces"], sorted(doc["envLabels"])


def main():
    surfaces, labels = read_registry()
    fails = []
    for s in surfaces:
        sub = s["subdomain"]
        if not sub:
            continue  # the apex surface has no label of its own to collide with

        if sub in labels:
            fails.append(
                f"registry surface '{s['key']}' takes the subdomain '{sub}', which is an "
                f"ENVIRONMENT LABEL.\n"
                f"       `splitEnvLabel('{sub}')` reads that hostname as the {sub} environment's "
                f"apex surface, so `https://{sub}.<apex>` is BOTH this surface and that "
                f"environment's front page. Whichever of the two a browser lands on resolves "
                f"every sibling link, sign-in redirect and API base into the OTHER environment. "
                f"Nothing errors and every address is real.\n"
                f"       Give the surface a different subdomain, or drop '{sub}' from ENV_LABELS "
                f"in ui/packages/ui/src/surfaces.ts if that environment will never exist."
            )
            continue

        # The second hazard, which the apex-prefix scheme did not have: a subdomain that ENDS in
        # an environment label. Checked against the same list rather than against `-testnet`
        # alone, so reserving a sixth label in the registry extends this without an edit here.
        hit = next((lab for lab in labels if sub.endswith(f"-{lab}")), None)
        if hit:
            head = sub[: -(len(hit) + 1)]
            fails.append(
                f"registry surface '{s['key']}' takes the subdomain '{sub}', which ENDS IN the "
                f"environment label '-{hit}'.\n"
                f"       `splitEnvLabel('{sub}')` reads that hostname as the surface '{head}' on "
                f"the {hit} environment, so `https://{sub}.<apex>` is BOTH this surface on the "
                f"unadorned environment and '{head}' on {hit}. A page on either resolves every "
                f"sibling address into the other. Nothing errors and every address is real.\n"
                f"       Rename the surface so its subdomain does not end in '-{hit}'."
            )

    if fails:
        print()
        for f in fails:
            print(f"  FAIL {f}")
        print(f"\n{len(fails)} environment-label collision(s).")
        return 1
    print(f"ok — {len(surfaces)} registry surface(s); none is, and none ends in, any of the "
          f"{len(labels)} environment label(s): {', '.join(labels)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
