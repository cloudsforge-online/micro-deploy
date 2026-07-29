# Indexer lag past the confirmation depth

**Triggered by** `IndexerLagPastConfirmationDepth - indexer_lag_blocks > indexer_confirmation_depth for 10m`
**Severity** SEV2 - page · **Owner** indexer

## What it means

The indexer is further behind the chain head than that chain's own confirmation
depth. Past that point deposits are **provably not being credited** - it is a
user-visible money failure wearing an infrastructure metric's clothes.

Depth is per chain and is read from `indexer_confirmation_depth`, not from a
constant: Hearth's is 60 and Bitcoin's is not.

## Order of checks

1. `indexer_rpc_success_ratio{provider}` - is a provider failing? A failover loop
   looks identical to a stalled worker in the lag metric.
2. `indexer_rpc_rate_limited_total{provider}` - are we being throttled? That is a
   different fix from a provider being down.
3. `indexer_reorg_depth` - a deep reorg makes the worker re-scan, which reads as
   lag and is correct behaviour.
4. Only then: is the worker alive? `jobs_claimed_total` for that chain family.

## Do not restart first

A restart loses no state, because the checkpoint is durable, but it also fixes
nothing if the cause is upstream and it resets the evidence. Establish which of
the four above it is before restarting anything.
