#!/usr/bin/env bash
# Run `hearth-receipt-deploy.js` on the CHAIN HOST, inside the hearth-node image.
#
#   ./scripts/hearth-receipt-run.sh --status      # read the chain, write nothing
#   ./scripts/hearth-receipt-run.sh --drill       # the redemption rehearsal
#   ./scripts/hearth-receipt-run.sh               # deploy fLTC, publish, attest, prove
#
# ── WHY A CONTAINER ──────────────────────────────────────────────────────────
#
# Same reason as `hearth-dex-run.sh`: the chain host has no `node` and no `pnpm`
# on any PATH, and installing one to run a deploy script would add a second,
# unpinned runtime to the machine that holds the mining keys. The `hearth-node`
# image already carries the runtime the chain is built against.
#
# ── WHY THE RESERVE IS MEASURED OUT HERE, NOT IN THERE ───────────────────────
#
# `litecoin-cli` authenticates with the cookie in litecoind's datadir. Handing
# that datadir to a container that also signs EMBER transactions and prints
# diagnostics would put a live credential one stray error message away from a
# transcript — which is exactly how bitcoind's rpcauth leaked once already, out
# of a caught exception nobody thought contained a URL.
#
# So the scan happens here, in a shell that knows the credential and prints only
# numbers, and the deploy script receives four values: a litoshi total, a height,
# that block's hash, and the address list the total covers. It refuses to attest
# without all four, and it refuses to attest a number nobody read.
#
# ── THE SCAN IS SLOW, AND THAT IS THE POINT ──────────────────────────────────
#
# `scantxoutset` walks the entire UTXO set — ~53.8 million outputs, two to four
# minutes. It is the only reading that requires nothing of us: no wallet, no
# import, no index we control, no database of ours. A stranger runs the identical
# command against their own node and gets the identical answer, which is what
# `docs/39` §4 means by "checkable on the chain by a stranger, without asking us".
set -uo pipefail

NETWORK="${CF_EMBER_NETWORK:-testnet}"
case "$NETWORK" in
  mainnet) RPC_PORT=8545 ;;
  testnet) RPC_PORT=8745 ;;
  *) echo "CF_EMBER_NETWORK is \"$NETWORK\"; known: mainnet, testnet" >&2; exit 2 ;;
esac

CF_HOME="${CF_HOME:-$HOME}"
HEARTH_SRC="${HEARTH_SRC:-$CF_HOME/dev/cloudsforge/hearth}"
MINER_KEYS="${MINER_KEYS:-$CF_HOME/dev/cloudsforge/miner-keys/$NETWORK}"
DEX_DIR="${DEX_DIR:-$CF_HOME/dex}"
IMAGE="${HEARTH_NODE_IMAGE:-ghcr.io/cloudsforge-online/hearth-node:sha-a094dba6ace0448a483f79533964e6663b870334}"

# The Litecoin node, and the addresses whose balances back the receipt.
#
# THE LIST IS THE CONTRACT. Whatever is in here is what gets published on chain
# through `setReserveAddresses`, and the attested total is the sum over exactly
# these and nothing else — so a stranger's re-scan reconciles or the attestation
# is wrong. Two treasury-purpose keys and one pool-purpose key: the pool address
# is included because pool-mined coin is platform-controlled coin, and leaving it
# out would make the published total smaller than the truth in the one direction
# that flatters us.
#
# Per-user DEPOSIT addresses are deliberately absent. Coin sitting in a user's
# deposit address is that user's, not reserve, and counting it as backing would
# be pledging other people's money.
LITECOIN_CLI="${LITECOIN_CLI:-/data/docs/litecoin-0.21.5.6/bin/litecoin-cli}"
LITECOIN_DATADIR="${LITECOIN_DATADIR:-/data/chains/litecoin}"
RESERVE_ADDRESSES="${CF_RECEIPT_ADDRESSES:-ltc1qswwly0reyr85mr9xjx4ujtep5q7nndmulpmmnq,ltc1qc4uhej2g2tc2ytqc5qczxmfyun87gctafnjghp,ltc1qtkkwej6dwp0m58k99ckac76qp4agyu3pr0pqvp}"

for p in "$HEARTH_SRC/node/src/chain/transaction.js" "$MINER_KEYS/coinbase-key.json" "$DEX_DIR/artifacts" "$DEX_DIR/hearth-receipt-deploy.js"; do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done
mkdir -p "$DEX_DIR/keys"
chmod 700 "$DEX_DIR/keys"

# ── measure ──────────────────────────────────────────────────────────────────
# Skipped for --status and --drill: neither attests against Litecoin, and a
# four-minute UTXO walk to print a status line is four minutes of a node that
# `runbook-chain-node-unreachable.md` records as able to wedge under load.
MEASURE=1
for a in "$@"; do
  case "$a" in --status|--drill) MEASURE=0 ;; esac
done

if [ "$MEASURE" = 1 ]; then
  [ -x "$LITECOIN_CLI" ] || { echo "no litecoin-cli at $LITECOIN_CLI" >&2; exit 1; }

  DESCRIPTORS=$(printf '%s' "$RESERVE_ADDRESSES" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"addr(%s)\"", (i>1?",":""), $i}}')
  echo "── scanning the Litecoin UTXO set for ${RESERVE_ADDRESSES//,/, } ─────"
  echo "   (this walks every unspent output on the chain; two to four minutes)"

  SCAN=$("$LITECOIN_CLI" -datadir="$LITECOIN_DATADIR" scantxoutset start "[$DESCRIPTORS]" </dev/null) || {
    echo "scantxoutset failed — if it reports a scan already running, wait or \`scantxoutset abort\`" >&2
    exit 1
  }

  # python3 rather than jq: jq is not on this host, and the amount has to become
  # an integer count of litoshis without ever passing through a float. 0.1 LTC is
  # not representable in binary floating point and `int(x * 1e8)` on a real
  # balance is how an attestation ends up one litoshi short of the truth.
  read -r RESERVE_SATS HEIGHT REF <<EOF
$(printf '%s' "$SCAN" | python3 -c '
import sys, json
from decimal import Decimal
s = json.load(sys.stdin, parse_float=Decimal)
if not s.get("success"):
    sys.exit("scantxoutset did not report success")
total = sum(Decimal(str(u["amount"])) for u in s["unspents"])
print(int(total * 100000000), s["height"], "0x" + s["bestblock"])
')
EOF
  [ -n "${REF:-}" ] || { echo "could not read the scan result" >&2; exit 1; }

  echo "   reserve  $RESERVE_SATS litoshis at Litecoin height $HEIGHT"
  echo "   block    $REF"
  echo
  export CF_RECEIPT_RESERVE_SATS="$RESERVE_SATS"
  export CF_RECEIPT_HEIGHT="$HEIGHT"
  export CF_RECEIPT_REF="$REF"
  export CF_RECEIPT_ADDRESSES="$RESERVE_ADDRESSES"
fi

exec docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v "$HEARTH_SRC:/hearth:ro" \
  -v "$MINER_KEYS:/minerdata:ro" \
  -v "$DEX_DIR/artifacts:/artifacts:ro" \
  -v "$DEX_DIR/keys:/dexkeys" \
  -v "$DEX_DIR/hearth-receipt-deploy.js:/receipt-deploy.js:ro" \
  -e "CF_EMBER_NETWORK=$NETWORK" \
  -e HEARTH_REPO=/hearth \
  -e HEARTH_ARTIFACTS=/artifacts \
  -e EMBER_MINER_DATA=/minerdata \
  -e HEARTH_DEX_HOME=/dexkeys \
  -e EMBER_HOME=/dexkeys \
  -e "EMBER_HOST_RPC=http://127.0.0.1:$RPC_PORT" \
  ${CF_RECEIPT_RESERVE_SATS:+-e CF_RECEIPT_RESERVE_SATS} \
  ${CF_RECEIPT_HEIGHT:+-e CF_RECEIPT_HEIGHT} \
  ${CF_RECEIPT_REF:+-e CF_RECEIPT_REF} \
  ${CF_RECEIPT_ADDRESSES:+-e CF_RECEIPT_ADDRESSES} \
  ${CF_RECEIPT_MAX_AGE:+-e CF_RECEIPT_MAX_AGE} \
  --entrypoint node \
  "$IMAGE" \
  /receipt-deploy.js "$@"
