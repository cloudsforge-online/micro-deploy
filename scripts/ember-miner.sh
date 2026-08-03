#!/usr/bin/env bash
# The owner's EMBER miner: one node, on the host, outside every compose project.
#
#   cd deploy
#   ./scripts/ember-miner.sh start
#   ./scripts/ember-miner.sh status     # is it MINING, not merely up
#   ./scripts/ember-miner.sh address    # where the coin goes
#   ./scripts/ember-miner.sh stop
#
# ── WHY IT HOLDS A PRIVATE KEY, WHICH IS NOT SLOPPINESS ───────────────────────
#
# Hearth binds the coinbase into the work itself. `node/src/chain/miner.js:103`
# hashes `POW.powSeed(cand.coreHash, n, cand.header.coinbasePub)` — the coinbase
# PUBLIC KEY is an input to the proof-of-work seed — and `:84` seals the winning
# candidate with `HDR.signProof(digestHex, privateKey)`, so the proof is signed
# by the coinbase key. `bin/hearthd.js:64` therefore REFUSES `--miner-address`
# under `--evm` rather than silently ignoring it.
#
# That is how `01-product-vision.md:20`'s "no farms, no pools" is enforced
# structurally rather than asserted: work done for one address cannot be
# redirected to another, because the address is part of what is being hashed. A
# miner that mines to you must hold your key. There is no version of this that
# takes an address alone.
#
# ── THE KEY, AND WHERE IT IS NOT ──────────────────────────────────────────────
#
# `$EMBER_MINER_DATA/coinbase-key.json`, written by `evmnode.js:78` at mode 0600
# on first start. Three properties, each deliberate:
#
#   * It is OUTSIDE EVERY GIT REPOSITORY. Not gitignored — absent. `~/.cloudsforge`
#     is not a work tree, so there is no `.gitignore` line to get edited away and
#     no `git add -A` that can reach it. (`.gitignore` here still carries a line
#     for the local env file this script writes, and `estate-verify.sh` checks
#     it with `git check-ignore -v` rather than trusting it.)
#   * It is OUTSIDE EVERY DOCKER VOLUME. `docker compose down -v`, `docker volume
#     prune`, and a stray `--volumes` on `ember-testnet.sh down` all destroy the
#     chain's data. None of them can reach this directory. The wallet outliving
#     the estate is the entire point: the coin in it is the owner's.
#   * It is mode 0600 and the directory is 0700.
#
# THE KEY IS NEVER PRINTED BY THIS SCRIPT. `address` prints the address, which is
# public. There is no flag here that reveals key material, deliberately — if you
# need it, it is one file you can read yourself.
#
# THIS IS A TESTNET KEY HOLDING TESTNET COIN. It must never be reused on a
# network that matters.
#
# ── HOW IT REACHES THE CHAIN ──────────────────────────────────────────────────
#
# Outside compose means no service DNS, so it dials the seed's PUBLISHED P2P port
# on the loopback: `--peer 127.0.0.1:8646`. Outbound is enough — gossip is
# symmetric once a socket exists — so nothing has to reach back into the host.
# Its own ports are 8551/8651/8652, clear of the three compose nodes.
#
# ── WHAT HAPPENS WHEN THE ESTATE IS TORN DOWN AND THIS IS NOT ─────────────────
#
# It keeps mining, and that is correct: it is a peer of a chain, not a component
# of the estate. What it CANNOT do alone is make progress — with the compose
# seed gone it has no peers, and it will keep mining its own branch, which
# reorgs away when the seed returns with more accumulated work. `status` reports
# the peer count for exactly this reason: a miner with zero peers is mining
# something nobody will accept, and it looks identical to a healthy one.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
HEARTH=${HEARTH_REPO:-$(cd "$HERE/../hearth" 2>/dev/null && pwd)}

# Outside every repository and every docker volume. See the header.
EMBER_HOME=${EMBER_HOME:-$HOME/.cloudsforge/ember-testnet}
DATA=${EMBER_MINER_DATA:-$EMBER_HOME/miner}
LOG=$EMBER_HOME/miner.log
PIDFILE=$EMBER_HOME/miner.pid

REST=${EMBER_MINER_REST:-http://127.0.0.1:8651}
JSONRPC_PORT=${EMBER_MINER_JSONRPC_PORT:-8551}
REST_PORT=${EMBER_MINER_REST_PORT:-8651}
P2P_PORT=${EMBER_MINER_P2P_PORT:-8652}
PEER=${EMBER_MINER_PEER:-127.0.0.1:8646}

# ── THE THREAD COUNT QUESTION, ANSWERED ───────────────────────────────────────
#
# There isn't one. `chain/miner.js:_mineOne` is a single `setTimeout` loop on one
# event loop in one process: hearthd is one thread and cannot be told to be more.
# The knob that exists is `--throttle`, a duty cycle in [0,1] — at t the loop
# sleeps `(1-t)*12`ms between 150-hash batches.
#
# 0.6 is the default here because it is what the two compose miners already run
# (`docker-compose.testnet.yml:68`), so the owner's node competes on equal terms
# rather than being handicapped or privileged.
#
# It is a HOST process, so it spends the Mac's cores and not the container VM's
# six — the estate's headroom and the miner's are two different budgets, which is
# another thing "outside the stack" buys. Raising it to 1.0 would not produce
# blocks faster: LWMA retargets to a 15-second interval whatever the hashrate, so
# the only thing more work buys is a larger SHARE of the same emission, paid for
# out of the machine the estate is running on.
#
# There is no thread count to set, at any value. See above: hearthd is one loop.
THROTTLE=${EMBER_MINER_THROTTLE:-0.6}

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

if [ -z "$HEARTH" ] || [ ! -f "$HEARTH/node/bin/hearthd.js" ]; then
  bad "no hearth checkout beside this repository — set HEARTH_REPO"
  exit 1
fi

running_pid() {
  [ -f "$PIDFILE" ] || return 1
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

info() { curl -s --max-time 5 "$REST/info" 2>/dev/null; }

# One field out of /info without a JSON dependency. python3 is already required
# by estate-verify.sh, so this adds nothing to the machine's floor.
field() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null; }

case "${1:-status}" in
  start)
    if pid=$(running_pid); then
      ok "already running (pid $pid)"
      exit 0
    fi
    mkdir -p "$DATA" || exit 1
    # 0700 before anything is written into it, so the key file is never briefly
    # readable in a world-readable directory.
    chmod 700 "$EMBER_HOME" "$DATA" 2>/dev/null

    # HEARTH_NETWORK is not optional and not cosmetic. Unset, params.js defaults
    # to `hearth` — chain id 7411, a DIFFERENT genesis — and this node would mine
    # a chain of its own beside the testnet, peer with nothing, and look from the
    # outside exactly like a miner that is working.
    HEARTH_NETWORK=hearth-testnet HEARTH_EVM=1 HEARTH_LOG_FORMAT=json \
    nohup node "$HEARTH/node/bin/hearthd.js" --evm \
      --data "$DATA" \
      --rpc "$REST_PORT" --jsonrpc "$JSONRPC_PORT" --p2p "$P2P_PORT" \
      --peer "$PEER" --mine --throttle "$THROTTLE" \
      >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"

    attempt=0
    while [ "$attempt" -lt 30 ]; do
      [ -n "$(info)" ] && break
      attempt=$((attempt + 1))
      sleep 1
    done
    if [ -z "$(info)" ]; then
      bad "the miner did not answer $REST/info within 30s — see $LOG"
      exit 1
    fi
    addr=$(info | field minerAddress)
    ok "mining to $addr (pid $(cat "$PIDFILE"), throttle $THROTTLE)"
    echo "       key   $DATA/coinbase-key.json  (mode 600, outside every repo and every volume)"
    echo "       log   $LOG"
    echo "       This is a TESTNET key holding TESTNET coin. Never reuse it anywhere real."
    ;;

  stop)
    if pid=$(running_pid); then
      # SIGINT, not SIGKILL: hearthd installs a SIGINT handler
      # (`bin/hearthd.js:94`) and the chain is append-only NDJSON, so an
      # interrupted write is a truncated last line rather than a corrupt store.
      kill -INT "$pid" 2>/dev/null
      attempt=0
      while [ "$attempt" -lt 15 ] && kill -0 "$pid" 2>/dev/null; do
        attempt=$((attempt + 1))
        sleep 1
      done
      kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
      rm -f "$PIDFILE"
      ok "stopped (pid $pid). The wallet at $DATA is untouched."
    else
      ok "not running"
    fi
    ;;

  address)
    # Public. Read from the running node when there is one, and from the key file
    # otherwise — the key file's `address` field, never its `privateKey`.
    a=$(info | field minerAddress)
    if [ -z "$a" ] && [ -f "$DATA/coinbase-key.json" ]; then
      a=$(python3 -c "import json;print(json.load(open('$DATA/coinbase-key.json'))['address'])" 2>/dev/null)
    fi
    [ -n "$a" ] && printf '%s\n' "$a" || { bad "no miner and no key file at $DATA"; exit 1; }
    ;;

  status)
    # ── "UP" IS NOT "MINING", AND THE DIFFERENCE IS THE WHOLE CHECK ────────────
    #
    # This estate keeps finding the same shape: a studio that reported healthy
    # while every generation failed, a reconciliation that reported clean while
    # comparing the ledger against itself. A miner is the same trap — the process
    # is alive, /info answers, and it has produced nothing for an hour.
    #
    # So four facts, and a process that is alive is only the first:
    #   1. the process exists
    #   2. `mining: true` — the loop is armed, not just the server
    #   3. `hashrate > 0` — it is actually evaluating Homefire
    #   4. HEIGHT ADVANCED between two samples — the only one that proves the
    #      work is landing on a chain other nodes will accept. A node hashing
    #      hard on an orphaned branch satisfies 1-3 and is worth nothing.
    #   plus `peers`, because at zero it can only be on its own branch.
    if pid=$(running_pid); then ok "process alive (pid $pid)"; else bad "no miner process (pidfile $PIDFILE)"; exit 1; fi
    j=$(info)
    [ -n "$j" ] || { bad "the process is alive but $REST/info does not answer"; exit 1; }

    mining=$(printf '%s' "$j" | field mining)
    rate=$(printf '%s' "$j" | field hashrate)
    peers=$(printf '%s' "$j" | field peers)
    addr=$(printf '%s' "$j" | field minerAddress)
    h1=$(printf '%s' "$j" | field height)

    [ "$mining" = "True" ] && ok "mining: the loop is armed" || bad "mining is $mining — the node is up and producing nothing"
    [ "${rate:-0}" -gt 0 ] 2>/dev/null && ok "hashrate ${rate} H/s — Homefire is actually being evaluated" \
      || bad "hashrate is ${rate:-unknown}; the process is alive and not hashing"
    [ "${peers:-0}" -gt 0 ] 2>/dev/null && ok "peers ${peers} — it can hear the rest of the network" \
      || bad "0 peers: whatever it mines, nobody will ever see. Is the testnet up?"

    # The one that cannot be faked by a busy loop. 20s is comfortably over the
    # 15s target block time; a slower sample would be quieter and less useful.
    printf '  ..   sampling height for 20s (target block time is 15s)\n'
    sleep 20
    h2=$(info | field height)
    if [ -n "$h1" ] && [ -n "$h2" ] && [ "$h2" -gt "$h1" ] 2>/dev/null; then
      ok "height advanced $h1 → $h2 — the chain this node is on is making progress"
    else
      bad "height did not advance in 20s ($h1 → $h2). Every check above can pass while this fails."
    fi

    # Informational, and last, because it is the one number a person actually
    # wants: what the owner holds. Read at `latest`, so it includes rewards not
    # yet 60 deep — this is a wallet balance, not the custody observation the
    # ledger reconciles against, and those are different questions.
    if [ -n "$addr" ]; then
      bal=$(curl -s --max-time 5 -X POST -H 'content-type: application/json' \
        --data-binary "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"]}" \
        "http://127.0.0.1:$JSONRPC_PORT/" | sed -n 's/.*"result":"\(0x[0-9a-f]*\)".*/\1/p')
      [ -n "$bal" ] && printf '  ..   %s holds %s EMBER (at the tip, not at 60 confirmations)\n' \
        "$addr" "$(python3 -c "print(f'{int('$bal',16)/1e18:.6f}')" 2>/dev/null)"
    fi
    ;;

  *)
    echo "usage: $(basename "$0") {start|stop|status|address}" >&2
    exit 2
    ;;
esac
