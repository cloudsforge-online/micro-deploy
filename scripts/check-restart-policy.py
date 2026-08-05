#!/usr/bin/env python3
"""Every long-running service comes back by itself, and this is what makes that checkable.

THE DEFECT THIS GUARDS, AND WHY A COMMENT COULD NOT
---------------------------------------------------
Compose has NO default restart policy. A service with no `restart:` key gets
Docker's default, which is `no` — the container stays down after a host reboot, a
`systemctl restart docker`, or an OOM kill, and nothing starts it again.

That is what `compose/docker-compose.estate.yml` had for all 29 APIs and for
`postgres`. It was fixed by putting `restart: unless-stopped` on a shared YAML
anchor, `x-service-defaults`. But an anchor is opt-in: a service that simply
forgets `<<: *service-defaults` inherits `no` and will not survive a reboot, and
NOTHING NOTICED. The regression would be silent and would be discovered by an
outage — which is the definition of a check that measures nothing.

It had already happened by the time this was written. See --live, below.

WHAT IT CHECKS
--------------
Two modes, because the file and the estate are two different facts and only one
of them is what actually reboots.

  --config   Render `docker compose config` over the given files and assert that
             every service resolves to `unless-stopped` or appears on the
             ONE_SHOTS allow-list below. This is the CI half: it runs on a
             checkout, with no estate, and fails a pull request.

  --live     `docker inspect` every container in a running compose project and
             assert the same thing about what is ACTUALLY RUNNING. This catches
             two things --config cannot see:

               1. ORPHANS. A container whose service was deleted from the compose
                  file keeps running under the old definition until somebody runs
                  `up --remove-orphans`. It is invisible to every render.
               2. OVERLAYS. A release overlay is a GENERATED file (see
                  scripts/release-render.py) and is gitignored, so CI never reads
                  the compose file the estate is actually deployed from.

             Both of those are the same live defect, found by this script the day
             it was written: `cf-testnet-foresight-admin-web-1` was running with
             `restart: no`. `foresight-admin-web` was removed from the base file
             by the P13 fold (docker-compose.estate.yml, "WAS HERE (4139)"), but
             a STALE `compose/docker-compose.release.testnet.yml` still pinned an
             image for it. An overlay naming a service the base does not define
             does not override anything — it CREATES a service, with an image and
             nothing else: no environment, no health check, no dependencies, and
             no restart policy. release-render.py refuses to emit that (see its
             own note at :117-120), and refusing to GENERATE it is not the same
             as noticing one that was generated before the guard existed.

THE POLICY WORD IS NOT THE WHOLE PROPERTY
-----------------------------------------
`restart:` is a promise about the steady state; the reboot is about the first
ninety seconds, when a service is up and `postgres` is not yet accepting
connections. So this also asserts the two things that decide whether a service
survives that window:

  * NO MAXIMUM RETRY COUNT. `on-failure:5` is a policy that GIVES UP. A service
    that loses five races against postgres on a cold, loaded box is then down
    for good, with a restart policy configured and a green check beside it —
    exactly the failure this file exists to prevent. `unless-stopped` retries
    forever with backoff, which is why it is the only accepted answer.

  * `always` IS REJECTED TOO, and that is deliberate rather than pedantic. The
    difference is what happens after an operator deliberately stops a container:
    `always` brings it back when the daemon restarts even then, which turns
    `docker stop` into something that does not survive a reboot and makes taking
    one service out for maintenance impossible to express.

Docker does NOT evaluate `depends_on` when it replays restart policies at daemon
start — ordering is a property of `up`, not of the daemon. That is not a defect
to fix here and it is why the retry-count rule above is the one that matters: the
estate does not come back in order, it comes back all at once and converges.

Deliberately dependency-free — json and subprocess, no PyYAML. Same rule as
scripts/check-runbooks.py: a check that only runs where a library happens to be
installed is a check that stops running.
"""
import argparse
import json
import subprocess
import sys

# ── THE ALLOW-LIST ────────────────────────────────────────────────────────────
#
# A service that MUST NOT restart is a real category, and every member of it
# states its reason here. A service that merely never had the question asked is
# not a category — that is the whole distinction this file is built on, and it is
# why the allow-list is names-and-reasons rather than a pattern that would
# quietly absorb the next mistake.
#
# These are checked, not merely excused: an allow-listed service must resolve to
# exactly `no`. A one-shot that silently became `unless-stopped` is the migrator
# crash-loop described below, and it would fail here too.
ONE_SHOT_SUFFIX = "-migrate"
ONE_SHOT_SUFFIX_REASON = (
    "a migrator runs once and exits 0. `unless-stopped` restarts a container that "
    "exits for ANY reason, including success, so it would re-run its migrations on "
    "every daemon start for ever — and the non-idempotent ones would fail on the "
    "second pass, leaving a crash loop and a `depends_on: "
    "service_completed_successfully` that never completes."
)
ONE_SHOTS = {
    "custody-keys-init": "mints the custody keyring into a volume and exits; re-running it on every boot would churn key material.",
    "studio-assets-init": "copies seed assets into a volume and exits.",
    "tessera-assets-check": "asserts the asset volume is populated and exits; it is a gate, not a service.",
}


def one_shot_reason(name):
    """Why this service is allowed to have `restart: no`, or None if it is not."""
    if name in ONE_SHOTS:
        return ONE_SHOTS[name]
    if name.endswith(ONE_SHOT_SUFFIX):
        return ONE_SHOT_SUFFIX_REASON
    return None


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"FAIL: `{' '.join(cmd)}` failed:\n{proc.stderr.strip()}")
    return proc.stdout


def check(observed, what):
    """observed: list of (service, policy, max_retries). Returns a failure list."""
    bad = []
    for name, policy, retries in sorted(observed):
        reason = one_shot_reason(name)
        if reason:
            # The allow-list is asserted in both directions.
            if policy != "no":
                bad.append(
                    f"{name}: is a one-shot ({reason.split('.')[0]}) but resolves to "
                    f"`{policy}` — it would re-run on every daemon start"
                )
            continue
        if policy in (None, "", "<unset>"):
            bad.append(
                f"{name}: HAS NO `restart:` KEY, so it inherits Docker's default of "
                f"`no` and will not come back after a reboot. It is missing "
                f"`<<: *service-defaults`, or it is an overlay-only service the base "
                f"file does not define."
            )
        elif policy != "unless-stopped":
            bad.append(
                f"{name}: `restart: {policy}` — the only accepted policy for a "
                f"long-running service is `unless-stopped`, and it is not on the "
                f"one-shot allow-list in {__file__.rsplit('/', 1)[-1]}"
            )
        elif retries:
            bad.append(
                f"{name}: `unless-stopped` with a maximum retry count of {retries} — "
                f"a policy that gives up is not a policy that survives a cold boot"
            )
    if bad:
        print(f"restart-policy failures in {what}:", *bad, sep="\n  ")
        return 1
    counted = len(observed)
    one_shots = sum(1 for n, _, _ in observed if one_shot_reason(n))
    print(
        f"ok: {what} — {counted - one_shots} long-running service(s) all "
        f"`unless-stopped` with no retry cap, {one_shots} allow-listed one-shot(s) at `no`"
    )
    return 0


def from_config(files, env_file, project):
    cmd = ["docker", "compose"]
    if env_file:
        cmd += ["--env-file", env_file]
    for f in files:
        cmd += ["-f", f]
    cmd += ["config", "--format", "json"]
    data = json.loads(run(cmd))
    observed = []
    for name, svc in data.get("services", {}).items():
        policy = svc.get("restart")
        retries = 0
        # Compose renders a retry cap into the policy string, `on-failure:5`.
        if policy and ":" in policy:
            policy, _, tail = policy.partition(":")
            retries = int(tail) if tail.isdigit() else 0
        observed.append((name, policy, retries))
    if not observed:
        sys.exit("FAIL: the rendered configuration defines no services at all")
    return observed, f"{project or data.get('name', 'config')} ({', '.join(files)})"


def from_live(project):
    ids = run(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"]).split()
    if not ids:
        sys.exit(
            f"FAIL: no containers are running in compose project `{project}`. "
            f"A live check with nothing to check is the vacuous case this file is about."
        )
    fmt = (
        '{{index .Config.Labels "com.docker.compose.service"}}\t'
        "{{.HostConfig.RestartPolicy.Name}}\t{{.HostConfig.RestartPolicy.MaximumRetryCount}}"
    )
    observed = []
    for line in run(["docker", "inspect", "-f", fmt] + ids).splitlines():
        if not line.strip():
            continue
        name, policy, retries = line.split("\t")
        observed.append((name, policy or None, int(retries or 0)))
    return observed, f"the running project `{project}`"


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("-f", "--file", action="append", default=[], help="a compose file; repeat for overlays")
parser.add_argument("--env-file", help="passed through to docker compose")
parser.add_argument("--project", help="name for the report, or the project to inspect with --live")
parser.add_argument("--live", action="store_true", help="inspect a RUNNING compose project instead of rendering files")
args = parser.parse_args()

if args.live:
    if not args.project:
        sys.exit("FAIL: --live needs --project")
    observed, what = from_live(args.project)
else:
    files = args.file or ["compose/docker-compose.estate.yml"]
    observed, what = from_config(files, args.env_file, args.project)

sys.exit(check(observed, what))
