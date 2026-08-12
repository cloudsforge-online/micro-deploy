# EMBER difficulty has been far above the floor for six hours

**Triggered by** `EmberDifficultySustainedFarAboveFloor` — `indexer_chain_difficulty{chain="ember"} / 256 > 100` for 6h.

**Severity** SEV4 - ticket · **Owner** chain

## What it means, and what it does not

One miner much larger than the browsers has been setting the difficulty for six
hours. **The chain is healthy.** Since hearth#13 (active from height 20,000) a
block more than 120 s late may be mined at the floor, so the worst block is
about two minutes however high difficulty goes — the wedge this condition used
to cause cannot recur. Do not restart anything; there is nothing to restart.

What has stopped working is **browser participation**. At 100x the floor a
visitor's tab wins a block rarely enough that mining reads as broken to them,
and every hour this stands is an hour the estate's one distinctive first action
(doc 36 §5.2) is dark. That is a product condition, not an operational one,
which is why this is a ticket that points at a plan rather than at a lever.

## First: is it ours?

The signature of the operator's own mining tab is exactly this alert's
signature, minus the duration. Check who is winning blocks before treating it
as external:

```sh
# per-coinbase share of the last 16 blocks, from the chain host's seed node
ssh malf@192.168.1.42 'docker exec cf-hearth-seed node -e "
const call=(m,p)=>fetch(\"http://127.0.0.1:8545\",{method:\"POST\",headers:{\"content-type\":\"application/json\"},body:JSON.stringify({jsonrpc:\"2.0\",id:1,method:m,params:p})}).then(r=>r.json());
(async()=>{const t=parseInt((await call(\"eth_blockNumber\",[])).result,16);const m={};
for(let n=t;n>t-16;n--){const b=(await call(\"eth_getBlockByNumber\",[\"0x\"+n.toString(16),false])).result;if(b)m[b.miner]=(m[b.miner]||0)+1}
console.log(t,m)})()"'
```

The estate's own coinbases are `0x980d52…5b45` (chain host) and
`0x2098b519…dcca8` (app host). A third address holding most of the window is
the condition this alert is about. If it is the operator's own tab, close it or
leave it — the harmful pattern is the on/off cycle, not the mining — and the
alert clears six hours after the difficulty does.

## If it is sustained and external

This is the trigger micro-org#451's plan was written for. The decision due is
recorded there in full; in one line each:

- **Phase 2 — pool aggregation.** Browsers mine through micro-pool and share
  proportionally, so small miners keep earning under a whale. Blocked on the
  §7.4 decision (doc 36), which is the owner's.
- **Phase 3 — hardware-resistant PoW.** The only durable answer if the outside
  miner is GPU-class. A redesign of Homefire (epoch-cached dataset), a hard
  fork with an activation height, weeks of work — `params.js` at
  `POW_SCRATCH_KIB` records why no retune of the existing constants can buy
  this.

What is deliberately **not** on that list: raising the server miners'
throttle to compete. One core per process (hearth#20) cannot close a 100x gap,
and chasing an outside miner raises difficulty further for every browser — the
same trade `docker-compose.miners-apphost.yml` documents.

## Clearing it

It clears itself six hours after difficulty falls back under 100x, which
happens on its own once the large miner leaves (the emergency rule plus the
LWMA absorb the drop within a couple of dozen blocks). Closing the ticket
without either a Phase 2/3 decision or an "it was our own tab" note defers the
same ticket to the next time, which is fine exactly once.
