# Jobs are overdue, or leases are expiring

**Triggered by** `JobQueueOverdue - jobs_overdue > 0 for 10m`
**Severity** SEV4 - ticket · **Owner** the owning service

## What it means

Work is due and not being done. Two very different causes:

- **Nothing is claiming.** `jobs_claimed_total` flat. The runner is not running,
  or it cannot reach Postgres.
- **A worker died holding a lease.** `jobs_claimed_total` healthy but completion
  lagging. This is the class of bug that produced the estate's double-billing:
  the lease expires, another worker claims the same row, and the side effect
  happens twice.

## Checks

1. `jobs_claimed_total` against `jobs_completed_total` - is the gap widening?
2. `db_pool_waiting` - a runner that cannot get a connection cannot claim.
3. The lease key must name the **contended resource** - `chain` for withdrawals,
   `bot_id` for ticks - not the row. A per-row lease serialises nothing.

## The dangerous case

If a non-idempotent handler ran twice, the fix is not in the queue - it is in the
ledger. Check for duplicate postings before declaring this resolved.
