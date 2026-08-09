#!/usr/bin/env python3
"""The provenance check must survive the release mechanism it exists to verify.

── THE DAY THIS WOULD HAVE BEEN FOUND OTHERWISE ─────────────────────────────

`check-running-provenance.sh` answers "what is running, and which git ref did it
come from?" by reading `docker ps` and comparing each container's TAG against the
`version` in the package.json of a watched ref. It has always split the image
reference on `:`.

micro-deploy#18 made `release-render.py` emit `image@sha256:…` for every manifest
entry carrying a digest, and `cfctl release` has recorded digests since
micro-org#288 — so 2.5.8 is the first release this estate deploys by digest. A
digest names bytes and not a version, and the split on `:` had nothing to split.

WHAT THAT COST DEPENDS ON THE HOST'S IMAGE STORE, AND BOTH ANSWERS ARE WRONG.
`docker ps` truncates `{{.Image}}` unless told not to, and for a digest reference
the truncation is not a shortening but a different string. Measured 2026-08-09
against the docker CLI with `/containers/json` served by a stub, so that the two
stores could be compared side by side:

    ImageID != the index digest (overlay2, what the estate host runs):
        {{.Image}}   -> ghcr.io/cloudsforge-online/micro-identity
    ImageID == the index digest (containerd image store):
        {{.Image}}   -> d8d8d8d8d8d8
    either store, --no-trunc:
        {{.Image}}   -> ghcr.io/cloudsforge-online/micro-identity@sha256:d8d8…

On the estate's store the digest is DELETED, and what remains parses cleanly as a
repository with an empty tag — so the check would not have gone quiet. It would
have reported MISMATCH on all 46 services at once, during a release, which reads
as a provenance emergency rather than as its own defect.

── WHAT THIS FILE ASSERTS ───────────────────────────────────────────────────

The overlay carries the tagged reference twice — a comment for whoever opens the
file, and the label `online.cloudsforge.release.tag` because `docker compose
config` re-emits from a parsed model and drops every comment. Only the label
reaches a container, so only the label can be read back off one.

Nothing here is typed twice. The rows fed to the provenance check are built from
what the REAL renderer emits and what REAL `docker compose config` resolves it
to, so if the label is ever renamed on either side of that seam this goes red
rather than testing a string that no longer exists.

  1. A digest-pinned row reaches the same verdict as the same service pinned by
     tag. Asserted DIFFERENTIALLY — the same fixture is rendered both ways and
     the two verdicts compared — because "the digest run exits 0" is satisfied by
     a check that skips every container it cannot read.
  2. A digest-pinned row whose label is MISSING fails loudly and is never
     reported as OK or SAME. Skipping it would make the check go quiet on exactly
     the releases the digest mechanism exists for, and no alarm gets read as
     provenance verified.
  3. A label naming a DIFFERENT repository than the image it sits on is a
     MISMATCH. The repository name is derived from the image; a check that took
     it from the label would let a mispinned container attribute itself to
     whatever it claimed.
  4. The reference is fetched with `--no-trunc`. The stub `ssh` records the
     command it was asked to run, so this is read off the real invocation rather
     than grepped out of the script's source.
  5. The fixture is checked against itself. If the render ever stops producing a
     digest pin or a label, every assertion above would pass while exercising
     nothing — the vacuous check this estate keeps paying for.

── WHY A FIXTURE ESTATE ─────────────────────────────────────────────────────

The check ssh's to the live host and reads git out of a sibling checkout, and CI
has neither. Both are already overridable — `CLOUDSFORGE_HOST` and
`CLOUDSFORGE_ESTATE` — so this builds two throwaway git repositories with real
package.json versions on real branches and puts a stub `ssh` on PATH that prints
the `docker ps` rows. The script under test is the real one, unmodified.

Exit non-zero on failure, print nothing but the verdict on success.
"""
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
RENDER = HERE / "release-render.py"
PROVENANCE = HERE / "check-running-provenance.sh"

TAG_LABEL = "online.cloudsforge.release.tag"

# The registry prefix the provenance check strips to get a repository name. The images below must
# carry it or the check would treat them as somebody else's containers and skip them — which is a
# pass, and the wrong one.
REGISTRY = "ghcr.io/cloudsforge-online/micro-"

# Syntactically real: `sha256:` and 64 lower-case hex, the shape `release-render.py` validates
# before it will pin one. Not a real GHCR object — nothing here pulls.
DIGEST = "sha256:" + "5c" * 32

VERSION = "9.9.9"
MAIN_VERSION = "1.0.0"

COMPOSE = f"""\
services:
  plain:
    image: {REGISTRY}plain:old
    build:
      context: .
  gated:
    profiles: ["somefeature"]
    image: {REGISTRY}gated:old
    build:
      context: .
"""

# MIXED ON PURPOSE, the same shape `check-release-render-pins-profiles.py` uses: `plain` carries no
# digest (every manifest cut before 2026-08-09, which is the rollback path) and `gated` carries one.
MANIFEST = f"""\
version: "{VERSION}"
generated: "2026-08-09T00:00:00.000Z"
generator: cfctl release
services:
  - name: plain
    repo: micro-plain
    kind: service
    image: {REGISTRY}plain
    tag: "{VERSION}"
    commit: "0000000000000000000000000000000000000000"
  - name: gated
    repo: micro-gated
    kind: service
    image: {REGISTRY}gated
    tag: "{VERSION}"
    commit: "1111111111111111111111111111111111111111"
    digest: "{DIGEST}"
absent:
"""

SSH_STUB = """\
#!/bin/sh
# Stands in for the estate host. Records the command it was asked to run — assertion 4 reads
# `--no-trunc` off this rather than off the script's source — and prints the fixture rows.
printf '%s\\n' "$*" >> "$SSH_ASKED"
cat "$PS_ROWS"
"""


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


if shutil.which("docker") is None:
    fail("docker is not available, so the renderer cannot be exercised.")
if shutil.which("node") is None:
    # The provenance check reads each package.json version with `node -p`, so without node every
    # comparison below would be "" against "" and every verdict meaningless.
    fail("node is not available, so the provenance check cannot read a package.json version.")


def git(repo, *args):
    subprocess.run(
        ["git", "-c", "user.email=ci@example.invalid", "-c", "user.name=ci", "-C", str(repo), *args],
        check=True,
        capture_output=True,
    )


def make_repo(root, name, ref_branch):
    """A throwaway checkout whose branch and `main` declare DIFFERENT versions.

    Different on purpose: with both the same, every verdict is `SAME` — an honest answer the check
    gives when provenance is unprovable, and one that would let a broken comparison look right.
    `OK` is only reachable when the two disagree, so this is what makes the verdicts below load-bearing.
    """
    repo = root / name
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "main")
    (repo / "package.json").write_text(json.dumps({"name": name, "version": MAIN_VERSION}) + "\n")
    git(repo, "add", "package.json")
    git(repo, "commit", "-qm", "main")
    git(repo, "checkout", "-q", "-b", ref_branch)
    (repo / "package.json").write_text(json.dumps({"name": name, "version": VERSION}) + "\n")
    git(repo, "commit", "-qam", "the release")
    return repo


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = pathlib.Path(tmp)
    base = tmpdir / "docker-compose.fixture.yml"
    manifest = tmpdir / f"{VERSION}.yaml"
    base.write_text(COMPOSE)

    estate = tmpdir / "estate"
    for name in ("plain", "gated"):
        make_repo(estate, name, f"design-system/{name}")

    bin_dir = tmpdir / "bin"
    bin_dir.mkdir()
    (bin_dir / "ssh").write_text(SSH_STUB)
    (bin_dir / "ssh").chmod(0o755)

    rows_file = tmpdir / "rows"
    asked_file = tmpdir / "asked"

    def rendered_services(text):
        """What compose actually resolves the overlay to: image and labels, per service.

        Read through `docker compose config` rather than off the rendered YAML because that is the
        model a container is created from — the same reason the renderer emits a label at all.
        """
        overlay = tmpdir / "docker-compose.release.yml"
        overlay.write_text(text)
        proc = subprocess.run(
            ["docker", "compose", "--profile", "somefeature",
             "-f", str(base), "-f", str(overlay), "config", "--format", "json"],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            fail(f"`docker compose config` cannot parse the rendered overlay:\n{proc.stderr}")
        services = json.loads(proc.stdout)["services"]
        return {
            name: (spec.get("image", ""), (spec.get("labels") or {}).get(TAG_LABEL, ""))
            for name, spec in services.items()
        }

    def render(manifest_text, label):
        manifest.write_text(manifest_text)
        proc = subprocess.run(
            [sys.executable, str(RENDER), str(manifest), "--base", str(base)],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            fail(f"release-render.py exited {proc.returncode} on the {label} manifest:\n{proc.stderr}")
        return proc.stdout

    def provenance(rows):
        """The real provenance check, against the fixture estate and a stub host."""
        rows_file.write_text("".join(f"{image}\t{tag}\n" for image, tag in rows))
        env = dict(os.environ)
        env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
        env["CLOUDSFORGE_ESTATE"] = str(estate)
        env["CLOUDSFORGE_HOST"] = "stub@example.invalid"
        env["SSH_ASKED"] = str(asked_file)
        env["PS_ROWS"] = str(rows_file)
        proc = subprocess.run(
            ["bash", str(PROVENANCE), "fixture", "design-system/"],
            capture_output=True,
            text=True,
            env=env,
        )
        return proc.returncode, proc.stdout + proc.stderr

    def verdict(output, service):
        """The one line about a service, with the reference itself removed.

        The comparison in assertion 1 is between a tag-pinned run and a digest-pinned one, and the
        two legitimately differ in how the reference is SPELT. What must not differ is the verdict.
        """
        for line in output.split("\n"):
            if re.match(rf"^\s+\S+\s+{re.escape(service)}\s", line):
                return " ".join(line.split())
        return ""

    # ── THE FIXTURE, BEFORE IT IS TRUSTED ────────────────────────────────────
    mixed = render(MANIFEST, "mixed")
    services = rendered_services(mixed)

    if "gated" not in services or "plain" not in services:
        fail(f"the overlay does not pin both fixture services; got {sorted(services)}")
    gated_image, gated_label = services["gated"]
    plain_image, plain_label = services["plain"]

    if "@sha256:" not in gated_image:
        fail(
            "the render pins `gated` as {!r}, which is not a digest. Every assertion below would\n"
            "       pass without a digest ever being read — the vacuous check this file refuses.".format(gated_image)
        )
    if not gated_label:
        fail(
            f"the render pins `gated` by digest and `docker compose config` carries no {TAG_LABEL}\n"
            f"       for it. The provenance check has nothing to read the version from, and the\n"
            f"       assertions below would be measuring the absence rather than the mechanism."
        )
    if plain_label or "@sha256:" in plain_image:
        fail(f"`plain` records no digest and rendered as {plain_image!r} / label {plain_label!r}")

    # ── 1. THE DIGEST-PINNED ROW REACHES THE SAME VERDICT AS THE TAG ─────────
    code, out = provenance([(gated_image, gated_label), (plain_image, plain_label)])
    if code != 0:
        fail(f"the provenance check failed on a correctly digest-pinned estate (exit {code}):\n\n{out}")
    if "nothing was verified" in out:
        fail(f"a digest-pinned estate was reported as unverifiable:\n\n{out}")
    digest_verdict = verdict(out, "gated")
    if not digest_verdict.startswith("OK gated"):
        fail(
            f"the digest-pinned service is not attributed to the ref that declares its version.\n"
            f"       verdict: {digest_verdict!r}\n\n{out}"
        )

    # Differentially, against the same fixture rendered without the digest. A check that ignored
    # the label and happened to reach OK some other way disagrees here.
    tagged = render(MANIFEST.replace(f'    digest: "{DIGEST}"\n', ""), "digest-free")
    tag_services = rendered_services(tagged)
    tag_image, tag_label = tag_services["gated"]
    if "@sha256:" in tag_image:
        fail(f"a manifest naming no digest still rendered a digest pin: {tag_image!r}")
    code, tag_out = provenance([(tag_image, tag_label), (plain_image, plain_label)])
    if code != 0:
        fail(f"the provenance check failed on a tag-pinned estate (exit {code}):\n\n{tag_out}")
    if verdict(tag_out, "gated") != digest_verdict:
        fail(
            "the same build reaches a different verdict depending on whether the release pinned it\n"
            "       by tag or by digest, which is the whole property this file is about.\n"
            f"       by tag:    {verdict(tag_out, 'gated')!r}\n"
            f"       by digest: {digest_verdict!r}"
        )

    # ── 2. A DIGEST PIN WITH NO LABEL IS A FAILURE, NEVER A SKIP ─────────────
    code, out = provenance([(gated_image, ""), (plain_image, plain_label)])
    if code == 0:
        fail(
            "a container pinned by digest and carrying no release-tag label was reported as a PASS.\n"
            "       There is no version on that container to compare against anything, so the only\n"
            "       honest answers are 'failed' and 'this check is broken'. Silence is neither, and\n"
            "       silence is what an operator reads as provenance verified.\n\n"
            f"{out}"
        )
    if "NO TAG" not in out or "gated" not in out:
        fail(f"the unlabelled digest pin failed without naming the container or the reason:\n\n{out}")
    if verdict(out, "gated").startswith(("OK", "SAME")):
        fail(f"the unlabelled digest pin was attributed to a ref anyway:\n\n{out}")

    # ── 3. A LABEL NAMING ANOTHER SERVICE IS A MISMATCH ──────────────────────
    code, out = provenance([(gated_image, f"{REGISTRY}plain:{VERSION}"), (plain_image, plain_label)])
    if code == 0:
        fail(
            "a digest-pinned container whose release-tag label names a DIFFERENT service passed.\n"
            "       An overlay that pinned one service to another's release line would be reported\n"
            "       as verified, and the repository each verdict is about would be the wrong one.\n\n"
            f"{out}"
        )
    if not verdict(out, "gated").startswith("MISMATCH"):
        fail(f"the cross-labelled container was not reported as a MISMATCH:\n\n{out}")

    # ── 4. THE REFERENCE IS READ UNTRUNCATED ─────────────────────────────────
    asked = asked_file.read_text() if asked_file.exists() else ""
    if not asked.strip():
        fail("the provenance check never invoked ssh, so nothing above exercised its host read.")
    if "--no-trunc" not in asked:
        fail(
            "the provenance check reads `docker ps` without `--no-trunc`. On the estate's image\n"
            "       store that DELETES the digest from `{{.Image}}` — measured 2026-08-09, a\n"
            "       digest-pinned container renders as `ghcr.io/cloudsforge-online/micro-identity`\n"
            "       with no digest and no tag — so every service reports MISMATCH with an empty\n"
            "       running version, on the first release that uses the mechanism.\n"
            f"       asked: {asked.strip()}"
        )
    if TAG_LABEL not in asked:
        fail(
            f"the provenance check does not ask `docker ps` for the {TAG_LABEL} label, so the only\n"
            f"       carrier of a version onto a digest-pinned container is never read.\n"
            f"       asked: {asked.strip()}"
        )

print(
    "ok: a digest-pinned release reaches the same provenance verdict as the tag it was resolved\n"
    "    from, an unlabelled digest pin fails loudly rather than silently, a label naming another\n"
    "    service is a mismatch, and the reference is read with --no-trunc so the digest survives"
)
