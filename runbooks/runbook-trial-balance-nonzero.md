# Trial balance is non-zero

**Triggered by** `LedgerTrialBalanceNonZero - ledger_trial_balance_delta != 0 for 2m`
**Severity** SEV1 - page, 24/7 · **Owner** ledger

## What it means

The sum of debits minus the sum of credits on the journal is not zero. This is
not "a number is off". Double-entry has exactly one invariant and this is it, so
until it is zero every balance derived from the journal is unproven - including
the ones users are looking at right now.

## Do this first, before diagnosing

1. Acknowledge the page. This stops escalation and starts the clock.
2. Open the Beacon incident, SEV1, and name yourself incident commander.
3. **Invoke `runbook-freeze-withdrawals`.** Freezing is reversible; a payout made
   against a wrong balance is not. Do this before you understand the cause.
4. Check the deploy annotation on Platform overview. If a release landed inside
   the window, roll back to the previous manifest **now** - see
   `runbook-rollback-release`.

## Then find it

- `sum by (currency) (ledger_trial_balance_delta)` - which currency, and by how
  much. A delta equal to a round transaction amount points at one entry; a delta
  that drifts points at a loop.
- `ledger_posting_failures_total{reason="unbalanced"}` - if this is rising, the
  bug is in a caller constructing entries, not in the ledger.
- Query the journal for entries in the incident window whose postings do not sum
  to zero. There should be none; the ones you find name the originating service.

## Fixing it

**Never an `UPDATE`.** An adjustment is a NEW balanced journal entry with a
reason code, proposed by one operator with a supporting correlation id and
approved by a second. Self-approval is refused by the service, not by this
document.

## After

Money-touching incidents produce a reconciliation statement: what the ledger said
before, what it says after, what was adjusted, under whose dual approval, with
which reason code. Post-incident review within five working days.
