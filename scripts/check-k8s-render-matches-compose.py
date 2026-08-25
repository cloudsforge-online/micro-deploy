#!/usr/bin/env python3
"""The generated Kubernetes workloads still match the compose file they came from.

THE DEFECT THIS PREVENTS
------------------------
Under compose, editing `compose/docker-compose.estate.yml` IS the deploy. The
next `scripts/release-deploy.sh` reads the edited file, and there is no second
artefact that can disagree with it.

Under Kubernetes there is. The compose file becomes a SOURCE, and the thing that
gets applied is `k8s/estate/<network>/`, rendered from it by
`scripts/k8s-render.py`. So an edit that is not re-rendered is an edit that is
written, reviewed, merged — and never deployed. Worse, `k8s-deploy.sh` reports a
completely green deploy of the previous shape, because from its side nothing is
wrong: the manifests it applied are the manifests it was given.

Three concrete shapes of that, all of them silent:

  * A NEW ENVIRONMENT VARIABLE on an existing service. The container comes up
    without it, and every `env.ts` in this estate reads unset as absent — so the
    feature it gates is simply off, on a pod reporting Ready.
  * A CHANGED HEALTHCHECK PORT. `k8s-render.py` takes a Service's port from the
    healthcheck when the compose service publishes none, so the ClusterIP keeps
    the old port while the container moves. The gateway's router still resolves
    the name, and answers 502 behind a gateway that is healthy — the failure
    `k8s-gateway.sh` documents as invisible from every direction an operator
    normally looks.
  * A NEW SERVICE. It has no Deployment at all, and `kubectl get deploy` reports
    51 of 51 Ready, because 51 is all it was ever told about.

WHY IT REGENERATES RATHER THAN COMPARING STRUCTURE
--------------------------------------------------
The same argument as `check-k8s-databases-match-initdb.py`. Comparing "does
every compose service have a Deployment" would catch the third case above and
miss the other two, along with everything else the renderer decides: which
`${VAR}` is a secretKeyRef and which is resolved to a literal, the probe derived
from the healthcheck, `Recreate` versus `RollingUpdate`, the trust bundle mount,
`optional: false` on every secret reference.

So it runs the renderer and compares bytes. Anything the renderer would emit
differently, for any reason, fails here.

WHICH RELEASE IT RENDERS AGAINST
--------------------------------
Not "the newest one". The rendered files carry the release they were built from
in their header, and `k8s-deploy.sh` reads that same line to decide what it is
deploying — so this check reads it too, and re-renders against THAT release.

The consequence is worth stating plainly, because it is a deliberate hole:
cutting a new release does not fail this check. It cannot, or every release would
turn red until somebody re-rendered, and a check that is red by default is a
check nobody reads. What fails here is a change to the compose file, the
render-vars, or the renderer itself. Moving the estate to a new release is a
re-render and a commit, and the thing that catches a forgotten one is the deploy
naming a release the operator did not expect — not this.

THE SECOND ASSERTION: TWO TABLES THAT MUST MOVE TOGETHER
--------------------------------------------------------
`ENV_FILE_SECRETS` in the renderer maps a compose `env_file:` to the Secret it
becomes; `FILES` in `k8s-secrets.py` is what actually builds those Secrets. The
renderer's own comment says one of them moving without the other is what this
check catches, so it does.

One direction already fails loudly — the renderer refuses to render an `env_file`
it has no Secret for. The other does not: a Secret name in `ENV_FILE_SECRETS`
that `k8s-secrets.py` no longer builds renders a `secretRef` to nothing, and for
the `required: false` env files that reference is `optional: true`, which means
the pod starts, reports Ready, and runs without the credentials in that file.

THE ONE THING IT CANNOT CHECK
-----------------------------
It compares the repository to the repository. A manifest edited directly on the
cluster with `kubectl edit`, or a Deployment deleted from one, is invisible to
it. `k8s-deploy.sh` re-applies all four files on every deploy, which closes that
by overwriting rather than by detecting.
"""
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
GENERATOR = ROOT / "scripts" / "k8s-render.py"
SECRETS = ROOT / "scripts" / "k8s-secrets.py"
COMPOSE = ROOT / "compose" / "docker-compose.estate.yml"

NETWORKS = ("mainnet", "testnet")

# Filename order is apply order — see the renderer's docstring. Listed here so a
# file that stops being emitted is a failure rather than a file nobody compares.
RENDERED = ("20-pvc.yaml", "30-migrate-jobs.yaml", "40-services.yaml", "50-deployments.yaml")

# `env-traefik` is built by `k8s-secrets.py` and is deliberately NOT in the
# renderer's table: it belongs to the gateway, which is not rendered from the
# estate compose file at all. `check-k8s-gateway-matches-compose.py` is what
# holds the gateway to its own env file.
NOT_AN_ESTATE_ENV_FILE = {"env-traefik"}

RELEASE_LINE = re.compile(r"^# Release:\s+(\S+)\s", re.M)
RELEASE_ARG = re.compile(r"--release (\S+)")

failures = []


def load(path, name):
    """Import a script for its tables. Both guard their work behind `main()`."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if importlib.util.find_spec("yaml") is None:
    # The same message the renderer gives, said here because the failure would
    # otherwise arrive as a SystemExit from the middle of an import below.
    sys.exit(
        "FAIL: PyYAML is not installed, so the compose file cannot be read.\n"
        "       python3 -m pip install pyyaml"
    )

for missing in [p for p in (GENERATOR, SECRETS, COMPOSE) if not p.exists()]:
    failures.append(f"{missing.relative_to(ROOT)} does not exist")

# ── 1. THE RENDERED TREE REPRODUCES ──────────────────────────────────────────
if not failures:
    for network in NETWORKS:
        outdir = ROOT / "k8s" / "estate" / network
        absent = [f for f in RENDERED if not (outdir / f).exists()]
        if absent:
            failures.append(
                f"k8s/estate/{network}/ is missing {', '.join(absent)}.\n"
                f"       Render it:\n"
                f"         ./scripts/k8s-render.py --network {network} "
                f"--release ../org/releases/<version>.yaml --outdir k8s/estate/{network}"
            )
            continue

        # Every file carries the header, and `k8s-deploy.sh` refuses to deploy a
        # directory whose four files name different releases. Catching that here
        # is cheaper than catching it on the cluster.
        stamped = {}
        for filename in RENDERED:
            text = (outdir / filename).read_text()
            match = RELEASE_LINE.search(text[:800])
            if not match:
                failures.append(
                    f"k8s/estate/{network}/{filename} has no `# Release:` header line. That header\n"
                    "       is not decoration: `k8s-deploy.sh` reads it to report what it is deploying,\n"
                    "       and a hand-edited generated file is the thing this check exists to refuse."
                )
                continue
            stamped.setdefault(match.group(1), []).append(filename)
        if not stamped:
            continue  # already reported above, once per headerless file
        if len(stamped) > 1:
            detail = "\n".join(f"         {v}: {', '.join(sorted(f))}" for v, f in sorted(stamped.items()))
            failures.append(
                f"k8s/estate/{network}/ names more than one release:\n{detail}\n"
                "       Half a re-render is worse than none — the Jobs would migrate to one\n"
                "       version's schema and the Deployments would run another's."
            )
            continue
        version = next(iter(stamped))

        # The header's regenerate line is a runnable command, and this is what
        # keeps it runnable. The path is pinned to the sibling-checkout layout
        # `scripts/provision-siblings.sh` declares, so that the command works on
        # any machine that followed it rather than only on the one it was typed.
        expected_arg = f"../org/releases/{version}.yaml"
        arg = RELEASE_ARG.search((outdir / RENDERED[0]).read_text()[:800])
        if not arg or arg.group(1) != expected_arg:
            failures.append(
                f"k8s/estate/{network}/{RENDERED[0]}'s regenerate line names "
                f"`{arg.group(1) if arg else '<nothing>'}`\n"
                f"       rather than `{expected_arg}`. That line is copied and run by whoever\n"
                "       re-renders; a path that only exists on one machine is a command that\n"
                "       fails everywhere else."
            )
            continue

        release = ROOT / expected_arg
        if not release.exists():
            failures.append(
                f"{expected_arg} does not exist, so {network} cannot be re-rendered and this\n"
                "       check cannot say anything at all. `org` is a REQUIRED sibling checkout:\n"
                "         ./scripts/provision-siblings.sh\n"
                "       It is a failure rather than a skip on purpose. A guard that goes quiet\n"
                "       when its input is missing reports green on precisely the machine where\n"
                "       it could not run."
            )
            continue

        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [sys.executable, str(GENERATOR), "--network", network,
                 "--release", expected_arg, "--outdir", tmp],
                capture_output=True,
                text=True,
                cwd=str(ROOT),
            )
            if result.returncode != 0:
                # The renderer fails closed on an unresolvable image, an unknown
                # env_file, a volume with no size, and a `SETTLEMENT_RPC_URLS`
                # expression that has drifted from render-vars. Its message says
                # which; pass it through rather than paraphrasing.
                failures.append(f"the renderer refused to run for {network}:\n{result.stdout}{result.stderr}")
                continue
            differing = [
                f for f in RENDERED
                if (pathlib.Path(tmp) / f).read_text() != (outdir / f).read_text()
            ]
            if differing:
                failures.append(
                    f"k8s/estate/{network}/{{{','.join(differing)}}} is not what the renderer\n"
                    f"       produces from {COMPOSE.relative_to(ROOT)} + render-vars.{network}.yaml.\n"
                    f"       Re-render it:\n"
                    f"         ./scripts/k8s-render.py --network {network} "
                    f"--release {expected_arg} --outdir k8s/estate/{network}"
                )

# ── 2. THE ENV-FILE TABLES AGREE ─────────────────────────────────────────────
if not failures:
    render = load(GENERATOR, "k8s_render")
    secrets = load(SECRETS, "k8s_secrets")

    declared = set(render.ENV_FILE_SECRETS.values())
    for network, entries in secrets.FILES.items():
        # By field name: the rows are EnvFileSecret, which exists precisely so
        # that adding one does not break an unpack here. See FILES.
        built = {e.name for e in entries if e.kind == "envfrom"}
        for name in sorted(declared - built):
            failures.append(
                f"the renderer emits `envFrom: secretRef: {name}` and k8s-secrets.py does not\n"
                f"       build it for {network}. For an `env_file` compose marks `required: false`\n"
                "       the reference is `optional: true`, so the pod starts, reports Ready, and\n"
                "       runs without every credential in that file.\n"
                "       Both tables move together: ENV_FILE_SECRETS in scripts/k8s-render.py and\n"
                "       FILES in scripts/k8s-secrets.py."
            )
        for name in sorted(built - declared - NOT_AN_ESTATE_ENV_FILE):
            failures.append(
                f"k8s-secrets.py builds Secret `{name}` for {network} as an `envfrom` file and no\n"
                "       service consumes it, because the renderer's ENV_FILE_SECRETS does not name\n"
                "       it. Either the compose `env_file:` it came from is gone — delete the row —\n"
                "       or the renderer has to be taught the mapping, or it is a gateway file and\n"
                "       belongs in this check's NOT_AN_ESTATE_ENV_FILE with the reason written down."
            )

if failures:
    print("FAIL: check-k8s-render-matches-compose")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print(
    f"ok: k8s/estate/{{{','.join(NETWORKS)}}}/ are what scripts/k8s-render.py produces from\n"
    f"    {COMPOSE.relative_to(ROOT)}, and every env_file Secret the renderer references is\n"
    "    one scripts/k8s-secrets.py builds"
)
