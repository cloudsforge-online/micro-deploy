# Reconciliation drift

**Triggered by** `LedgerReconciliationDrift - ledger_reconciliation_drift_native != 0`
**Severity** SEV3 - ticket; page above the chain's dust threshold · **Owner** ledger

## What it means

What the ledger says custody holds and what the chain says custody holds have
diverged. Two truths is precisely what a single journal exists to prevent, so
this is a real finding even when the number is small.

## Which side is wrong

- **Indexer side.** Is the indexer lagging (`indexer_lag_blocks`)? A drift that
  tracks lag is not a drift - it is a snapshot taken at two different times.
- **Ledger side.** Unreconciled entries by age, and reservations older than 24h.
  An entry that was never reconciled is drift by definition.
- **Neither.** An on-chain movement nobody recorded: a manual sweep done with
  curl, a dust consolidation, a fee paid from the treasury.

## Fixing

If the chain moved and the ledger did not, the correction is a new balanced entry
under dual approval. Never edit a posting.

Record the reason code. A drift with no reason code is a drift that will be
rediscovered next quarter by somebody who does not know it was investigated.
