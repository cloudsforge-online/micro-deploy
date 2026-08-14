#!/usr/bin/env bash
# Run `hearth-dex-deploy.js` on the CHAIN HOST, inside the hearth-node image.
#
#   ./scripts/hearth-dex-run.sh --status          # read the chain, write nothing
#   ./scripts/hearth-dex-run.sh --dry-run         # everything except the sends
#   ./scripts/hearth-dex-run.sh                   # deploy, then check
#
# ── WHY A CONTAINER, ON A HOST THAT ALREADY RUNS THE CHAIN ───────────────────
#
# The chain host has no `node` and no `pnpm`, on any PATH, including under
# `bash -lc`. It runs the EMBER daemons as host processes and the miners as
# containers, and nothing on it has ever needed a JavaScript runtime of its own.
# Installing one to run a deploy script would add a second, unpinned Node to a
# machine that holds mining keys. The `hearth-node` image already carries the
# exact runtime the chain itself is built against (v22.23.1), so the script runs
# there and the host stays as it is.
#
# `--network host` because the RPC listens on 127.0.0.1 and is not published.
# `--user 1000:1000` because the keys this writes must belong to the operator,
# not to root — a 0600 file owned by root is a file the next run cannot read.
# The miner directory is mounted READ-ONLY: this script spends the coinbase key,
# it has no business rewriting it.
set -uo pipefail

NETWORK="${CF_EMBER_NETWORK:-testnet}"
case "$NETWORK" in
  mainnet) RPC_PORT=8545 ;;
  testnet) RPC_PORT=8745 ;;
  *) echo "CF_EMBER_NETWORK is \"$NETWORK\"; known: mainnet, testnet" >&2; exit 2 ;;
esac

# Where things are on the chain host. Overridable so this is testable elsewhere,
# defaulted so the common case is a bare invocation.
CF_HOME="${CF_HOME:-$HOME}"
HEARTH_SRC="${HEARTH_SRC:-$CF_HOME/dev/cloudsforge/hearth}"
MINER_KEYS="${MINER_KEYS:-$CF_HOME/dev/cloudsforge/miner-keys/$NETWORK}"
DEX_DIR="${DEX_DIR:-$CF_HOME/dex}"

# The image is pinned by digest-bearing tag rather than `:latest` for the same
# reason every other pin in this repository exists: a deploy that cannot say
# which build it ran is a deploy nobody can reproduce. Bump it deliberately.
IMAGE="${HEARTH_NODE_IMAGE:-ghcr.io/cloudsforge-online/hearth-node:sha-a094dba6ace0448a483f79533964e6663b870334}"

for p in "$HEARTH_SRC/node/src/chain/transaction.js" "$MINER_KEYS/coinbase-key.json" "$DEX_DIR/artifacts" "$DEX_DIR/hearth-dex-deploy.js"; do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done
mkdir -p "$DEX_DIR/keys"
chmod 700 "$DEX_DIR/keys"

exec docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v "$HEARTH_SRC:/hearth:ro" \
  -v "$MINER_KEYS:/minerdata:ro" \
  -v "$DEX_DIR/artifacts:/artifacts:ro" \
  -v "$DEX_DIR/keys:/dexkeys" \
  -v "$DEX_DIR/hearth-dex-deploy.js:/dex-deploy.js:ro" \
  -e "CF_EMBER_NETWORK=$NETWORK" \
  -e HEARTH_REPO=/hearth \
  -e HEARTH_ARTIFACTS=/artifacts \
  -e EMBER_MINER_DATA=/minerdata \
  -e HEARTH_DEX_HOME=/dexkeys \
  -e EMBER_HOME=/dexkeys \
  -e "EMBER_HOST_RPC=http://127.0.0.1:$RPC_PORT" \
  ${HEARTH_DEX_OWNERS:+-e "HEARTH_DEX_OWNERS=$HEARTH_DEX_OWNERS"} \
  --entrypoint node \
  "$IMAGE" \
  /dex-deploy.js "$@"
