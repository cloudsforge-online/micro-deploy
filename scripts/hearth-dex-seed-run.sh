#!/usr/bin/env bash
# Run `hearth-dex-seed.js` on the CHAIN HOST, inside the hearth-node image.
#
#   ./scripts/hearth-dex-seed-run.sh --status     # read the pool, write nothing
#   ./scripts/hearth-dex-seed-run.sh --dry-run    # everything except the sends
#   ./scripts/hearth-dex-seed-run.sh              # deploy the token, fund the pair, exercise it
#   ./scripts/hearth-dex-seed-run.sh --exercise   # trade against a pool that already exists
#
# The sibling of `hearth-dex-run.sh`, and the reasoning is entirely that file's:
# the chain host has no `node` on any PATH, so the script runs in the image the
# chain itself is built against rather than putting a second, unpinned Node on
# the machine that holds the mining keys.
#
# ── ONE DIFFERENCE FROM THE DEPLOY WRAPPER, AND IT MATTERS ───────────────────
#
# `hearth-dex-deploy.js` is one self-contained file and mounts as one file.
# `hearth-dex-seed.js` requires `./lib/hearth-evm.js`, which resolves relative to
# its own directory — so the script and its lib are mounted as a DIRECTORY at a
# path where that relative require still works. Mounting the script alone gives
# `Cannot find module './lib/hearth-evm.js'`, and the fix is not to inline the
# library back into the script.
#
# ── AND ONE ENVIRONMENT VARIABLE THAT IS NOT OPTIONAL ON MAINNET ─────────────
#
# `HEARTH_DEX_SEED_EMBER` and `HEARTH_DEX_SEED_TOKEN` default to testnet depths.
# On mainnet the opening depth is an owner decision (`docs/39` §7) and must be
# passed in deliberately; this wrapper forwards them but invents nothing.
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
  "$DEX_DIR/artifacts/FixedSupplyToken.json" \
  "$DEX_DIR/seed/hearth-dex-seed.js" \
  "$DEX_DIR/seed/lib/hearth-evm.js" \
  "$DEX_DIR/keys/deployment-$( [ "$NETWORK" = mainnet ] && echo 7411 || echo 7412 ).json"
do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done

exec docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v "$HEARTH_SRC:/hearth:ro" \
  -v "$MINER_KEYS:/minerdata:ro" \
  -v "$DEX_DIR/artifacts:/artifacts:ro" \
  -v "$DEX_DIR/keys:/dexkeys" \
  -v "$DEX_DIR/seed:/dexseed:ro" \
  -e "CF_EMBER_NETWORK=$NETWORK" \
  -e HEARTH_REPO=/hearth \
  -e HEARTH_ARTIFACTS=/artifacts \
  -e EMBER_MINER_DATA=/minerdata \
  -e HEARTH_DEX_HOME=/dexkeys \
  -e EMBER_HOME=/dexkeys \
  -e "EMBER_HOST_RPC=http://127.0.0.1:$RPC_PORT" \
  ${HEARTH_DEX_PAIR_TOKEN:+-e "HEARTH_DEX_PAIR_TOKEN=$HEARTH_DEX_PAIR_TOKEN"} \
  ${HEARTH_DEX_TOKEN_NAME:+-e "HEARTH_DEX_TOKEN_NAME=$HEARTH_DEX_TOKEN_NAME"} \
  ${HEARTH_DEX_TOKEN_SYMBOL:+-e "HEARTH_DEX_TOKEN_SYMBOL=$HEARTH_DEX_TOKEN_SYMBOL"} \
  ${HEARTH_DEX_TOKEN_SUPPLY:+-e "HEARTH_DEX_TOKEN_SUPPLY=$HEARTH_DEX_TOKEN_SUPPLY"} \
  ${HEARTH_DEX_SEED_EMBER:+-e "HEARTH_DEX_SEED_EMBER=$HEARTH_DEX_SEED_EMBER"} \
  ${HEARTH_DEX_SEED_TOKEN:+-e "HEARTH_DEX_SEED_TOKEN=$HEARTH_DEX_SEED_TOKEN"} \
  ${HEARTH_DEX_SWAP_EMBER:+-e "HEARTH_DEX_SWAP_EMBER=$HEARTH_DEX_SWAP_EMBER"} \
  ${HEARTH_DEX_REMOVE_PERCENT:+-e "HEARTH_DEX_REMOVE_PERCENT=$HEARTH_DEX_REMOVE_PERCENT"} \
  --entrypoint node \
  "$IMAGE" \
  /dexseed/hearth-dex-seed.js "$@"
