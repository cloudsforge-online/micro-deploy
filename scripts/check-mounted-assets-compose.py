#!/usr/bin/env python3
"""A mounted bundle may not hand a browser a root-relative asset path.

THE DEFECT THIS EXISTS TO PREVENT, WHICH HAPPENED
--------------------------------------------------
Reported 2026-08-21: "the images in forge worlds are broken". A live sweep of
all fourteen mounts found root-relative asset references on five surfaces —
`/worlds`, `/worlds/emberkin`, `/worlds/aetherholm`, `/create` and `/foresight`
— every one of them a 404. `/worlds/emberkin` was the worst: the whole dex
rendered empty, because the five `game/data/*.json` reads went to the apex.

The mechanism is one sentence, and it is the same one that produced the
og:image defect in wave 3f:

    vite's `base` rewrites `src=` and `href=` in `index.html`, and the URLs it
    emits for statically imported assets. It does NOT rewrite a string literal
    that lives inside a module.

So `<img src="/mark-256.png">` written in a `.tsx` file keeps asking for
`<apex>/mark-256.png` after the bundle moves to `<apex>/create`. Nothing in the
repository notices. The bundle builds, the tests pass — several of the tests
that SHOULD have caught this were comparing the unmounted string against the
catalogue it came from, which is the same string twice — and the surface ships
with holes in it.

WHY THIS IS A DEPLOY-LEVEL CHECK AND NOT FOURTEEN REPO TESTS
-------------------------------------------------------------
Because the mount is not a fact any single repository owns. `basePath` is
declared in micro-ui's registry, the router strips it, nginx serves under it and
`BUNDLE_REPOS` below is the only place the surface key and the repository
directory are written down together. A repo-local test can assert that ITS
accessors compose; it cannot know that a fifteenth surface was mounted last week
and never got one. This walks the table, so a surface added to the registry is
covered the day it is added.

WHAT COUNTS AS AN OFFENCE
--------------------------
A root-relative literal ending in an asset extension, sitting where a browser
will fetch it verbatim:

    src="/a.png"              href="/a.svg"           poster="/a.mp4"
    src={'/a.png'}            fetch('/art/M.json')

and what does not, because something composes the mount first:

    src={publicPath('/a.png')}        fetch(publicPath('/art/M.json'))
    src={assetBase() + '/a.png'}      path: '/art/a.png'   (a catalogue row)

The last one is the important exemption. Generated catalogues — emberkin's and
aetherholm's `src/art/catalogue.ts`, worlds's `src/art/*.ts` — MUST go on
spelling the path nginx serves the file from, because their own tests
cross-reference those strings against the files under `public/`. The mount is
composed at the accessor that turns a row into a URL. So this checks the USE,
never the declaration, which is why it reads `src=`/`href=`/`fetch(` and not
bare strings.

COMMENTS ARE STRIPPED FIRST, AND THAT IS LOAD-BEARING
------------------------------------------------------
Four separate checks in this estate have failed by reading their own
explanation. Every fix for this defect leaves a comment behind that says what
the broken URL used to be — this file's own docstring contains `src="/a.png"`
twice. A scan for the ABSENCE of a pattern must not be able to see the prose
describing it, so `strip_comments()` runs before any match.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent

# Keyed on the SURFACE KEY, mapped to the repository directory. Kept in step
# with `check-base-paths-agree.py`, which reads the same pairing from the
# registry and fails if a mounted surface is missing from it — that check is the
# reason this table can be trusted to be complete.
BUNDLE_REPOS = {
    "journal": "journal-web",
    "exchange": "exchange-web",
    "market": "market-web",
    "create": "mint-web",
    "trade": "trade-web",
    "agora": "agora-web",
    "pool": "pool-web",
    "worlds": "worlds-web",
    "emberkin": "emberkin-web",
    "aetherholm": "aetherholm-web",
    "tessera": "tessera-web",
    "developers": "devportal-web",
    "explorer": "explorer-web",
    "foresight": "foresight-web",
}

ASSET = r"png|jpg|jpeg|svg|webp|gif|avif|ico|glb|gltf|woff2?|mp4|webm|json"

# An attribute a browser fetches verbatim, given a bare string literal. Both
# quoting shapes: `src="/a.png"` (plain JSX/HTML) and `src={'/a.png'}` (a brace
# holding nothing but a literal). A brace holding a CALL — `{publicPath('…')}` —
# does not match, which is the whole point.
ATTR = re.compile(
    r"""(?:src|href|poster|srcSet)\s*=\s*(?:"|'|\{\s*['"`])(/[A-Za-z0-9._/-]+\.(?:%s))\b"""
    % ASSET
)

# A fetch of an asset by bare literal. `fetch(publicPath('…'))` does not match.
FETCH = re.compile(r"""fetch\(\s*['"`](/[A-Za-z0-9._/-]+\.(?:%s))\b""" % ASSET)

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")


def strip_comments(text):
    """Blank out comments, preserving line count so reported lines stay true.

    Crude on purpose: a `//` inside a string literal (`'https://…'`) is
    truncated too. That can only ever HIDE a would-be offender, never invent
    one, and a root-relative asset path cannot contain `//` — so the trade is
    safe in the direction that matters.
    """
    text = BLOCK_COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
    return LINE_COMMENT.sub("", text)


def offences_in(path):
    """Every (line, url) this file hands a browser without composing the mount."""
    text = strip_comments(path.read_text(encoding="utf8", errors="replace"))
    found = []
    for pattern in (ATTR, FETCH):
        for m in pattern.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            found.append((line, m.group(1)))
    return found


def main():
    missing, offenders = [], []
    for key, repo in sorted(BUNDLE_REPOS.items()):
        src = MICRO / repo / "src"
        if not src.is_dir():
            missing.append(f"{key}: {repo}/src is not checked out")
            continue
        for path in sorted(src.rglob("*")):
            if path.suffix not in (".ts", ".tsx", ".js", ".jsx"):
                continue
            for line, url in offences_in(path):
                rel = path.relative_to(MICRO)
                offenders.append(f"  {rel}:{line}  {url}")

    for note in missing:
        print(f"skipped — {note}")

    if offenders:
        print(
            "\nThese hand a browser a root-relative asset path. The bundle is served\n"
            "from a subfolder of the apex, so each one resolves at the APEX ROOT and\n"
            "404s. vite's `base` does not rewrite a string literal inside a module.\n"
            "\n"
            "Compose the mount at the point of use — `publicPath('/x.png')` from the\n"
            "repository's own `src/lib/routes.ts` — and leave any generated catalogue\n"
            "spelling the path nginx serves the file from.\n"
        )
        print("\n".join(offenders))
        return 1

    print(f"OK — {len(BUNDLE_REPOS) - len(missing)} mounted bundles compose every asset URL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
