#!/usr/bin/env python3
"""A deploy must fail before it touches anything, or not fail at all.

── THE OUTAGE THIS PREVENTS ─────────────────────────────────────────────────

`release-deploy.sh <version>` ships one version across all 48 deployables,
because the estate is only ever tested as a set. It used to do that with a
single `docker compose up -d`, which interleaves the phases: for each service in
turn compose pulls the image and then recreates the container.

So one `denied` from GHCR on the 30th image did not refuse the deploy — it
ABORTED IT PARTWAY. 29 services on the new release, 19 on the old one, a
combination no manifest describes and nobody has ever run, and `--rollback`
cannot name a previous version for the half that moved because they are on
different halves of two releases. A registry hiccup, which is a thing that
happens to a busy registry several times a week, produced an estate-wide
inconsistency that only a second successful deploy could clear.

The fix has two halves and this file exists because each is invisible in the
other's absence:

  * RETRY, so a blip is not a refusal. But retrying inside `up -d` would still
    abort partway once the retries ran out.
  * SPLIT, so every image is on the host before any container is replaced. But a
    split with no retry still refuses a whole release for one slow moment.

── WHAT THIS FILE ASSERTS ───────────────────────────────────────────────────

  1. On a clean run every image is pulled BEFORE the switch, and the switch
     happens exactly once. Read off the recorded invocations by ORDER, not by
     presence: "it pulls and it switches" was true of the broken version too.
  2. A transient failure is retried and the deploy still completes, with the
     wait DOUBLING between attempts. A fixed short retry against a rate limit is
     a client turning one slow moment into an outage of its own.
  3. A transient failure that never clears aborts — and aborts with no container
     touched. This is the case the old code got least wrong and most expensively:
     it is the one where refusing is right and refusing HALFWAY is the outage.
  4. A genuinely missing tag aborts IMMEDIATELY, on the first attempt. Retrying
     it would be harmless in isolation and is not harmless in practice: it turns
     "this release was never published" into a slow ambiguous failure, at the one
     moment somebody is watching the wrong window.
  5. An image that pulls without error and is not on the host afterwards aborts
     before the switch. `pulled` and `present` are different claims and only the
     second one is what the switch depends on.
  6. The switch phase is not ALLOWED to reach the registry — `--pull never` —
     so the ordering above is a property of the command rather than a habit of
     the script. Asserted against this CLI's own help, so it holds as an
     if-supported-then-used rather than being skipped where it matters.

── WHY A FIXTURE ESTATE AND A STUB DOCKER ───────────────────────────────────

The behaviour under test is what happens when a REGISTRY MISBEHAVES, and there
is no way to ask a real one to fail twice and then succeed. So `docker` is a stub
that plays a scripted sequence per image reference and records every invocation
it was given — while passing `docker compose config` through to the real CLI, so
the rendering, the interpolation and the overlay merge are all genuine and the
list of images the deploy pulls is derived the way it is derived in production.

`docker compose up` is recorded and never executed. The script under test is the
real one, byte for byte, copied into the fixture root only because it locates its
own compose files relative to itself.

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
DEPLOY = HERE / "release-deploy.sh"
RENDER = HERE / "release-render.py"
TARGETS = HERE / "render-prometheus-targets.py"

REGISTRY = "ghcr.io/cloudsforge-online/micro-"
VERSION = "1.0.0"

# Three attempts and a one-second base, so the two failing runs below cost 1s + 2s
# rather than the deploy default of five attempts from three seconds (45s each).
# The DOUBLING is asserted, not the absolute numbers, so this cannot pass against
# a fixed-interval retry that happens to be configured the same way.
ATTEMPTS = 3
BACKOFF = 1

IDENTITY = f"{REGISTRY}identity:{VERSION}"
LEDGER = f"{REGISTRY}ledger:{VERSION}"
# Not in the release manifest, and still needed by the project: the case that makes
# a project-wide `docker compose pull` unusable and a release-refs-only pull
# incomplete. A fresh host has neither.
THIRD_PARTY = "postgres:17-alpine"

# The health checks are load-bearing rather than decorative. Since micro-org#308
# the deploy renders Prometheus's scrape list in pre-flight, and it decides what
# is scrapable from the port each service's own health check probes `/readyz` on.
# Without them this fixture renders an empty target list, the renderer refuses —
# correctly — and every assertion below fails for a reason that is not the pull
# order. With them, this check also exercises the new gate.
COMPOSE = """\
services:
  identity:
    image: %sidentity:old
    build:
      context: .
    environment:
      PORT: "4000"
      IDENTITY_HANDOFF_ORIGINS: "https://hub${CF_WEB_SUFFIX},https://${CF_SITE_HOST}"
    healthcheck:
      test: ["CMD-SHELL", "node -e \\"fetch('http://127.0.0.1:4000/readyz')\\""]
  ledger:
    image: %sledger:old
    build:
      context: .
    environment:
      PORT: "4000"
    healthcheck:
      test: ["CMD-SHELL", "node -e \\"fetch('http://127.0.0.1:4000/readyz')\\""]
  postgres:
    image: %s
""" % (REGISTRY, REGISTRY, THIRD_PARTY)

# The renderer reads both of these from the deploy root, so the sandbox needs its
# own. They are the smallest documents that satisfy it: one static target so the
# "which services already have their own job" parse has something to find, and a
# tier for each manifest entry so the render is not refused for being untiered.
PROMETHEUS_YML = """\
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
"""

TIERS = """\
identity: "2"
ledger: "1"
"""

MANIFEST = f"""\
version: "{VERSION}"
generated: "2026-08-09T00:00:00.000Z"
generator: cfctl release
services:
  - name: identity
    repo: micro-identity
    kind: service
    image: {REGISTRY}identity
    tag: "{VERSION}"
    commit: "0000000000000000000000000000000000000000"
  - name: ledger
    repo: micro-ledger
    kind: service
    image: {REGISTRY}ledger
    tag: "{VERSION}"
    commit: "1111111111111111111111111111111111111111"
absent:
"""

TRAEFIK_ENV = """\
CF_WEB_APEX=cloudsforge.localtest.me
CF_WEB_SUFFIX=.cloudsforge.localtest.me
CF_SITE_HOST=cloudsforge.localtest.me
"""

# A stub, and it holds no credential of any kind — the real file is gitignored and
# is never read by anything here.
TOKENS_ENV = "CF_FIXTURE_TOKEN=not-a-secret\n"

DOCKER_STUB = '''#!/usr/bin/env python3
"""A docker that a test can make misbehave, and that records what it was asked."""
import json, os, pathlib, subprocess, sys

argv = sys.argv[1:]
log = pathlib.Path(os.environ["DOCKER_LOG"])
plan = json.loads(pathlib.Path(os.environ["DOCKER_PLAN"]).read_text())


def record():
    with log.open("a") as fh:
        fh.write(json.dumps(argv) + "\\n")
    # Which config directory docker was actually given, per invocation. A separate
    # file rather than a field on the line above, so every assertion written
    # against the argv log keeps reading a plain list.
    env_log = os.environ.get("DOCKER_ENV_LOG")
    if env_log:
        with pathlib.Path(env_log).open("a") as fh:
            fh.write((os.environ.get("DOCKER_CONFIG") or "") + "\\n")


def passthrough():
    sys.exit(subprocess.run([os.environ["REAL_DOCKER"], *argv]).returncode)


def scripted(kind, ref):
    """The next outcome for this reference: 'ok', or an error to print on stderr.

    A shorter list than the number of attempts repeats its last entry, so
    "fails forever" is one element rather than a guess about the retry count.
    """
    seq = plan.get(kind, {}).get(ref)
    if not seq:
        return "ok"
    # This invocation is already in the log, hence the -1: attempt one reads seq[0].
    seen = sum(1 for line in log.read_text().splitlines() if json.loads(line) == argv) - 1
    return seq[min(seen, len(seq) - 1)]


if argv[:1] == ["compose"]:
    # `config`, `--services` and `up --help` are real: the overlay merge, the
    # interpolation and the flag probe must all be the genuine article. `up` is
    # recorded and NEVER executed — this is a test, not a deploy.
    if "up" in argv and "--help" not in argv:
        record()
        sys.exit(0)
    passthrough()

record()

if argv[:2] == ["manifest", "inspect"]:
    outcome = scripted("manifest", argv[2])
elif argv[:1] == ["pull"]:
    ref = [a for a in argv[1:] if not a.startswith("-")][0]
    outcome = scripted("pull", ref)
elif argv[:2] == ["image", "inspect"]:
    ref = argv[2]
    outcome = "no such image: " + ref if ref in plan.get("absent", []) else "ok"
else:
    passthrough()

if outcome == "ok":
    sys.exit(0)
print(outcome, file=sys.stderr)
sys.exit(1)
'''

TUNNEL_STUB = """\
#!/bin/sh
# Stands in for the post-deploy reachability probe, which ssh's to the live host.
echo "  (fixture) tunnel origin check skipped"
"""


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


real_docker = shutil.which("docker")
if real_docker is None:
    # Not a skip. `docker compose config` is what resolves the overlay into the
    # list of images the deploy pulls, and without it every assertion below would
    # be about an empty list — which passes.
    fail("docker is not available, so the overlay cannot be resolved into a pull set.")


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    (root / "scripts").mkdir()
    (root / "prometheus").mkdir()
    (root / "compose" / "env").mkdir(parents=True)
    (root / "releases").mkdir()
    (root / "bin").mkdir()

    # The real script, byte for byte. Copied only because it resolves its compose
    # files relative to its own location.
    shutil.copy(DEPLOY, root / "scripts" / "release-deploy.sh")
    shutil.copy(RENDER, root / "scripts" / "release-render.py")
    # Also the real thing, for the same reason: `release-deploy.sh` runs it in
    # pre-flight and refuses the deploy if the release cannot be described to
    # Prometheus (micro-org#308), so a sandbox without it aborts before it
    # reaches the pull ordering this file is about.
    shutil.copy(TARGETS, root / "scripts" / "render-prometheus-targets.py")
    # Not a stub: `release-deploy.sh` refuses a crossed env-file pair through it
    # (micro-org#238), so the fixture needs the real thing or every run below
    # would abort before it reached a registry. The fixture's own file names
    # belong to neither environment, which that check passes over deliberately.
    shutil.copy(HERE / "check-env-files-agree.sh", root / "scripts")
    (root / "scripts" / "check-env-files-agree.sh").chmod(0o755)
    (root / "scripts" / "check-tunnel-origin.sh").write_text(TUNNEL_STUB)
    (root / "scripts" / "check-tunnel-origin.sh").chmod(0o755)

    (root / "compose" / "docker-compose.fixture.yml").write_text(COMPOSE)
    (root / "compose" / "env" / "traefik.env").write_text(TRAEFIK_ENV)
    (root / "compose" / "fixture.env").write_text("CF_PROJECT=release-deploy-fixture\n")
    (root / "compose" / "tokens.fixture.env").write_text(TOKENS_ENV)
    (root / "releases" / f"{VERSION}.yaml").write_text(MANIFEST)
    (root / "prometheus" / "prometheus.yml").write_text(PROMETHEUS_YML)
    (root / "prometheus" / "tiers.yaml").write_text(TIERS)

    (root / "bin" / "docker").write_text(DOCKER_STUB)
    (root / "bin" / "docker").chmod(0o755)

    # ── A DOCKER CONFIG WHOSE CREDENTIAL HELPER CANNOT RUN (micro-org#359) ────
    #
    # The app host is Windows/WSL: `~/.docker/config.json` inside the distro is
    # Docker Desktop's WINDOWS config, and its `credsStore` names a helper that
    # needs an interactive Windows logon session. Over ssh there is not one, so
    # every `docker pull` failed on the credential lookup — for a set of packages
    # that are public and needed no credential at all.
    #
    # The helper here EXISTS and FAILS, which is the combination that matters:
    # measured on 192.168.1.129 on 2026-08-10, `docker-credential-desktop.exe`,
    # `-wincred.exe` and `-ecr-login.exe` were all on PATH through WSL's Windows
    # interop. A check for the binary's presence would have passed on the very
    # host that could not deploy, so this fixture reproduces "present and broken"
    # rather than "absent".
    BROKEN_HELPER = "cffixturebroken"
    (root / "bin" / f"docker-credential-{BROKEN_HELPER}").write_text(
        "#!/bin/sh\n"
        "# The message the Windows helper actually produced, verbatim.\n"
        "echo 'A specified logon session does not exist."
        " It may already have been terminated.' >&2\n"
        "exit 1\n"
    )
    (root / "bin" / f"docker-credential-{BROKEN_HELPER}").chmod(0o755)

    broken_cfg = root / "dockercfg-broken"
    broken_cfg.mkdir()
    (broken_cfg / "config.json").write_text(json.dumps({"credsStore": BROKEN_HELPER}))
    # DOCKER_CONFIG also selects the CLI's PLUGIN directory, and on a machine whose
    # compose plugin is user-scoped — measured on a dev Mac 2026-08-11, plugins in
    # $HOME/.docker/cli-plugins — moving DOCKER_CONFIG takes `docker compose` away
    # with it and every later step dies with "unknown command: docker compose".
    # The fixture reproduces that layout when the host has it, so the script's
    # inheriting of the plugin directory is exercised where it is load-bearing and
    # simply absent where plugins are system-wide (CI).
    real_plugins = pathlib.Path(os.path.expanduser("~/.docker/cli-plugins"))
    if real_plugins.is_dir():
        (broken_cfg / "cli-plugins").symlink_to(real_plugins)

    fallback_cfg = root / "dockercfg-fallback"

    def credential_env():
        """A shell that looks like the app host's: a helper that is there and fails."""
        return {
            "DOCKER_CONFIG": str(broken_cfg),
            "DOCKER_CONFIG_FALLBACK": str(fallback_cfg),
        }

    plan_file = root / "plan.json"
    log_file = root / "docker.log"

    env_log_file = root / "docker-config.log"

    def deploy(plan, args=(VERSION,), env_extra=None):
        """One run of the real script against a scripted registry.

        Returns (exit code, combined output, list of recorded docker argvs).
        """
        plan_file.write_text(json.dumps(plan))
        log_file.write_text("")
        env_log_file.write_text("")
        env = dict(os.environ)
        env.update(
            DOCKER_ENV_LOG=str(env_log_file),
        )
        env.update(env_extra or {})
        env.update(
            PATH=f"{root / 'bin'}{os.pathsep}{env['PATH']}",
            REAL_DOCKER=real_docker,
            DOCKER_PLAN=str(plan_file),
            DOCKER_LOG=str(log_file),
            BASE="compose/docker-compose.fixture.yml",
            RELEASES="releases",
            OVERLAY="compose/docker-compose.release.fixture.yml",
            ESTATE_ENV="compose/fixture.env",
            TOKENS_FILE="compose/tokens.fixture.env",
            REGISTRY_ATTEMPTS=str(ATTEMPTS),
            REGISTRY_BACKOFF=str(BACKOFF),
        )
        proc = subprocess.run(
            ["bash", str(root / "scripts" / "release-deploy.sh"), *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(root),
        )
        calls = [json.loads(line) for line in log_file.read_text().splitlines()]
        return proc.returncode, proc.stdout + proc.stderr, calls

    def pulls_of(calls, ref):
        return [c for c in calls if c[:1] == ["pull"] and ref in c]

    def inspects_of(calls, ref):
        return [c for c in calls if c[:2] == ["manifest", "inspect"] and ref in c]

    def switches(calls):
        return [c for c in calls if c[:1] == ["compose"] and "up" in c and "--help" not in c]

    # ── 1. A CLEAN RUN PULLS EVERYTHING, THEN SWITCHES ONCE ──────────────────
    code, out, calls = deploy({})
    if code != 0:
        fail(f"a deploy with a healthy registry did not succeed (exit {code}):\n\n{out}")

    switch = switches(calls)
    if len(switch) != 1:
        fail(f"expected exactly one `compose up`, recorded {len(switch)}:\n\n{out}")

    for ref in (IDENTITY, LEDGER, THIRD_PARTY):
        if not pulls_of(calls, ref):
            missing = "the release does not name it, and compose would still need it" \
                if ref == THIRD_PARTY else "it is pinned by the release"
            fail(
                f"{ref} was never pulled before the switch, though {missing}.\n"
                f"       Compose would have had to fetch it DURING the switch, which is the\n"
                f"       interleaving this whole change exists to end.\n\n{out}"
            )

    switch_at = calls.index(switch[0])
    late = [c for c in calls[switch_at:] if c[:1] == ["pull"]]
    if late:
        fail(
            "an image was pulled AFTER the switch began, so the two phases are still\n"
            f"       interleaved and a registry failure can still land halfway: {late}\n\n{out}"
        )

    # ── 6. AND THE SWITCH IS NOT ALLOWED TO REACH THE REGISTRY ───────────────
    help_text = subprocess.run(
        [real_docker, "compose", "up", "--help"], capture_output=True, text=True
    )
    if "--pull" in (help_text.stdout + help_text.stderr):
        joined = " ".join(switch[0])
        if "--pull never" not in joined:
            fail(
                "this compose supports `--pull never` and the switch was invoked without it.\n"
                "       Ordering the phases is then a convention rather than a property: compose\n"
                "       stays free to contact the registry mid-switch and abort partway, which is\n"
                "       the exact failure the phase split was written for.\n"
                f"       invoked: {joined}"
            )

    # ── 2. A TRANSIENT FAILURE IS RETRIED, AND THE WAIT DOUBLES ──────────────
    code, out, calls = deploy({"pull": {LEDGER: ["denied: denied", "denied: denied", "ok"]}})
    if code != 0:
        fail(
            "a deploy was refused because ONE image needed two attempts. GHCR returns\n"
            f"       `denied` under load and to a token a second from being refreshed (exit {code}).\n\n{out}"
        )
    if len(pulls_of(calls, LEDGER)) != 3:
        fail(
            f"expected 3 pull attempts for the flaky image, saw {len(pulls_of(calls, LEDGER))}:\n\n{out}"
        )
    if not switches(calls):
        fail(f"the deploy reported success without ever switching:\n\n{out}")

    waits = [int(w) for w in re.findall(r"waiting (\d+)s", out)]
    if len(waits) < 2:
        fail(f"the retries did not announce how long they waited; saw {waits}:\n\n{out}")
    if waits[1] <= waits[0]:
        fail(
            "the wait between attempts does not grow. The two things that actually cause a\n"
            "       blip — a rate limit and a saturated link — are both made WORSE by retrying\n"
            f"       at a fixed short interval: a client turning one slow moment into its own\n"
            f"       outage. waits: {waits}"
        )

    # ── 3. A TRANSIENT FAILURE THAT NEVER CLEARS ABORTS, TOUCHING NOTHING ────
    code, out, calls = deploy({"pull": {LEDGER: ["denied: denied"]}})
    if code == 0:
        fail(f"an image that could not be pulled at all was deployed anyway:\n\n{out}")
    if len(pulls_of(calls, LEDGER)) != ATTEMPTS:
        fail(
            f"expected {ATTEMPTS} attempts before giving up, saw "
            f"{len(pulls_of(calls, LEDGER))}:\n\n{out}"
        )
    if switches(calls):
        fail(
            "THE ESTATE WAS SWITCHED WITH AN IMAGE MISSING. This is the outage: some\n"
            "       services move to the new release and the rest stay on the old one, a\n"
            "       combination no manifest describes and no rollback can name.\n\n"
            f"{out}"
        )
    if "denied" not in out or "GHCR" not in out:
        fail(
            "the abort does not say what a persistent `denied` usually means — a package\n"
            "       that inherited a private repository's visibility — so the operator is left\n"
            f"       to rediscover the GHCR visibility trap during a release.\n\n{out}"
        )

    # ── 4. A MISSING TAG ABORTS ON THE FIRST ATTEMPT ─────────────────────────
    code, out, calls = deploy({"manifest": {LEDGER: ["manifest unknown"]}})
    if code == 0:
        fail(f"a release naming an image that does not exist was deployed:\n\n{out}")
    if len(inspects_of(calls, LEDGER)) != 1:
        fail(
            "a tag the registry says does not exist was retried "
            f"({len(inspects_of(calls, LEDGER))} attempts). The registry looked and answered;\n"
            "       trying again gets the same answer more slowly, and turns 'this release was\n"
            f"       never published' into a slow ambiguous failure.\n\n{out}"
        )
    if pulls_of(calls, IDENTITY) or switches(calls):
        fail(f"the deploy pulled or switched after a missing tag was found:\n\n{out}")

    # ── 5. PULLED AND PRESENT ARE DIFFERENT CLAIMS ───────────────────────────
    code, out, calls = deploy({"absent": [LEDGER]})
    if code == 0:
        fail(
            "an image that pulled without error and is NOT on this host was deployed. The\n"
            "       switch depends on the image being present, not on the pull having exited 0\n"
            f"       — a manifest list with no entry for this platform does exactly this.\n\n{out}"
        )
    if switches(calls):
        fail(f"the estate was switched with an image that is not on the host:\n\n{out}")

    # ── AND --dry-run STILL CHANGES NOTHING ──────────────────────────────────
    code, out, calls = deploy({}, args=(VERSION, "--dry-run"))
    if code != 0:
        fail(f"--dry-run failed against a healthy registry (exit {code}):\n\n{out}")
    if calls_pulled := [c for c in calls if c[:1] == ["pull"]]:
        fail(
            "--dry-run pulled images. It is documented as 'render and check, change\n"
            f"       nothing', and tens of gigabytes is a change: {calls_pulled}\n\n{out}"
        )
    if switches(calls):
        fail(f"--dry-run switched the estate:\n\n{out}")

    # ── 7. A CREDENTIAL HELPER THAT CANNOT RUN IS ROUTED AROUND ──────────────
    #
    # Not merely reported. Every deploy from the app host over ssh hits this, and
    # a deploy that requires the operator to know an undocumented `export` first
    # is a deploy the estate cannot perform from its own documentation.
    code, out, calls = deploy({}, env_extra=credential_env())
    if code != 0:
        fail(
            "a deploy could not complete on a host whose docker credential helper fails,\n"
            "       though the estate's packages are public and need no credential at all.\n"
            f"       This is every ssh deploy from the Windows/WSL app host (exit {code}).\n\n{out}"
        )
    if not switches(calls):
        fail(f"the credential-helper run reported success without switching:\n\n{out}")

    used = [line for line in env_log_file.read_text().splitlines() if line]
    if not used:
        fail("no docker invocation was recorded, so which config it used cannot be read.")
    wrong = sorted({u for u in used if u != str(fallback_cfg)})
    if wrong:
        fail(
            "docker was invoked with a config directory other than the helper-free one:\n"
            f"       {wrong}\n"
            "       The pre-flight reported it had routed around the broken helper and then\n"
            "       did not, which is the same eighteen-minute stall with a reassuring line\n"
            f"       of output above it.\n\n{out}"
        )
    written = json.loads((fallback_cfg / "config.json").read_text())
    if written.get("credsStore") or written.get("credHelpers"):
        fail(
            f"the config the deploy switched to names a credential helper itself: {written}\n"
            "       It exists to name none; docker would consult it and fail identically."
        )
    if "logon session" not in out:
        fail(
            "the pre-flight did not print what the credential helper said. `error getting\n"
            "       credentials` reads as a missing login and the remedy is the opposite, so\n"
            f"       the helper's own message is the thing that makes it diagnosable.\n\n{out}"
        )

    # ── 8. AND ONE THAT SLIPS PAST THE PRE-FLIGHT STOPS THE RUN AT ONCE ──────
    #
    # THIS IS THE EIGHTEEN MINUTES. A helper can pass the pre-flight's `list` probe
    # and still fail the pull, so the classification has to hold on its own.
    #
    # A credential failure is not the registry's answer and not a blip: docker
    # never opened a connection, and the result is a property of the MACHINE. It
    # will be identical for every image. Retrying it five times per reference
    # across ~50 references is 3+6+12+24 = 45s of sleeping each, ~37 minutes, to
    # re-derive a fact that was complete at second zero.
    #
    # Asserted as ONE attempt and a run that stops, not merely as an eventual
    # failure: "it fails in the end" was true of the version that hung.
    creds_error = (
        "error getting credentials - err: exit status 1, out: `A specified logon "
        "session does not exist. It may already have been terminated.`"
    )
    code, out, calls = deploy({"pull": {LEDGER: [creds_error]}}, env_extra=credential_env())
    if code == 0:
        fail(f"a deploy whose images could not be pulled at all reported success:\n\n{out}")
    attempts = len(pulls_of(calls, LEDGER))
    if attempts != 1:
        fail(
            f"a credential failure was retried: {attempts} attempts for one image. docker\n"
            "       never reached a registry — the helper failed locally — so every attempt\n"
            "       asks a question whose answer cannot change, and the deploy sleeps its way\n"
            f"       through the whole release before saying so.\n\n{out}"
        )
    later = pulls_of(calls, THIRD_PARTY)
    if later:
        fail(
            "the run carried on to the next image after proving this host cannot\n"
            "       authenticate to any registry. One reference is the whole proof; the rest\n"
            f"       cost the full backoff each to reach the same conclusion.\n\n{out}"
        )
    if switches(calls):
        fail(f"the estate was switched after a credential failure:\n\n{out}")
    if "DOCKER_CONFIG" not in out:
        fail(
            "the abort does not name the remedy. `error getting credentials` reads as a\n"
            "       missing docker login, and the fix is to remove the credential path\n"
            f"       entirely — which nobody guesses at 3am.\n\n{out}"
        )

print(
    "ok: every image is pulled before any container is replaced, a transient registry\n"
    "    failure is retried with a growing wait, one that never clears aborts without\n"
    "    touching a container, a tag the registry says does not exist aborts at once,\n"
    "    and a credential helper this host cannot run is routed around rather than\n"
    "    retried — or, if it slips past, stops the run on the first reference"
)
