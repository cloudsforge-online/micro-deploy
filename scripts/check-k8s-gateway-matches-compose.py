#!/usr/bin/env python3
"""The gateway in the cluster is the gateway in the compose file.

THE CLAIM THIS ENFORCES
-----------------------
`k8s/gateway/60-gateway.yaml` opens by saying it is "the same Traefik, the same
version, the same arguments, reading the same four files", and names this script
as what keeps that claim true rather than merely intended. This is that script.

The claim is the whole reason the routing was NOT translated into IngressRoute
CRDs. That translation is 3,318 lines, 67 routers, 59 services and 14
middlewares, and the manifest argues at length that every one of those rules is
something somebody arrived at from an incident — so the migration runs the same
proxy over the same files instead, and the only thing that changed is where the
files come from. A hand-copied argument list is exactly the kind of thing that
survives the migration and then drifts on the next edit, which is what turns
"the same gateway" into a sentence in a comment.

WHY DRIFT HERE IS SILENT, WHICH IS WHY IT NEEDS A CHECK
-------------------------------------------------------
Every failure this guards is a gateway that starts, reports Ready, passes
`traefik healthcheck --ping`, and serves:

  * A MIDDLEWARE CHAIN THAT LOST AN ENTRY. `tunnel` is the only path a browser
    on the internet takes and nothing local drives it; `websecure` is what every
    check in this repository drives. Drop a middleware from `tunnel` alone and
    real visitors lose the request id, the security headers and the CORS
    allowlist while every check on the host stays green. `surface-routes.py`
    check 9 asserts the two chains match IN THE COMPOSE FILE. Nothing asserted it
    here until this existed.
  * AN ENTRYPOINT WITH NO WAY IN. Adding `--entrypoints.X.address=:N` to a
    compose service publishes nothing until a `ports:` line does; adding it to a
    Deployment publishes nothing until a containerPort AND a Service port do.
    Miss the Service and the entrypoint is listening, healthy, and unreachable.
  * A CERTIFICATE UNDER THE WRONG NAME. `tls.yml` names `certFile` and `keyFile`
    by absolute path. `k8s-gateway.sh` builds `secret/gateway-certs` from a
    hardcoded pair of filenames, and a Secret key becomes a filename under the
    mount path — so renaming the leaf in `tls.yml` and not in the script leaves
    Traefik serving `CN=TRAEFIK DEFAULT CERT`. The compose file records what that
    costs: every verifier in this repository reports green, because `curl -k` and
    `ignoreHTTPSErrors: true` were its only two clients, while a real browser
    loads a page after a click-through and then fails every cross-origin call,
    since no browser offers an interstitial for an XHR.
  * A VERSION BUMP ON ONE SIDE. Two Traefiks, one of them untested against the
    dynamic files.

WHAT IT DOES NOT CHECK, AND WHERE THAT LIVES
---------------------------------------------
It does not read `gateway/dynamic/*.yml` as routing. That is
`scripts/surface-routes.py`'s job and it is a much bigger one — routers against
the surface registry in both directions, an API router per deployed backend, the
CORS allowlist. Those files are MOUNTED rather than copied, by both platforms, so
they cannot drift between the two: `k8s-gateway.sh` builds the ConfigMap from
`gateway/dynamic/` on every apply for exactly that reason. What can drift is
everything AROUND them, which is what this compares.

Nor does it look at the cluster. `k8s-gateway.sh` checks the live side — that
`secret/env-traefik` carries the names the templates need, and that every
upstream in the router table has a Service on the port the router uses.
"""
import importlib.util
import pathlib
import re
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so neither gateway definition can be read.\n"
        "       python3 -m pip install pyyaml"
    )

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "compose" / "docker-compose.gateway.yml"
MANIFEST = ROOT / "k8s" / "gateway" / "60-gateway.yaml"
TLS = ROOT / "gateway" / "dynamic" / "tls.yml"
APPLY = ROOT / "scripts" / "k8s-gateway.sh"
SECRETS = ROOT / "scripts" / "k8s-secrets.py"

# ── THE DECLARED DIVERGENCES ─────────────────────────────────────────────────
#
# Every difference between the two argument lists is listed here with the reason
# it exists. An undeclared one fails, in both directions: a compose argument with
# no counterpart, and a manifest argument compose never asked for.
#
# There is exactly one, and the manifest says so in the comment above the line
# ("the ONLY line in this file that had to change for the cluster"). If a second
# is ever genuinely needed, adding a row here is the place the reasoning goes.
ARG_TRANSLATIONS = {
    "--tracing.otlp.grpc.endpoint=otel-collector:4317":
        "--tracing.otlp.grpc.endpoint=otel-collector.cf-telemetry.svc.cluster.local:4317",
}

WHY_TRANSLATED = {
    "--tracing.otlp.grpc.endpoint=otel-collector:4317":
        "under compose the telemetry plane and both gateways sat on the same shared external "
        "`app` network, so the bare name resolved. The collector is now in `cf-telemetry`, one "
        "copy for both namespaces exactly as before, so the name has to be qualified.",
}

# The two entrypoints that must carry the SAME middleware chain, and why. Copied
# from `surface-routes.py`'s PAIRED_ENTRYPOINTS deliberately rather than
# imported: that script asserts this of the COMPOSE file and this one asserts it
# of the manifest, and the two files are allowed to be checked out of step with
# each other in a way that a shared constant would hide.
PAIRED_ENTRYPOINTS = ("websecure", "tunnel")

ENTRYPOINT_ADDRESS = re.compile(r"^--entrypoints\.([a-z]+)\.address=:(\d+)$")
ENTRYPOINT_CHAIN = re.compile(r"^--entrypoints\.([a-z]+)\.http\.middlewares=(\S+)$")
FILE_DIRECTORY = re.compile(r"^--providers\.file\.directory=(\S+)$")
FROM_FILE_KEY = re.compile(r"--from-file=([A-Za-z0-9._-]+)=")

failures = []


def fail(message):
    failures.append(message)


for missing in [p for p in (COMPOSE, MANIFEST, TLS, APPLY, SECRETS) if not p.exists()]:
    fail(f"{missing.relative_to(ROOT)} does not exist")

if failures:
    print("FAIL: check-k8s-gateway-matches-compose")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

compose = yaml.safe_load(COMPOSE.read_text())["services"]["gateway"]
documents = [d for d in yaml.safe_load_all(MANIFEST.read_text()) if d]
deployments = [d for d in documents if d.get("kind") == "Deployment"]
services = [d for d in documents if d.get("kind") == "Service"]

if len(deployments) != 1 or len(services) != 1:
    fail(
        f"{MANIFEST.relative_to(ROOT)} holds {len(deployments)} Deployment(s) and "
        f"{len(services)} Service(s); this check assumes exactly one of each"
    )
    print("FAIL: check-k8s-gateway-matches-compose")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

pod = deployments[0]["spec"]["template"]["spec"]
container = pod["containers"][0]
service_ports = {p["port"] for p in services[0]["spec"]["ports"]}

# ── 1. THE SAME TRAEFIK ──────────────────────────────────────────────────────
if compose["image"] != container.get("image"):
    fail(
        f"compose runs `{compose['image']}` and the manifest runs `{container.get('image')}`.\n"
        "       The whole reason `gateway/dynamic/` was not translated to IngressRoute CRDs is\n"
        "       that both platforms run the same proxy over the same files. Two versions is two\n"
        "       proxies, one of which nothing has ever tested against those files."
    )

# ── 2. THE SAME ARGUMENTS, IN THE SAME ORDER ─────────────────────────────────
#
# Order is compared, not just membership. Traefik does not care, but a reviewer
# diffing the two files does, and a list that has been reordered is a list whose
# next diff is unreadable.
compose_args = list(compose["command"])
manifest_args = list(container.get("args") or [])
translated = [ARG_TRANSLATIONS.get(a, a) for a in compose_args]

if translated != manifest_args:
    only_compose = [a for a in translated if a not in manifest_args]
    only_manifest = [a for a in manifest_args if a not in translated]
    detail = ""
    for arg in only_compose:
        source = next((k for k, v in ARG_TRANSLATIONS.items() if v == arg), arg)
        detail += f"\n         in compose, not in the manifest:  {source}"
    for arg in only_manifest:
        detail += f"\n         in the manifest, not in compose:  {arg}"
    if not detail:
        detail = "\n         the same arguments, in a different order"
    fail(
        "the two argument lists differ:" + detail + "\n"
        "       Every difference has to be DECLARED in ARG_TRANSLATIONS in this script, with\n"
        "       the reason it exists. A flag added to one gateway and not the other is a\n"
        "       behaviour that is live on one network's path and absent on the other's, and\n"
        "       both pods report Ready either way."
    )

# ── 3. THE PAIRED ENTRYPOINT CHAINS ARE IDENTICAL, IN THE MANIFEST TOO ───────
#
# Implied by (2) as long as compose passes `surface-routes.py` check 9, and
# asserted anyway: (2) admits declared translations, and the day one of those is
# a middleware chain this is the check that still says no.
chains = {}
for arg in manifest_args:
    match = ENTRYPOINT_CHAIN.match(arg)
    if match:
        chains[match.group(1)] = match.group(2).split(",")

for name in PAIRED_ENTRYPOINTS:
    if name not in chains:
        fail(
            f"the `{name}` entrypoint has no `--entrypoints.{name}.http.middlewares` flag in\n"
            f"       {MANIFEST.relative_to(ROOT)}. An entrypoint with no chain applies NO\n"
            "       middleware — no request id, no security headers, no CORS allowlist — to\n"
            "       every request that arrives on it."
        )

if all(n in chains for n in PAIRED_ENTRYPOINTS):
    a, b = PAIRED_ENTRYPOINTS
    if chains[a] != chains[b]:
        fail(
            f"the `{a}` and `{b}` entrypoints carry DIFFERENT middleware chains in\n"
            f"       {MANIFEST.relative_to(ROOT)} —\n"
            f"         {a}: {','.join(chains[a])}\n"
            f"         {b}: {','.join(chains[b])}\n"
            "       `tunnel` is the path cloudflared uses and nothing local drives it, so\n"
            "       whatever it is missing is missing for every real visitor while every check\n"
            "       on this host stays green."
        )

# ── 4. EVERY ENTRYPOINT HAS A WAY IN ─────────────────────────────────────────
container_ports = {p["containerPort"]: p.get("name") for p in container.get("ports") or []}
for arg in manifest_args:
    match = ENTRYPOINT_ADDRESS.match(arg)
    if not match:
        continue
    name, port = match.group(1), int(match.group(2))
    if port not in container_ports:
        fail(
            f"the `{name}` entrypoint listens on :{port} and the container declares no\n"
            f"       containerPort {port}. Traefik binds it either way, so the pod is Ready and\n"
            "       the entrypoint answers nothing that was not sent to a port Kubernetes knows\n"
            "       about."
        )
        continue
    if port not in service_ports:
        fail(
            f"the `{name}` entrypoint listens on :{port} and service/gateway does not publish\n"
            f"       port {port}. A Pod has no DNS name in Kubernetes; only a Service does, so\n"
            "       an entrypoint with no Service port is listening, healthy and unreachable."
        )

# ── 5. THE FILES BOTH GATEWAYS READ ARE MOUNTED AT THE PATHS THEY NAME ───────
mounts = {m["mountPath"]: m for m in container.get("volumeMounts") or []}

# Compose bind mounts, as `<source>:<target>[:<mode>]`. Only the target matters
# here: the source is a checkout on one platform and an object on the other, and
# that difference is the migration rather than a defect.
#
# Split on the colons BETWEEN the fields, not the one inside
# `${CF_CERT_DIR:-../gateway/certs}` — a naive split makes the default value look
# like the target and the check then reports the mount it was handed as missing.
def fields(volume):
    parts, depth, current = [], 0, ""
    for index, character in enumerate(volume):
        if character == "{" and index and volume[index - 1] == "$":
            depth += 1
        elif character == "}" and depth:
            depth -= 1
        if character == ":" and not depth:
            parts.append(current)
            current = ""
        else:
            current += character
    parts.append(current)
    return parts


compose_targets = set()
for volume in compose.get("volumes") or []:
    parts = fields(volume)
    if len(parts) >= 2:
        compose_targets.add(parts[1])

for target in sorted(compose_targets):
    if target not in mounts:
        fail(
            f"compose mounts something at `{target}` and the manifest mounts nothing there.\n"
            "       Traefik reads a directory that is simply empty — it starts, listens, and\n"
            "       404s or fails every handshake depending on which directory it was."
        )
    elif not mounts[target].get("readOnly"):
        fail(
            f"`{target}` is mounted read-only under compose and writable in the manifest.\n"
            "       The gateway terminates TLS for the whole estate; it has no reason to be\n"
            "       able to write its own configuration or its own key."
        )

for arg in manifest_args:
    match = FILE_DIRECTORY.match(arg)
    if match and match.group(1) not in mounts:
        fail(
            f"`--providers.file.directory={match.group(1)}` names a path the pod does not\n"
            "       mount. The file provider finds no files, logs nothing about it, and every\n"
            "       one of the 67 routers is simply absent behind a gateway that reports Ready."
        )

# ── 6. THE CERTIFICATE ARRIVES UNDER THE NAME tls.yml ASKS FOR ───────────────
#
# A Secret key becomes a filename under the mount path, so the chain that has to
# hold is: `tls.yml` names /etc/traefik/certs/estate.crt -> the manifest mounts
# the Secret at /etc/traefik/certs -> `k8s-gateway.sh` puts a key called
# estate.crt in it. Break any link and Traefik serves its own default
# certificate, which every check in this repository accepts.
store = (yaml.safe_load(TLS.read_text()) or {}).get("tls", {}).get("stores", {}).get("default", {})
certificate = store.get("defaultCertificate") or {}
named = [certificate.get("certFile"), certificate.get("keyFile")]

if not all(named):
    fail(
        f"{TLS.relative_to(ROOT)} declares no `tls.stores.default.defaultCertificate` with both\n"
        "       a certFile and a keyFile, so there is nothing to hold the cluster's Secret to."
    )
else:
    secret_keys = set(FROM_FILE_KEY.findall(APPLY.read_text()))
    for path in named:
        directory, _, filename = path.rpartition("/")
        if directory not in mounts:
            fail(
                f"{TLS.relative_to(ROOT)} names `{path}` and the pod mounts nothing at\n"
                f"       `{directory}`. Traefik falls back to CN=TRAEFIK DEFAULT CERT, which\n"
                "       `curl -k` and `ignoreHTTPSErrors: true` both accept and a browser does\n"
                "       not — so it is green everywhere except in front of a person."
            )
        elif filename not in secret_keys:
            fail(
                f"{TLS.relative_to(ROOT)} names `{path}` and {APPLY.relative_to(ROOT)} builds\n"
                f"       secret/gateway-certs with the key(s) {', '.join(sorted(secret_keys)) or '<none>'}.\n"
                "       A Secret key is the filename it appears under, so the file Traefik opens\n"
                "       is not there, and it serves its own default certificate instead."
            )

# ── 7. THE SAME ENV FILE, BY WAY OF A SECRET ─────────────────────────────────
#
# Compose loads `env/${CF_TRAEFIK_ENV:-traefik}.env`; the pod takes an envFrom
# secretRef. The two have to name the same file per network, or the templates in
# `gateway/dynamic/` render `Host(``)` — a valid rule that matches no request
# ever sent, logs nothing, and leaves the surface dead behind the catch-all.
spec = importlib.util.spec_from_file_location("k8s_secrets", SECRETS)
k8s_secrets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k8s_secrets)

secret_refs = [
    ref["secretRef"]["name"]
    for ref in container.get("envFrom") or []
    if "secretRef" in ref
]
compose_env_files = list(compose.get("env_file") or [])

if len(secret_refs) != 1 or len(compose_env_files) != 1:
    fail(
        f"compose loads {len(compose_env_files)} env_file(s) and the pod takes "
        f"{len(secret_refs)} secretRef(s);\n"
        "       this check assumes exactly one of each, because the gateway's whole\n"
        "       configuration surface is that file."
    )
else:
    pattern = compose_env_files[0]
    for network in sorted(k8s_secrets.FILES):
        # Resolved the same way `release-deploy.sh` resolves it: from the
        # network's env file, not from the ambient environment.
        env_file = ROOT / "compose" / f"{network}.env"
        selector = None
        for line in env_file.read_text().splitlines() if env_file.exists() else []:
            if line.startswith("CF_TRAEFIK_ENV="):
                selector = line.split("=", 1)[1].strip()
        if selector is None:
            fail(
                f"compose/{network}.env does not set CF_TRAEFIK_ENV, so which env file the\n"
                f"       {network} gateway loads depends on the operator's shell. Both networks\n"
                "       set it explicitly today and release-deploy.sh reads it from this file."
            )
            continue
        expected = "compose/" + pattern.replace("${CF_TRAEFIK_ENV:-traefik}", selector)
        built = {
            e[0]: e[1]
            for e in k8s_secrets.FILES[network]
            if e[0] == secret_refs[0] and e[2] == "envfrom"
        }
        if not built:
            fail(
                f"the pod takes `envFrom: secretRef: {secret_refs[0]}` and k8s-secrets.py builds\n"
                f"       no such Secret for {network}. The dynamic files are Go templates over\n"
                "       `env`; an unset name renders an empty host, which is a valid rule matching\n"
                "       no request ever sent."
            )
        elif built[secret_refs[0]] != expected:
            fail(
                f"for {network}, compose loads `{expected}` and k8s-secrets.py builds\n"
                f"       secret/{secret_refs[0]} from `{built[secret_refs[0]]}`. One of the two\n"
                "       gateways is configured for the other network's apex."
            )

# ── 7b. THE TWO GATEWAYS SHARE A NAMESPACE, SO THEY CANNOT SHARE A SECRET ────
#
# `docs/network-consolidation.md` §6.3 moved the testnet Traefik into
# `cloudsforge-estate` so it could reach the thirty consolidated services by
# their short names. Both Deployments now read `envFrom: secretRef: env-traefik`
# from the SAME manifest — the difference is made at apply time, by the fourth
# element of the testnet row in FILES, which redirects the Secret to a different
# name in that namespace.
#
# Drop that override and nothing here crashes. `k8s-secrets.py` would write
# testnet's environment into `cf-testnet`, where no gateway is left to read it,
# and `env-traefik` in `cloudsforge-estate` would remain the mainnet one. The
# testnet gateway would then either fail to start (loudly, if the name is
# missing) or — if someone "fixed" it by pointing both at `env-traefik` — come
# up stamping `CF-Network: mainnet` on every testnet hostname and answering 200
# with mainnet rows. That second outcome is the one worth a check.
TESTNET_GW = [e for e in k8s_secrets.FILES["testnet"] if e[0] == "env-traefik"]
if len(TESTNET_GW) != 1:
    fail(
        "FILES['testnet'] no longer has exactly one `env-traefik` row, so which file the\n"
        "       testnet gateway's environment comes from is ambiguous."
    )
else:
    target = TESTNET_GW[0][3] if len(TESTNET_GW[0]) > 3 else {}
    mainnet_names = {e[0] for e in k8s_secrets.FILES["mainnet"]}
    if target.get("namespace") != "cloudsforge-estate":
        fail(
            "the testnet gateway runs in `cloudsforge-estate` but FILES['testnet'] does not\n"
            "       send its env Secret there. It would be written to a namespace holding no\n"
            "       gateway, and scripts/k8s-gateway.sh --network testnet would refuse to deploy."
        )
    elif not target.get("name"):
        fail(
            "the testnet gateway's env Secret has no name override, so it would be applied as\n"
            "       `env-traefik` into `cloudsforge-estate` — overwriting the MAINNET gateway's\n"
            "       environment with testnet's apex and `CF_EMBER_NETWORK=testnet`."
        )
    elif target["name"] in mainnet_names:
        fail(
            f"the testnet gateway's env Secret is named `{target['name']}`, which is also a\n"
            "       mainnet Secret name in the same namespace. One estate would overwrite the\n"
            "       other's environment, and the loser would stamp every request with the\n"
            "       winner's `CF_EMBER_NETWORK`."
        )

# ── 8. THE SAME LIVENESS QUESTION ────────────────────────────────────────────
#
# Compose's healthcheck and the readiness probe both have to be
# `traefik healthcheck --ping`, and that is not interchangeable with a TCP probe
# or an HTTP GET: it answers only once the entrypoints are listening AND the file
# provider has loaded, which is the distinction that matters, because a Traefik
# that is listening with no routes 404s everything while a socket check passes.
healthcheck = [c for c in (compose.get("healthcheck") or {}).get("test") or [] if c != "CMD"]
probe = ((container.get("readinessProbe") or {}).get("exec") or {}).get("command") or []
if healthcheck != probe:
    fail(
        f"compose asks `{' '.join(healthcheck) or '<nothing>'}` and the readiness probe asks\n"
        f"       `{' '.join(probe) or '<nothing>'}`. A gateway whose readiness is decided by a\n"
        "       different question is a gateway that can be declared Ready before it has any\n"
        "       routes, which 404s the estate rather than failing it."
    )

if failures:
    print("FAIL: check-k8s-gateway-matches-compose")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

declared = "\n".join(
    f"    declared divergence: {k}\n"
    f"                      -> {v}\n"
    f"                         {WHY_TRANSLATED.get(k, '(no reason recorded)')}"
    for k, v in ARG_TRANSLATIONS.items()
)
print(
    f"ok: {MANIFEST.relative_to(ROOT)} runs the same Traefik as "
    f"{COMPOSE.relative_to(ROOT)},\n"
    f"    with the same {len(compose_args)} arguments, the same mounts, the same certificate\n"
    "    filenames and the same readiness question\n" + declared
)
