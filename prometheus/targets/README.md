# `file_sd` targets

Everything in this directory is **generated** and nothing in it is committed.

`prometheus.yml`'s `cf-services` job reads `/etc/prometheus/targets/*.yaml` with a
30-second `refresh_interval`. On the deploy host that path is a read-only bind
mount of this directory, so a target list written here is being scraped within
half a minute, with no Prometheus restart and no gap.

`services.yaml` is written by `scripts/render-prometheus-targets.py`, which
`scripts/release-deploy.sh` runs from the release manifest at the same moment it
renders the pinned compose overlay from that same manifest. One file answers
"what is running" and both consumers read it.

## Why the generated file is gitignored rather than committed

This file used to be committed, and for the whole life of the telemetry plane its
contents were the literal string `[]`. Measured on mainnet on 2026-08-09: eight
active targets, seven of them the monitoring stack watching itself and one the
gateway, while 48 services were deployed and pinned by digest — and twenty alert
rules, including every money alert the estate has, evaluating against no data
(micro-org#308).

A committed target list is a second answer to "what is running", which is the
argument the old file made against itself in its own header and then lost:

> A hand-maintained scrape list is a second answer to "what is running", and the
> estate already lost that argument once with the `API_PREFIXES` array.

So it is ignored, on the same rule and for the same reason as
`compose/docker-compose.release*`: generated, never authored, and committing it
lets a stale artefact outlive the manifest it came from.

## What a fresh checkout scrapes

Nothing, until a deploy runs. Prometheus tolerates a `file_sd` glob that matches
no files — it reports zero targets for the job rather than failing to start — and
zero targets is the honest state for a checkout that has not deployed anything.
The first `release-deploy.sh` writes the file.

## Which services end up here

Not a list anybody maintains. A service is emitted when its own compose health
check probes `/readyz` on a port, because rule 4 of `docs/ecosystem/03` §2 makes
`/livez`, `/readyz` and `/metrics` one obligation — so the port the estate
already asserts answers the second is the port that answers the third. Static
front ends probe `/healthz` on 8080 and fall out without being named. Services
whose `/metrics` needs a credential are skipped because `prometheus.yml` already
scrapes them in a job of their own, which is where a per-job token can live.

The reasoning, the measurements behind it and the `tier` label are all in
`scripts/render-prometheus-targets.py` and `prometheus/tiers.yaml`.

## Why every target is a container name and carries an `instance` label

`indexer:4000` is a question, not an address. Prometheus is attached to
`cloudsforge-estate_default` **and** `cf-testnet_default` — the second because
reaching one testnet container for the `cf-indexer-testnet` job meant joining its
whole network (micro-org#398) — and Docker resolves a bare name against those in
name order. `cf-testnet_default` sorts first.

So from 2026-08-11T23:59:45Z every target in this directory was answered by the
**testnet** container, and the samples were stored under the mainnet job's
labels. Three mainnet chain series stop and testnet starts in the same 15-second
sample. Every target stayed `up` and every number stayed plausible; the alert
plane simply evaluated the wrong network (micro-org#437).

Container names are unique per host across compose projects, which is the one
property a scrape address needs, so the generator emits
`<project>-<service>-<n>:<port>` with the project read off the compose model.

`instance` is pinned to the old `<service>:<port>`. The address had to change;
the series identity must not, or every recording rule and dashboard panel keyed
on it would be orphaned to fix a resolution bug they have nothing to do with. A
service with replicas is the exception — there the ordinal is what distinguishes
the targets, so `instance` is left to the address.

`scripts/check-prometheus-target-ambiguity.py` refuses any target in this
directory or in `prometheus.yml` that is a bare service name, so the next person
to attach Prometheus to another network cannot reintroduce this quietly.
