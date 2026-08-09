# A withdrawal is stuck

**Triggered by** `WithdrawalStuck - withdrawal_stuck >= 1 for 5m`
**Severity** SEV1 - page · **Owner** settlement

## What it means

A withdrawal has sat in `pending`, `signed` or `broadcast` longer than the
chain's policy allows. The request succeeded and the money did not move, so no
latency or error-rate metric will show this. A user is waiting.

## Establish the state before touching anything

The dangerous case is a transaction that IS in flight and looks stuck. Broadcast
it twice and you have paid twice.

1. Deposits & withdrawals dashboard, withdrawal state age histogram. Which state,
   and for how long?
2. `pending` - custody never answered. Check `up{job="custody"}`; if it is down,
   this is `runbook-custody-unreachable` and the queue is behaving correctly.
3. `signed` - signed and not broadcast. Check the settlement job runner:
   `jobs_overdue`, `jobs_dead_total`.
4. `broadcast` - ask the INDEXER, not the node: has the transaction hash been
   seen? Is it in a mempool? Has it been dropped?

## Mitigation

- Under-priced fee, still in a mempool: bump, do not re-sign. A replacement must
  reuse the nonce.
- Dropped and provably not in any mempool: abandon it. An abandonment is a
  **reversing journal entry**, never a status edit, and it needs dual approval
  plus explicit confirmation that no transaction is in flight.

## The rule

If you cannot prove the transaction is not in flight, do not abandon it. A
delayed withdrawal is a bad day; a duplicated one is an incident with a
reconciliation statement attached.
