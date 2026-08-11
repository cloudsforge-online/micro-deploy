#!/usr/bin/env python3
"""Turn a release manifest into a compose overlay that pins every image.

    ./scripts/release-render.py ../org/releases/2026.08.1.yaml > compose/docker-compose.release.yml

WHY THIS EXISTS
---------------
micro-org already decides what a release IS, and that decision is good: a
manifest is a generated file naming exactly which image of each service is in a
release, `cfctl release` generates it from each repository's package.json version
and its git HEAD, a dirty checkout cannot be released because "an image tag
cannot name a working tree", and rollback is checking out the previous file.
None of that is re-invented here.

What did not exist is a CONSUMER. `cfctl release --verify` proves the images can
be pulled; nothing anywhere turned a manifest into a running system. So the
manifest satisfied "a release is a file" and not the sentence that matters in
17 §89 — "deployable and rollbackable BY MANIFEST ALONE". This is the piece that
makes that sentence true:

    deploy   = render(manifest N)   + docker compose up
    rollback = render(manifest N-1) + docker compose up

Those are the same command. That is the whole point: a rollback that is a
different procedure from a deploy is a procedure nobody has practised.

WHAT IT EMITS
-------------
An OVERLAY, not a replacement. The base compose file keeps owning environment,
dependency order, health checks and ports — the things that are properties of the
environment rather than of the release — and this overlay changes exactly one
thing per service: where the image comes from. `build:` is removed with `!reset`
so that a release deploy CANNOT silently fall back to building from a working
tree, which is the failure mode the manifest exists to eliminate.

Migrators are pinned to the same image as their service, deliberately. A migrator
running a different build from the service that then asserts its schema is the
oldest way to brick a deploy.

BY DIGEST WHEN THE MANIFEST HAS ONE (micro-org#295)
---------------------------------------------------
A tag is a mutable pointer and this estate's own machinery moves it: publishing
tags at the package.json version on every push to `main` or `release/**`, so an
unmerged release branch leaves `main` on the previous version and the next merge
republishes the PREVIOUS release's tag from a different commit. Six repositories
did exactly that with 2.5.6 (measured 2026-08-09, micro-org#288).

`cfctl release` now records the GHCR INDEX digest each tag resolved to at cut
time, and `cfctl release --verify` fails when a tag no longer resolves to it.
That makes a moved tag detectable. It does not make it harmless: `--verify` and
`docker compose up` are two separate resolutions of the same mutable name, and
only the first was checked. So an entry that carries a digest is rendered as
`image@sha256:…` — the artifact — and only an entry with no digest is rendered
as `image:tag`.

THE TAG FALLBACK IS LOAD-BEARING, NOT A COURTESY. Every manifest cut before
2026-08-09 has no `digest:` line at all, and rollback is checking out the
previous file — so those files ARE the rollback path. Rendering them must go on
producing byte-identical output to what it produced before this change, and it
does. A MIXED manifest is equally supported: `cfctl release` warns and succeeds
with a partial digest set when a release is cut in the minutes before some
images publish, so some entries carry a digest and some do not, and both render.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("manifest", help="path to a release manifest (org/releases/<version>.yaml)")
parser.add_argument("--base", default="compose/docker-compose.estate.yml", help="the compose file the overlay applies to")
# ── WHICH ENVIRONMENT'S SERVICE LIST, WHICH IS NOT A DETAIL ──────────────────
#
# The base file renders a DIFFERENT SET OF SERVICES per environment: `faucet` is
# defined on testnet and not on mainnet (faucet/src/env.ts fixes NETWORK to
# 'testnet' at compile time — mainnet EMBER is mined money and has no faucet).
#
# Without this, `config --services` below was always asked the MAINNET question,
# so a testnet render decided `faucet` "is not in this environment" and dropped
# its pin. A dropped pin does not fail: the base file's `build:` survives, and
# the release deploy silently builds faucet from whatever is in the working tree
# — which is the single failure mode this whole script exists to eliminate, and
# it would have been introduced by the script itself.
#
# ── REPEATABLE, BECAUSE ONE ENV FILE STOPPED BEING ENOUGH TO RENDER AT ALL ────
#
# This took a single value, and `--env-file` REPLACES compose's default `.env`
# rather than adding to it — so whichever one file was passed became the whole
# environment. That was survivable only while every value the base file
# interpolates lived in the estate env file.
#
# It stopped being survivable the moment the Postgres password became a variable
# (micro-deploy@16cdbf2, micro-org#190). That password lives in the gitignored
# `compose/estate/tokens*.env`, which is the file this argument could not also
# accept, so `docker compose config --services` below failed outright:
#
#   error while interpolating services.postgres.environment.POSTGRES_PASSWORD:
#   required variable CF_POSTGRES_PASSWORD is missing a value
#
# and no release could be rendered on either network — with the variable set
# correctly in both tokens files the whole time.
#
# `release-deploy.sh`'s DEPLOY step had always passed two files for exactly this
# reason and says so in its own header (#158). Only the render was left with
# one. So this is `append`, the flag is repeated on the caller, and repeated
# flags merge with the last winning — the same order, and the same rule, as the
# deploy it has to agree with.
parser.add_argument(
    "--env-file",
    action="append",
    default=[],
    dest="env_file",
    metavar="PATH",
    help="passed to `docker compose` so the base service list is the one THIS environment "
    "defines. Repeatable; later files win on a shared key, matching release-deploy.sh.",
)
parser.add_argument("--out", help="write here instead of stdout")
# ── THE ESCAPE HATCH FOR THE HOST THAT REALLY DOES HAVE THE SOURCE ───────────
#
# See the refusal further down. A service this environment defines with a
# `build:`, which the release does not pin, is a deploy that dies at the switch
# on any host without that source checked out — so the render refuses it. On the
# chain host, which has all 48 sibling repositories, the same deploy builds and
# works, and an operator there may knowingly want it. This flag is how they say
# so, and `release-deploy.sh` does not pass it: a release deploy that builds is a
# thing somebody has to type.
parser.add_argument(
    "--allow-unpinned-build",
    action="store_true",
    help="render even when this environment defines a service with a `build:` that the "
    "release does not pin. The deploy will BUILD it from the working tree.",
)
args = parser.parse_args()

manifest_path = pathlib.Path(args.manifest)
if not manifest_path.exists():
    sys.exit(f"FAIL: no manifest at {manifest_path}")

# --------------------------------------------------------------------------
# Parse exactly the shape cfctl's renderManifest emits, and nothing else.
#
# This mirrors org/tools/cfctl.ts parseManifest on purpose, including its
# reasoning: "a manifest that is not exactly this shape was not generated by
# cfctl and should not be deployed." A tolerant parser here would accept a
# hand-written file, and a hand-written manifest is the drift the format exists
# to prevent.
# --------------------------------------------------------------------------
text = manifest_path.read_text()
version = ""
services = []
absent = []
section = None
current = None

for raw in text.split("\n"):
    line = raw.rstrip()
    if not line or line.lstrip().startswith("#"):
        continue
    if line.startswith("version:"):
        version = line[len("version:"):].strip().strip('"')
        continue
    if line.startswith("generated:") or line.startswith("generator:"):
        continue
    if line == "services:":
        if current:
            services.append(current)
            current = None
        section = "services"
        continue
    if line == "absent:":
        if current:
            services.append(current)
            current = None
        section = "absent"
        continue
    if section == "absent" and line.startswith("  - "):
        absent.append(line[4:].strip())
        continue
    if section == "services":
        if line.startswith("  - "):
            if current:
                services.append(current)
            current = {}
        body = re.sub(r"^ {2}(- )?", "", line)
        body = re.sub(r"^ {2}", "", body)
        if ":" in body and current is not None:
            key, _, value = body.partition(":")
            current[key.strip()] = value.strip().strip('"')
if current:
    services.append(current)

if not version:
    sys.exit(f"FAIL: {manifest_path} names no version. Refusing to render a release that cannot be named.")
if not services:
    # The same refusal cfctl's --verify makes: "'all 0 images exist' is a true
    # sentence and a useless one."
    sys.exit(f"FAIL: {manifest_path} names no images. A manifest that pins nothing is not a release.")

# --------------------------------------------------------------------------
# What the environment actually defines. Asking compose rather than parsing the
# YAML: an overlay naming a service the base does not define would not override
# anything, it would CREATE a container with an image and no environment, no
# health check and no dependencies — which would start, and would be wrong.
# --------------------------------------------------------------------------
base = pathlib.Path(args.base)
if not base.exists():
    sys.exit(f"FAIL: no base compose file at {base}")


def compose(subcommand, *flags, profiles=()):
    """`docker compose` with this environment's env files, and optionally its profiles.

    Every flag here belongs BEFORE the subcommand — `--env-file`, `--profile` and
    `-f` are all options of `docker compose` itself, not of `config`.
    """
    cmd = ["docker", "compose"]
    for env_file in args.env_file:
        cmd += ["--env-file", env_file]
    for profile in profiles:
        cmd += ["--profile", profile]
    cmd += ["-f", str(base), subcommand]
    return cmd + list(flags)


# ── EVERY PROFILE, BECAUSE A PROFILE IS THE SECOND WAY TO BE "NOT DEFINED" ────
#
# `config --services` reports only services in ACTIVE profiles, and with no
# `--profile` flag that means only the unprofiled ones. So a profile-gated
# service was reported as not defined in this environment, its pin was dropped,
# and the base file's `build:` survived — the exact failure the note above the
# --env-file flag describes, arriving by a second route that fix did not cover.
#
# That note is worth re-reading, because it says the faucet pin was being
# dropped and that passing the environment's own env file restored it. Only half
# of that was true. `faucet` carries `profiles: ["ember-testnet"]`, so it was
# omitted from `--services` on TESTNET too, for this reason rather than that
# one, and had stayed unpinned ever since. Measured on the host on 2026-08-09
# while cutting 2.5.7: 46 of 48 manifest entries rendered, the two missing being
# `faucet` and `pool` — every profiled deployable in the file and nothing else.
#
# Asking for every profile is right because THIS SCRIPT DOES NOT START ANYTHING.
# It decides what a service would run AS, not whether it runs. Profile selection
# stays entirely with the `up` that consumes the overlay, and a service whose
# profile is not activated there still does not start — it merely now has an
# image pinned for when somebody activates it. Which is the whole point: `pool`
# ships behind a profile and will be started by hand, and a hand-started service
# that silently builds from a working tree is worse than one nobody pinned,
# because the release manifest claims it is pinned.
#
# Enumerated rather than `--profile "*"`: the wildcard is newer than the flag,
# and this asks compose for the list rather than reading the YAML for it, which
# is the same reason `--services` is asked for below instead of parsed.
try:
    proc = subprocess.run(compose("config", "--profiles"), capture_output=True, text=True, check=True)
except FileNotFoundError:
    sys.exit("FAIL: docker is not available, so the base service list cannot be read. Refusing to guess it.")
except subprocess.CalledProcessError as exc:
    sys.exit(f"FAIL: `docker compose config --profiles` failed:\n{exc.stderr}")
profiles = [p.strip() for p in proc.stdout.split("\n") if p.strip()]

try:
    proc = subprocess.run(compose("config", "--services", profiles=profiles), capture_output=True, text=True, check=True)
except FileNotFoundError:
    sys.exit("FAIL: docker is not available, so the base service list cannot be read. Refusing to guess it.")
except subprocess.CalledProcessError as exc:
    sys.exit(f"FAIL: `docker compose config --services` failed:\n{exc.stderr}")
defined = {s.strip() for s in proc.stdout.split("\n") if s.strip()}

# ── AND WHICH OF THEM WOULD BE BUILT RATHER THAN PULLED ──────────────────────
#
# `--services` says what exists; it does not say which of those carries a
# `build:`. That distinction is the difference between a warning and a deploy
# that cannot happen, so it is asked for rather than inferred — the same rule
# the two calls above follow, and for the same reason: the YAML is not the
# configuration, the interpolated model is.
try:
    proc = subprocess.run(
        compose("config", "--format", "json", profiles=profiles), capture_output=True, text=True, check=True
    )
    buildable = {
        name for name, body in json.loads(proc.stdout).get("services", {}).items() if body.get("build")
    }
except FileNotFoundError:
    sys.exit("FAIL: docker is not available, so the base service list cannot be read. Refusing to guess it.")
except subprocess.CalledProcessError as exc:
    sys.exit(f"FAIL: `docker compose config --format json` failed:\n{exc.stderr}")
except (ValueError, AttributeError) as exc:
    # Not survivable-by-degrading. Treating an unreadable model as "nothing has a
    # build" would turn the refusal below off silently, which is the shape of
    # guard this estate keeps finding: one that passes because what it guards is
    # absent.
    sys.exit(f"FAIL: `docker compose config --format json` produced something this cannot read: {exc}")

# ── THE SHAPE OF A DIGEST, CHECKED RATHER THAN TRUSTED ───────────────────────
#
# The same expression cfctl's readContentDigest validates GHCR's answer with,
# for the same reason it validates rather than trusts: a truncated or proxied
# value that merely looks like a digest would render an image reference nothing
# can pull, and the place to discover that is here rather than on the host at
# 3am. An index digest is `sha256:` and sixty-four lower-case hex characters.
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")

# Whether THIS release names any digests at all decides how the file describes
# itself. A manifest cut before 2026-08-09 names none, and a header explaining
# digest pinning on a file that pins nothing by digest would be a claim about
# entries it does not have — as well as making the rendered output of the
# estate's rollback path differ from what it has always been.
any_digest = any(svc.get("digest", "") for svc in services)

# The tag lives in a comment for whoever opens this file, and in a LABEL for
# `docker compose config` — which re-emits the file from a parsed model and
# drops every comment in it (measured 2026-08-09 with Compose 5.4.0: a
# `# tag 2.5.7` beside a digest-pinned `image:` is absent from the output, while
# a label beside it survives verbatim). A digest names bytes and not a version,
# so a rendered estate with neither of these is one nobody can read.
#
# NOT NAMED `…release.image`, which is what it was called first. release-deploy.sh
# reads every reference back out of this file with `grep -oE 'image: [^ ]+'` to
# pre-flight the pulls, and `-o` matches anywhere in a line: a key ENDING in
# `image` made `online.cloudsforge.release.image: "ghcr.io/…:2.5.7"` match too.
# Measured 2026-08-09, rendering 2.5.7 re-cut with digests against the mainnet
# base: 96 references extracted where the manifest names 48, half of them quoted
# strings no registry can be asked about, so the deploy would have refused every
# release with "48 of 96 image(s) cannot be pulled". The grep is anchored now as
# well, and both halves of that fix are
# asserted by check-release-render-pins-profiles.py — but a label name that
# cannot collide is worth having anyway.
TAG_LABEL = "online.cloudsforge.release.tag"

lines = [
    "# GENERATED by scripts/release-render.py — do not hand-edit.",
    f"# Release:  {version}",
    f"# Manifest: {manifest_path}",
    "#",
    "# Pins every service to the image the manifest names, and REMOVES `build:` so",
    "# that a release deploy cannot fall back to building from a working tree.",
    "#",
]
if any_digest:
    lines += [
        "# This release names DIGESTS, so every entry that has one is pinned to the",
        "# artifact instead of to a name pointing at it (micro-org#288/#295). A tag is",
        "# mutable and this estate republishes tags; a digest is the name of the bytes.",
        "#",
        "# `docker compose` PULLS a digest and `docker compose build` CANNOT USE ONE.",
        "# That is consistent with the `build: !reset null` below rather than in tension",
        "# with it, and it is worth saying out loud: a digest-pinned entry has no local",
        "# build to fall back to, by construction. That is the intended property.",
        "#",
        "# `micro-identity@sha256:d82f87dc…` does not say `2.5.7`, so each digest-pinned",
        "# entry carries the tagged reference it was resolved from TWICE: in a comment for",
        f"# whoever opens this file, and in the label `{TAG_LABEL}` for",
        "# `docker compose config`, which re-emits from a parsed model and drops every",
        "# comment in it.",
        "#",
    ]
lines += [
    "#   deploy:   docker compose -f compose/docker-compose.estate.yml -f THIS up -d",
    "#   rollback: render the previous manifest and run the same command.",
    "",
    "services:",
]

pinned, skipped, missing = [], [], []
by_digest, by_tag = [], []
for svc in services:
    name = svc.get("name", "")
    image, tag = svc.get("image", ""), svc.get("tag", "")
    if not name or not image or not tag:
        sys.exit(f"FAIL: {manifest_path} has an entry missing name, image or tag: {svc!r}")
    # Absent, not empty: cfctl omits the line rather than emitting `digest: ""`,
    # and the parser above turns a key that is not there into no key at all.
    digest = svc.get("digest", "")
    if digest and not DIGEST.match(digest):
        sys.exit(
            f"FAIL: {manifest_path} records a digest for `{name}` that is not an index digest: {digest!r}\n"
            f"       Expected sha256: and 64 lower-case hex characters. Rendering it would pin an\n"
            f"       image reference that cannot be pulled, and the deploy would find that out."
        )
    # A web or ops deployable is in the manifest but is not part of this
    # environment. Recorded, not silently dropped.
    targets = [t for t in (name, f"{name}-migrate") if t in defined]
    if not targets:
        skipped.append(name)
        continue
    (by_digest if digest else by_tag).append(name)
    for target in targets:
        lines.append(f"  {target}:")
        if digest:
            # On the entry, above the line it explains. Deliberately not a
            # trailing comment on `image:` itself: release-deploy.sh reads the
            # references back out of this file with a `grep -oE` on that line to
            # pre-flight every pull, and a comment sharing the line is one
            # careless change to that expression away from being pulled.
            lines.append(f"    # {image}:{tag}")
        lines.append(f"    image: {image}@{digest}" if digest else f"    image: {image}:{tag}")
        # !reset is how compose deletes an inherited value rather than merging
        # it. Without it the base file's `build:` survives and compose would
        # rebuild from the working tree, which is exactly what a pinned release
        # must never do.
        lines.append("    build: !reset null")
        if digest:
            lines.append("    labels:")
            lines.append(f'      {TAG_LABEL}: "{image}:{tag}"')
        pinned.append(target)

# A service this environment runs that the release does not name. This is the
# `absent` case, and it is the one the manifest format calls out by name: "a
# manifest with a silent hole is how a service gets left on an old image while
# everything around it moves."
manifest_names = {s.get("name", "") for s in services}
for name in sorted(defined):
    root = name[: -len("-migrate")] if name.endswith("-migrate") else name
    if root in manifest_names or root == "postgres":
        continue
    missing.append(name)

# ── A MISSING PIN ON A SERVICE WITH A `build:` IS NOT A WARNING ──────────────
#
# The footer below has warned about `missing` since this script was written, and
# on 2026-08-11 that warning was correct, printed, and useless. Deploying 2.5.19
# to the app host pulled all 48 images, passed `--dry-run` ("all 46 image(s)
# exist") and then died at the switch:
#
#     #1 [internal] load local bake definitions
#     unable to prepare context: path "/home/savvaniss/dev/cloudsforge/pool-web" not found
#     deploy failed
#
# `pool` and `pool-web` are running services of the mainnet estate that NO
# manifest has ever named — `grep -c "name: pool" org/releases/*.yaml` is 0 in
# all twelve — so their `build:` survived into the deploy, and the app host has
# only five sibling repositories checked out. Compose refuses the whole `up`
# rather than half of it, so nothing moved; the release simply could not be
# deployed at all (micro-org#380).
#
# The distinction this makes is the one that decides which of those two endings
# happens. A service the release does not name and that has no `build:` keeps
# the image it already had — the silent hole the footer warns about, survivable
# and worth reading. A service the release does not name that DOES have a
# `build:` is a deploy that ends in a builder, on a host that may not have the
# source, minutes after it started pulling and with a message that names a
# filesystem path rather than a release. So it is refused here, by name, before
# anything is written.
#
# It refuses old manifests too, and that is deliberate rather than overlooked:
# rendering one of those and deploying it fails anyway — later, louder, and
# further from the cause. `--allow-unpinned-build` is for the host that really
# does have the source and knows it.
unpinned_builds = sorted(name for name in missing if name in buildable)
if unpinned_builds and not args.allow_unpinned_build:
    detail = []
    for name in unpinned_builds:
        detail.append(f"    {name}")
    sys.exit(
        f"FAIL: {manifest_path} does not name {len(unpinned_builds)} service(s) that this environment\n"
        f"       defines WITH A `build:`, so a release deploy would build them from a working tree:\n"
        + "\n".join(detail)
        + "\n\n"
        "       That is not a release. Either add them to the manifest pinned at the image they\n"
        "       are actually running, or list them under `absent:` and remove them from the\n"
        "       environment — a manifest with a silent hole is how a service gets left behind.\n"
        "       Pass --allow-unpinned-build to render anyway on a host that has the source."
    )

lines.append("")
lines.append(f"# pinned {len(pinned)} container(s) from {len(services)} manifest entries")
if any_digest:
    lines.append(f"# pinned by digest: {len(by_digest)}; by tag alone: {len(by_tag)}")
    if by_tag:
        # A PARTIAL DIGEST SET IS A SUPPORTED STATE, NOT A DEGRADED ONE.
        # `cfctl release` warns and succeeds when a release is cut in the
        # minutes before some images publish (micro-org#288), so this file will
        # meet mixed manifests. Named rather than counted, because "which ones
        # are still pinned by a mutable name" is the question an operator has.
        lines.append("# The entries below are pinned by a MUTABLE name — their manifest records no")
        lines.append("# digest, so what they pull is whatever the tag resolves to at `up` time:")
        for name in sorted(by_tag):
            lines.append(f"#   {name}")
if skipped:
    lines.append(f"# in the manifest but NOT in this environment: {', '.join(sorted(skipped))}")
if absent:
    lines.append(f"# the manifest lists as absent: {', '.join(absent)}")
if missing:
    lines.append("#")
    lines.append("# WARNING — this environment defines these and the release does not name them.")
    lines.append("# They keep whatever image they already had, which is the silent hole the")
    lines.append("# manifest format exists to prevent:")
    for name in missing:
        lines.append(f"#   {name}")

out = "\n".join(lines) + "\n"
if args.out:
    pathlib.Path(args.out).write_text(out)
    print(f"wrote {args.out}: {len(pinned)} container(s) pinned for release {version}", file=sys.stderr)
else:
    sys.stdout.write(out)

# Said on stderr as well as in the file, because the file is read by compose and
# this line is read by the operator running the deploy. Only when the manifest
# names digests at all: a release cut before 2026-08-09 names none, and telling
# an operator rolling one back that "0 of 48 are pinned by digest" would read as
# a fault in the render rather than as the age of the file.
if any_digest and by_tag:
    print(
        f"\nWARNING: {len(by_tag)} of {len(services)} entries in release {version} record no digest and are\n"
        f"pinned by tag: {', '.join(sorted(by_tag))}.\n"
        f"That is a supported state — a release cut before its images published — and not a render\n"
        f"failure. `cfctl release --verify` reports those entries as unverifiable.",
        file=sys.stderr,
    )

if missing:
    print(f"\nWARNING: {len(missing)} container(s) in this environment are not named by release {version}: {', '.join(missing)}", file=sys.stderr)
