#!/usr/bin/env bash
# The EMBER testnet the estate indexes — Hearth's own compose file, run as it is.
#
#   cd deploy
#   ./scripts/ember-testnet.sh up       # seed + two miners, chain id 7412
#   ./scripts/ember-testnet.sh status
#   ./scripts/ember-testnet.sh down     # keeps the chain; --volumes discards it
#
# ── WHY THERE IS NO COMPOSE FILE IN THIS REPOSITORY ───────────────────────────
#
# Because `hearth/docker-compose.testnet.yml` already is one, and `hearth` is the
# frozen legacy repository: read it, run it, never modify it. Copying its three
# services here to "own" them would create a second definition of a chain that
# has exactly one, and the first time the two disagreed the symptom would be two
# nodes with different genesis hashes and no peers.
#
# So this file starts THAT file, unchanged, and adds nothing to it. Everything
# below is argument, ports and lifecycle — not configuration.
#
# ── TESTNET, NOT "DEVNET", AND THE ESTATE ALREADY SAID SO ─────────────────────
#
# `contracts/packages/chain/src/index.ts:17` declares `Network = 'mainnet' |
# 'testnet'`. There is no third value, so a "devnet" has nowhere to live in the
# type system — `indexer/src/chains.ts:57` would refuse the string, and
# `LEDGER_RECONCILE_NETWORK` (docker-compose.estate.yml) has said `testnet` since
# before this chain existed. The full ecosystem is testnet; production will be
# mainnet; there is no third vocabulary.
#
# That also settles the parameters. EMBER is 15-second blocks and 60
# confirmations — fifteen minutes to a confirmed balance — and
# `contracts/packages/chain/src/index.ts:45` calls that depth "the number Hearth
# publishes to exchanges". Shortening it for a nicer dev loop would leave the
# estate's own `chainSpec().confirmations` reasoning about a chain that no longer
# matched its constants, which is not a faster environment but a dishonest one.
# The estate's design already absorbs the latency with a pre-funded reserve.
#
# ── WHAT RUNS, AND ON WHICH PORTS ─────────────────────────────────────────────
#
#   hearth-testnet-seed     :8545 eth JSON-RPC   :8645 REST   :8646 P2P
#   hearth-testnet-miner1   :8547               :8647
#   hearth-testnet-miner2   :8549               :8649
#
# The estate's indexer reaches :8545 through `host.docker.internal` rather than a
# compose network, for the ownership reason above. The OWNER'S miner is a fourth
# node and is NOT here — it runs on the host, outside every compose project, and
# holds the owner's key. See `ember-miner.sh`.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
HEARTH=${HEARTH_REPO:-$(cd "$HERE/../hearth" 2>/dev/null && pwd)}
COMPOSE_FILE=${HEARTH_TESTNET_COMPOSE:-docker-compose.testnet.yml}
RPC=${EMBER_HOST_RPC:-http://127.0.0.1:8545}
REST=${EMBER_HOST_REST:-http://127.0.0.1:8645}

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

if [ -z "$HEARTH" ] || [ ! -f "$HEARTH/$COMPOSE_FILE" ]; then
  bad "no hearth checkout beside this repository (looked for $HEARTH/$COMPOSE_FILE)"
  echo "       set HEARTH_REPO to point at it. This script runs hearth's file; it does not carry one." >&2
  exit 1
fi

# `eth_blockNumber` over the published port. Used by `up` to wait and by `status`
# to report, so there is one definition of "the chain is answering".
height() {
  curl -s --max-time 5 -X POST -H 'content-type: application/json' \
    --data-binary '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$RPC" 2>/dev/null \
    | sed -n 's/.*"result":"0x\([0-9a-f]*\)".*/\1/p'
}

case "${1:-up}" in
  up)
    echo "── the EMBER testnet: hearth/$COMPOSE_FILE, unmodified ──────────────────"
    docker compose -f "$HEARTH/$COMPOSE_FILE" --project-directory "$HEARTH" up -d --build || exit 1

    # Poll rather than sleep a fixed amount. A fixed sleep is either longer than
    # it needs to be or shorter than it needs to be, and which one it is depends
    # on the machine rather than on anything under test.
    attempt=0
    while [ "$attempt" -lt 60 ]; do
      h=$(height)
      [ -n "$h" ] && break
      attempt=$((attempt + 1))
      sleep 1
    done
    if [ -z "${h:-}" ]; then
      bad "no eth JSON-RPC at $RPC after 60s — the estate's indexer will follow nothing"
      exit 1
    fi
    id=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
      --data-binary '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' "$RPC" \
      | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p')
    # 0x1cf4 is 7412. Asserted rather than printed: a node answering on this port
    # with a different id is a node the estate's `contracts-chain` constants do
    # not describe, and every confirmation depth downstream would be wrong.
    if [ "$id" = "0x1cf4" ]; then
      ok "chain id 7412 (EMBER testnet), height $((16#$h))"
    else
      bad "the node at $RPC reports chain id $id, not 0x1cf4 (7412) — this is not the chain the estate indexes"
      exit 1
    fi
    echo
    echo "  The two miners here keep the chain alive. The OWNER'S miner is separate,"
    echo "  runs on the host outside compose, and holds the owner's key:"
    echo
    echo "      ./scripts/ember-miner.sh start"
    ;;

  down)
    # `--volumes` is NEVER the default. The named volumes hold the chain, and a
    # discarded chain is a discarded custody position: every seeded address, and
    # every EMBER the owner's miner has earned, ceases to have a history.
    if [ "${2:-}" = "--volumes" ]; then
      echo "!! discarding the chain's named volumes — every seeded balance goes with them"
      docker compose -f "$HEARTH/$COMPOSE_FILE" --project-directory "$HEARTH" down -v
    else
      docker compose -f "$HEARTH/$COMPOSE_FILE" --project-directory "$HEARTH" down
      echo "  the chain is kept. '$(basename "$0") down --volumes' discards it."
    fi
    ;;

  status)
    h=$(height)
    if [ -z "$h" ]; then
      bad "no node answering at $RPC"
      exit 1
    fi
    ok "eth JSON-RPC at $RPC, height $((16#$h))"
    curl -s --max-time 5 "$REST/info" || true
    echo
    ;;

  *)
    echo "usage: $(basename "$0") {up|down [--volumes]|status}" >&2
    exit 2
    ;;
esac
