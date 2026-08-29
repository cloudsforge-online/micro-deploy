#!/usr/bin/env python3
"""Render the ONE Deployment that serves every web bundle.

    ./scripts/k8s-render-web.py --release ../org/releases/2026.8.100.yaml \
        --out k8s/estate/mainnet/55-web.yaml

WHY ONE POD, AND WHY IT IS NOT A MERGED nginx.conf
---------------------------------------------------
Twenty web bundles were twenty Deployments, twenty pods and twenty nginx
processes, each serving a few megabytes of static files. That is the clearest
case in the estate of a process boundary bought for nothing: they share no
state, call nothing, and differ only in which directory they read.

The obvious consolidation — merge the twenty `nginx.conf` route tables into one
server block — is the dangerous one. Between them they hold fifteen distinct
server-level `error_page` targets, one `sub_filter`, one `alias`, two `map`
blocks and about three hundred `location` directives whose precedence is
load-bearing. Every way that merge goes wrong produces **a 200 with the wrong
bundle's content**, which no health probe and no uptime check can see. The
estate has recorded that failure shape more than once.

So the configs are NOT merged. Each bundle's `nginx.conf` is carried across
BYTE FOR BYTE except for its `listen` line, and runs as its own `server` block
on a loopback port inside one nginx process. A small dispatcher on 8080 proxies
to them by path (for the apex mounts) or by `server_name` (for the bundles that
keep their own hostname). Precedence inside a bundle is therefore exactly what
it is today, because it is the same file.

The cost is one loopback proxy hop per request, inside a single process. That
is the price of not re-deriving three hundred `location` directives by hand,
and it is worth paying.

WHAT THE INIT CONTAINERS ARE FOR
--------------------------------
The bundle IMAGES are unchanged and still pinned by digest in the release
manifest — this script does not build anything. Each one runs once as an init
container and copies its own document root into a shared `emptyDir`; the nginx
container then serves the union. So "which bundle is in this pod" is still
answered by the release manifest, `cfctl release --verify` still means what it
meant, and a rollback is still the previous release file.

The fourteen apex mounts already namespace themselves inside their images
(`/usr/share/nginx/html/market`, `…/journal`), so their union is disjoint by
construction. The bundles that serve from `/` would collide, so each is copied
under `_h/<name>/` and its config's `root` is repointed there — a change of
DIRECTORY, not of URL path, so no bundle's base path moves and the
`vite`-base hazard does not arise.
"""
import argparse
import pathlib
import re
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("FAIL: PyYAML is not installed.\n       python3 -m pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPOS = ROOT.parent

# ── THE BUNDLES, AND WHERE EACH ONE'S FILES LIVE ─────────────────────────────
#
# `mount` is the URL prefix the gateway already sends and the image already
# writes to. `None` means the bundle serves from `/` on a hostname of its own;
# those get a subdirectory and a `server_name` block instead.
#
# Read off each repo's Dockerfile (`COPY --from=build /app/dist …`) rather than
# guessed, and `check-web-merge-matches-images.py` re-reads them.
BUNDLES: list[tuple[str, str | None, str | None]] = [
    # (repo, apex mount, own hostname prefix)
    ("site", "/", None),
    ("market-web", "/market", None),
    ("mint-web", "/create", None),
    ("trade-web", "/trade", None),
    ("worlds-web", "/worlds", None),
    ("emberkin-web", "/worlds/emberkin", None),
    ("aetherholm-web", "/worlds/aetherholm", None),
    ("tessera-web", "/worlds/tessera", None),
    ("explorer-web", "/explorer", None),
    ("devportal-web", "/developers", None),
    ("foresight-web", "/foresight", None),
    ("pool-web", "/pool", None),
    ("exchange-web", "/exchange", None),
    ("journal-web", "/journal", None),
    ("agora-web", "/agora", None),
    ("hub-web", None, "hub"),
    ("admin-web", None, "admin"),
    ("network-site", None, "network"),
    ("lantern-web", None, "lantern"),
    ("beacon-web", None, "beacon"),
]

# ── status-web IS DELIBERATELY NOT HERE ──────────────────────────────────────
#
# `docs/apex-consolidation.md` §1: a status page that shares an origin with the
# thing it reports on cannot report the interesting outage. Sharing a POD is
# strictly worse than sharing an origin — one bad rollout takes down both the
# estate's surfaces and the page that would say so.
#
# It stays its own Deployment permanently. This comment is here so a later
# sweep reads the reason before folding it in.
EXCLUDED = {"status-web"}

BASE_PORT = 8100
LISTEN = re.compile(r"^(\s*)listen\s+8080\s*;", re.M)
ROOTDIR = re.compile(r"^(\s*)root\s+/usr/share/nginx/html\s*;", re.M)
MAP_BLOCK = re.compile(r"^map\s+[^\{]*\{.*?^\}", re.M | re.S)
SERVER_BLOCK = re.compile(r"^server\s*\{.*^\}", re.M | re.S)


def bundle_config(repo: str, port: int, subdir: str | None) -> tuple[list[str], str]:
    """Return (map blocks, the server block) with listen and root rewritten."""
    path = REPOS / repo / "nginx.conf"
    if not path.exists():
        sys.exit(f"FAIL: {path} does not exist. This script reads each bundle's own config.")
    text = path.read_text()

    maps = MAP_BLOCK.findall(text)
    server = SERVER_BLOCK.search(text)
    if not server:
        sys.exit(f"FAIL: no `server {{ … }}` block in {repo}/nginx.conf")
    body = server.group(0)

    if not LISTEN.search(body):
        sys.exit(
            f"FAIL: {repo}/nginx.conf does not `listen 8080;`. Every bundle does today, and this\n"
            "      script rewrites exactly that line. Read the file before changing this."
        )
    body = LISTEN.sub(rf"\1listen 127.0.0.1:{port};", body)

    if subdir is not None:
        if not ROOTDIR.search(body):
            sys.exit(f"FAIL: {repo}/nginx.conf has no `root /usr/share/nginx/html;` to repoint")
        body = ROOTDIR.sub(rf"\1root /usr/share/nginx/html/_h/{subdir};", body)

    return maps, body


def render(release: pathlib.Path) -> str:
    manifest = yaml.safe_load(release.read_text())
    images = {e["name"]: e for e in manifest.get("services") or manifest.get("deployables") or []}

    seen_maps: list[str] = []
    servers: list[str] = []
    inits: list[dict] = []
    apex_locations: list[str] = []
    host_servers: list[str] = []

    for index, (repo, mount, host) in enumerate(BUNDLES):
        port = BASE_PORT + index
        subdir = None if mount else repo
        maps, body = bundle_config(repo, port, subdir)
        for block in maps:
            if block not in seen_maps:
                seen_maps.append(block)
        servers.append(f"# ── {repo} — its own nginx.conf, verbatim but for `listen` ──\n{body}")

        entry = images.get(repo)
        if not entry:
            sys.exit(
                f"FAIL: {release.name} has no entry for `{repo}`. Every bundle in BUNDLES must be\n"
                "      in the release, or this pod would serve a directory nobody built."
            )
        image = entry.get("image") or ""
        digest = entry.get("digest")
        if digest and "@" not in image:
            image = f"{image.split(':')[0]}@{digest}"
        # ── COPY ONLY WHAT THIS BUNDLE OWNS ──────────────────────────────────
        #
        # Every mounted bundle builds FROM `nginx-unprivileged`, whose
        # `/usr/share/nginx/html` already holds the stock `index.html` and
        # `50x.html`. The bundle then COPYs its own dist into a SUBDIRECTORY of
        # that, so the stock files survive in its image untouched.
        #
        # Copying the whole html tree therefore drags fourteen copies of
        # nginx's welcome page into the shared volume, and the last one wins —
        # which is exactly what happened on the first attempt: the apex served
        # nginx's default page, with a 200, while every other mount was
        # correct. A 200 with the wrong content and no error anywhere.
        #
        # So each bundle copies only the directory it owns. For the mounted
        # ones that is their mount path; for the ones that serve from `/`,
        # their whole tree into a private subdirectory where the stock files
        # are already shadowed by their own build.
        if mount and mount != "/":
            src = f"/usr/share/nginx/html{mount}/."
            dest = f"/w{mount}"
        elif mount == "/":
            src = "/usr/share/nginx/html/."
            dest = "/w"
        else:
            src = "/usr/share/nginx/html/."
            dest = f"/w/_h/{subdir}"
        inits.append(
            {
                "name": f"copy-{repo}",
                "image": image,
                # `-a` keeps modification times, which is what nginx derives ETags from.
                "command": ["sh", "-c", f"mkdir -p {dest} && cp -a {src} {dest}/"],
                "volumeMounts": [{"name": "bundles", "mountPath": "/w"}],
                "securityContext": {"runAsUser": 0},
            }
        )

        if mount == "/":
            continue  # site is the dispatcher's catch-all, emitted below
        if mount:
            apex_locations.append(
                f"        location = {mount} {{ proxy_pass http://127.0.0.1:{port}; }}\n"
                f"        location {mount}/ {{ proxy_pass http://127.0.0.1:{port}; }}"
            )
        else:
            host_servers.append(
                f"    # {repo} keeps its own hostname; both spellings of it.\n"
                f"    server {{\n"
                f"        listen 8080;\n"
                f"        server_name ~^{host}(-testnet)?\\.;\n"
                f"        location / {{ proxy_pass http://127.0.0.1:{port}; }}\n"
                f"    }}"
            )

    site_port = BASE_PORT + [b[0] for b in BUNDLES].index("site")
    dispatcher = f"""    # ── THE DISPATCHER ──────────────────────────────────────────────────────
    #
    # Path for the apex mounts, `server_name` for the bundles that kept a
    # hostname. It carries no policy of its own: every header, cache rule,
    # redirect and 404 shape is decided by the bundle's own server block on
    # loopback, exactly as it is today.
    #
    # `Host` is forwarded because each bundle's `map $host $cf_env` gates its
    # sitemap and robots.txt on whether the hostname is an environment prefix.
    # Dropping it would publish a testnet sitemap to crawlers.
    server {{
        listen 8080 default_server;
        server_name _;

        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;

        # Proves this pod is up. It does NOT prove a bundle is served, which is
        # what the readiness probe is for — it asks for a real mount.
        location = /healthz {{ access_log off; default_type text/plain; return 200 "ok\\n"; }}

{chr(10).join(apex_locations)}

        # site owns the apex root, and therefore everything not claimed above.
        location / {{ proxy_pass http://127.0.0.1:{site_port}; }}
    }}

{chr(10).join(host_servers)}"""

    conf = "\n\n".join(["\n".join(seen_maps), *servers, dispatcher])

    labels = {"app.kubernetes.io/name": "web", "app.kubernetes.io/part-of": "cloudsforge-estate"}
    docs = [
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "web-nginx", "namespace": "cloudsforge-estate", "labels": labels},
            "data": {
                "default.conf": conf,
                # ── THE FILE hub-web AND pool-web BOTH `include` ─────────────
                #
                # In their own images this is generated at start-up by envsubst
                # from `deployment.inc.template`, with `POOL_API_PRESENCE`
                # defaulted in the Dockerfile — an unset variable there makes
                # nginx refuse to start, which is why the image sets it.
                #
                # In this pod there is no such template and no envsubst step, so
                # the rendered result is carried directly. Both bundles include
                # the same path and both render to this same single directive,
                # read out of the two running pods on 2026-08-26 rather than
                # reconstructed.
                #
                # Only the exact string `absent` tells the bundles there is no
                # pool behind this estate; every other value means there is one.
                # This estate runs one, so: present.
                "deployment.inc": 'return 200 \'{"poolApi":"present"}\';\n',
            },
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "web", "namespace": "cloudsforge-estate", "labels": labels},
            "spec": {
                "selector": {"app.kubernetes.io/name": "web"},
                "ports": [{"name": "http", "port": 8080, "targetPort": "http"}],
            },
        },
        {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "web", "namespace": "cloudsforge-estate", "labels": labels},
            "spec": {
                # ONE, since wave M5f (owner decision 2026-08-29: the ecosystem
                # runs in under 20 containers). This used to be two, arguing that
                # a single replica makes a node eviction an estate-wide outage.
                # That argument quietly assumed a second node to be evicted TO —
                # and this is a single-node cluster, so both replicas always sat
                # on the same node and died together. The second replica bought
                # zero-downtime ROLLOUTS only, and maxSurge=1 below still buys
                # exactly that: the new pod comes up beside the old one during a
                # deploy, then the old one goes. Steady state is one container.
                "replicas": 1,
                "selector": {"matchLabels": {"app.kubernetes.io/name": "web"}},
                "strategy": {
                    "type": "RollingUpdate",
                    "rollingUpdate": {"maxUnavailable": 0, "maxSurge": 1},
                },
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {
                        "initContainers": inits,
                        "containers": [
                            {
                                "name": "nginx",
                                "image": "nginxinc/nginx-unprivileged:1.27-alpine",
                                "ports": [{"name": "http", "containerPort": 8080}],
                                "volumeMounts": [
                                    {
                                        "name": "bundles",
                                        "mountPath": "/usr/share/nginx/html",
                                        "readOnly": True,
                                    },
                                    {"name": "conf", "mountPath": "/etc/nginx/conf.d", "readOnly": True},
                                ],
                                # A real mount, not /healthz: nginx answers /healthz before it
                                # holds a single file, so /healthz cannot tell "up" from "empty".
                                "readinessProbe": {
                                    "httpGet": {"path": "/journal/", "port": "http"},
                                    "initialDelaySeconds": 3,
                                    "periodSeconds": 10,
                                },
                                "livenessProbe": {
                                    "httpGet": {"path": "/healthz", "port": "http"},
                                    "initialDelaySeconds": 10,
                                    "periodSeconds": 20,
                                },
                            }
                        ],
                        "volumes": [
                            {"name": "bundles", "emptyDir": {}},
                            {"name": "conf", "configMap": {"name": "web-nginx"}},
                        ],
                    },
                },
            },
        },
    ]

    header = (
        f"# GENERATED by scripts/k8s-render-web.py from {release.name} — do not edit.\n"
        "#\n"
        "# One Deployment serving every web bundle. Each bundle's own nginx.conf runs\n"
        "# unchanged on a loopback port; see the script's header for why the configs are\n"
        "# not merged.\n"
    )
    return header + "".join(
        "---\n" + yaml.dump(d, default_flow_style=False, sort_keys=False, width=10_000) for d in docs
    )


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--release", required=True)
parser.add_argument("--out")
args = parser.parse_args()

output = render(pathlib.Path(args.release))
if args.out:
    pathlib.Path(args.out).write_text(output)
    print(f"wrote {args.out}: {len(BUNDLES)} bundle(s) in one Deployment")
else:
    print(output)
