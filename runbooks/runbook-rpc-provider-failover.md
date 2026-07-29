# An RPC provider is failing

**Triggered by** `indexer_rpc_success_ratio low, or indexer_rpc_failover_total rising`
**Severity** SEV3 - ticket · **Owner** indexer

## What it means

Failover working is a ticket, not a page. The indexer is designed to fail over;
this alert says it is doing so, which is information rather than an emergency.

It becomes an emergency when `indexer_lag_blocks` passes the confirmation depth -
that is a separate, paging alert.

## Distinguish

- **Down**: `indexer_rpc_success_ratio` collapses. Fail over; open a ticket with
  the provider.
- **Rate-limited**: `indexer_rpc_rate_limited_total` rises while the success ratio
  only dips. Different fix - back off, or buy more quota. The indexer is the
  largest consumer of chain RPC in the estate and these metrics are the bill.
- **Slow but succeeding**: neither rises, but lag grows. That is capacity, not
  health.

## Do not

Do not remove the failing provider from the pool permanently during an incident.
A pool of one has no failover, and that is the state you least want on the day
the remaining provider has an outage.
