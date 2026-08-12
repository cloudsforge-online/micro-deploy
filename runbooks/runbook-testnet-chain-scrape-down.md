# The testnet indexer is not being scraped

**Triggered by** `TestnetChainScrapeDown`
**Severity** SEV4 - ticket · **Owner** chain

## What it means

`up{job="cf-indexer-testnet"} == 0` for ten minutes. Prometheus cannot reach
`cf-testnet-indexer-1:4000`.

Nothing about the testnet estate is broken by this on its own. What is broken is
the **monitoring of the testnet EMBER chain**: `EmberTipNotAdvancing` and
`EmberDifficultyAtFloor` are written for both networks and read
`indexer_tip_height{chain="ember"}` and `indexer_chain_difficulty{chain="ember"}`
with no network selector. While this target is down there are no testnet series,
`changes()` over an empty vector returns nothing, and both rules go **silent** —
which is indistinguishable from a healthy testnet chain.

That is the whole reason this alert exists. Until 2026-08-12 the testnet series
had never existed at all (micro-org#398), and the two chain rules had been
quietly mainnet-only for their entire life while their own summary text said
`{{ $labels.network }}`. A monitoring gap that closes itself back up unobserved
is the same defect twice.

## First: is it the scrape, or the service?

```sh
# on the app host, inside WSL
docker ps --filter name=cf-testnet-indexer --format '{{.Names}}\t{{.Status}}'
docker exec cf-testnet-indexer-1 node -e "fetch('http://127.0.0.1:4000/metrics').then(r=>r.text()).then(t=>console.log(t.split('\n').filter(l=>/^indexer_tip_height/.test(l)).join('\n')))"
```

* **Container missing or unhealthy** — this is a testnet estate incident, not a
  monitoring one. Bring testnet up; this alert clears on its own.
* **Container healthy and serving `indexer_tip_height{...,network="testnet"}`** —
  the service is fine and Prometheus cannot reach it. Continue below.

## The usual cause: Prometheus lost the testnet network

Prometheus runs in the `cfmicro` project and the testnet estate runs in
`cf-testnet`. They are different compose projects on different networks, and the
only reason a scrape works at all is that `compose/docker-compose.telemetry.yml`
attaches Prometheus to `cf-testnet_default` as an external network. A Prometheus
container recreated by something that does not read that file — a hand-typed
`docker run`, an older checkout, a `docker compose up` with a different `-f`
list — comes back without the attachment.

```sh
docker inspect cfmicro-prometheus-1 \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

Expect `cf-micro-app`, `cloudsforge-estate_default` **and** `cf-testnet_default`.
If the last is absent:

```sh
cd /home/savvaniss/dev/cloudsforge/deploy
export DOCKER_CONFIG=/home/savvaniss/.docker-nocreds
./up.sh                      # or: make up
```

That is the fix, and it is idempotent — `up.sh` recreates Prometheus with every
network the telemetry file declares.

Bring the telemetry plane up **with `up.sh`, not with a bare `docker compose`**.

```sh
# this fails, on the app host, every time:
docker compose -p cfmicro -f compose/docker-compose.telemetry.yml up -d prometheus
#   required variable CF_GRAFANA_ADMIN_PASSWORD is missing a value
```

The reason is worth knowing, because the error names a variable and the variable
is not the problem. Compose takes its project directory from the first `-f`, so
it looks for `.env` in **`compose/`** — and `compose/.env` is a symlink to
`estate/tokens.env`. A bare invocation does not merely miss `deploy/.env`; it
silently loads the estate's tokens file instead, which has never carried a
Grafana password. `up.sh` sources `deploy/.env` into the environment before it
calls compose, so interpolation resolves. `--env-file .env` also works and is
the right escape hatch if you must run compose by hand. Measured 2026-08-12.

Do **not** attach the network by hand with `docker network connect` — it works,
it clears the alert, and it is lost on the next recreate, which is exactly the
failure mode you are standing in.

## The other cause: the container name changed

The target is a **container name**, `cf-testnet-indexer-1`, not a service name,
because both estates define a service called `indexer` and a container on two
networks cannot disambiguate the two. So renaming the testnet compose project
breaks this target, silently, and nothing else in the estate would notice.

```sh
docker ps --format '{{.Names}}' | grep indexer
```

If the testnet indexer is no longer `cf-testnet-indexer-1`, the target in
`prometheus/prometheus.yml` is stale — change it there and reload, rather than
patching the running container:

```sh
docker exec cfmicro-prometheus-1 wget -q --post-data= -O- http://127.0.0.1:9090/-/reload
```

`CF_PROJECT` for testnet is `cf-testnet` and is set in `compose/testnet.env`; it
was renamed once already (micro-org#257, `cftestnet` → `cf-testnet`), which is
precisely why this paragraph is here.

## Confirming the fix

```
up{job="cf-indexer-testnet"}
```

should be `1`, and within a scrape interval:

```
indexer_tip_height{chain="ember",network="testnet"}
```

should exist and climb. `/api/v1/label/network/values` should answer
`["mainnet","testnet"]` — if it still answers `["mainnet"]`, the scrape is up and
the metric relabelling is dropping everything, which means the keep-list in
`prometheus.yml` no longer matches the metric names the indexer emits.

## What this alert deliberately does not cover

Only `indexer_tip_height` and `indexer_chain_difficulty` are kept from that
target. `indexer_lag_blocks` and `indexer_chain_halted` are dropped on purpose —
both carry `severity: page`, and nobody is on call for testnet. The RED metrics
are dropped because `slo.yaml` aggregates `sum by (service)` with no job
selector, so keeping them would fold testnet traffic into the **mainnet**
indexer's error budget. Widening the keep-list is a decision about what testnet
is allowed to page for; take it as one, in `prometheus.yml`, with the reasoning
written down beside the list.
