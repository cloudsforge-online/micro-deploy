#!/usr/bin/env python3
"""No two services that run on one host may publish the same host port.

WHAT THIS GUARDS
----------------
`compose/docker-compose.backup.yml` published `127.0.0.1:${CF_PORT_BASE:-4}130`,
and `trade-web` in `compose/docker-compose.estate.yml` had owned that port since
the day trade-web shipped. The first attempt to start the backup runner on
mainnet built the image, created the container, and then failed at the very last
step (micro-org#328):

    Bind for 127.0.0.1:4130 failed: port is already allocated

The estate was never at risk — a publish that cannot bind is refused a network
namespace and nothing else changes. What it cost was the one action that gives
this estate any backup at all, and it cost it after a full image build, with an
error that names a port and no service.

WHY NOTHING CAUGHT IT
---------------------
The backup overlay is the only compose file here that no deploy path renders. It
is named by no release manifest, `release-deploy.sh` never composes it, and its
own header tells an operator to bring it up by hand. So the two files had never
been in one model, and a file cannot see another file's ports. `make config`
composes the telemetry and gateway overlays and would have caught the same
mistake there; the estate set had no equivalent.

WHY NOT `docker compose config`
-------------------------------
It is the obvious answer and it does not run in CI. Composing the estate file
needs `compose/estate/tokens.env`, which is untracked, mode 0600 and exists on
exactly two hosts — and `CF_BACKUP_ENVIRONMENT` is a `:?` variable, so the render
fails outright without it. A check that can only run on the machine where the
mistake has already been made is not a check. This reads the YAML instead, which
needs nothing but the repository.

WHAT IT CHECKS
--------------
Each SET below is one host-port namespace: files that are composed together, into
one project, on one machine. Within a set, no host port may be claimed twice.

The sets are declared rather than inferred. Two compose files may legitimately
carry the same `${CF_PORT_BASE:-4}1xx` template and never collide, because
mainnet and testnet are the same templates with different bases — so a check that
compared every file against every other would report collisions that cannot
happen and would be silenced within a week. Comparing the TEMPLATE TEXT is the
right granularity for a declared set: within one set the base is one value
whatever it is, so two identical templates are two identical ports, and two
different templates are two different ports.

Adding an overlay to the estate means adding it here. That is the point.
"""

import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the CI step installs it
    print("pyyaml is required: python3 -m pip install pyyaml", file=sys.stderr)
    sys.exit(2)

ROOT = pathlib.Path(__file__).resolve().parent.parent

# One entry per host-port namespace, with the composition it models.
SETS = {
    # `docker compose -p cloudsforge-estate -f compose/docker-compose.estate.yml \
    #     -f compose/docker-compose.backup.yml up -d backup-runner`
    # — the command in the backup overlay's own header, and the one micro-org#328
    # failed on. The release overlay is not listed: it is generated, and it
    # publishes nothing the estate file has not already declared.
    "estate": [
        "compose/docker-compose.estate.yml",
        "compose/docker-compose.backup.yml",
    ],
}


def host_port(spec) -> str | None:
    """The host side of a compose port entry, or None if it publishes nothing.

    Long form is a mapping with `published`. Short form is a string, and the host
    side is what precedes the LAST colon — `127.0.0.1:4130:4130`, `4130:4130` and
    `4130` are all real shapes, and a bare container port publishes an ephemeral
    host port that cannot collide.
    """
    if isinstance(spec, dict):
        published = spec.get("published")
        return None if published is None else str(published)
    # `4130:4130/udp` — the protocol suffix belongs to the container side and is
    # not part of the comparison. Split rather than strip: `rstrip` takes a
    # character set, not a suffix, and would eat digits from a port that ended in
    # one of them.
    text = str(spec).split("/", 1)[0]
    if ":" not in text:
        return None
    return text.rsplit(":", 1)[0]


def without_bind_address(published: str) -> str:
    """`127.0.0.1:4130` and `4130` claim the same port and must compare equal.

    A bind address is dropped rather than compared. `0.0.0.0:4130` and
    `127.0.0.1:4130` are a real collision — the wildcard covers the loopback —
    and treating the two as distinct would make this check miss the one shape it
    is most likely to meet.
    """
    return re.sub(r"^(\d{1,3}(\.\d{1,3}){3}|\[[0-9a-fA-F:]+\]):", "", published)


def main() -> int:
    failures: list[str] = []
    checked = 0

    for name, relatives in SETS.items():
        claims: dict[str, tuple[str, str, str]] = {}
        for relative in relatives:
            path = ROOT / relative
            if not path.exists():
                failures.append(
                    f"[{name}] {relative} is listed in this check and does not exist. Either the "
                    f"file moved and this list is stale, or the composition it models is gone."
                )
                continue
            document = yaml.safe_load(path.read_text()) or {}
            for service, body in (document.get("services") or {}).items():
                for spec in (body or {}).get("ports") or []:
                    published = host_port(spec)
                    if published is None:
                        continue
                    checked += 1
                    key = without_bind_address(published)
                    if key in claims:
                        owner_file, owner_service, owner_published = claims[key]
                        failures.append(
                            f"[{name}] host port {published} is published by {service} "
                            f"({relative}) and {owner_published} by {owner_service} "
                            f"({owner_file}). These files are composed into one project on one "
                            f"host, so the second container to start is refused: 'port is already "
                            f"allocated'."
                        )
                    else:
                        claims[key] = (relative, service, published)

    if failures:
        print("host port collisions:", *failures, sep="\n  ")
        print(
            f"\n{len(failures)} collision(s). This fails at `docker compose up`, on the host, "
            f"after the image is built — see cloudsforge-online/micro-org#328."
        )
        return 1

    print(
        f"ok: {checked} published port(s) across {sum(len(v) for v in SETS.values())} compose "
        f"file(s) in {len(SETS)} host-port namespace(s), no port claimed twice"
    )
    return 0


sys.exit(main())
