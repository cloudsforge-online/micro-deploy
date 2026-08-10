# The EMBER tip has stopped advancing

**Triggered by** `EmberTipNotAdvancing`
**Severity** SEV3 - ticket · **Owner** chain

## What it means

No new EMBER block has been indexed for **at least fifteen minutes**, against a
15 s target block time. The rule is `changes(indexer_tip_height{chain="ember"}
[10m]) == 0` held for a further 5 m, so the shortest thing that can trigger it
is a 15-minute gap.

This is a ticket and not a page on purpose. Every stall this estate has measured
resolved without anybody doing anything — see **How long this normally lasts**
below. The reason to read this page is to establish *which* stall you have,
because one of the three causes does not self-heal.

## First: is the CHAIN stuck, or is the INDEXER stuck?

`indexer_tip_height` is the indexer's view of the tip. It freezes when the chain
stops producing blocks and it freezes when the indexer stops reading them, and
the alert expression cannot tell those apart. Do not skip this step; the three
causes below have nothing in common except this symptom.

Ask the node for its own height, without going through the indexer:

```sh
curl -s https://rpc.cloudsforge.online \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
```

Run it twice, a minute apart. Then compare with what Prometheus has:

```
indexer_tip_height{chain="ember"}
```

* **Node height climbing, indexer height frozen** — the chain is fine and the
  indexer is not. This is an indexer incident: check `indexer_chain_halted`
  (`IndexerChainHalted` covers a deliberate reorg-policy stop) and
  `indexer_lag_blocks`, and go to `runbook-indexer-lag.md`.
* **Node height frozen too** — the chain really has stopped. Continue below.
* **No answer at all from the node** — go to `runbook-hearth-node-down.md`.
  Note that a node with zero peers answers this call perfectly while mining a
  chain nobody accepts, so check peers rather than liveness.

If the alert is **not** firing and you got here because a dashboard looks flat,
check `TelemetryComponentDown` first. If the indexer stops being scraped, the
series goes absent, `changes()` returns nothing, and this rule goes *silent* —
it cannot fire on a missing indexer, only on a frozen one.

## The chain is stopped. Why?

### 1. Difficulty left high by hashrate that has gone away (the common one)

EMBER's LWMA retarget looks back 60 blocks. When a large, temporary source of
hashrate — a browser tab on the mining bar, someone's laptop — joins for a few
minutes and then leaves, difficulty has already climbed to match it and the
remaining miners have to grind it back down one block at a time.

```
indexer_chain_difficulty{chain="ember"}
```

Compare with **256**, which is the floor (`MAX_TARGET`, pinned to
`GENESIS_TARGET`, in `hearth/node/src/params.js`). If difficulty is well above
256 and *falling*, this is what you have, and it is fixing itself.

Measured on mainnet 2026-08-10: hashrate arriving at 19:07:39Z drove difficulty
from 262 to a peak of **8417 — 33x the floor — in thirteen minutes**, and it
then took **1 h 39 m to fall back to 4075** and was still descending. The
descent runs at roughly 11% per block (measured per-block ratios 0.805, 0.843,
0.866, 0.884, 0.897), and each of those blocks takes proportionally longer than
the last one did. A smaller excursion the same afternoon — peak 2102, 8x the
floor — cleared completely in **30 minutes**.

**Do not restart the node to make this go away.** A restart does not change
difficulty; it only costs you the peer set and whatever was in flight.

### 2. Not enough hashrate at all

If difficulty is at or near 256 and the tip is still stuck, the retarget has
already given everything it has. Check the miners are alive:

```sh
# chain host (192.168.1.42)
docker logs --tail 20 cf-miner-mainnet
# app host (192.168.1.129)
docker logs --tail 20 cf-miner-mainnet-apphost
```

Both print a status line every 60 s. If one is dead or its `--throttle` has been
lowered, that is your cause. This is the standing condition
`EmberDifficultyAtFloor` describes; see `runbook-ember-difficulty-at-floor.md`.

### 3. The node is up, has peers, and is not building

Rare, and the only one that does not self-heal. Check the node is actually
serving templates and that the miner is getting them — the app-host miner talks
to `rpc.cloudsforge.online`, which goes out through Cloudflare and back through
the tunnel to the chain host's gateway, so it can fail while a loopback call
from the chain host succeeds. Test the public path specifically, from the app
host, before concluding the node is fine.

## How long this normally lasts

Every number here is from mainnet, blocks 8249-11249, 2026-08-09 12:22:01Z to
2026-08-10 20:59:49Z (32.6 h, 3,000 solve times):

| | |
|---|---|
| median solve time | 24 s |
| mean | 39.2 s |
| p95 | 113 s |
| p99 | 197 s |
| longest routine gap | 771 s |
| the three real stalls | 1,210 s · 1,407 s · 3,147 s |

**39 seconds mean against a 15 s target is not a bug in this alert.** At the
difficulty floor, EMBER's honest steady state is slower than its target, because
total hashrate is about 19-20 H/s and a 15 s block at difficulty 256 needs about
17 H/s. That is the standing condition, and it has its own ticket.

So: **under 15 minutes is normal and this alert will not fire. Fifteen minutes
to an hour is an excursion, and waiting is the correct action.** Past an hour
you are outside everything this estate has measured — that has never happened,
and it is worth an issue on `cloudsforge-online/micro-org` describing what you
saw, because it is the observation that would justify a paging escalation. There
is deliberately no page today for exactly the reason that its threshold would
have to be invented.

## What NOT to do

* **Do not restart `cf-hearth-seed`** to clear a high-difficulty stall. The
  difficulty is in the chain, not in the process.
* **Do not lower the difficulty by hand.** There is no supported way to, and the
  parameter changes that would make the retarget recover faster are consensus
  changes tracked in `cloudsforge-online/micro-org#363` — the chain owner's
  call, not an on-call action.
* **Do not add a browser tab of hashrate to "help".** It is what caused the
  stall: it raises difficulty while it is there and leaves the chain wedged when
  it goes. Add hashrate as a *permanent* miner or not at all.

## Related

* `runbook-ember-difficulty-at-floor.md` — the standing condition behind the
  slow steady state
* `runbook-indexer-lag.md` — when the node is fine and the indexer is not
* `runbook-hearth-node-down.md` — when the node does not answer
* `runbook-reorg-recovery.md` — when `indexer_chain_halted` is set
