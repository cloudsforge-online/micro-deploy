#!/usr/bin/env python3
"""Where a service verifies tokens, and where it exchanges its credential, is the ANCHOR's answer.

WHAT THIS GUARDS
----------------
`x-identity-trust` is three lines in `compose/docker-compose.estate.yml`:

    IDENTITY_ISSUER:   http://identity:4000                        (a claim string, not a route)
    IDENTITY_JWKS_URL: ${CF_IDENTITY_JWKS_URL:-http://identity:4000/.well-known/jwks.json}
    IDENTITY_URL:      ${CF_IDENTITY_URL:-http://identity:4000}

Under the combined view (micro-org#459) ONE identity serves both estates. `compose/testnet.env`
points the last two at the mainnet identity's public endpoints; `compose/mainnet.env` sets neither,
so mainnet keeps talking to the container beside it. That is the entire mechanism, and it is
per-estate by interpolation rather than by a second compose file.

A merge key does not win. `environment:` is a mapping, `<<: [*common-env, *identity-trust]` merges
into it, and a key written afterwards REPLACES what the merge brought — silently, with no warning
from compose and no diff from the anchor. So one stale literal in one service block quietly opts
that service out of the shared identity, on the estate where sharing is the point.

WHAT IT COST, MEASURED 2026-08-14
---------------------------------
`hub-api`, `admin-api` and `admin-api-migrate` each carried `IDENTITY_URL: http://identity:4000`,
written as the first of their upstream URLs long before this anchor existed. On testnet that meant:

  * The credential exchange went to the TESTNET identity. `tokens.testnet.env` holds credentials
    minted in the MAINNET identity carrying `network: testnet` — the row names the estate, which is
    what makes one identity safe — so the testnet identity had never seen them and answered 401
    "the service credential presented is not valid". `ServiceTokenProvider` then throws
    `ServiceTokenUnavailableError`, which is not an `HttpError`, so hub-api's `describeFault` fell
    through to its last arm: **"<upstream> could not be reached"**, on all eleven tiles, while
    `fetch` from that same container to `wallet:4000` answered perfectly well. A reader saw
    "wallet did not answer. wallet could not be reached" on every panel of the wallet page.
  * `GET /auth/me` sent the reader's own bearer — minted by the mainnet identity, because there is
    only one login — to the testnet identity, which rejected it as `bad_signature`.

Both are one line, in three places, and nothing in CI could see it: the anchor was correct, the env
file was correct, and the running container was wrong.

WHAT IT CHECKS
--------------
  1. No service block sets `IDENTITY_URL` or `IDENTITY_JWKS_URL` as its own key. They come from the
     anchor or they do not come at all. (`IDENTITY_ISSUER` is exempt: it is a claim string every
     estate shares, and the anchor sets the same literal a block would.)
  2. The anchor still interpolates both from `CF_*`, with the local container as the default — the
     other way to break this is to "simplify" the anchor.
  3. `compose/testnet.env` sets both `CF_IDENTITY_*`; `compose/mainnet.env` sets neither. The
     asymmetry IS the direction: testnet trusts mainnet's identity, never the reverse.
  4. Every block holding a `*_IDENTITY_CREDENTIAL` merges `*identity-trust`, because a credential is
     exchanged at whatever `IDENTITY_URL` says and a block that does not merge the anchor has no
     answer to which estate that is.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "compose" / "docker-compose.estate.yml"
TESTNET_ENV = ROOT / "compose" / "testnet.env"
MAINNET_ENV = ROOT / "compose" / "mainnet.env"

ANCHOR = "*identity-trust"

# The two keys the anchor owns. `IDENTITY_ISSUER` is deliberately absent: it is the `iss` claim
# string rather than a route, it is the same literal on both estates, and a block repeating it
# changes nothing.
OWNED = ("IDENTITY_URL", "IDENTITY_JWKS_URL")

failures: list[str] = []


def bad(message: str) -> None:
    failures.append(message)
    print(f"FAIL  {message}")


def ok(message: str) -> None:
    print(f"ok    {message}")


# ── the compose file, read as text ────────────────────────────────────────────────────────────
#
# Text and not PyYAML, because PyYAML RESOLVES the merge: after loading, an overriding key and an
# inherited one are the same key with the same value and the defect is invisible. The thing being
# checked is what somebody typed.

lines = COMPOSE.read_text().splitlines()

SERVICE_RE = re.compile(r"^  ([a-z0-9][a-z0-9-]*):\s*$")
KEY_RE = re.compile(r"^      ([A-Z_][A-Z0-9_]*):")
ENVIRONMENT_RE = re.compile(r"^    environment:\s*$")
MERGE_RE = re.compile(r"^      <<:")

service: str | None = None
in_environment = False
merges_anchor = False
credential_at: dict[str, int] = {}
anchor_at: dict[str, bool] = {}

for number, line in enumerate(lines, start=1):
    match = SERVICE_RE.match(line)
    if match:
        if service is not None:
            anchor_at[service] = merges_anchor
        service = match.group(1)
        in_environment = False
        merges_anchor = False
        continue
    if service is None:
        continue
    if ENVIRONMENT_RE.match(line):
        in_environment = True
        continue
    # Any other key at the service's own indent ends the environment mapping.
    if re.match(r"^    [a-z_]", line) and not ENVIRONMENT_RE.match(line):
        in_environment = False
    if not in_environment:
        continue
    if MERGE_RE.match(line) and ANCHOR in line:
        merges_anchor = True
        continue
    key = KEY_RE.match(line)
    if not key:
        continue
    name = key.group(1)
    if name in OWNED:
        bad(
            f"{COMPOSE.name}:{number}: service '{service}' sets {name} itself. It is written after "
            f"'<<:', so it REPLACES what {ANCHOR} merged in and opts this service out of the shared "
            f"identity on the estate that shares one. Delete the line."
        )
    if name.endswith("_IDENTITY_CREDENTIAL"):
        credential_at[service] = number

if service is not None:
    anchor_at[service] = merges_anchor

if not failures:
    ok(f"no service block overrides {' or '.join(OWNED)}")

# ── 2. the anchor itself ──────────────────────────────────────────────────────────────────────

text = COMPOSE.read_text()
for key, variable in (
    ("IDENTITY_URL", "CF_IDENTITY_URL"),
    ("IDENTITY_JWKS_URL", "CF_IDENTITY_JWKS_URL"),
):
    pattern = re.compile(
        r"^x-identity-trust:.*?^\s+" + key + r":\s*\$\{" + variable + r":-http://identity:4000",
        re.MULTILINE | re.DOTALL,
    )
    if pattern.search(text):
        ok(f"x-identity-trust reads {key} from ${{{variable}}}, defaulting to the local container")
    else:
        bad(
            f"x-identity-trust no longer sets {key} to ${{{variable}:-http://identity:4000...}}. "
            "That interpolation is how one estate trusts the other's identity and how the other "
            "keeps trusting its own; a literal here silently retires the combined view."
        )

# ── 3. the env files, and the direction of trust ──────────────────────────────────────────────

testnet = TESTNET_ENV.read_text()
mainnet = MAINNET_ENV.read_text()
for variable in ("CF_IDENTITY_URL", "CF_IDENTITY_JWKS_URL"):
    set_in_testnet = re.search(rf"^{variable}=\S", testnet, re.MULTILINE) is not None
    set_in_mainnet = re.search(rf"^{variable}=", mainnet, re.MULTILINE) is not None
    if not set_in_testnet:
        bad(
            f"compose/testnet.env does not set {variable}. Without it the testnet estate verifies "
            "tokens and exchanges credentials at its own identity, which holds neither the "
            "combined view's signing keys nor its credential rows."
        )
    if set_in_mainnet:
        bad(
            f"compose/mainnet.env sets {variable}. The asymmetry is the direction of trust: "
            "testnet trusts the mainnet identity, never the reverse."
        )
    if set_in_testnet and not set_in_mainnet:
        ok(f"{variable} is set on testnet and unset on mainnet")

# ── 4. a credential without the anchor has nowhere to exchange it ─────────────────────────────

for name, number in sorted(credential_at.items()):
    if anchor_at.get(name):
        continue
    bad(
        f"{COMPOSE.name}:{number}: service '{name}' is handed a service credential but does not "
        f"merge {ANCHOR}, so nothing says which identity it exchanges that credential at."
    )
if credential_at and not any("does not merge" in f for f in failures):
    ok(f"all {len(credential_at)} credential-holding services merge {ANCHOR}")

print()
if failures:
    print(f"{len(failures)} failure(s)")
    sys.exit(1)
print("identity trust is the anchor's answer everywhere")
