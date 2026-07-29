#!/usr/bin/env python3
"""Write the runbook set that the alert rules link to.

Kept as a generator for one reason: every runbook must carry the same header
shape (trigger, severity, owner) so an operator reading one under pressure knows
where the next thing is. A header that varies is a header that gets skimmed.

The Makefile's `check-runbooks` target fails the build if any alert's
`runbook_url` points at a file this has not written — which is what makes "an
alert without a runbook is deleted, not silenced" a property rather than an
intention.
"""
import pathlib

R = pathlib.Path(__file__).resolve().parent

HEAD = """# {title}

**Triggered by** `{trigger}`
**Severity** {sev} · **Owner** {owner}

"""

BOOKS = {
"runbook-trial-balance-nonzero": dict(
  title="Trial balance is non-zero",
  trigger="LedgerTrialBalanceNonZero - ledger_trial_balance_delta != 0 for 2m",
  sev="SEV1 - page, 24/7", owner="ledger",
  body="""
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
"""),

"runbook-stuck-withdrawal": dict(
  title="A withdrawal is stuck",
  trigger="WithdrawalStuck - withdrawal_stuck_total >= 1 for 5m",
  sev="SEV1 - page", owner="settlement",
  body="""
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
"""),

"runbook-custody-unreachable": dict(
  title="Custody is unreachable",
  trigger='CustodyUnreachable - up{job="custody"} == 0 for 2m',
  sev="SEV1 - page", owner="security",
  body="""
## What it means

Signing is unavailable. Custody is **permanently single-replica** (AD-18) and
that is accepted, written down rather than discovered - one container per
address, which blocks any multi-host move.

## The correct degradation

- Deposits still land. Nothing about receiving needs custody.
- Withdrawals and sweeps **queue**. They must not fail.
- That degradation belongs on the public status page, not in a user's inbox three
  hours later. Post it.

## Checks

1. Is the process down, or is it the per-address containers? Custody's
   container-per-address model hits host limits before anything else does -
   `custody_addresses_total` is a capacity panel, not a business one.
2. Is the encrypted volume mounted and decryptable?
3. Is the master secret present in the environment? It is deliberately excluded
   from backups; a restored host will not have it.
4. Confirm the queue is queuing, not failing: `settlement_sweep_pending` should
   climb, `jobs_dead_total` should not.

## Do not

Do not attempt key recovery to work around an outage. Break-glass needs two
operators, a signed incident record and a hardware-token challenge each, and it
is not a workaround for a restart.
"""),

"runbook-indexer-lag": dict(
  title="Indexer lag past the confirmation depth",
  trigger="IndexerLagPastConfirmationDepth - indexer_lag_blocks > indexer_confirmation_depth for 10m",
  sev="SEV2 - page", owner="indexer",
  body="""
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
"""),

"runbook-reconciliation-drift": dict(
  title="Reconciliation drift",
  trigger="LedgerReconciliationDrift - ledger_reconciliation_drift_native != 0",
  sev="SEV3 - ticket; page above the chain's dust threshold", owner="ledger",
  body="""
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
"""),

"runbook-frozen-deposit-address": dict(
  title="A deposit address is frozen",
  trigger="DepositAddressFrozen - wallet_deposit_address_frozen > 0",
  sev="SEV3 - ticket", owner="wallet",
  body="""
## What it means

Crediting has stopped on one or more deposit addresses. Money sent to them is
safe and is not being credited to the user. This metric exists so the condition
is visible before the user complains, which is how it was found last time.

## The only fix

A recorded manual sweep. It is a money-touching operation performed under
pressure by someone already having a bad day, so it goes through the admin screen
with a preview of the postings, dual approval and a reason code - never through a
curl command with a hand-typed address.

## Before sweeping

1. Confirm the on-chain history from the INDEXER, not from a block explorer in a
   browser tab.
2. Compare against the address's high-water mark. The gap is what is owed.
3. Preview the postings. If the preview does not balance, stop - that is
   `runbook-trial-balance-nonzero` waiting to happen.
"""),

"runbook-dead-letter-drain": dict(
  title="Dead-lettered jobs are accumulating",
  trigger="JobDeadLetterGrowth - increase(jobs_dead_total[15m]) > 0",
  sev="SEV4 - ticket", owner="the owning service",
  body="""
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
"""),

"runbook-lease-expiry-storm": dict(
  title="Jobs are overdue, or leases are expiring",
  trigger="JobQueueOverdue - jobs_overdue > 0 for 10m",
  sev="SEV4 - ticket", owner="the owning service",
  body="""
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
"""),

"runbook-hearth-fork": dict(
  title="Hearth nodes disagree",
  trigger="ChainHeightSpreadSustained - beacon_chain_height_spread > 3 for 15m",
  sev="SEV2 - page", owner="chain",
  body="""
## What it means

The nodes report different heights and have done so for fifteen minutes. That is
a partition or a fork, not a slow node - a slow node catches up.

## Do not restart nodes

Restarting is how you pick a chain by accident. Establish which chain is the
chain first.

1. Per-node height and peers (`beacon_chain_peers{node}`). A miner at zero peers
   is not down; it is mining a chain nobody will accept.
2. Compare block hashes at the last common height. Same height and a different
   hash is a fork; a different height with shared ancestry is a partition.
3. Check the EVM flag and the data directory on every node. `--evm` is a
   DIFFERENT CHAIN, not an upgrade, and it shares the `blocks.ndjson` filename -
   a node pointed at the wrong directory reads the wrong chain's blocks.
4. Check `beacon_conformance_vectors` - a consensus-rule divergence shows here.

## While it is unresolved

Suspend crediting for EMBER deposits. A deposit confirmed on the losing branch is
a credit that has to be reversed.
"""),

"runbook-hearth-node-down": dict(
  title="A Hearth node is down or isolated",
  trigger="beacon_chain_peers == 0, or HearthConformanceVectorsFailing",
  sev="SEV3 - ticket", owner="chain",
  body="""
## What it means

A chain node is a **stateful singleton**. Adding a node adds a validator, not
capacity, so there is no horizontal remedy here.

## Zero peers is not "down"

A node with zero peers answers every health check and mines a chain nobody will
accept. Check peers before checking liveness.

## Checks

1. `beacon_target_up` for the node, and separately for its **RPC**. These stopped
   being the same fact the moment there were two listeners: the EVM node logs
   `json-rpc listen failed` and carries on serving REST, so the node reports
   healthy with a climbing height while nothing can read a balance from it.
2. Seed reachability from the miners.
3. Disk. Replay re-validates every block, so a node that cannot load its store
   sits in replay indefinitely rather than failing.

## Conformance

`beacon_conformance_vectors{result="failed"} > 0` on any suite blocks the next
Hearth release. A suite that could not be RUN reports under `result="skipped"`
and never under `passed` - an empty failure table means passing, not missing.
"""),

"runbook-reorg-recovery": dict(
  title="Chain reorganisation beyond the policy depth",
  trigger="indexer_reorg_depth past the configured depth",
  sev="SEV2", owner="indexer",
  body="""
## What it means

Blocks that were confirmed no longer exist. Anything credited on them was
credited on a history that has been replaced.

## Order

1. Stop crediting on that chain.
2. Establish the reorg depth and the common ancestor from the indexer's own
   checkpoint, not from a provider - providers disagree during a reorg, which is
   the whole problem.
3. List every deposit credited above the common ancestor. Those are the ones at
   risk.
4. Re-scan from the ancestor. Deposits that reappear are fine; deposits that do
   not are reversals.

## Reversals

A reversal is a new balanced journal entry, never an update, under dual approval.
The trial-balance invariant must hold across the pair by construction.

## After

If the reorg depth exceeded the chain's confirmation depth, the confirmation
depth is wrong. Change it, and say so in the post-incident review - the depth
exists to make this impossible.
"""),

"runbook-rpc-provider-failover": dict(
  title="An RPC provider is failing",
  trigger="indexer_rpc_success_ratio low, or indexer_rpc_failover_total rising",
  sev="SEV3 - ticket", owner="indexer",
  body="""
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
"""),

"runbook-telemetry-plane-down": dict(
  title="Part of the observability plane has stopped",
  trigger="TelemetryComponentDown, BeaconScrapeFailing, BeaconJourneyStale, BeaconTargetDown",
  sev="SEV3 - ticket", owner="platform",
  body="""
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
"""),

"runbook-metric-contract-missing": dict(
  title="A money-integrity metric has no series",
  trigger="MoneyMetricContractMissing - absent(ledger_trial_balance_delta) or ...",
  sev="SEV4 - ticket", owner="platform",
  body="""
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
"""),

"runbook-rollback-release": dict(
  title="Roll back to the previous release manifest",
  trigger="Any deploy-correlated incident; SLOErrorBudgetBurnFast; GatewayErrorRatioHigh",
  sev="Any", owner="on-call",
  body="""
## The manifest is the rollback unit

There is no shared version across twenty-five repositories. A release is a
**manifest** - `stack/releases/<version>.yaml`, generated by CI, naming exactly
which image of each service is in this release. Rollback is checking out the
previous manifest and applying it. It is not `git revert` in one repository.

## Mitigation precedes diagnosis

If a release landed inside the incident window, roll back **before** diagnosing.
The deploy annotation on Platform overview is what tells you; it is posted by
`cfctl release` and it is the single most valuable mark on any of these
dashboards.

## Order

1. Confirm the correlation: does the metric turn at the annotation, or before it?
   Rolling back an unrelated release costs an hour and teaches the wrong lesson.
2. Roll back to the previous manifest.
3. Watch the SLI, not the deploy. A rollback that completes is not a rollback
   that worked.
4. If the schema changed, a rollback is NOT sufficient on its own - expand and
   contract discipline means the old code must still read the new schema. If it
   cannot, this is a forward fix rather than a rollback, and say so in the
   channel.

## Then

Freeze the service until the cause is understood. A second deploy on top of a
rolled-back one during an incident is how two problems become one confusing one.
"""),

"runbook-restore-from-backup": dict(
  title="Restore from backup",
  trigger="BackupAgeExceeded - no successful backup in 36h; and the quarterly drill",
  sev="SEV2 for the alert; scheduled for the drill", owner="platform",
  body="""
## The alert is on AGE, not on failure

A backup job that silently stops firing produces no failure to alert on. If
`backup_last_success_timestamp_seconds` is stale, the first question is whether
the job ran at all - not whether it errored.

## Two things are needed and either alone is useless

Custody restores require **both** the encrypted volume snapshot and the master
secret, which is deliberately excluded from every backup and lives in a password
manager or KMS. A snapshot without the secret is noise.

## RPO and RTO

| Service | RPO | RTO | Method |
| --- | --- | --- | --- |
| `ledger` | 0 | 30 min | WAL archiving off-host, plus PITR |
| `custody` | 0 | 1 h | Encrypted volume snapshot, plus the separately-held master secret |
| `wallet`, `settlement`, `billing`, `identity` | 5 min | 1 h | WAL archiving, plus PITR |
| `indexer` | 24 h | 4 h | Nightly dump. **Rebuildable from chain** - the RPO is a convenience |
| Prometheus / Tempo / Loki | 24 h | best-effort | Not backed up. Losing a week of traces is not a business event |

## Verify, every time

Restore into an isolated environment and check four things: identity can mint a
token; the ledger's trial balance is 0; custody can decrypt one known address
using the separately-held master secret; the indexer resumes from its checkpoint.

Record the wall-clock time against the RTO. **A drill that exceeds its RTO
changes the RTO or changes the method - it is never just noted.**

A copy on the same disk as the original is not a backup, and a backup nobody has
restored is a hypothesis.
"""),

"runbook-incident-comms": dict(
  title="Incident communications",
  trigger="BeaconCriticalJourneyFailing; every SEV1 and SEV2",
  sev="Any", owner="incident commander",
  body="""
## A journey failing is user-visible failure

A metric says "p99 is high"; a journey says "a user cannot withdraw". This alert
is the second kind, which is why it pages.

Beacon's journey grid before Grafana: the journey names what broke, and the
service dashboards tell you why.

## First five minutes

- **0-60s, any severity.** Acknowledge the page - this stops escalation. Open the
  Beacon incident. Note the `cf.request_id` or `trace_id` from the alert.
- **SEV1 minute 1.** Declare in the channel and name yourself incident commander.
  The commander decides and does not debug; in a SEV1 the commander is never also
  the operations lead.
- **SEV1 minute 2.** Money integrity dashboard first, always.
- **SEV1 minute 3.** Deploy annotation. Roll back if correlated, before diagnosing.
- **SEV1 minute 4.** If money movement is implicated, freeze withdrawals.
- **SEV1 minute 5.** Post the first public update.

## Public updates

Written by the on-call operator in `admin-web`, stored on the Beacon incident -
one incident, two audiences, one write. An automated incident opens with a
**generic** template ("We are investigating elevated errors affecting Wallet"),
never the alert text, which carries internal target names.

| Sev | First update | Cadence | Final |
| --- | --- | --- | --- |
| SEV1 | 15 min | every 30 min, even "no change" | resolution note within 1h; public review in 5 working days |
| SEV2 | 30 min | every 60 min | resolution note |
| SEV3 | only if user-visible for over 30 min | every 2h | resolution note |
| SEV4 | not published | - | - |

Never publish latency numbers, error rates, internal target names, replica counts
or journey step names. Those are an availability map for an attacker.
"""),
}

if __name__ == "__main__":
    for name, spec in BOOKS.items():
        (R / f"{name}.md").write_text(HEAD.format(**spec) + spec["body"].strip() + "\n")
        print(name)
