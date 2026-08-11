#!/usr/bin/env python3
"""A release must pin every service it names — behind a profile, and to a digest.

── WHAT THIS GUARDS, AND THE DAY IT DID NOT EXIST ────────────────────────────

`release-render.py` decides which services to pin by asking
`docker compose config --services`. That command reports only services in ACTIVE
profiles, so with no `--profile` flag it reports only the unprofiled ones. A
profile-gated service was therefore read as "not defined in this environment",
its pin was dropped, and the base file's `build:` survived into the release
overlay — which is the single failure mode that script exists to eliminate.

Measured on the mainnet host on 2026-08-09 while cutting 2.5.7: 46 of 48
manifest entries rendered. The two missing were `faucet` and `pool`, which are
exactly the two profiled deployables in the file. The overlay said so in a
comment on its last line — `in the manifest but NOT in this environment: faucet,
pool` — where nobody reads it, and nothing failed.

A dropped pin is quiet in the worst way. `pool` ships behind a profile and is
started by hand, so it would have started from whatever was checked out on the
host, while the release manifest recorded an image tag it was not running.

── AND THE SIBLING QUESTION: PINNED TO WHAT? (micro-org#295) ─────────────────

`build: !reset null` stops a release building from a working tree. It says
nothing about what the image reference resolves to, and a tag is a mutable
pointer this estate's own machinery moves — `publish-image.yml` republishes the
package.json version on every push to `main` or `release/**`, so six
repositories' 2.5.6 branches left `main` on 2.5.5 and every later merge
republished the tag `releases/2.5.5.yaml` pins (measured 2026-08-09,
micro-org#288). `cfctl release` now records the GHCR index digest each tag
resolved to at cut time, and the renderer pins to it.

Three things must hold at once, and they pull against each other:

  * an entry WITH a digest renders `image@sha256:…` and not `image:tag`
  * an entry WITHOUT one renders `image:tag`, exactly as it always did — every
    manifest cut before 2026-08-09 has no digests and those files are the
    rollback path
  * a MIXED manifest renders rather than erroring, because `cfctl release`
    deliberately warns-and-succeeds with a partial digest set when a release is
    cut minutes before some images publish

So the fixture manifest below is mixed on purpose: `plain` has no digest and
`gated` has one. One render exercises all three.

── HOW THIS AVOIDS BEING A CHECK THAT CANNOT FAIL ────────────────────────────

An assertion that "no `gated:9.9.9` appears in the output" passes trivially
against a renderer that emits nothing for `gated` at all, and an assertion that
"`@sha256:` appears" passes against a renderer that emits it for everything. So
the digest case is checked DIFFERENTIALLY: the same manifest is rendered twice,
once as written and once with the `digest:` line deleted, and the two outputs
must disagree in exactly the expected way. A renderer that ignored the field
entirely produces two identical renders and fails here.

The fixture is also checked against itself. If a later edit drops the `digest:`
line from `MANIFEST`, every digest assertion below would go green while proving
nothing — the estate's most-repeated defect, a guard that passes because the
thing it guards is absent. That is a failure here, not a pass.

── WHY A FIXTURE RATHER THAN THE ESTATE FILE ─────────────────────────────────

The real base compose needs the estate's env files to interpolate, and those are
gitignored secrets that CI does not have. So this builds the smallest compose
that can express the bug — one plain service, one profiled service — and asserts
the renderer pins both. It uses the real `docker compose` and the real renderer;
only the input is small.

Exit non-zero on failure, print nothing but the verdict on success.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
RENDER = HERE / "release-render.py"

# A syntactically real index digest — `sha256:` and 64 lower-case hex — because
# the renderer validates the shape and refuses to pin one it cannot parse. Not a
# real GHCR object: nothing here pulls, and a check that needed the registry to
# be up would be a check that goes red for reasons that are not this one.
DIGEST = "sha256:" + "5c" * 32

COMPOSE = """\
services:
  plain:
    image: example.invalid/plain:old
    build:
      context: .
  gated:
    profiles: ["somefeature"]
    image: example.invalid/gated:old
    build:
      context: .
  pulled:
    image: example.invalid/pulled:old
"""

# MIXED ON PURPOSE. `plain` carries no `digest:` — the shape of every manifest
# cut before 2026-08-09, which is the estate's rollback path — and `gated`
# carries one. A renderer that errored on the mix, or that pinned only one form,
# fails below.
MANIFEST = f"""\
version: "9.9.9"
generated: "2026-08-09T00:00:00.000Z"
generator: cfctl release
services:
  - name: plain
    repo: micro-plain
    kind: service
    image: ghcr.io/example/plain
    tag: "9.9.9"
    commit: "0000000000000000000000000000000000000000"
  - name: gated
    repo: micro-gated
    kind: service
    image: ghcr.io/example/gated
    tag: "9.9.9"
    commit: "1111111111111111111111111111111111111111"
    digest: "{DIGEST}"
absent:
"""


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


if shutil.which("docker") is None:
    # Not a pass. The renderer refuses to guess the service list without docker
    # for the same reason this refuses to certify it without one.
    fail("docker is not available, so the renderer cannot be exercised.")

# THE FIXTURE, CHECKED BEFORE IT IS TRUSTED. Every digest assertion below is
# satisfied by an input that names no digest, so an edit that dropped the line
# would leave a green check guarding nothing.
if f'digest: "{DIGEST}"' not in MANIFEST:
    fail(
        "the fixture manifest names no digest, so every digest assertion below would\n"
        "       pass without exercising anything. That is the vacuous check this file refuses."
    )

with tempfile.TemporaryDirectory() as tmp:
    tmpdir = pathlib.Path(tmp)
    base = tmpdir / "docker-compose.fixture.yml"
    manifest = tmpdir / "9.9.9.yaml"
    overlay = tmpdir / "docker-compose.release.yml"
    base.write_text(COMPOSE)
    manifest.write_text(MANIFEST)

    def image_refs(text):
        """The references the overlay actually pins, and not the prose about them.

        Every assertion below reads this rather than the whole render. The
        overlay's header spells `micro-identity@sha256:d82f87dc…` out while
        explaining what a digest pin is, and a substring search for `@sha256:`
        counted that sentence — which would have let a renderer that pins
        nothing by digest satisfy a digest check with its own documentation.
        """
        return [line[len("    image: "):] for line in text.split("\n") if line.startswith("    image: ")]

    def run_render(text, *flags):
        """The real renderer over a manifest, returning the whole result."""
        manifest.write_text(text)
        return subprocess.run(
            [sys.executable, str(RENDER), str(manifest), "--base", str(base), *flags],
            capture_output=True,
            text=True,
        )

    def render(text, label, *flags):
        """The real renderer over a manifest, or a failure naming which one."""
        proc = run_render(text, *flags)
        if proc.returncode != 0:
            fail(f"release-render.py exited {proc.returncode} on the {label} manifest:\n{proc.stderr}")
        return proc.stdout

    # A MIXED manifest is a supported state, not an error. If this render fails
    # the estate cannot deploy a release cut in the minutes before some images
    # published, which cfctl deliberately allows.
    out = render(MANIFEST, "mixed")

    # The profiled service is the whole point, but assert both: a renderer that
    # pinned only `gated` would be just as broken and would pass a one-sided test.
    for name in ("plain", "gated"):
        if f"  {name}:\n" not in out:
            fail(
                f"the overlay does not pin `{name}`, which the manifest names.\n"
                f"       A named-but-unpinned service keeps its `build:` and is built from\n"
                f"       the working tree by a release deploy.\n\n{out}"
            )

    # Pinning the name is not enough — `build: !reset null` is what actually stops
    # the fallback, and an overlay that sets `image:` while leaving `build:` in
    # place still builds from the tree.
    #
    # Counted as an indented LINE rather than as a substring. The overlay's own
    # header quotes the string while explaining why a digest-pinned entry has no
    # build to fall back to, and a substring count was satisfied by the prose
    # alone — a guard the thing it guards need not be present to pass.
    resets = sum(1 for line in out.split("\n") if line == "    build: !reset null")
    if resets != 2:
        fail(f"expected `build: !reset null` on both services, found {resets}:\n\n{out}")

    if "NOT in this environment" in out:
        fail(f"the renderer reported a service as absent from an environment that defines it:\n\n{out}")

    # ── THE DIGEST-BEARING ENTRY IS PINNED TO THE ARTIFACT ────────────────────
    refs = image_refs(out)
    if f"ghcr.io/example/gated@{DIGEST}" not in refs:
        fail(
            "the manifest records a digest for `gated` and the overlay does not pin it.\n"
            "       `docker compose up` resolves the reference a second time, after\n"
            "       `cfctl release --verify` resolved it once, so a tag that moved between\n"
            "       the two deploys an image the release never named.\n\n"
            f"{out}"
        )
    if "ghcr.io/example/gated:9.9.9" in refs:
        fail(f"`gated` has a digest and is still pinned by its mutable tag:\n\n{out}")

    # ── AND THE ONE WITHOUT A DIGEST IS STILL PINNED BY TAG ───────────────────
    # Not a nicety. Rollback is checking out the previous manifest, and every
    # manifest before 2026-08-09 is this shape.
    if "ghcr.io/example/plain:9.9.9" not in refs:
        fail(
            "`plain` records no digest and the overlay no longer pins it by tag.\n"
            "       Every manifest cut before 2026-08-09 is that shape, and those files are\n"
            "       the rollback path.\n\n"
            f"{out}"
        )
    digest_pins = [r for r in refs if "@sha256:" in r]
    if len(digest_pins) != 1:
        fail(f"expected exactly one digest-pinned reference, got {digest_pins}:\n\n{out}")

    # ── DIFFERENTIALLY, SO THE TWO ASSERTIONS ABOVE CANNOT BOTH BE VACUOUS ────
    #
    # Same manifest, digest line deleted. A renderer that never read the field
    # produces an identical render and is caught here rather than passing two
    # assertions that happen to be satisfied by whatever it does emit.
    without = render(MANIFEST.replace(f'    digest: "{DIGEST}"\n', ""), "digest-free")
    if any("@sha256:" in ref for ref in image_refs(without)):
        fail(f"a manifest with no digest at all still rendered a digest pin:\n\n{without}")
    if "ghcr.io/example/gated:9.9.9" not in image_refs(without):
        fail(f"with the digest removed, `gated` is not pinned by tag either:\n\n{without}")
    if without == out:
        fail(
            "the render is byte-identical with and without the manifest's digest, so the\n"
            "       renderer is not reading the field and every assertion above is vacuous."
        )

    # ── AN UNPINNED SERVICE WITH A `build:` IS REFUSED, NOT WARNED ABOUT ──────
    #
    # micro-org#380. `pool` and `pool-web` are running mainnet services no
    # manifest has ever named, so their `build:` survived into the release
    # overlay; the 2.5.19 deploy to the app host pulled 48 images, passed its own
    # `--dry-run`, and died at the switch on `unable to prepare context: path
    # ".../pool-web" not found`. The renderer had warned, in a comment on the
    # last line of the file it wrote, where nobody read it.
    #
    # `gated` is dropped from the manifest here rather than added to the compose,
    # so the fixture's other assertions keep exercising the same two services.
    without_gated = MANIFEST.split("  - name: gated")[0] + "absent:\n"
    if "name: gated" in without_gated:
        fail("the fixture for the unpinned-build case still names `gated`, so it proves nothing.")
    refusal = run_render(without_gated)
    if refusal.returncode == 0:
        fail(
            "the renderer rendered a release that does not pin `gated`, which this environment\n"
            "       defines with a `build:`. That overlay deploys by BUILDING from a working tree,\n"
            f"       on a host that need not have one:\n\n{refusal.stdout}"
        )
    if "gated" not in refusal.stderr:
        fail(f"the refusal does not name the service it is about:\n{refusal.stderr}")

    # THE REFUSAL KEYS ON `build:`, NOT ON BEING UNNAMED. `pulled` is in this
    # environment and in no manifest here, and it has no build — so it keeps the
    # image it already has, which is a warning and always was. If this render
    # failed, the check above would be indistinguishable from "every unnamed
    # service is fatal", which would make `absent:` unusable and every manifest
    # cut before a service existed unrenderable.
    if "pulled" in refusal.stderr:
        fail(
            "the refusal names `pulled`, which has no `build:` — it cannot be built from a tree\n"
            f"       and keeps the image it already had:\n{refusal.stderr}"
        )
    if "pulled" not in out:
        fail(f"the overlay no longer warns about `pulled`, which no manifest here names:\n\n{out}")

    # AND THE HOST THAT REALLY HAS THE SOURCE CAN STILL SAY SO.
    allowed = render(without_gated, "unpinned-build with --allow-unpinned-build", "--allow-unpinned-build")
    if "  gated:\n" in allowed:
        fail(f"`gated` is not in this manifest and the overlay pins it anyway:\n\n{allowed}")

    # ── THE TAG SURVIVES INTO WHAT COMPOSE ACTUALLY READS ─────────────────────
    #
    # `micro-identity@sha256:d82f87dc…` does not say `2.5.7`, and the renderer
    # answers that with a comment on the entry. `docker compose config` re-emits
    # the file from a parsed model and DROPS every comment in it (measured
    # 2026-08-09, Compose 5.4.0), so the comment alone leaves the operator's
    # other reading of "what is running" — the rendered config, and `docker
    # inspect` — naming bytes and no version. The label is what carries it
    # there, and this is the assertion that stops it being dropped as
    # redundant with the comment it is not redundant with.
    if "    # ghcr.io/example/gated:9.9.9\n" not in out:
        fail(f"the digest-pinned entry carries no tag comment for whoever opens the file:\n\n{out}")

    overlay.write_text(out)
    # `--profile` before the subcommand, and named: it is an option of
    # `docker compose` itself, and without it `config` omits `gated` entirely —
    # which is the same omission the top half of this file is about, arriving
    # here as a KeyError rather than as a silent pass.
    proc = subprocess.run(
        ["docker", "compose", "--profile", "somefeature",
         "-f", str(base), "-f", str(overlay), "config", "--format", "json"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        fail(f"`docker compose config` cannot parse the digest-pinned overlay:\n{proc.stderr}")
    gated = json.loads(proc.stdout)["services"]["gated"]
    if gated.get("image") != f"ghcr.io/example/gated@{DIGEST}":
        fail(f"compose resolved `gated` to {gated.get('image')!r}, not to the digest the manifest pins.")
    if "ghcr.io/example/gated:9.9.9" not in json.dumps(gated):
        fail(
            "the tag `gated` was pinned from survives nowhere in `docker compose config`.\n"
            "       Compose drops comments, so an operator reading the rendered configuration —\n"
            "       or `docker inspect` on the running container — sees a digest and no version.\n\n"
            f"{json.dumps(gated, indent=2)}"
        )

    # ── AND THE DEPLOY CAN STILL READ THE REFERENCES BACK OUT ─────────────────
    #
    # release-deploy.sh pre-flights every pull by extracting the references from
    # the rendered overlay with grep before it changes anything, and that
    # extraction is a second parser of this file's format — so it is exercised
    # here rather than discovered on the host.
    #
    # It found something. The tag label was first called
    # `online.cloudsforge.release.image`, and the deploy's `grep -oE 'image:
    # [^ ]+'` matches ANYWHERE in a line, so it picked the label up as well:
    # 96 references out of a 2.5.7 render whose manifest names 48, half of them
    # quoted strings no registry can be asked about. Every one would have failed
    # `docker manifest inspect` and the deploy refuses to proceed when any does,
    # so the estate could not have deployed a digest-pinned release at all —
    # found by this assertion, on 2026-08-09, before it was ever run for real.
    deploy_sh = (HERE / "release-deploy.sh").read_text()
    extractor = re.search(r"\$\(grep -oE '([^']+)' \"\$OVERLAY\"", deploy_sh)
    if not extractor:
        fail(
            "release-deploy.sh no longer extracts image references from the overlay with a\n"
            "       `grep -oE '…' \"$OVERLAY\"`, so this check cannot exercise the deploy's own\n"
            "       reading of the rendered file and would pass without proving it."
        )
    found = subprocess.run(
        ["grep", "-oE", extractor.group(1), str(overlay)],
        capture_output=True,
        text=True,
    ).stdout.split("\n")
    found = sorted({line.split("image: ", 1)[1] for line in found if "image: " in line})
    if found != sorted(refs):
        fail(
            "release-deploy.sh's pre-flight reads references out of the overlay that the\n"
            "       overlay does not pin. It runs `docker manifest inspect` on each and refuses\n"
            "       to deploy when any fails, so this is a release that cannot be deployed.\n"
            f"       pinned:    {sorted(refs)}\n"
            f"       extracted: {found}"
        )

print(
    "ok: the release overlay pins profile-gated services as well as plain ones, pins a\n"
    "    digest-bearing entry to @sha256 while a digest-free one keeps its tag, keeps the\n"
    "    tag readable through `docker compose config`, and release-deploy.sh's pre-flight\n"
    "    reads back exactly the references it pins"
)
