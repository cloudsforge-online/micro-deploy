#!/usr/bin/env python3
"""A path a module REMOUNTED has a gateway rewrite, or the caller reaches the wrong module.

WHY THIS EXISTS
---------------
It exists because the thing it checks shipped broken, to production, and stayed
broken for a day with nothing anywhere reporting a fault.

Merging services into one process makes route matching FIRST-WINS across one flat
table. When two modules declare the same path, the loser is not an error — it is a
handler that is never called, in a module whose own test suite still passes
completely. The estate's rule for that collision is:

    the PUBLIC owner — the module a caller outside the estate already addresses —
    keeps the bare path, and the other module REMOUNTS under a namespace.

**A remount inside the process is only half of that rule.** The bytes on the wire
still say the bare path, because the bundle that sends them was not changed and
must not have to be. So the router that carries those bytes has to rewrite them.

WHAT HAPPENED WHEN THE SECOND HALF WAS SKIPPED
----------------------------------------------
Wave M5b remounted tessera's four `/v1/listings…` routes so that market could keep
the bare path, and did not touch the gateway. Measured against the live estate on
2026-08-30, through the tunnel with a Host header so no CDN hop is in the answer:

    GET /worlds/tessera/v1/listings/x/risk   404, error code `not_found`
    GET /worlds/tessera/v1/listings          200, an empty list, UNAUTHENTICATED
    GET /worlds/tessera/v1/tessera/listings  401

The 404 on the first line is MARKET's "no such record" — a genuine route miss on
that process says `no route for GET …` instead, which is how the two were told
apart. So every signed-in user's tessera listings rendered EMPTY, `POST
/v1/listings` from tessera-web reached market's create handler, and the third line
is where tessera's own routes were actually living: at an address nothing called.

Nothing could have caught it. The remount is in one repository, the router in
another; both are individually correct, and every test on both sides is green.

WHAT THIS CHECKS
----------------
It derives the requirement from the SOURCE rather than from a list maintained here:

  1. Scrape every `agora/src/**/server.ts` for an exported `REMOUNTED_PATHS`
     object literal, plus the `MOUNT_PREFIX`/`TITLE_MOUNT_PREFIX`/`OPERATOR_PREFIX`
     constant it is built from. A module that adds a remount is covered the day it
     adds it, with no edit here.
  2. For each remounted path, require SOME `replacePathRegex` middleware in the
     gateway whose regex matches the bare path and whose replacement produces the
     remounted one.
  3. Require that middleware to be ATTACHED to at least one router — a middleware
     defined and never referenced is the same outage with an extra file in it.

WHAT IT DELIBERATELY DOES NOT CHECK
-----------------------------------
WHICH router. A remount can be reached by several hostnames (tessera's is on two),
and enumerating them here would be this file guessing at a topology `estate-web.yml`
already states. The failure this exists to prevent is a rewrite that is ABSENT, not
one attached to four routers where three would do.

Nor does it check the modules whose remount is not a gateway concern at all. There
is one such module and the list used to have two: aetherholm was exempted on the
ground that `worlds` computes a title's address from its registered base URL, so
"no request for these paths ever passes through Traefik". That was true of WORLDS
and false of the estate — two routers in `estate-web.yml` carry `/v1` for that
title, and the first M5d deploy answered `GET /worlds/aetherholm/v1/title` with
TESSERA's descriptor. The exemption is deleted, not reworded.

Its two paths are FROZEN CONSTANTS imported from `@cloudsforge/contracts-worlds`
rather than string literals, so this file resolves them out of the contracts
checkout. It used to record such a pair as "exists, value unknown" and pass; that
is the shape the aetherholm hole had, and an unresolvable constant is now a
FAILURE — a path whose value this file cannot read is a path it cannot check.

Exit 0 when every remount has a rewrite. Exit 1 otherwise, and NEVER skips: a check
that cannot run reports failure rather than a success it did not establish.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
AGORA = MICRO / "agora" / "src"
# The frozen paths two titles share are declared here, not in either title. Read rather
# than mirrored: a literal copied into this file would agree with itself for ever.
CONTRACTS = MICRO / "contracts" / "packages"
GATEWAY = ROOT / "gateway" / "dynamic"

# ── REMOUNTS THAT ARE NOT A GATEWAY CONCERN, AND WHY ─────────────────────────
#
# `<module dir>` -> the reason no `replacePathRegex` can or should carry it. An
# entry here is a CLAIM: if the module ever stops remounting, this file fails on
# the stale entry, exactly as `EXPECTED_UNROUTED` in surface-routes.py does.
NOT_A_GATEWAY_REWRITE = {
    "community": (
        "community has no router, no hostname and no `cf-svc-community` — it is reached only "
        "in-process and by service name, so no caller sends it a bare path through Traefik. Its "
        "two remounts are the INTERNAL side of collisions whose public owners are devplatform "
        "(`/v1/scopes`) and agora itself (`/v1/posts/:id`); those two keep the bare path and are "
        "already routed. The claim that community is unrouted is CHECKED below, not trusted."
    ),
}

fails = []
notes = []


def bad(msg):
    fails.append(msg)


def contract_constant(name):
    """The value of `export const <name> = '…'` in the contracts checkout, or None.

    Both titles get these two paths from ONE package, which is why they collide at all, and it is
    also why this reads the package rather than either title: the day the constant moves, this file
    follows it instead of comparing a stale copy against a live gateway.

    A missing contracts checkout is not treated as "not found" quietly — the caller turns None into
    a failure, and the count assertion below makes an empty scan impossible to mistake for a clean
    one.
    """
    if not CONTRACTS.is_dir():
        return None
    for path in sorted(CONTRACTS.glob("*/src/*.ts")):
        found = re.search(
            rf"^export const {re.escape(name)}\s*=\s*'([^']+)'",
            path.read_text(encoding="utf8"),
            re.M,
        )
        if found:
            return found.group(1)
    return None


def module_remounts():
    """`{module dir: {bare path: remounted path}}`, read from each module's server.ts."""
    if not AGORA.is_dir():
        print(f"FAIL: micro-agora is not checked out at {AGORA} — no remount could be read.")
        print("      This is a failure, not a skip: every remount below would go unchecked.")
        sys.exit(1)
    out = {}
    for path in sorted(AGORA.rglob("server.ts")):
        text = path.read_text(encoding="utf8")
        if "export const REMOUNTED_PATHS" not in text:
            continue
        rel_dir = path.relative_to(AGORA).parent.as_posix()
        block = re.search(
            r"export const REMOUNTED_PATHS[^=]*=\s*Object\.freeze\(\{(.*?)\}\)", text, re.S
        )
        if not block:
            # ── A DERIVED MAP, WHICH IS A BLANKET REMOUNT ────────────────────────────────
            #
            # hub builds `REMOUNTED_PATHS` from its own route table rather than writing a
            # literal, precisely so a route ADDED there is remounted without anyone
            # remembering to. There is nothing for the literal scraper above to read, and
            # SKIPPING would be the worst possible answer — a module whose whole surface
            # moved, reported as having moved nothing.
            #
            # So a `MOUNT_PREFIX` beside a derived map is read as a blanket claim: every
            # `/v1/<x>` becomes `<PREFIX>/<x>`. A module that exports neither shape FAILS.
            prefix = re.search(r"export const MOUNT_PREFIX\s*=\s*'([^']+)'", text)
            if prefix is None:
                bad(
                    f"{rel_dir}/server.ts exports REMOUNTED_PATHS in a shape this checker cannot "
                    "read, and no MOUNT_PREFIX beside it. It is not skipped: an unreadable remount "
                    "is indistinguishable from an unrewritten one, and the second is an outage."
                )
                continue
            out[rel_dir] = {"/v1/<any>": f"{prefix.group(1)}/<any>"}
            continue
        # The prefix constants a remount may be built from. Read from the same file, so a
        # renamed prefix cannot leave this resolving a stale literal.
        prefixes = dict(
            re.findall(r"export const ([A-Z_]*PREFIX)\s*=\s*'([^']+)'", text)
        )
        pairs = {}
        for m in re.finditer(r"'([^']+)':\s*[`']([^`']*)[`']", block.group(1)):
            pairs[m.group(1)] = m.group(2)
        for m in re.finditer(r"'([^']+)':\s*`\$\{([A-Z_]+)\}([^`]*)`", block.group(1)):
            prefix = prefixes.get(m.group(2))
            if prefix is None:
                bad(f"{path.name}: REMOUNTED_PATHS uses {m.group(2)}, which this file cannot resolve")
                continue
            pairs[m.group(1)] = f"{prefix}{m.group(3)}"
        # `[FROZEN_CONSTANT]: `${PREFIX}${FROZEN_CONSTANT}`` — aetherholm's shape.
        for m in re.finditer(r"\[([A-Z_]+)\]:\s*`\$\{([A-Z_]+)\}\$\{([A-Z_]+)\}`", block.group(1)):
            imported = re.search(rf"^export const {m.group(1)}\s*=\s*'([^']+)'", text, re.M)
            value = imported.group(1) if imported else contract_constant(m.group(1))
            if value is None:
                # ── AND THIS IS A FAILURE, WHERE IT USED TO BE A PASS ────────────────────────
                #
                # The old branch recorded `<NAME>` and reported "value lives in contracts; pair
                # exists". A pair that exists is not a pair that is ROUTED, and aetherholm's two
                # went a whole release with no rewrite behind exactly that message.
                bad(
                    f"{rel_dir}/server.ts remounts the frozen constant {m.group(1)}, and neither "
                    f"that file nor {CONTRACTS} declares its value. The remount cannot be checked "
                    "against the gateway, and an unchecked remount is how the wrong module answers."
                )
                continue
            pairs[value] = f"{prefixes.get(m.group(2), '')}{value}"
        if not pairs:
            bad(
                f"{rel_dir}/server.ts declares REMOUNTED_PATHS and this checker read NO pairs out "
                "of it. Failing rather than reporting zero remounts, for the reason above."
            )
            continue
        out[rel_dir] = pairs
    return out


def gateway_text():
    files = sorted(GATEWAY.glob("*.yml"))
    if not files:
        print(f"FAIL: no gateway files under {GATEWAY} — nothing could be checked.")
        sys.exit(1)
    return {p.name: p.read_text(encoding="utf8") for p in files}


def rewrites(texts):
    """`[(name, regex, replacement, attached)]` for every replacePathRegex middleware."""
    found = []
    for name, text in texts.items():
        for m in re.finditer(
            r"^    ([a-z0-9-]+):\n      replacePathRegex:\n"
            r"        regex: \"([^\"]+)\"\n        replacement: \"([^\"]+)\"",
            text,
            re.M,
        ):
            mw = m.group(1)
            attached = any(
                re.search(rf"middlewares: \[[^\]]*\b{re.escape(mw)}\b", t) for t in texts.values()
            )
            found.append((mw, m.group(2), m.group(3), attached, name))
    return found


def covers(regex, replacement, bare, remounted):
    """Does this middleware turn `bare` into `remounted`?

    `<any>` is the blanket form: a probe path is substituted on both sides, so a
    `^/v1/(.*)` rule is checked by what it does to a real path rather than by its text.
    """
    if bare.endswith("<any>"):
        probe = "zzz-probe/x"
        bare = bare.replace("<any>", probe)
        remounted = remounted.replace("<any>", probe)
    try:
        compiled = re.compile(regex)
    except re.error:
        return False
    match = compiled.match(bare)
    if not match:
        return False
    # Traefik's `$1` is Go's; Python wants `\1`. Only positional groups are used here.
    produced = compiled.sub(re.sub(r"\$(\d)", r"\\\1", replacement), bare)
    return produced == remounted


def main():
    remounts = module_remounts()
    if not remounts:
        print("FAIL: no module declares REMOUNTED_PATHS — the scraper has stopped matching.")
        print("      An empty result is indistinguishable from 'nothing is remounted', so it fails.")
        sys.exit(1)

    texts = gateway_text()
    mws = rewrites(texts)

    for module in sorted(NOT_A_GATEWAY_REWRITE):
        if module not in remounts:
            bad(
                f"{module} is declared in NOT_A_GATEWAY_REWRITE but remounts nothing — the "
                "claim has stopped being true and would silently exempt a future remount"
            )

    # The "not publicly routed" exemption, CHECKED. A module that gains a gateway service or
    # router has gained the caller the exemption says it does not have, and its remounts need a
    # rewrite from that moment — which is exactly the shape of an outage nobody would look for.
    joined = "\n".join(texts.values())
    for module in sorted(NOT_A_GATEWAY_REWRITE):
        leaf = module.rsplit("/", 1)[-1]
        if "no router" not in NOT_A_GATEWAY_REWRITE[module]:
            continue
        hits = re.findall(rf"^    (cf-[a-z0-9-]*{re.escape(leaf)}[a-z0-9-]*):", joined, re.M)
        if hits:
            bad(
                f"{module} is exempted on the ground that it has no gateway router, and the "
                f"gateway now defines {', '.join(sorted(set(hits)))}. Either the exemption is "
                "stale or a remount has just become reachable at its bare path."
            )

    for module, pairs in sorted(remounts.items()):
        if module in NOT_A_GATEWAY_REWRITE:
            notes.append(f"  ok   {module:22} {len(pairs)} remount(s), exempt: {NOT_A_GATEWAY_REWRITE[module][:60]}…")
            continue
        for bare, remounted in sorted(pairs.items()):
            if bare.startswith("<"):
                bad(f"{module}: `{bare}` was never resolved to a path — see contract_constant()")
                continue
            hit = [m for m in mws if covers(m[1], m[2], bare, remounted)]
            if not hit:
                bad(
                    f"{module}: `{bare}` is remounted to `{remounted}` in the merged process and NO "
                    "gateway `replacePathRegex` produces that. Every caller still sends the bare "
                    "path, so it reaches whichever module kept it — a 200 from the wrong module, "
                    "which is what wave M5b shipped for tessera's listings."
                )
                continue
            live = [m for m in hit if m[3]]
            if not live:
                bad(
                    f"{module}: `{bare}` has a rewrite ({hit[0][0]}) that NO router references. "
                    "A middleware nobody attaches is the same outage with an extra file in it."
                )
                continue
            notes.append(f"  ok   {module:22} {bare} -> {remounted}  via {live[0][0]} ({live[0][4]})")

    for line in notes:
        print(line)
    print()
    if fails:
        for f in fails:
            print(f"FAIL {f}")
        print(f"\n{len(fails)} remount(s) without a gateway rewrite.")
        sys.exit(1)
    total = sum(len(p) for p in remounts.values())
    print(
        f"ok — {len(remounts)} module(s) remount {total} path(s); every one either has an attached "
        "rewrite or a declared reason it needs none."
    )


main()
