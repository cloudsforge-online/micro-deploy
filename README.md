# The telemetry plane

AD-20, built. A **parallel** stack: it runs beside the existing eighteen-container
estate without touching it, shares no port, no container name and no volume with
it, and joins exactly one of its networks — read-only, to scrape Beacon.

Nothing under `repos/` or in the root `docker-compose.yml` is modified by
anything here, and `down.sh` removes only what this project created.

> **Why this is first, and not last.** The only way to prove a decomposition did
> not break behaviour is to compare traces, error rates and journey results
> across the cutover. Instrument afterwards and the baseline is gone. This lands
> in P2, before the first repository is split.

---

## Bringing it up

```sh
cd micro/deploy
cp .env.example .env      # optional; every value has a working default
make up                   # telemetry plane
make gateway              # telemetry plane + Traefik
make check                # every validation, offline
make estate               # confirm the existing estate is still healthy
make down                 # stop, keeping 15d of metrics and 30d of logs
make clean                # stop and delete all telemetry history
```

`make up` runs `up.sh`, which writes the two credential files, regenerates the
dashboards from the validated palette, warns if the existing estate is not
running, and then brings compose up. Bare `docker compose -f
compose/docker-compose.telemetry.yml up -d` also works once `up.sh` has run
once — it is the credential files that need creating, not the containers.

---

## Port allocation

Everything is in **9xxx**, which was verified clear against `lsof -iTCP -sTCP:LISTEN`
and `docker ps` before it was chosen. The existing estate holds 3000–3003,
4001–4006, 4010–4011, 5432, 8080–8081, 8545–8549, 8645–8649 and 18545.

| Host | Container | Component | |
| --- | --- | --- | --- |
| `127.0.0.1:9090` | 9090 | Prometheus | metrics, rules, alert evaluation |
| `127.0.0.1:9091` | 3000 | Grafana | the operator pane |
| `127.0.0.1:9092` | 3100 | Loki | raw log stream |
| `127.0.0.1:9093` | 9093 | Alertmanager | routing, grouping, inhibition |
| `127.0.0.1:9094` | 3200 | Tempo | traces |
| `127.0.0.1:9095` | 80 | Traefik | HTTP, redirects to TLS |
| `127.0.0.1:9096` | 443 | Traefik | TLS termination |
| `127.0.0.1:9097` | 8082 | Traefik | Prometheus metrics |
| `127.0.0.1:9098` | 13133 | OTel collector | health check |
| `127.0.0.1:9099` | 8889 | OTel collector | Prometheus exposition |
| `127.0.0.1:9317` | 4317 | OTel collector | **OTLP gRPC** — services |
| `127.0.0.1:9318` | 4318 | OTel collector | **OTLP HTTP** — browsers |

**Every port is bound to `127.0.0.1`.** This is an operator plane, not a public
surface, and the estate already treats pay, keyvault and postgres this way. A
Grafana on `0.0.0.0` with a default password is one port-scan from being the
worst thing on the host. Reach it over SSH, or through the gateway with real
auth in front.

---

## Networks

Three, per AD-17, plus one attachment to the existing estate.

| Network | Docker name | Who is on it |
| --- | --- | --- |
| `edge` | `cf-micro-edge` | gateway, and anything it routes to |
| `app` | `cf-micro-app` | services, and the telemetry backends |
| `vault` | `cf-micro-vault` | custody, ledger, settlement — **`internal: true`** |
| `estate` | `stack_default` | **external.** Prometheus and Alertmanager only |

**Custody is unreachable from `app` structurally, not by rule.** A container
attached only to `cf-micro-vault` has no route to a container attached only to
`cf-micro-app`; there is no firewall anyone has to remember to write, and no
label anyone can add to defeat it. `vault` is additionally `internal`, so nothing
on it can reach the internet — custody has no business making an outbound call,
and the indexer's twelve RPC providers are precisely why the indexer is a
separate service (AD-07).

Prometheus joins `stack_default` so it can scrape `beacon:4011`. Joining an
external network does not create, modify or remove it; the estate's compose file
is untouched and unaware.

---

## What each component is for

**`otel-collector`** — the only component that knows where telemetry goes.
Services speak OTLP to it and hold no backend address, which is what makes
adopting a commercial APM later a change to one exporter block rather than a
re-instrumentation of 38 repositories. It also does the redaction, the address
truncation and the tail sampling, so those policies are enforced once rather
than in every service.

**`prometheus`** — metrics, recording rules and alert evaluation. Exemplar
storage is on, which is what makes "p99 spiked" one click from the trace that was
slow.

**`tempo`** — traces. Object-storage-backed with no index to operate. Its
metrics generator remote-writes span metrics and service graphs back into
Prometheus, which is where the upstream-call latency panels come from without
anyone instrumenting a service pair by hand.

**`loki`** — the raw log stream. **Loki holds the stream; Lantern holds the
triage view.** Lantern is not replaced: it groups errors into issues by
normalised fingerprint — "this failure, 1,240 times, first seen 09:12" rather
than 1,240 rows — and it owns browser errors. Error grouping is the product; log
search is the commodity. Buy the commodity, keep the product. That division is
also what makes Lantern's 7-day retention acceptable.

**`alertmanager`** — routing, grouping and inhibition. Every alert opens a
**Beacon incident** as well as being delivered, because Beacon already owns
incident open/close, hysteresis, the timeline and the status page. Two incident
systems is two records to reconcile at the worst possible moment.

**`grafana`** — one pane over all three signals, with the trace↔log↔metric links
wired in provisioning rather than left to whoever opens the panel.

**`gateway` (Traefik)** — label-based discovery, which is what deletes eighteen
`container_name:` entries and every fixed host port and makes `deploy.replicas`
legal at all. It owns TLS, CORS, and the `/internal` refusal.

### The `/internal` refusal moved, and so did its invariant

Today `/internal` is refused by a path rule in
`deploy/cloudflared/config.example.yml`, asserted by a CI job that parses that
YAML (`.github/workflows/ci.yml:155`). AD-17 moves routing and TLS to the
gateway, so the **mechanism** moves — and the invariant has to move with it, or
the check keeps passing against a file nothing reads any more, which is worse
than no check at all.

It is now a router in `gateway/dynamic/policy.yml` at priority 100000, pointed at
an unreachable service. It is a *route*, not a middleware, because a middleware
chain cannot refuse a request. It lives in a policy file rather than in a label
because **a service must not be able to relax the rule that constrains it.**

Verified behaviour:

```
/internal          -> 502      //INTERNAL/x     -> 502
/internal/credit   -> 502      /Internal        -> 502
/internalisation   -> 404      (correctly NOT matched)
```

502 rather than 403: a 403 confirms the path exists to whoever is probing, and
502 is exactly what an unreachable upstream looks like from outside the box —
which is what `/internal` should look like.

---

## Retention, and what each number costs

| Signal | Value | Why this number |
| --- | --- | --- |
| Prometheus, raw | **15d** | Long enough to work an incident and its week-on-week comparison. Beyond that, nobody queries raw 15-second resolution — they query a trend, which is what the downsampled series is for. Also bounded at 8GB, because a monitor that fills the disk it shares with Postgres has taken the platform down. |
| Prometheus, downsampled | **400d at 5m** | Two consumers: capacity trends, and the 90-day uptime bars on the public status page. 400 days is not arbitrary — it matches Beacon's `BEACON_ROLLUP_RETENTION_DAYS=400`, so the status page's history and Grafana's agree. |
| Tempo | **7d, tail-sampled** | Enough to debug last week. Older than that, the question is answered by metrics and the audit plane, not by re-reading a span. Traces are the highest-volume signal and the one with the steepest cost curve, which is why sampling is aggressive and retention is short. |
| Loki | **30d** | Longer than traces because a log line is small and because "when did this start" is asked of logs far more often than of traces. Shorter than the audit plane, deliberately: logs are best-effort, can be dropped by the memory limiter under load, and must never be the system of record for anything. |

**Losing telemetry is not a business event.** None of it is backed up beyond
object-storage durability, and that is a decision, not an omission: the ledger's
RPO is zero and Prometheus's is a day.

### The 400-day line needs saying plainly

**Prometheus cannot downsample.** AD-20 writes "15d raw, 400d downsampled" as
though it were a configuration value; there is no such flag. Prometheus has one
retention for all data at one resolution.

What is implemented instead: `prometheus/rules/slo.yaml` records a `cf:ds5m:*`
family at 5-minute resolution — roughly 1/20th the sample volume — and the
long-horizon panels read those. They are also exactly what gets shipped when a
remote-write store lands, which is why `--web.enable-remote-write-receiver` is
already on.

To actually keep 400 days, one of these is required and none is free: Thanos or
Mimir (a second stateful system, and 13-operational-model.md §13's whole argument
against a broker applies), or Prometheus's own retention raised to 400d with the
storage bill and query cost that implies. **The recommendation is Mimir at the
point the 90-day uptime bars need real history**, and until then the 5m rollups
serve the trend panels honestly. This is the largest gap between AD-20 as written
and AD-20 as built.

---

## Secrets

No secret is in any committed file. `.env` is gitignored; `up.sh` reads it and
writes two credential *files* which are mounted:

| File | Read by | Mechanism |
| --- | --- | --- |
| `prometheus/secrets/beacon_token` | Prometheus | `http_headers: files:` on the Beacon scrape |
| `alertmanager/secrets/{page,ticket}_webhook_url` | Alertmanager | `url_file:` on each receiver |

Files rather than environment variables, because a credential in an environment
variable is a credential in `docker inspect`, in every crash dump and in the
process table.

**Unconfigured is a supported mode.** With nothing set, alert delivery falls back
to the Beacon incident receiver — a degradation you can see (no acknowledgement,
no escalation) rather than a failure that stops the plane from starting.

### Beacon costs one thing more than AD-20 predicted

AD-20: *"Beacon emits Prometheus format explicitly so that adopting a scraper
costs a scrape config rather than a rewrite, and nothing has ever scraped it."*

The scrape config is written and it works. It costs a scrape config **and a
credential**: Beacon gates `/metrics` behind the same auth as every other route
(`infra/beacon/src/server.js:373`), which is correct — an open `/metrics`
publishes the shape of the estate to anyone who can reach the port — but it is a
step the decision record does not mention.

`BEACON_TOKEN` is **empty on the running estate**, so the scrape returns 401
until an operator sets it in the estate's `.env` *and* sets the same value as
`CF_BEACON_TOKEN` here. `BeaconScrapeFailing` fires on exactly this, and its
runbook lists the four causes in likelihood order.

This was verified rather than assumed: with a token set on both sides, the target
scrapes green and `beacon_up` lands in Prometheus. The configuration is right;
the estate is missing one variable.

---

## Divergences from the specification, and why

These are places where the documents and the code disagree, and the code wins
because a rule referencing a metric nobody publishes evaluates to empty and
alerts on nothing — silently, which is the failure mode this whole plane exists
to prevent.

| 13-operational-model.md says | `@cloudsforge/telemetry` emits | Used here |
| --- | --- | --- |
| `http_server_requests_total` | `http_requests_total` | the library's |
| `http_server_request_duration_seconds` | `http_request_duration_ms` (**milliseconds**) | the library's |
| `jobs_dead_lettered_total` | `jobs_dead_total` | the library's |
| `jobs_inflight` | `http_requests_in_flight`; jobs expose `jobs_pending` / `jobs_overdue` | the library's |
| `jobs_lease_expired_total` | not emitted | `jobs_overdue` as the proxy, noted in the panel |

The document is using the OTel semantic-convention spelling and the library is
not. **One of the two must change**, and this is a decision for the architect,
not for a deploy directory: renaming the library's metrics is a P2 change to one
package, while amending the document is free. The library is what these
dashboards and rules reference either way.

### Metrics that do not exist yet

The money and chain rules reference metrics that `ledger`, `wallet`,
`settlement`, `custody` and `indexer` must emit. Those services are P4/P5 and are
not written. Those rules are the **contract**: a service that does not emit
`ledger_trial_balance_delta` fails an alert that is already deployed and already
has a runbook, rather than shipping and being instrumented afterwards.

`MoneyMetricContractMissing` is the rule that stops this being a silent gap.
`absent()` inverts the default: not publishing the metric is itself the alert.
Without it, a missing metric and a healthy ledger look identical — which is
precisely the estate's current condition, where no metrics scraped anywhere
presents as no alerts firing.

---

## Dashboards

Five of the nine are built: Platform overview, Service detail (templated by
`$service`), Money integrity, Deposits & withdrawals, Chain health. Business,
Product funnels, Custody & security and Developer platform need `analytics`,
`billing`, `custody` and `devplatform`, none of which exist.

**They are generated, not hand-written.** `grafana/build-dashboards.py` reads
`grafana/theme/palette.json` and writes fixed colours into every panel, because
Grafana has no mechanism for registering a custom named palette — a colour is
either one of Grafana's own names or a hex literal in each panel. Forty panels of
hand-typed hex is forty chances to drift, and the palette is validated rather
than decorative: ember↔gold sit at ΔE 2.8 under deuteranopia, which is the
difference between two series and one.

The generator also enforces the rules, not just the values:

- **`timeseries()` takes one unit and has no second-axis argument.** Two measures
  of different scale become two panels sharing the dashboard's time range. Rate
  and error ratio are two panels; CPU and memory are two panels; hashrate and
  difficulty would be two panels.
- **Categorical colours are assigned by NAME, in slot order, never cycled.**
  Passing a ninth series raises rather than generating a hue. Keying by name is
  the palette's "colour follows the entity, not its rank" rule: filtering a chart
  down to three chains does not recolour the survivors.
- **Quantiles take the sequential ember ramp**, not three categorical hues. p50,
  p95 and p99 are one measurement at increasing severity, and lightness says so.
- **Status marks ship icon + label + colour** — `● pass`, `▲ skip`, `■ fail`.
  Colour never carries meaning alone, because the surface a colourblind operator
  reads under stress is the one that is red.
- **A missing reading renders as `▲ no data answered`**, never as an empty cell.
  An empty chart and a failed chart must not look the same, and on the Money
  integrity dashboard a trial balance that is *absent* must not read as balanced.

The Money integrity dashboard's first panel is the trial balance, at 56px, with
no warning band — there is no amount by which double-entry is allowed to be
wrong. Its alert is `LedgerTrialBalanceNonZero`, SEV1, paging, with no error
budget.

To regenerate: `make dashboards`. Provisioned dashboards are read-only in the UI
on purpose — a panel edited in the browser is a change no repository has, lost on
the next deploy, and discovered when somebody opens it during an incident.

---

## Alerts

Twenty rules, and **every one carries a `runbook_url` that resolves to a file in
`runbooks/`**. `make check-runbooks` fails the build otherwise. An alert without
a runbook is deleted, not silenced, because an unactionable page teaches the
on-call to ignore pages.

Page (user-visible failure or irreversible money risk): trial balance non-zero,
stuck withdrawal, custody unreachable, indexer lag past the confirmation depth,
sustained chain height spread, a critical Beacon journey failing twice
consecutively, fast Tier-1 SLO burn, gateway 5xx above 5%, backup age past 36h.

Ticket (everything else): reconciliation drift, frozen deposit addresses,
dead-lettered jobs, overdue jobs, slow SLO burn, Beacon scrape failing, a
telemetry component down, a stale journey, failing conformance vectors, a Beacon
target down, and a missing metric contract.

A metric says "p99 is high"; a journey says "a user cannot withdraw". Page on the
second.

---

## Layout

```
compose/
  docker-compose.telemetry.yml   the plane
  docker-compose.gateway.yml     Traefik, label discovery
  env/*.env                      one file per service, no secrets, no fan-out
otel/collector.yaml              redaction, truncation, tail sampling, three exporters
prometheus/
  prometheus.yml                 scrape config, incl. Beacon
  rules/slo.yaml                 SLIs, burn rates, 5m rollups
  rules/alerts.yaml              20 rules, every one with a runbook
  targets/services.yaml          file_sd, generated from the release manifest
tempo/tempo.yaml                 7d, metrics generator
loki/loki.yaml                   30d, label cardinality bounded
alertmanager/alertmanager.yml    routing, grouping, 3 inhibit rules
gateway/dynamic/policy.yml       /internal refusal, CORS, security headers
grafana/
  build-dashboards.py            the palette, applied by construction
  theme/palette.json             the validated values, as data
  dashboards/*.json              generated; provisioned read-only
  provisioning/                  datasources with trace<->log<->metric links
runbooks/*.md                    17, one per alert that needs one
scripts/check-runbooks.py        the runbook rule, as a build failure
```

### Per-service env files, and why the fan-out had to go

The estate's compose hands eight services all 64 variables through one
`env_file: .env`. That is how the game container holds the custody master
secret — not because anyone decided it should, but because one list was easier
than eight. `compose/env/` makes it impossible by construction: **a variable a
container was never given cannot leak from it.** The collector needs three
variables and receives three.

This is the highest-severity item in the estate and close to free.
