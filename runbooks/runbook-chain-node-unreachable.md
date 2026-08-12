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

**On a different machine from the estate**, and they are host processes rather
than containers. `docker ps` will not list them and `docker compose restart`
cannot touch them.

Since the 2026-08-10 split they live on the chain host, `malf@192.168.1.42`, and
the app stack reaches them over WireGuard — `10.10.0.1` from `10.10.0.2`. So the
first move on this alert is `ssh malf@192.168.1.42`, and a caller that cannot
reach a node might be telling you about the tunnel rather than the node.

| Chain | RPC port | datadir | unit |
| --- | --- | --- | --- |
| LTC | 50002 | `/data/chains/litecoin` | `litecoind.service` |
| BTC | 50001 | `/data/chains/bitcoin` | `bitcoind.service` |
| DOGE | 9332 | `/data/chains/dogecoin` | `dogecoind.service` |

`ps -eo pid,etimes,comm | grep coind` gives you the pid and how long it has been
up; a short `etimes` means somebody already restarted it and you are looking at
the aftermath.

### Which of the two ways it was started matters

Since 2026-08-12 all three have systemd units (`deploy/systemd/`, micro-org#338
§5.4) — but **enabled is not started**. Ask before you act:

```sh
systemctl is-active bitcoind    # active  -> systemd owns it, use systemctl
                                # inactive -> it is a hand-started process
```

`dogecoind` runs under systemd today. `bitcoind` and `litecoind` were still the
hand-started processes at the time of writing and take systemd over at the next
reboot or the next announced restart. **Do not `systemctl start` one that says
`inactive` while its daemon is running** — that starts a second one, it dies on
the datadir lock saying "Bitcoin Core is probably already running", the unit goes
red and the chain is fine. Measured, not guessed; `deploy/systemd/README.md` has
the journal.

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

2. **Does HTTP answer, from where the callers are?** Not from the chain host —
   the pool, indexer and settlement are containers on the APP host and reach
   these nodes across the WireGuard link, which `rpcbind=10.10.0.1` and
   `rpcallowip=10.10.0.2/32` are what make legal. Loopback on the chain host
   answers a question nobody is asking, and `10.10.0.1` asked from the chain
   host itself answers **403**, correctly, because the source is not
   `10.10.0.2`. Ask from inside a caller so you are asking the same question it
   is — on the app host, not this one:

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

If `systemctl is-active <chain>d` said **active**, it is one command and systemd
does the waiting for you:

```sh
sudo systemctl restart litecoind
```

If it said **inactive**, the node is hand-started and this is the moment to hand
it to systemd rather than start another loose process — you are restarting it
anyway:

```sh
/data/docs/litecoin-0.21.5.6/bin/litecoin-cli -datadir=/data/chains/litecoin stop
while pgrep -x litecoind >/dev/null; do sleep 2; done
sudo systemctl start litecoind
```

`pgrep -x`, on the process name. `pgrep -f "…/data/chains/litecoin…"` matches the
shell running the loop against its own command line, so it waits forever and
looks exactly like a node refusing to shut down — which is the one thing that
must not be answered with `kill -9`.

**Do not skip the wait.** litecoind releases the datadir lock *after* its pid
leaves `ps`, so a start typed straight after a stop loses the race and the node
stays down. This is why the units are `Type=simple`: `systemctl` cannot lose it.
Measured on dogecoind 2026-08-12 — `systemctl restart` took 77 seconds to
return, all of it waiting for the shutdown to finish.

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
the honest ceiling is the machine's cores minus what else runs on it. That
number changed on 2026-08-10: micro-org#31's second machine exists, the estate's
containers left, and this host now runs three chain daemons, the two EMBER
miners and the two hearth seed nodes and nothing else. So there is more headroom
here than the 8/64 decision assumed — which is a reason to re-measure before
raising, not a reason to raise.

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
- **Not a chain-host reboot.** That looks different and worse: all three nodes
  gone at once, every UTXO surface down together, and `ChainNodeTemplateStale`
  fires beside `AssetWithdrawalsFrozen` and the indexer's lag rather than alone.
  Since 2026-08-12 the units bring all three back on their own — check
  `systemctl status bitcoind litecoind dogecoind` and `journalctl -u <unit> -b`
  before touching anything, because a node loading a 700 GB block index is not a
  node that failed to start. `deploy/systemd/README.md` is that story.

## After

If the node wedged with 8/64 in place, that is a capacity finding and belongs in
the post-incident review with the concurrent-caller count that produced it. The
number of services reading the same node has grown every release, and "raise it
again" is a decision that should be made once with the numbers rather than four
times under a page.
