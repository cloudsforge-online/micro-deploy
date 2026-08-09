# A chain node has stopped answering

**Triggered by** `ChainNodeTemplateStale - pool_template_age_seconds > 120 for 5m`
**Severity** SEV2 - page · **Owner** pool

## What it means

The pool asks its node for a block template every ten seconds
(`POOL_TEMPLATE_POLL_MS`). This age is how long ago the last answer arrived, and
120 seconds is the pool's own `TEMPLATE_STALE_AFTER_MS` — the point where its
`/readyz` stops claiming the chain works. Past it, every miner pointed at the
estate is hashing on work that can no longer win.

It is a page and not a ticket for two reasons that have nothing to do with the
pool: the same node backs the indexer, so deposits stop being credited, and the
ledger freezes the asset behind it within two reconciliation sweeps
(`AssetWithdrawalsFrozen`). By the time the money alert fires the cause is forty
minutes old.

## The node is almost certainly UP

This is the part that costs the most time if it is not said first. On 2026-08-09
litecoind was running, fully synced, and answering `litecoin-cli` **instantly**,
while every HTTP JSON-RPC caller got:

```
work queue depth exceeded
```

with idle RPC workers and no connections in `getpeerinfo` to explain it. A node
that answers its own CLI is not a node that is down, and `ps`, `uptime` and
`getblockchaininfo` from the CLI will all tell you everything is fine. They are
answering a different question.

So do not begin by restarting the pool, and do not begin by re-syncing anything.

## Where the nodes are

They are **host processes on the estate machine, not containers**. `docker ps`
will not list them and `docker compose restart` cannot touch them.

| Chain | RPC port | datadir |
| --- | --- | --- |
| LTC | 50002 | `/data/chains/litecoin` |
| BTC | 50001 | `/data/chains/bitcoin` |
| DOGE | 9332 | `/data/chains/dogecoin` |

Each is started as `<bindir>/<chain>d -datadir=/data/chains/<chain> -daemon`,
where the binaries live under `/data/docs/`. `ps -eo pid,etimes,comm | grep coind`
gives you the pid and how long it has been up; a short `etimes` means somebody
already restarted it and you are looking at the aftermath.

## Confirm which half is broken

Two questions, in this order.

1. **Does the CLI answer?**

   ```sh
   /data/docs/litecoin-0.21.5.6/bin/litecoin-cli -datadir=/data/chains/litecoin \
     getblockchaininfo | head
   ```

   If this hangs or refuses, the node really is down — that is a different
   incident, and `runbook-hearth-node-down.md`'s shape applies: check disk,
   check `debug.log`, restart, expect a reindex if it was killed mid-write.

2. **Does HTTP answer, from where the callers are?** The pool, indexer and
   settlement reach the node over the docker bridge, not over loopback, and the
   `rpcallowip` ranges below are what makes that legal. Ask from inside a
   container so you are asking the same question they are:

   ```sh
   docker exec cloudsforge-estate-pool-1 sh -lc \
     'curl -s -m 5 -o /dev/null -w "%{http_code}\n" "$POOL_LTC_NODE_URL" \
        -X POST -H "content-type: application/json" \
        -d "{\"jsonrpc\":\"1.0\",\"method\":\"getblockchaininfo\",\"params\":[]}"'
   ```

   Never echo the URL itself; it carries the RPC password.

**CLI answers and HTTP does not is the wedge.** That is this runbook's case.

## Fixing the wedge

Restart the node. Nothing else clears it — the work queue does not drain, and
waiting is how a thirty-minute outage becomes a three-hour one.

```sh
/data/docs/litecoin-0.21.5.6/bin/litecoin-cli -datadir=/data/chains/litecoin stop
# wait for the pid to leave `ps`, then start it exactly as it was started:
/data/docs/litecoin-0.21.5.6/bin/litecoind -datadir=/data/chains/litecoin -daemon
```

Stop it with `stop`, never with `kill -9`: a node killed mid-write comes back
wanting a reindex, and on a txindex=1 chain that is hours during which the alert
you are clearing stays fired.

The pool recovers on its own within one poll and the indexer within one follower
loop. Neither needs restarting, and restarting them mid-recovery is how a
recovered incident acquires a second cause.

## Why it wedges, and what is already done about it

The estate's read pattern is many small concurrent JSON-RPC calls — the indexer
walking a block's addresses, the pool polling, settlement quoting fees. Stock
Core defaults are `rpcthreads=4` and `rpcworkqueue=16`, which the estate exceeds
routinely rather than exceptionally, and an overflowed queue does not shed load:
it stays overflowed.

**All three nodes now run `rpcthreads=8` and `rpcworkqueue=64`** — set in
`/data/chains/<chain>/<chain>.conf`, verified present on litecoin, bitcoin and
dogecoin on 2026-08-10. If you are reading this because the alert fired anyway,
check those two lines are still there before raising them further; a conf edit
that was never restarted into is a common way for a fix to be present and
inactive.

Raising them is not free. Each worker is a thread against the same datadir, and
the honest ceiling is the machine's cores minus what the estate's containers
need. If 8/64 is genuinely insufficient the answer is the second machine
(micro-org#31), not a larger number here.

## What this alert is not

- **Not `IndexerChainHalted`.** That is a deliberate stop after a reorg past the
  policy depth, cleared only by an operator — see `runbook-reorg-recovery.md`. A
  wedged node leaves it at 0.
- **Not `indexer_provider_failures_total`.** Measured on 2026-08-10, that
  counter's routine 5-minute p99 is 56 with a max of 76, and the 2026-08-09
  outage produced about 78. It cannot separate the two, which is why no alert is
  written on it. Do not use it to decide whether this is real.
- **Not a pool bug**, until question 1 above says the CLI answers and question 2
  says HTTP answers too.

## After

If the node wedged with 8/64 in place, that is a capacity finding and belongs in
the post-incident review with the concurrent-caller count that produced it. The
number of services reading the same node has grown every release, and "raise it
again" is a decision that should be made once with the numbers rather than four
times under a page.
