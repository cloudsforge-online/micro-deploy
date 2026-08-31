#!/usr/bin/env python3
"""Every long-lived service credential is an interpolation, and it is spelt right.

WHAT THIS GUARDS
----------------
Eighteen service blocks in this estate authenticate to their peers by exchanging a
long-lived `cfsc_…` credential for short-lived tokens — `ServiceTokenProvider` in
`@cloudsforge/auth`, adopted service by service since micro-org#228 and by
emberkin in micro-emberkin#3. `estate-bootstrap.sh` section 5b mints one per
service into the untracked tokens file, and the compose block's only job is to
hand it through as `NAME: ${NAME:-}`.

That one line has two ways to be wrong and both are silent.

  * THE NAME. `estate-bootstrap.sh` has minted `MARKET_IDENTITY_CREDENTIAL` all
    along and nothing read it — the market block records that in its own comment.
    A credential wired to a variable name nothing sets interpolates to the empty
    string forever, and every service treats empty as absent, so the container
    boots, serves, and authenticates with whatever fallback it still has. There
    is no error at any point. `estate-verify.sh` found six testnet services
    running on an empty credential this way.
  * THE VALUE. A credential is a SECRET. It belongs in the untracked tokens file
    and never in a tracked compose file, and the difference between the two is
    one operator pasting a value where an interpolation should be. That is the
    failure that cannot be undone: a pushed secret is compromised the moment it
    lands, and the remedy is a rotation and not a `git rm --cached`.

So the rule is exact rather than approximate: a key ending `_IDENTITY_CREDENTIAL`
must be `${<the same name>:-}`. Not a literal, not a different variable, not a
non-empty default — every one of those is a way of shipping something that looks
configured and is not.

THE LEGACY TOKEN BESIDE IT, WHICH IS WHERE THE ORDERING BITES
-------------------------------------------------------------
A service mid-migration carries both variables, because a deploy cannot change
the image and the compose block in the same instant: the container that boots
with the old image and the new block, or the new image and the old block, must
still start. `env.ts` on such a service requires ONE OF the two and treats each
as individually optional, which is what makes the transition survivable — and
what makes REMOVING the token before ADDING the credential a service that will
not boot at all.

But the token slot still validates its SHAPE when it is set, because in `static`
mode the value is presented verbatim as a Bearer and rubbish there earns a 401
from every upstream with nothing naming the cause. `emberkin/src/env.ts` demands
`/^ey[A-Za-z0-9_-]*\\./`. So a compose default of
`estate-placeholder-token-0000000000000000` — which was correct while the slot was
REQUIRED, since it let a bootstrap-less host render — becomes a boot THROW the
moment the slot is optional: a host with a perfectly good credential and no minted
token crash-loops on the variable that is only still present for the rollout.

Hence: a block carrying both must default the token empty, so the credential is
what satisfies the check and absence is absence.

WHAT IT CHECKS
--------------
  1. Every `*_IDENTITY_CREDENTIAL` in every compose file is exactly
     `${<same name>:-}` (or `${<same name>-}`, which renders identically).
  2. No service carries both a credential and a `*_SERVICE_TOKEN` with a
     non-empty default.
  3. emberkin and emberkin-migrate are both handed a credential — micro-emberkin#3
     — and the migrator is named explicitly because it loads the same `env.ts`
     and refuses to boot without one of the two, which would take the service
     down with it through `service_completed_successfully`.
  4. At least fourteen blocks carry a credential at all. Rules 1 and 2 are both
     satisfied by a file that mentions none, and this estate has eighteen.

Exit non-zero on failure, print nothing but the verdict on success.
"""
import pathlib
import re
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so the merge keys that carry environment onto\n"
        "       these services cannot be resolved.\n"
        "       This is a failure and not a skip: every rule below would go unchecked,\n"
        "       and a check that reports a pass it did not establish is worse than none.\n"
        "       python3 -m pip install pyyaml"
    )

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ROOT / "compose"

CREDENTIAL = re.compile(r"^[A-Z][A-Z0-9_]*_IDENTITY_CREDENTIAL$")
# `*_SERVICE_TOKEN`, excluding identity's own `IDENTITY_SERVICE_TOKEN_GRANTS` and
# anything else that merely starts with the issuer's name: what is meant here is a
# minted bearer handed TO a service.
SERVICE_TOKEN = re.compile(r"^[A-Z][A-Z0-9_]*_SERVICE_TOKEN$")

# How this repository writes "unset unless an operator says otherwise". `${FOO:-}`
# and `${FOO-}` both render to the empty string, which every `env.ts` in the estate
# reads as absent.
EMPTY_DEFAULT = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*):?-\}$")

# ── THE FLOOR COUNTS CREDENTIALS, NOT BLOCKS (wave M5d) ──────────────────────────────
#
# It counted BLOCKS and expected eighteen, which was the right measure while one block
# meant one service. The merge waves collapsed most of them: five blocks carry a
# credential today and `agora` alone carries thirteen of them. Lowering a block floor to
# track that would be this assertion retiring itself one wave at a time — and it would
# have gone on passing the day a merge dropped twelve credentials on the floor, because
# the block that lost them would still be one block carrying one.
#
# So it counts the distinct `*_IDENTITY_CREDENTIAL` NAMES wired anywhere. That number
# tracks SERVICES rather than containers, which is what the rule is about, and it does
# not move when a merge changes where they are wired. Twenty-two are wired today; twelve
# leaves room for services to be retired without this becoming a chore, and none for the
# file to quietly stop wiring them — the state rules 1 and 2 would both call clean.
#
# Deliberately NOT re-derived from the compose file: a floor computed from the thing
# under test passes by construction.
MINIMUM_CREDENTIALS = 12
# And a block floor, kept as the weaker second signal it now is.
MINIMUM = 3

# ── WAVE M5d: THE TWO BLOCKS THAT MUST CARRY A CREDENTIAL ARE NOW agora's ────────────
#
# `emberkin` and `emberkin-migrate` were these until 2026-08-31; emberkin is a module of
# agora now (`agora/src/emberkin/`) and there is no emberkin container. The requirement
# it stands for is UNCHANGED and now applies to more: `EMBERKIN_IDENTITY_CREDENTIAL` is
# still what stops that module running in `static` mode on a ten-minute bearer, and the
# same two blocks also carry wallet's, hub's, admin's and nda's. Naming the blocks that
# exist is what keeps the rule enforced; naming ones that do not would make it vacuous.
REQUIRED = ("agora", "agora-migrate")


def unknown_tag(loader, suffix, node):
    """Tolerate `!reset` and friends.

    `release-render.py` generates `compose/docker-compose.release.yml` with
    `build: !reset null`, and an overlay is exactly where a variable would be
    added to a service without touching the base.
    """
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return None


class Loader(yaml.SafeLoader):
    """SafeLoader, extended only to IGNORE unknown tags — never to construct one.

    Subclassed rather than `yaml.load` passed a bare loader: this stays exactly as
    safe as `yaml.safe_load`, because SafeLoader has no constructor for
    `!!python/object` and this class adds none. The one addition maps every `!` tag
    to plain data.
    """


Loader.add_multi_constructor("!", unknown_tag)


def environments(path):
    """Every service in a compose file as (name, {VAR: value}), merges resolved."""
    try:
        doc = yaml.load(path.read_text(), Loader=Loader)
    except yaml.YAMLError as exc:
        sys.exit(f"FAIL: {path.name} is not parseable, so nothing in it was checked:\n{exc}")
    if not isinstance(doc, dict):
        return
    services = doc.get("services")
    if not isinstance(services, dict):
        return
    for name, spec in services.items():
        if not isinstance(spec, dict):
            continue
        env = spec.get("environment")
        if isinstance(env, dict):
            yield name, {str(k): v for k, v in env.items()}
        elif isinstance(env, list):
            # The `- KEY=value` form. Docker accepts both and nothing stops a future
            # service using it; a check that only understood the mapping form would
            # read such a service as having no environment at all.
            pairs = {}
            for item in env:
                key, _, value = str(item).partition("=")
                pairs[key.strip()] = value
            yield name, pairs
        else:
            yield name, {}


def main():
    files = sorted(COMPOSE.glob("*.yml")) + sorted(COMPOSE.glob("*.yaml"))
    if not files:
        sys.exit(
            f"FAIL: no compose files under {COMPOSE}. Nothing was checked, which is not the\n"
            f"       same as nothing being wrong."
        )

    bad = []
    credentialled = set()
    credential_names = set()

    for path in files:
        for service, env in environments(path):
            where = f"{path.name}:{service}"
            creds = [k for k in env if CREDENTIAL.match(k)]

            for key in creds:
                raw = env[key]
                value = "" if raw is None else str(raw).strip()
                match = EMPTY_DEFAULT.match(value)
                if not match:
                    # The value is NOT printed back when it fails to be an
                    # interpolation, because the one way to fail that badly is to
                    # have pasted the secret in. Echoing it would put it in a CI
                    # log, which is a second public place.
                    bad.append(
                        f"{where}: {key} is not `${{{key}:-}}`. A credential is a secret and "
                        f"belongs in the untracked tokens file; the compose block passes it "
                        f"through and never holds it. If it is another variable's name instead, "
                        f"it interpolates to empty on every host forever and the service falls "
                        f"back silently — which is how six testnet services ran with no "
                        f"credential at all."
                    )
                    continue
                if match.group(1) != key:
                    bad.append(
                        f"{where}: {key} is wired to ${{{match.group(1)}}}. Nothing sets that "
                        f"name, so it renders empty on every host and the service treats empty "
                        f"as absent — it boots, serves, and authenticates with whatever fallback "
                        f"it has left, with no error anywhere. `estate-bootstrap.sh` mints this "
                        f"under the key's own name."
                    )
                    continue
                credentialled.add(service)
                credential_names.update(creds)

            if not creds:
                continue

            # ── PAIRED BY PREFIX, NOT BY BLOCK (wave M5d) ────────────────────────────
            #
            # `<X>_SERVICE_TOKEN` is a LEGACY slot only where `<X>_IDENTITY_CREDENTIAL`
            # exists to supersede it — that pairing is the whole of rule 2's reasoning:
            # a placeholder throws at boot on a host that has a perfectly good credential
            # for the same service and no minted token for it.
            #
            # Until the merge waves, one block meant one service and "any credential in
            # this block" and "this token's own credential" were the same set. They are
            # not any more. `agora` carries FIVE credentials and also carries
            # `TRADE_SERVICE_TOKEN`, which is not a legacy slot at all: trade has no
            # `TRADE_IDENTITY_CREDENTIAL` and never had one, so that token is its ONLY
            # bearer (SD-05, its own and never shared) and its placeholder default is
            # what lets a bootstrap-less host render.
            #
            # Unpaired, this rule would have demanded an empty default for a variable
            # `agora/src/trade/env.ts` reads with `requiredSecret` — a boot refusal on
            # every host, produced by a check meant to prevent one. Pairing is strictly
            # more precise and loses no existing catch: every pre-merge block had one
            # prefix, so block-scope and prefix-scope agreed on all of them.
            cred_prefixes = {c.rsplit("_IDENTITY_CREDENTIAL", 1)[0] for c in creds}
            for key in sorted(k for k in env if SERVICE_TOKEN.match(k)):
                prefix = key.rsplit("_SERVICE_TOKEN", 1)[0]
                if prefix not in cred_prefixes:
                    continue
                raw = env[key]
                value = "" if raw is None else str(raw).strip()
                if EMPTY_DEFAULT.match(value):
                    continue
                bad.append(
                    f"{where}: {key} defaults to a literal while {prefix}_IDENTITY_CREDENTIAL is also wired. "
                    f"The token slot is optional now and still SHAPE-CHECKED when set — it must "
                    f"be a minted JWT, because in `static` mode the value is presented verbatim "
                    f"as a Bearer — so a placeholder here throws at boot on a host that has a "
                    f"perfectly good credential and no minted token. The variable stays for the "
                    f"length of the rollout; its placeholder cannot. Default it empty."
                )

    for service in REQUIRED:
        if service in credentialled:
            continue
        bad.append(
            f"{service} is handed no *_IDENTITY_CREDENTIAL. micro-emberkin#3 made it exchange "
            f"one for short-lived tokens; without it the service runs in `static` mode on a "
            f"ten-minute bearer read once at boot, which authenticates for the first ten minutes "
            f"of its life and presents a corpse afterwards — on request paths, so it fails when a "
            f"player acts, not on a timer anything is watching. The migrator is named here too "
            f"because it loads the same `env.ts` and takes the service down with it."
        )

    if len(credential_names) < MINIMUM_CREDENTIALS:
        bad.append(
            f"only {len(credential_names)} distinct *_IDENTITY_CREDENTIAL name(s) are wired "
            f"anywhere and this estate has twenty-two. Every rule above is satisfied by a file "
            f"that wires none, so this is the assertion that stops the check passing over an "
            f"empty answer — and it counts NAMES rather than blocks, because a merge moves "
            f"credentials between blocks without changing how many services need one."
        )
    if len(credentialled) < MINIMUM:
        bad.append(
            f"only {len(credentialled)} service block(s) wire a credential at all. The estate has "
            f"collapsed into few enough containers that this is the weaker signal, but a file "
            f"that wired every credential into ONE block would still be a file that had stopped "
            f"describing the estate."
        )

    if bad:
        print("FAIL: service credential wiring", file=sys.stderr)
        for line in bad:
            print(f"  - {line}", file=sys.stderr)
        return 1

    print(
        f"ok: {len(credentialled)} service blocks take a long-lived credential, every one of them as an "
        f"interpolation of\n    its own name, and no legacy service token defaults to a literal "
        f"beside one"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
