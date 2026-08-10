# EMBER is at its difficulty floor and still below target block rate

**Triggered by** `EmberDifficultyAtFloor`
**Severity** SEV4 - ticket · **Owner** chain

## What it means

Two facts at once, and it is the conjunction that matters:

1. `indexer_chain_difficulty{chain="ember"} <= 256` — difficulty is at the
   lowest value the chain's parameters permit.
2. The chain produced **fewer than 240 blocks in the last hour**, which is
   3600 / `TARGET_BLOCK_TIME`, and `TARGET_BLOCK_TIME` is 15 in
   `hearth/node/src/params.js`.

The retarget is **saturated**. It cannot make the chain any easier than it
already is, so it has no remaining influence on the block rate. EMBER is slow
because there is not enough hashrate, and no adjustment parameter can create
hashrate.

**Being at the floor is not, by itself, a problem.** A chain at the floor with
plenty of hashrate simply mines quickly, which is fine. That is why this alert
has the second clause, and it is why it should clear itself if hashrate is
added — see **Has it worked?** below.

## Nothing is broken

This is a capacity decision, not an incident. There is no process to restart, no
corruption to repair and no data at risk. If you have been paged for this,
something is misrouted — check `severity`/`team` on the alert.

## The measurement

Mainnet, blocks 8249-11249, 2026-08-09 12:22:01Z to 2026-08-10 20:59:49Z:

| | |
|---|---|
| blocks at difficulty exactly 256 | **2,830 of 3,001** (94%) |
| longest unbroken run at the floor | 2,686 blocks over **28.99 h** |
| block rate over that window | median **94/h**, mean 92.7/h, max 216/h |
| target | 240/h |
| solve times at the floor | median 24 s, mean 38.5 s, p95 113 s |

The chain has been running at roughly **39% of its target rate for over a day**,
with the retarget pinned against its stop the entire time.

## The arithmetic

At difficulty 256 a 15-second block needs about **17 H/s** sustained. As of
2026-08-10 the estate runs two miners:

| miner | host | throttle | approx. |
|---|---|---|---|
| `cf-miner-mainnet` | chain host, 192.168.1.42 | | ~7-8 H/s |
| `cf-miner-mainnet-apphost` | app host, 192.168.1.129 | 0.10 | ~12 H/s |

That is about 19-20 H/s, which is *just* above the requirement — which is why
the second miner (micro-deploy#53, 2026-08-10) is expected to clear this alert
rather than merely improve it. Confirm both are alive before doing anything
else:

```sh
docker logs --tail 20 cf-miner-mainnet          # on 192.168.1.42
docker logs --tail 20 cf-miner-mainnet-apphost  # on 192.168.1.129
```

Each prints a status line every 60 s carrying its hashrate. A miner that has
died, or whose `--throttle` has been reduced, is the first thing to check and
the cheapest thing to fix.

## Has it worked?

The honest state of this threshold, recorded so that nobody mistakes it for a
validated one: across all 336 five-minute samples of the rolling-hour block
count that mainnet Prometheus held on 2026-08-10, the rate was **never** at or
above 240 — max 216. The second clause has therefore never been observed false.
It is a guard against a state this estate has not reached.

So there are two ways to read this alert firing *after* 2026-08-10:

* **It fires while difficulty is still descending from an excursion** — ignore
  it; you are in `runbook-ember-tip-not-advancing.md` territory and the chain is
  recovering. Note that during the descent difficulty is *above* 256, so
  strictly this alert should not be firing at all; if it is, the excursion has
  already ended.
* **It fires with both miners healthy and the chain settled at the floor** — the
  hashrate arithmetic above is wrong, the deficit is larger than estimated, and
  that is a genuinely useful finding. Record the measured block rate on
  `cloudsforge-online/micro-org#363`.

## The two levers

### 1. More hashrate

The only lever that is entirely within this estate's control and does not touch
consensus. Raise `--throttle` on an existing miner, or add another
`docker-compose.miners-apphost.yml`-shaped service on a host that has spare CPU.

Cost: CPU on a host that is also serving the application. `--throttle 0.10` on
the app host was chosen to leave the app stack alone; raising it trades
application headroom for block rate, so measure the host before and after.

**Do not** solve this with browser hashrate from the mining bar. It is not
durable, and hashrate that arrives and leaves is what produces the wedges in
`runbook-ember-tip-not-advancing.md`: difficulty climbs to match it and the
permanent miners are left grinding it back down.

### 2. Change the retarget — NOT an on-call action

`cloudsforge-online/micro-org#363` records three parameter changes that would
make EMBER recover from excursions faster: a shorter LWMA window (currently 60),
a tighter solve-time clamp (currently `TARGET_BLOCK_TIME * 6` = 90 s), and a
lower floor. All three are **consensus changes**, they are the chain owner's
decision, and they are deliberately out of scope for both this runbook and the
alert that points at it.

Be clear about what they would and would not do. A lower floor would let
difficulty fall further and so would raise the block rate at today's hashrate —
it addresses this alert directly. A shorter window and a tighter clamp only
speed up *recovery from an excursion*; they do nothing about a standing hashrate
deficit, and they would not silence this rule.

## Verifying the metric exists

`indexer_chain_difficulty` is published by micro-indexer from the tip stream
only, and only for chains that actually have a proof-of-work difficulty — EVM
and the Bitcoin family. There is deliberately no series for Solana. If this
alert is inactive and you want to know whether that means "healthy" or "the
metric is missing" — the distinction micro-org#310 exists for:

```sh
curl -s 'http://127.0.0.1:9090/api/v1/label/__name__/values' \
  | grep indexer_chain_difficulty
```

No match means nothing is publishing it and this alert cannot fire. A match with
no `chain="ember"` series means the indexer is not following EMBER's tip.

Note one more silent case: the second clause uses `offset 1h`, so for the first
hour after a Prometheus restart the right-hand side has no samples, the whole
expression is empty, and this rule is quiet regardless of the chain's state.

## Related

* `runbook-ember-tip-not-advancing.md` — the acute version of the same problem
* `runbook-hearth-node-down.md` — if a miner cannot reach the node at all
