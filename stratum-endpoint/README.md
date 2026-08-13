# stratum-endpoint

Owns one fact: **the address hardware miners should dial.**

micro-org#457. Runs beside the estate, observes the public WAN address, and republishes it only
when it changes *and* is provably usable.

## The asymmetry it is built around

A **null** endpoint makes `pool-web` say "contact the administrator". A **wrong** endpoint makes a
miner point firmware at a socket that refuses, retry hard, and blame the pool.

The second is worse. So every path here fails towards *"I do not know"*: an observation that cannot
be trusted leaves the live value alone and raises a metric. It never publishes a guess, and it
never *clears* a working value because a resolver had a bad minute.

## What it refuses, and why each one matters

| Observation | Outcome |
|---|---|
| Resolvers disagree | refuse — this is a signal, not something to retry through |
| Fewer than 2 resolvers answered | refuse — one resolver is a single point of *wrongness*, not just failure |
| RFC1918 / loopback / link-local | refuse — the resolver answered with something local |
| **CGNAT `100.64/10`** | refuse — **the carrier NATs this line, so no port-forward on your own router can make it reachable** |
| Unchanged | no-op — the pool is not recreated for nothing |

CGNAT is called out separately because it *looks* public and is the most likely wrong answer on a
residential line. The refusal message says so, to stop an operator going to check their router.

## What it touches

Writes one generated file, `compose/generated/stratum.env`:

```
CF_STRATUM_PUBLIC_HOST=<address>
```

…then recreates **one** service: `docker compose up -d --no-deps pool`.

It is deliberately **not** a deployer:

- not `release-deploy.sh` — a WAN address changing must not roll the whole estate;
- not a bare `docker compose up` — that drops `mainnet.env` and degrades public hostnames to
  `localtest.me`;
- one service, no dependency cascade.

It never writes a secret. A WAN address is public by definition, which is why the file is in
`compose/generated/` rather than `compose/secrets/`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `STRATUM_IP_RESOLVERS` | ipify, ifconfig.me, icanhazip | comma-separated; a quorum of 2 must agree |
| `STRATUM_ENV_FILE` | `/estate/compose/generated/stratum.env` | the generated file |
| `STRATUM_COMPOSE_FILE` | `/estate/compose/docker-compose.estate.yml` | |
| `STRATUM_COMPOSE_PROJECT` | `cloudsforge-estate` | |
| `STRATUM_INTERVAL_MS` | `300000` | observation interval |
| `STRATUM_APPLY` | `true` | `false` observes and writes but never recreates — use it first |

## Metrics

`stratum_public_host_changes_total`, `stratum_public_host_refusals_total`,
`stratum_resolver_disagreement_total`, `stratum_apply_failures_total`,
`stratum_public_host_last_change_timestamp_seconds`, `stratum_public_host_known`.

`stratum_apply_failures_total` is the one that matters most: the file is written and the container
is not yet reading it, so the API still advertises the OLD address. That is the safe direction, and
it is not the intended state.

## Before it can help

**Knowing the WAN address does not prove the NAT rule exists.** Sequence:

1. Owner adds the NAT rule (router → app host, TCP 3333/3334).
2. Prove it from outside: `nc -vz <wan-address> 3334`.
3. Only then let this service own the value, and set the per-chain
   `POOL_<CHAIN>_STRATUM_PUBLIC_PORT`.

Publishing an endpoint before step 2 converts an honest "contact the admin" into a support burden.

## Related

- **micro-org#302** — payouts. A reachable endpoint without payouts means miners accrue an
  entitlement the estate cannot honour. That one holds other people's money and matters more.
- **micro-org#285** — the endpoint used to be guessed from `window.location`; it is explicit config
  now, which is why it is `null` rather than wrong.
