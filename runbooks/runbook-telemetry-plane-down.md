# Part of the observability plane has stopped

**Triggered by** `TelemetryComponentDown, BeaconScrapeFailing, BeaconJourneyStale, BeaconTargetDown`
**Severity** SEV3 - ticket · **Owner** platform

## What it means

Something downstream of the failed component is now reporting **silence**, which
is not the same as health. This is the alert that stops a green dashboard being
mistaken for a working system.

## BeaconScrapeFailing is usually not Beacon

Beacon gates `/metrics` behind the same auth as every other route, deliberately -
an open `/metrics` publishes the shape of the estate to anyone who can reach the
port. Likely causes, in order:

1. `CF_BEACON_TOKEN` is unset in `micro/deploy/.env`, so `up.sh` wrote an empty
   `prometheus/secrets/beacon_token` and the scrape 401s.
2. `BEACON_TOKEN` is unset on the Beacon container itself, so no static token
   will ever match.
3. The two are set to different values.
4. Beacon is actually down - check this last, because Beacon holds live state in
   memory and stays up through a Postgres outage by design.

## BeaconJourneyStale

A journey that stopped running reports its last status forever, so a green grid
can mean the scheduler died and no status metric says so. Check
`beacon_journey_last_run_timestamp_seconds`, then Beacon's own logs.

## Collector

`otelcol_exporter_send_failed_spans` and the exporter queue size. A collector
that cannot reach Tempo drops traces silently once its retry budget is spent; the
metrics pipeline is unaffected, so the symptom is "traces missing, everything
else fine".
