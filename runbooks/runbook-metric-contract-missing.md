# A money-integrity metric has no series

**Triggered by** `MoneyMetricContractMissing - absent(ledger_trial_balance_delta) or ...`
**Severity** SEV4 - ticket · **Owner** platform

## What it means

One of `ledger_trial_balance_delta`, `withdrawal_stuck_total` or
`indexer_lag_blocks` is not being published by anything. Every alert that depends
on it is deployed and **cannot fire**.

This is the exact failure the telemetry plane exists to prevent: the estate's
current state - no metrics scraped anywhere - presents as no alerts firing, which
is indistinguishable from health. `absent()` inverts it, so not publishing the
metric is itself the alert.

## Expected, for now

Until `ledger`, `settlement` and `indexer` ship (P4/P5) this alert fires by design
and should be acknowledged, not silenced. Silencing it means it will not fire when
it starts meaning something.

## After those services exist

It means instrumentation regressed. Check, in order:

1. The service's `/metrics` endpoint directly - is it emitting the series?
2. `prometheus/targets/services.yaml` - is the service in the scrape list? It is
   generated from the release manifest, so a service deployed outside the
   manifest is a service nothing scrapes.
3. `up{service="..."}` - is the target being scraped at all?
