#!/usr/bin/env python3
"""One base path, written in five places, and none of them derived from the others.

WHY THIS EXISTS
---------------
`deploy/docs/apex-consolidation.md` moves a surface off its own subdomain and
mounts it at a subfolder of the apex. The address that results — `/journal` — is
not one setting. It is FIVE independent statements in four repositories, each
consumed by a different piece of software at a different moment, and every one of
them has to say the same string:

    1. the registry     ui/packages/ui/src/surfaces.ts   `basePath: '/journal'`
       — what every OTHER bundle in the estate composes its links from
    2. the router       journal-web/src/lib/routes.ts    `export const BASE`
       — what the bundle's own links, canonicals and feed URL are built from
    3. the build        journal-web/vite.config.ts       `base: '/journal/'`
       — what goes in front of every hashed asset name in index.html
    4. the server       journal-web/nginx.conf           `location /journal/…`
       — where the container will actually answer
    5. the gateway      deploy/gateway/dynamic/estate-web.yml
       — which requests on the apex reach that container at all
    6. the API base     <repo>/src/lib/hosts.ts          `apiBase()`
       — where the RUNNING page sends `/v1/…`, which is the mount again and is
         the one statement that is a derivation rather than a literal

Nothing in the stack cross-checks them, and each disagreement FAILS DIFFERENTLY
and none of them fails loudly:

    1 vs 2   the estate's links point at `/journal`; the bundle thinks it lives
             at `/blog` and every internal link, `<link rel=canonical>` and
             `<loc>` in the sitemap names an address the gateway does not route.
             The landing page works. Everything one click deeper 404s.
    2 vs 3   the HTML is correct and the ASSETS are not: `index.html` asks for
             `/blog/assets/index-a1b2.js`, nginx has no such location, and the
             browser gets a 404 body with `content-type: text/html` where a
             module was expected. The page renders BLANK with one console line.
    3 vs 4   the same, one layer down and reversed — the assets are built for a
             path the server does not serve.
    4 vs 5   the gateway routes `/journal` to a container that answers 404 on it.
             Traefik reports a healthy backend; the reader gets nginx's default.
    any vs 6 the page loads perfectly, every asset arrives, every link is right —
             and every API call goes to the APEX ROOT instead of the mount,
             where micro-site answers its own SPA shell or a 404, always as
             `text/html`. Every panel renders a failure state and the network
             tab is entirely green. `micro-web-template` shipped exactly this
             for the fortnight after wave 3, because its CI had no pushes to
             run on, and it is the file every new surface is scaffolded from.

Every one of those is a 200-shaped failure somewhere upstream of the actual
mistake, which is why this is a check and not a convention.

THE PAIRWISE READING IS THE POINT
---------------------------------
This does not "look for /journal". It reads all five, compares them to the
REGISTRY as the single source, and names WHICH TWO disagree — because the five
live in four repositories and the useful output is not "something is wrong" but
"vite.config.ts says /blog and the registry says /journal".

SCOPE: SURFACES THAT SERVE THEIR OWN BUNDLE AT A PATH
-----------------------------------------------------
`basePath` alone does not mean "mounted at a subfolder". `wallet` and `signin`
are `basePath` rows that are ROUTES INSIDE Forge Hub, and `faucet` is a route on
the Network site; those have no repository, no vite config and no nginx of their
own, and demanding one would fail on three correct rows. The registry answers the
question itself with `servesOwnBundle()`, which discriminates on the dev port —
see its comment for why that is exact rather than a heuristic — and this reads
that function rather than re-deciding it here.

A sibling checkout that is absent is REPORTED and skipped for parts 2-4, in this
directory's usual style: CI checks out `deploy`, `ui`, `foresight` and `billing`,
and a deploy host clones no frontend at all. Parts 1 and 5 need only this
repository and micro-ui, and they always run.

Exit 0 when the five agree. Exit 1 otherwise.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MICRO = ROOT.parent
UI = MICRO / "ui" / "packages" / "ui"
WEB_MAP = ROOT / "gateway" / "dynamic" / "estate-web.yml"

fails = []


def bad(msg):
    fails.append(msg)


# ── the checkout each path-mounted bundle lives in ───────────────────────────
#
# The same irregular mapping `surface-routes.py` keeps for its own reason, and
# for the same reason: the registry names SURFACES, not repositories, and
# `create` is micro-mint-web while `developers` is micro-devportal-web. Keyed on
# the SURFACE KEY — a path-mounted surface has no subdomain to key on, which is
# the entire premise of this file.
#
# Checked in both directions below, so a wave that moves a surface without
# landing here fails rather than going unchecked.
BUNDLE_REPOS = {
    "journal": "journal-web",
    "exchange": "exchange-web",
    "market": "market-web",
    "create": "mint-web",
    "trade": "trade-web",
    "agora": "agora-web",
    "pool": "pool-web",
    "worlds": "worlds-web",
    # Wave 3f — nested, and the repo name does NOT contain the mount. A title
    # lives in `<title>-web` and is served from `/worlds/<title>`, so this table
    # cannot be derived from either name; that is why it is a table.
    "emberkin": "emberkin-web",
    "aetherholm": "aetherholm-web",
    "tessera": "tessera-web",
    # Wave 3g. The repo is `devportal-web` and the surface key is `developers` —
    # a third spelling of one thing, and the reason this is a table rather than
    # a derivation.
    "developers": "devportal-web",
    "explorer": "explorer-web",
    "foresight": "foresight-web",
}


def registry_surfaces():
    """Read `SURFACES` and `servesOwnBundle` by running micro-ui's own module."""
    if not UI.is_dir():
        print(f"FAIL: micro-ui is not checked out at {UI} — the registry cannot be read.")
        print("      This is a failure, not a skip: the base paths would go unchecked.")
        sys.exit(1)
    script = (
        "import {SURFACES, servesOwnBundle} from './src/surfaces.ts';"
        "console.log(JSON.stringify(SURFACES.map(s=>"
        "({key:s.key,subdomain:s.subdomain,basePath:s.basePath ?? null,"
        "servesUi:s.servesUi,ownBundle:servesOwnBundle(s)}))))"
    )
    try:
        out = subprocess.run(
            ["node", "--import", "tsx", "-e", script],
            cwd=UI, capture_output=True, text=True, timeout=120,
        )
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


BASE_RE = re.compile(r"^export const BASE\s*=\s*['\"](?P<v>[^'\"]*)['\"]")
VITE_BASE_RE = re.compile(r"^\s*base:\s*['\"](?P<v>[^'\"]*)['\"]")
# nginx `location` in any of its forms — `=`, `~`, `~*`, `^~` or a plain prefix.
# The modifier is captured because it changes what the line MEANS: `location = /x`
# matches one URI, `location /x` matches a prefix, and `location ~ ^/x` matches a
# REGULAR EXPRESSION whose text is not a URI at all. A check that read all three
# as the same kind of string would compare `^/journal/(a|b)$` against `/journal`
# and conclude they disagree — which is exactly what the first run of this file
# did, and the reason the modifier is not merely recorded but acted on below.
NGINX_LOC_RE = re.compile(r"^\s*location\s+(?P<mod>=|~\*?|\^~)?\s*(?P<pat>\S+)\s*\{")


def read_first(path, pattern):
    """The first line of `path` matching `pattern`, or None. (value, lineno)."""
    if not path.exists():
        return None
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        m = pattern.match(line)
        if m:
            return m.group("v"), lineno
    return None


def location_prefix(mod, pat):
    """The URI prefix a `location` can actually answer on. (prefix, note).

    For `=`, `^~` and a bare prefix, the pattern IS a URI prefix and this is a
    pass-through. For `~` and `~*` it is a regular expression, and the only part
    that constrains WHERE it can match is the literal run following a `^`
    anchor — so `^/journal/(favicon-[0-9]+x[0-9]+\\.png|og-1200x630\\.png)$`
    confines itself to `/journal/` and nothing after that first metacharacter
    narrows it further for this purpose.

    An UNANCHORED regex location is a finding rather than a prefix: `~ \\.png$`
    answers for `/journal/a.png` and `/anything-at-all/b.png` alike, so it is not
    confined to the mount even when every URI it happens to receive today is. It
    returns a None prefix and a note saying so, and the caller reports it.
    """
    if mod not in ("~", "~*"):
        return pat, None
    if not pat.startswith("^"):
        return None, ("it is an UNANCHORED regex, so it is not confined to any prefix — it answers "
                      "for a matching URI anywhere on the host, inside this mount or outside it")
    # The literal run after `^`, stopping at the first regex metacharacter.
    literal = re.match(r"\^([^\\^$.|?*+()\[\]{}]*)", pat).group(1)
    return literal, None


# ── PART 6: WHERE THE RUNNING PAGE SENDS ITS API CALLS ────────────────────────
#
# The other four bundle statements are LITERALS and can be compared to the
# registry directly. This one is a derivation — `apiBase()` composes an answer at
# run time — so what is checked is that it composes the mount AT ALL, by one of
# the three shapes the estate actually uses. A bundle that invents a fourth is
# the failure this exists for, and the fourth that existed was
# `micro-web-template`'s: a resolver that answered `''` for same-origin, which is
# correct for a surface at the root and sends every call to the apex for a
# surface at a path.
#
# WHY A SHAPE AND NOT A VALUE. `apiBase()` reads `window.location` and, on nine
# of these bundles, the reader's chosen network as well (micro-org#459). There is
# no value to compare against from here without running a browser. The shape is
# what distinguishes "composes the mount" from "does not", and the three below
# are exhaustive over the estate as measured on 2026-09-01 — `micro-org#…` task
# 207 exists to collapse them to one, at which point this becomes a single case.
SHAPES = (
    (
        "apiBaseFor",
        "delegates to `apiBaseFor` in @cloudsforge/ui, which returns the surface's own mount "
        "for same-origin and drops it under `pnpm dev` where no gateway strips it",
    ),
    (
        "BASE",
        "composes its own router `BASE` onto the viewed origin, which is the same answer "
        "reached the other way round",
    ),
    (
        "viewedSurfaceUrl",
        "returns the whole surface URL, mount included, and narrows to the origin only when "
        "the hostname is local",
    ),
    (
        r"pathname\.replace",
        "derives the mount from its own surface URL's pathname, which is the same answer "
        "`apiBaseFor` computes and the shape it was extracted from",
    ),
)

# ── AND THE BUNDLES THAT HAVE NO OWN-SURFACE API BASE, WHICH IS NOT THE SAME ──
#
# Three of the path-mounted surfaces do not call an API of their own at all, or
# call one that lives at a DIFFERENT registry key. For those the question part 6
# asks is meaningless, and answering it with a shape would be inventing an
# obligation. Each is declared with the key it really uses, and the declaration
# is CHECKED below in both directions — a stale entry fails like any other table
# in this directory.
NO_OWN_API = {
    "worlds": (
        "api",
        "worlds-web talks to `api.<apex>`, which the gateway comment beside `cf-api-worlds-host` "
        "also states. `API_SURFACE` and `PRODUCT` are deliberately different keys in its "
        "`hosts.ts`, and `api` is not path-mounted, so there is no mount for its API base to "
        "carry",
    ),
    "exchange": (
        None,
        "exchange-web calls identity (`nimbusUrl()`) and a chain RPC (`rpcUrl()`), and nothing "
        "of its own. There is no `/v1/…` from this bundle to send anywhere",
    ),
    "journal": (
        None,
        "journal-web is content: it calls identity for the account bar and nothing else. Its "
        "articles are in the bundle",
    ),
}


def api_base_carries_mount(key, base, repo, checkout):
    """Part 6: `apiBase()` must compose the mount, by one of the recognised shapes."""
    hosts = checkout / "src" / "lib" / "hosts.ts"
    if not hosts.exists():
        bad(
            f"'{key}' is mounted at '{base}' and {repo}/src/lib/hosts.ts does not exist, so "
            f"nothing here can say where its running page sends `/v1/…`. Either the module moved "
            f"or this bundle resolves its API some other way, unchecked either direction"
        )
        return
    text = hosts.read_text(encoding="utf8")
    # Comments first: every one of these files argues about the mount at length, and the words
    # `apiBaseFor` and `BASE` appear in prose in most of them.
    body = re.sub(r"/\*[\s\S]*?\*/", "", text)
    body = re.sub(r"//[^\n]*", "", body)
    found = [name for name, _ in SHAPES if re.search(name if "\\" in name else rf"\b{name}\b", body)]
    if found:
        return
    if key in NO_OWN_API:
        used, why = NO_OWN_API[key]
        # The claim, checked. A bundle that GAINS an own-surface API base while sitting on this
        # list would be exempted from the one check that would have caught it.
        if used is None and re.search(r"\bapiBase\b", body):
            bad(
                f"'{key}' is declared as having no API base of its own — {why} — and "
                f"{repo}/src/lib/hosts.ts now defines `apiBase`. Either it gained one, in which "
                f"case it needs a shape that carries the mount, or the entry is stale"
            )
        if used is not None and not re.search(rf"'{used}'", body):
            bad(
                f"'{key}' is declared as reaching its API at the '{used}' surface — {why} — and "
                f"{repo}/src/lib/hosts.ts no longer names '{used}'. The exemption has stopped "
                f"being true and the mount is unchecked"
            )
        return
    bad(
        f"'{key}' is mounted at '{base}' and {repo}/src/lib/hosts.ts composes its API base by "
        f"none of the shapes that carry a mount. The page will load, every asset will arrive and "
        f"every link will be right, and every `/v1/…` call will go to the apex root — where "
        f"micro-site answers `text/html`, so each panel renders a failure state over a green "
        f"network tab. One of:\n"
        + "\n".join(f"           * `{name}` — {why}" for name, why in SHAPES)
    )


def check_bundle(key, base, repo):
    """Parts 2-4: the bundle's own three statements, in its own checkout."""
    checkout = MICRO / repo
    if not checkout.is_dir():
        return repo  # unread, reported by the caller

    # ── 2: the router module ──────────────────────────────────────────────
    #
    # This is the one the ESTATE cannot see. Parts 3 and 4 fail visibly the
    # first time anyone loads the page; a wrong `BASE` produces a page that
    # loads perfectly and links exclusively to addresses that do not exist.
    routes = checkout / "src" / "lib" / "routes.ts"
    got = read_first(routes, BASE_RE)
    if got is None:
        bad(
            f"'{key}' is mounted at '{base}' and {repo}/src/lib/routes.ts has no "
            f"`export const BASE = '…'`. Either the bundle builds its links some other way — in "
            f"which case nothing checks that they match the registry — or the module moved and "
            f"this claim has stopped being checkable"
        )
    elif got[0] != base:
        bad(
            f"the registry mounts '{key}' at '{base}' and {repo}/src/lib/routes.ts:{got[1]} says "
            f"BASE = '{got[0]}'. The bundle's OWN links, its canonical and its feed URL are all "
            f"built from BASE, so every one of them names an address the gateway does not route — "
            f"and the landing page still works, which is why this is silent"
        )

    # ── 3: the build's asset prefix ───────────────────────────────────────
    #
    # TRAILING SLASH REQUIRED, and it is not cosmetic: vite CONCATENATES `base`
    # with an asset name, so `/journal` yields `/journalassets/index-a1b2.js`.
    # vite.config.ts says so itself at the setting. Asserting `base + '/'` here
    # rather than `base` is therefore reading the tool's actual behaviour, not
    # tolerating a formatting difference.
    vite = checkout / "vite.config.ts"
    got = read_first(vite, VITE_BASE_RE)
    want = base + "/"
    if got is None:
        bad(
            f"'{key}' is mounted at '{base}' and {repo}/vite.config.ts sets no `base:`. vite "
            f"defaults it to '/', so every hashed asset in index.html is requested from the APEX "
            f"root — where the site's own bundle answers, with its index.html, and the page renders "
            f"blank"
        )
    elif got[0] != want:
        bad(
            f"the registry mounts '{key}' at '{base}' and {repo}/vite.config.ts:{got[1]} sets "
            f"base = '{got[0]}', not '{want}'. Every hashed asset is requested from the wrong "
            f"prefix; the HTML arrives, the modules 404, and the console shows one line about a "
            f"MIME type"
        )

    # ── 4: where the container actually answers ───────────────────────────
    #
    # Not "some location mentions the base" — EVERY location that serves content
    # must, or the ones that do not are dead. The exclusions are the two
    # locations that correctly live OUTSIDE the mount: `/healthz`, which the
    # orchestrator probes on the container and which knows nothing about the
    # publication, and the `location /` catch-all, which nginx.conf's header
    # states exists to answer 404 for exactly this reason.
    api_base_carries_mount(key, base, repo, checkout)

    nginx = checkout / "nginx.conf"
    if not nginx.exists():
        bad(f"'{key}' is mounted at '{base}' and {repo}/nginx.conf does not exist — nothing here "
            f"can say where its container answers")
        return None
    stray, inside = [], 0
    for lineno, line in enumerate(nginx.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = NGINX_LOC_RE.match(line)
        if not m:
            continue
        mod, pat = m.group("mod") or "", m.group("pat")
        shown = f"location {mod + ' ' if mod else ''}{pat}"
        prefix, note = location_prefix(mod, pat)
        # `/healthz` is the one location that correctly lives OUTSIDE the mount:
        # the orchestrator probes the CONTAINER, and a liveness probe knows
        # nothing about the publication it happens to be serving. `location /`
        # is the catch-all that nginx.conf's own header says exists to answer
        # 404 for exactly this reason.
        if prefix in ("/", "/healthz"):
            continue
        if prefix is None:
            stray.append(f"{lineno}: {shown} — {note}")
        elif prefix == base or prefix.startswith(base + "/"):
            inside += 1
        else:
            stray.append(f"{lineno}: {shown}")
    if stray:
        bad(
            f"the registry mounts '{key}' at '{base}' and {repo}/nginx.conf serves content OUTSIDE "
            f"that mount — {'; '.join(stray)}. The gateway only routes '{base}' to this container, "
            f"so those locations are unreachable in production while working perfectly in "
            f"development, which is the hardest version of this bug to see"
        )
    elif inside == 0:
        bad(
            f"the registry mounts '{key}' at '{base}' and no `location` in {repo}/nginx.conf names "
            f"that prefix at all. The gateway routes '{base}' here and the container answers its "
            f"`location /` 404 to every request"
        )
    return None


# ── 5: the gateway's own rule ────────────────────────────────────────────────
#
# The alternation, and why it is asserted as a SHAPE rather than as a substring.
# Traefik 3.2.3's `PathPrefix` is a RAW STRING PREFIX — measured, twice, on the
# running gateway: bare `PathPrefix(`/journal`)` matches `/journalism` and
# `/journalism/x` as well. The rule that is correct and the only one accepted
# here is the pair `Path(`<base>`) || PathPrefix(`<base>/`)`, which matches the
# bare path, the trailing slash and everything under it, and rejects any longer
# first segment.
#
# `check-router-prefix-ordering.py` asserts the PRIORITY half of the same rule —
# that this router outranks the bundle whose host it is borrowing. The two halves
# are split because they fail differently and at different times: a bad shape
# steals a sibling's URLs, a bad priority loses its own.
#
# READ `rule:` LINES, NOT THE FILE. estate-web.yml QUOTES THE WRONG FORM TWICE,
# in the comment block that exists to explain why it is wrong — and the first
# version of this function searched the whole file, so it found the counter-
# example in the prose and reported the correct rule as a bare PathPrefix. It
# also passed a mutation that deleted the router outright, because the comments
# still contained both halves of the alternation. A file that documents its own
# hazards is exactly the file where substring-searching the prose is unsafe.
RULE_RE = re.compile(r"^\s*rule:\s*(?P<q>['\"])(?P<rule>.*)(?P=q)\s*$")


def gateway_rule_shape(surfaces):
    if not WEB_MAP.exists():
        bad(f"{WEB_MAP} does not exist — the gateway half cannot be checked")
        return
    rules = [
        m.group("rule")
        for line in WEB_MAP.read_text().splitlines()
        if not line.lstrip().startswith("#")
        for m in [RULE_RE.match(line)] if m
    ]
    for s in surfaces:
        base = s["basePath"]
        exact = f"Path(`{base}`)"
        prefix = f"PathPrefix(`{base}/`)"
        if any(exact in r and prefix in r for r in rules):
            continue
        bare = f"PathPrefix(`{base}`)"
        if any(bare in r for r in rules):
            bad(
                f"'{s['key']}' is mounted at '{base}' and {WEB_MAP.name} routes it with a bare "
                f"PathPrefix(`{base}`). Traefik's PathPrefix is a RAW STRING PREFIX — measured on "
                f"this estate's own gateway — so that rule also claims '{base}ism', '{base}-old' "
                f"and every other path sharing those characters, taking them from whatever should "
                f"serve them. Use Path(`{base}`) || PathPrefix(`{base}/`)"
            )
        else:
            bad(
                f"'{s['key']}' is mounted at '{base}' in the registry and NO router in "
                f"{WEB_MAP.name} matches that path — every other bundle in the estate composes "
                f"links to it from the registry, and all of them 404 at the gateway"
            )


VERIFY = ROOT / "scripts" / "estate-verify.sh"


def verifier_agrees(mounted):
    """A SIXTH statement of the same string, and a seventh place it must be absent.

    `estate-verify.sh` drives each frontend container directly, and a mounted
    bundle answers at its mount INSIDE its own container — `GET /` is a 404 there,
    correctly. Its surface table therefore carries the mount as a fourth field,
    and this reads it back.

    Two directions, because the two failures are opposite and both were live:

      MISSING   the table probed `/` on three moved surfaces and reported three
                healthy frontends as dead. A verifier that cries wolf is worse
                than one that says nothing, because the next real failure lands
                in a list the reader has learned to skim.

      STALE     the origin loops still named `exchange<suffix>`, a hostname the
                estate 301s away from and deliberately removed from
                LANTERN_RUM_ORIGINS and IDENTITY_HANDOFF_ORIGINS. So the suite
                demanded back a permission that had been given up ON PURPOSE —
                and the remedy it asked for was to re-open it.

    Both are the same underlying mistake: a wave moved a surface and this file was
    not one of the places anybody remembered. That is what a check is for.
    """
    if not VERIFY.exists():
        bad(f"{VERIFY.name} is missing, so the verifier's own copy of every mount goes unchecked")
        return

    text = VERIFY.read_text()
    table = dict(re.findall(r'^\s*"([a-z0-9][a-z0-9-]*) \d{4} (/\S*(?: /\S+)?)"', text, re.M))
    by_repo = {repo: s for s in mounted for key, repo in BUNDLE_REPOS.items() if key == s["key"]}

    for repo, fields in sorted(table.items()):
        parts = fields.split()
        declared = parts[1] if len(parts) > 1 else None
        want = by_repo.get(repo, {}).get("basePath")
        if want and declared != want:
            bad(
                f"estate-verify.sh probes '{repo}' with mount {declared!r}, and the registry says "
                f"{want!r}. With no mount it asks the container for '/', which a mounted bundle "
                f"404s correctly — so a working surface is reported dead"
            )
        elif not want and declared is not None:
            bad(
                f"estate-verify.sh probes '{repo}' with mount {declared!r}, and the registry gives "
                f"that surface no basePath. Every probe is prefixed with a folder the container "
                f"does not serve, so a working surface is reported dead"
            )

    # A surface that MOVED must no longer be named as a browser origin: its old
    # hostname redirects, and the grants for it were deleted with the move.
    for s in mounted:
        stale = f'"https://{s["key"]}$WEB_SUFFIX"', f'"{s["key"]}$WEB_SUFFIX"'
        for form in stale:
            if form in text:
                bad(
                    f"estate-verify.sh still names {form} as an origin, and '{s['key']}' moved to "
                    f"'{s['basePath']}' — that hostname 301s and its CORS, hand-off and RUM grants "
                    f"were deleted with the move. The check demands the estate re-open a permission "
                    f"it gave up on purpose. The origin is the apex now, and it is already tested"
                )
                break


def main():
    surfaces = registry_surfaces()
    mounted = [s for s in surfaces if s["basePath"] and s["ownBundle"]]

    # The table is a claim in both directions, like every other table in this
    # directory: a surface that moved without landing here would be silently
    # unchecked, and a name here that is no longer path-mounted is a stale entry
    # pointing this check at a repository it has no business reading.
    keys = {s["key"] for s in mounted}
    for key in sorted(keys - set(BUNDLE_REPOS)):
        bad(
            f"surface '{key}' serves its own bundle at '{next(s['basePath'] for s in mounted if s['key'] == key)}' "
            f"and has no entry in BUNDLE_REPOS, so this check cannot tell which checkout holds its "
            f"routes.ts, vite.config.ts and nginx.conf. Its gateway rule is still checked; its "
            f"bundle is not"
        )
    for key in sorted(set(BUNDLE_REPOS) - keys):
        bad(
            f"BUNDLE_REPOS names '{key}', which is not a registry surface serving its own bundle at "
            f"a path. Either the surface moved back to a subdomain — in which case its gateway "
            f"rule, its redirect and its CORS grants all move with it — or it was renamed"
        )

    unread = []
    for s in mounted:
        repo = BUNDLE_REPOS.get(s["key"])
        if repo is None:
            continue
        missing = check_bundle(s["key"], s["basePath"], repo)
        if missing:
            unread.append(missing)

    # The part-6 exemptions are a table, so they are a claim in both directions like every other
    # one here: a name that has stopped being a path-mounted surface is pointing this check at a
    # question nobody is asking, and hiding the answer to one that is.
    for key in sorted(set(NO_OWN_API) - keys):
        bad(
            f"NO_OWN_API names '{key}', which is not a registry surface serving its own bundle at "
            f"a path. Either it moved back to a subdomain or it was renamed; either way the "
            f"exemption is exempting nothing and would silently cover a future surface of that name"
        )

    gateway_rule_shape(mounted)
    verifier_agrees(mounted)

    for f in fails:
        print(f"FAIL {f}")
    if unread:
        print(f"  note the bundle's own files were not read for {', '.join(sorted(unread))} — not "
              f"checked out here. The registry and gateway halves both ran.")
    if fails:
        print(f"\n{len(fails)} disagreement(s).")
        return 1
    print(
        f"ok — {len(mounted)} path-mounted surface(s), six statements each, all agreeing"
        + (f" ({len(NO_OWN_API)} of them declared as having no API base of their own)."
           if NO_OWN_API else ".")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
