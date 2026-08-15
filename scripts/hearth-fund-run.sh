#!/usr/bin/env bash
# Run `hearth-fund.js` on the CHAIN HOST, inside the hearth-node image.
#
#   ./scripts/hearth-fund-run.sh --status 0xabc…       # read both balances, write nothing
#   ./scripts/hearth-fund-run.sh --dry-run 0xabc… 60   # everything except the send
#   ./scripts/hearth-fund-run.sh 0xabc… 60             # send 60 EMBER
#
# The sibling of `hearth-dex-seed-run.sh`, and the reasoning is that file's: the
# chain host has no `node` on any PATH, so the script runs in the image the chain
# itself is built against rather than putting a second, unpinned Node on the
# machine that holds the mining keys. Like that wrapper it mounts the script's
# DIRECTORY, because `./lib/hearth-evm.js` resolves relative to the script.
#
# ── WHAT IT DOES NOT MOUNT ───────────────────────────────────────────────────
#
# No artifacts, no `$DEX_DIR/keys`. This script sends EMBER and knows nothing
# about the exchange; mounting the exchange's writable note directory into it
# would give a plain transfer a way to alter the deployment record. The only
# writable path here is none.
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

for p in \
  "$HEARTH_SRC/node/src/chain/transaction.js" \
  "$MINER_KEYS/coinbase-key.json" \
  "$DEX_DIR/seed/hearth-fund.js" \
  "$DEX_DIR/seed/lib/hearth-evm.js"
do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done

exec docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v "$HEARTH_SRC:/hearth:ro" \
  -v "$MINER_KEYS:/minerdata:ro" \
  -v "$DEX_DIR/seed:/dexseed:ro" \
  -e "CF_EMBER_NETWORK=$NETWORK" \
  -e HEARTH_REPO=/hearth \
  -e EMBER_MINER_DATA=/minerdata \
  -e "EMBER_HOST_RPC=http://127.0.0.1:$RPC_PORT" \
  --entrypoint node \
  "$IMAGE" \
  /dexseed/hearth-fund.js "$@"
