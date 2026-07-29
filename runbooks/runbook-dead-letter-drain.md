# Dead-lettered jobs are accumulating

**Triggered by** `JobDeadLetterGrowth - increase(jobs_dead_total[15m]) > 0`
**Severity** SEV4 - ticket · **Owner** the owning service

## What it means

Work that exhausted its retries. It will never happen unless somebody makes it
happen, and nothing else will tell you it did not happen.

## Do not bulk-replay

Replaying blindly is how a double withdrawal is created. Every job in the dead
letter is read before it is replayed.

1. Group by `kind`. One kind failing is a bug; every kind failing is a dependency.
2. Read the error. A permanent failure - a deleted user, a closed account -
   should be discarded with a note, not retried.
3. If it is transient and has since resolved, replay **one** and watch it before
   replaying the rest.
4. If the handler is not idempotent, do not replay it at all until it is. Check
   for an idempotency key first.
