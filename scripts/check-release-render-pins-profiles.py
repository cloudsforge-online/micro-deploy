#!/usr/bin/env python3
"""A release must pin every service it names, including the ones behind a profile.

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
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
RENDER = HERE / "release-render.py"

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
"""

MANIFEST = """\
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
absent:
"""


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


if shutil.which("docker") is None:
    # Not a pass. The renderer refuses to guess the service list without docker
    # for the same reason this refuses to certify it without one.
    fail("docker is not available, so the renderer cannot be exercised.")

with tempfile.TemporaryDirectory() as tmp:
    tmpdir = pathlib.Path(tmp)
    base = tmpdir / "docker-compose.fixture.yml"
    manifest = tmpdir / "9.9.9.yaml"
    base.write_text(COMPOSE)
    manifest.write_text(MANIFEST)

    proc = subprocess.run(
        [sys.executable, str(RENDER), str(manifest), "--base", str(base)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        fail(f"release-render.py exited {proc.returncode}:\n{proc.stderr}")

    out = proc.stdout

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
    if out.count("build: !reset null") != 2:
        fail(f"expected `build: !reset null` on both services:\n\n{out}")

    if "NOT in this environment" in out:
        fail(f"the renderer reported a service as absent from an environment that defines it:\n\n{out}")

print("ok: the release overlay pins profile-gated services as well as plain ones")
