#!/usr/bin/env python3
"""`WALLET_FEE_QUOTES` only ever opens a chain settlement can actually pay out of.

── WHAT IS BEING GUARDED, AND WHY IT IS NOT "IS THIS VALID JSON" ─────────────

`x-wallet-fee-quotes` is the single most consequential string in this file, and
it is consequential in a direction that is easy to miss. It is not only the
withdrawal price list. `wallet/src/index.ts` wraps its observability in
`payableChainsOnly(payableFromFeeQuotes(env.feeQuotes))` with the PAYABILITY
half outermost, so an asset named here is a chain this estate will hand out a
deposit address for, watch, and credit — and an asset absent is one it will do
none of those things for, however well the indexer can see it.

So adding one key to this object opens the money-IN path for a chain. The
question that has to be asked at the same moment is whether the money-OUT path
is open too, and until this check existed nothing asked it anywhere:

  * `settlement/src/env.ts` reports a chain with no endpoint as `no_endpoint`
    and refuses each request by name — deliberately a status rather than a boot
    failure, so one unconfigured chain cannot take the others down.
  * `wallet` never consults that status. It reads this table.

A deployment that quotes a fee for a chain `SETTLEMENT_RPC_URLS` cannot name is
therefore one that issues real addresses, credits real coin, and answers every
withdrawal of it with a permanent refusal. Nothing crashes and nothing logs an
error: the deposits work. micro-org#373 §6.3 derived exactly this ordering
constraint by hand and concluded BTC must not appear here until a UTXO source
and a fee source existed. This is that constraint, enforced.

── THE REACHABILITY TEST IS STRUCTURAL, NOT A LIST ──────────────────────────

The set of chains settlement can be given an endpoint for is READ OUT of the
sibling anchor `x-settlement-rpc-urls` — its `ember` default plus one chain per
`${VAR:+,"chain":"$VAR"}` fragment — and then confirmed by rendering that anchor
with real `docker compose` and reading the keys back. There is no list in this
file to drift: wiring DOGE into that anchor makes DOGE quotable here on the same
commit, and removing a fragment makes the chain it named fail here immediately.

What it refuses today is ETH, SOL and XRP. All three are `AssetCode` members
that `wallet/src/env.ts` would accept without complaint, none of them has a
fragment in the settlement anchor, and XRP's adapter answers `unimplemented`
outright. A fee quote for any of them opens deposits for a coin this estate can
never send back.

── AND THE SHAPE CHECKS, WHICH ARE A BOOT LOOP AND NOT A FEATURE ────────────

`wallet/src/env.ts` parses this eagerly and `src/migrator.ts` imports the same
module, so a malformed value throws at import on `wallet` AND `wallet-migrate`,
under `restart: unless-stopped`. The refusals reproduced below are the ones that
a compose edit can actually produce — not JSON, not an object, an empty value
(`BigInt('')` is `0n`, which is a free withdrawal), a non-integer, a negative, a
zero. The one refusal deliberately NOT reproduced is env.ts's "at least one
whole coin at this asset's decimals" bound: the decimals table lives in
`@cloudsforge/contracts-chain`, in another repository, and a copy of it here
would be a second source of truth for exactly the kind of figure this check
exists to protect. That bound stays where the authority is.

The chain slug is `asset.lower()` rather than a mapping table, and that is not a
convenience: `wallet/src/addresses.ts` declares `type ChainId =
Lowercase<IssuableAssetCode>`, so the relationship IS the lowercase of the asset
code by construction upstream.

── HOW THIS AVOIDS BEING A CHECK THAT CANNOT FAIL ───────────────────────────

Both anchors are read out of the estate compose and rendered by real
`docker compose config`, so the strings under test are the ones the estate
deploys. Then `--self-test` runs the same validator over eight hand-built
mutations — an unreachable chain, a zero fee, an empty value, a JSON array, and
so on — and fails if any of them is ACCEPTED. A validator that answers "ok" to
everything passes the live file too, and that is the failure mode of every
check like this one.

NO VALUE FROM THE SETTLEMENT ANCHOR IS EVER PRINTED: on every UTXO chain it
carries an HTTP Basic password. Fee quotes are not secret and are printed.

Exit 0 only if every assertion holds.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so neither anchor can be read out of the estate compose "
        "file.\n"
        "       This is a failure and not a skip: a check that reports a pass it did not "
        "establish is worse than no check.\n"
        "       python3 -m pip install pyyaml"
    )

ROOT = pathlib.Path(__file__).resolve().parent.parent
ESTATE = ROOT / "compose" / "docker-compose.estate.yml"

FEE_ANCHOR = "x-wallet-fee-quotes"
FEE_VARIABLE = "WALLET_FEE_QUOTES"
RPC_ANCHOR = "x-settlement-rpc-urls"
RPC_VARIABLE = "SETTLEMENT_RPC_URLS"

# Both containers run wallet's eager `env.ts`. A migrator left off the anchor stops the release at
# its migration step rather than starting with a different table, which is worse in one specific
# way: the estate is then half-deployed on a value nobody chose.
#
# ── WAVE M5d: THE TWO CONTAINERS ARE NOW NAMED `agora` ───────────────────────────────────────
#
# wallet is a MODULE of agora since 2026-08-31 (`agora/src/wallet/`), so there is no `wallet`
# service in the compose file to check and there is no `wallet-migrate` Job. The property this
# check defends is unchanged and, if anything, sharper: `agora/src/wallet/env.ts` still parses
# WALLET_FEE_QUOTES eagerly at import, and `agora/src/migrator.ts` still reaches it — through
# `walletMigrationTargets()` in `agora/src/wallet/module.ts` — so a malformed table is still a
# crash loop on the server pod AND a stopped migration, and a container left off the anchor still
# opens no chain at all or reads a second, drifting copy.
#
# What is NEW is that these two containers now carry twenty-three modules between them, so an
# anchor missed here takes the whole estate down rather than the wallet. That makes the check more
# load-bearing than it was, not less, which is why the names are updated rather than the readers
# dropped to one.
FEE_READERS = ("agora", "agora-migrate")

# `${VAR:+,"chain":"$VAR"}` — one optional chain, its key and the variable that supplies it.
FRAGMENT = re.compile(r'\$\{(?P<var>[A-Z0-9_]+):\+,"(?P<chain>[a-z]+)":')
# `{"ember":"${EMBER_RPC_URL:-…}"` — the one chain with a default, so always present.
DEFAULTED = re.compile(r'"(?P<chain>[a-z]+)":"\$\{[A-Z0-9_]+:-')


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


class Rejected(Exception):
    """What `wallet/src/env.ts` would have thrown at import, or what this check adds to it."""


def validate(raw, reachable):
    """Refuse exactly what a boot would refuse, plus the reachability rule this check adds.

    Raises `Rejected`. Returns the parsed table so the caller can report it. `reachable` is the set
    of chain slugs `SETTLEMENT_RPC_URLS` can name — never hard-coded, always read from its anchor.
    """
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise Rejected(
            f"{FEE_VARIABLE} is not JSON ({exc.msg} at position {exc.pos}). `wallet/src/env.ts` "
            f"parses this at import, so it is a crash loop on `wallet` and `wallet-migrate` both."
        ) from exc
    if not isinstance(parsed, dict):
        raise Rejected(f"{FEE_VARIABLE} is not a JSON object.")
    if not parsed:
        raise Rejected(
            f"{FEE_VARIABLE} is empty. That is a deployment which takes no deposits and pays no "
            f"withdrawals for any asset — legal, and never what an estate compose file means."
        )

    for asset, value in parsed.items():
        where = f"{FEE_VARIABLE}.{asset}"
        if asset != asset.upper():
            raise Rejected(
                f"{where} is not upper case. `wallet/src/env.ts` looks the key up in `CHAINS`, "
                f"whose keys are the `AssetCode` union, so a lower-case key installs a quote for a "
                f"coin that does not exist while the real asset stays absent and refused."
            )
        if not isinstance(value, str):
            raise Rejected(
                f"{where} is {type(value).__name__} and must be a decimal STRING. A JSON number "
                f"loses precision above 2^53, which an 18-decimal chain reaches routinely."
            )
        if value.strip() == "":
            raise Rejected(
                f"{where} is empty. `BigInt('')` is `0n` and does not throw, so this reads as a "
                f"free withdrawal paid out of the treasury with no error raised anywhere."
            )
        if not re.fullmatch(r"-?[0-9]+", value.strip()):
            raise Rejected(f"{where} is not an integer.")
        fee = int(value)
        if fee < 0:
            raise Rejected(f"{where} must not be negative.")
        if fee == 0:
            raise Rejected(
                f"{where} is zero. Waiving the network fee is a decision an operator takes on "
                f"purpose; it must never be what a malformed value degrades into."
            )

        # ── THE RULE THIS CHECK EXISTS FOR ────────────────────────────────────
        chain = asset.lower()
        if chain not in reachable:
            raise Rejected(
                f"{where} opens {asset} deposits on a chain {RPC_VARIABLE} cannot name. "
                f"`wallet/src/index.ts` gates its observability on this table, so this key makes "
                f"the estate hand out a real {asset} address, watch it and credit it — while "
                f"settlement reports `{chain}` as `no_endpoint` and refuses every withdrawal of it "
                f"permanently. Coins in, nothing out, and no error anywhere because the deposits "
                f"work. Wire `{chain}` into `{RPC_ANCHOR}` first (micro-org#373 §6.3). "
                f"{RPC_VARIABLE} can name: {', '.join(sorted(reachable))}."
            )
    return parsed


def main():
    if shutil.which("docker") is None:
        fail("docker is not available, so neither anchor can be rendered. Refusing to guess them.")

    try:
        estate = yaml.safe_load(ESTATE.read_text())
    except yaml.YAMLError as exc:
        fail(f"{ESTATE.name} is not parseable, so nothing in it was checked:\n{exc}")

    def anchor_of(key):
        value = estate.get(key)
        if not isinstance(value, str) or not value.strip():
            fail(
                f"{ESTATE.name} defines no `{key}` string. Either the anchor was renamed and this "
                f"check is now guarding nothing, or the estate has stopped setting it at all."
            )
        return value.strip()

    fee_anchor = anchor_of(FEE_ANCHOR)
    rpc_anchor = anchor_of(RPC_ANCHOR)
    if "'" in fee_anchor or "'" in rpc_anchor:
        fail(
            "an anchor contains a single quote, so this check cannot embed it in a fixture compose "
            "file without changing it. Rewrite the fixture emitter rather than weakening what is "
            "under test."
        )

    # ── THE ANCHOR REACHES BOTH CONTAINERS ───────────────────────────────────
    services = estate.get("services") or {}
    for required in FEE_READERS:
        spec = services.get(required)
        environment = spec.get("environment") if isinstance(spec, dict) else None
        if not isinstance(environment, dict) or environment.get(FEE_VARIABLE) != fee_anchor:
            fail(
                f"`{required}` does not take {FEE_VARIABLE} from the `{FEE_ANCHOR}` anchor. Both "
                f"it and the service run wallet's eager `env.ts`, so both parse this at import; a "
                f"container left off the anchor either opens no chain at all or reads a second, "
                f"drifting copy of the table."
            )

    # ── WHAT SETTLEMENT CAN BE GIVEN AN ENDPOINT FOR, FROM ITS OWN ANCHOR ────
    optional = {match["chain"]: match["var"] for match in FRAGMENT.finditer(rpc_anchor)}
    defaulted = {match["chain"] for match in DEFAULTED.finditer(rpc_anchor)}
    if not defaulted:
        fail(
            f"`{RPC_ANCHOR}` has no `\"chain\":\"${{VAR:-…}}\"` default, so this check could not "
            f"tell which chain is always present. The anchor's shape changed; read it and update "
            f"the two patterns here rather than dropping the reachability rule."
        )

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = pathlib.Path(tmp)
        fixture = tmpdir / "docker-compose.fixture.yml"
        fixture.write_text(
            "services:\n"
            "  probe:\n"
            "    image: example.invalid/probe:latest\n"
            "    environment:\n"
            f"      {FEE_VARIABLE}: '{fee_anchor}'\n"
            f"      {RPC_VARIABLE}: '{rpc_anchor}'\n"
        )
        env_file = tmpdir / "render.env"
        # Invented, and never printed. Their only job is to make every optional fragment expand so
        # the rendered map names every chain the anchor CAN name.
        env_file.write_text(
            "".join(f"{var}=http://fixture-user:fixture-pass@127.0.0.1:1\n" for var in optional.values())
        )
        proc = subprocess.run(
            ["docker", "compose", "--env-file", str(env_file), "-f", str(fixture),
             "config", "--format", "json"],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            # stderr can quote an interpolated endpoint, so it is not echoed.
            fail("`docker compose config` could not render the two anchors together.")
        rendered = json.loads(proc.stdout)["services"]["probe"]["environment"]

    try:
        every_chain = json.loads(rendered[RPC_VARIABLE])
    except json.JSONDecodeError:
        fail(
            f"{RPC_VARIABLE} did not render to JSON with every optional variable set, so the set "
            f"of reachable chains could not be established. `check-settlement-rpc-urls.py` is the "
            f"check that diagnoses that; this one refuses to guess around it."
        )
    reachable = set(every_chain) | defaulted
    missing_fragments = sorted(chain for chain in optional if chain not in every_chain)
    if missing_fragments:
        fail(
            f"`{RPC_ANCHOR}` has a fragment for {', '.join(missing_fragments)} that did not render "
            f"a key. The two patterns in this check and the anchor have drifted apart, so the "
            f"reachable set is wrong in the permissive direction."
        )

    try:
        quotes = validate(rendered[FEE_VARIABLE], reachable)
    except Rejected as exc:
        fail(str(exc))

    # ── THE VALIDATOR CAN SAY NO ─────────────────────────────────────────────
    #
    # Every assertion above is satisfied by a `validate` that returns unconditionally, and the live
    # table is the one input guaranteed not to exercise a refusal. So each refusal is provoked.
    mutations = {
        "not JSON at all": "{",
        "a JSON array": '["EMBER"]',
        "an empty table": "{}",
        "a lower-case key": '{"ltc":"10000"}',
        "a JSON number": '{"LTC":10000}',
        "an empty value": '{"LTC":""}',
        "a zero fee": '{"LTC":"0"}',
        "a negative fee": '{"LTC":"-1"}',
        "a non-integer": '{"LTC":"1.5"}',
        "a chain settlement cannot reach": '{"XRP":"1000"}',
    }
    accepted = []
    for description, raw in mutations.items():
        try:
            validate(raw, reachable)
        except Rejected:
            continue
        accepted.append(description)
    if accepted:
        fail(
            "the validator ACCEPTED " + ", ".join(accepted) + ". Everything it reported about the "
            "live file is therefore unestablished — a check that cannot say no has not said yes."
        )

    print(
        f"ok: {FEE_VARIABLE} renders to a well-formed table naming "
        f"{', '.join(sorted(quotes))}; every one of them is a chain {RPC_VARIABLE} can carry an "
        f"endpoint for, so no chain is open to deposits that settlement could not pay back out of; "
        f"both wallet containers take the anchor; and the validator was shown to reject "
        f"{len(mutations)} malformed tables including {list(mutations)[-1]}"
    )


if __name__ == "__main__":
    main()
