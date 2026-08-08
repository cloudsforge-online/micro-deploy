# Reconciliation drift

**Triggered by** `LedgerReconciliationDrift - ledger_reconciliation_drift_native != 0`
**Severity** SEV3 - ticket; page above the chain's dust threshold · **Owner** ledger

## READ THIS FIRST: there are now two different pages, and they are not the same morning

Reconciliation compares the ledger's custody total against what the chain says
the custody addresses hold. Since the chain-backing release there are **two**
ways it can freeze withdrawals, and the difference decides everything you do
next:

| Metric | `observed_source` | What happened |
|---|---|---|
| `ledger_reconciliation_observed = 1`, drift != 0 | `indexer` | **A real drift.** Two numbers were measured and they disagree. Work the rest of this runbook. |
| `ledger_reconciliation_observed = 0` | `unavailable` | **Nobody could look.** There is no drift, because there is no second number. Do NOT go hunting a discrepancy. Go to the section below. |

`ledger_reconciliation_drift` is only written when a drift was actually computed.
**`Number(null)` is `0`**, so a gauge that was always written would publish the
most reassuring number available for the state where nothing was measured at all;
`ledger_reconciliation_observed` is the series that tells you whether to believe
the other one.

Confirm it in the database rather than from the gauge:

```sql
select asset_code, observed_source, status,
       indexer_observed_total::text, drift::text, finished_at
  from reconciliation_runs order by started_at desc limit 20;
```

`indexer_observed_total` and `drift` are **NULL together or not at all** — the
schema enforces it. A NULL is "unknown". A `0` is a measurement of an empty
chain, and those are different facts.

**`observed_source = 'liability_sum'` on a chain asset is a defect, not a
finding.** It means the ledger compared itself against itself, which is the check
this release removed. Migration 11 refuses to write it; if you see one on EMBER,
BTC, ETH, SOL or XRP, the constraint has been dropped and that is the incident.

## `unavailable` / `failed` — nobody could observe the chain

The asset is frozen and no drift was measured. Withdrawals are stopped, which is
correct: an asset whose backing nobody can see is an asset nobody should be able
to withdraw. It will not unfreeze on its own — **only an exactly-clean observed
run lifts a freeze**, and an unobserved run can never be clean.

Ask the indexer directly. Its refusal names the reason:

```sh
curl -s -H "authorization: Bearer $SERVICE_TOKEN" \
  http://indexer:4000/v1/custody/ember/testnet/total | jq .
```

| code | Status | What to do |
|---|---|---|
| `chain_not_followed` | 503 | This replica has no provider for the chain. `INDEXER_CHAINS` and `INDEXER_RPC_<CHAIN>_<NETWORK>`. **This is the expected state for EMBER wherever Hearth has not launched.** |
| `family_not_supported` | 501 | This build cannot read that family's balances. Not fixable by waiting. |
| `nothing_indexed` / `depth_not_walked` | 503 | The follower has not walked back to `head - confirmations + 1`. Backfill: `POST /v1/backfills/:chain/:network`. |
| `below_confirmation_depth` | 503 | The chain is younger than its own confirmation depth. Wait. |
| `head_diverged` | 503 | The node serves a different block than the indexer walked, or a reorg landed mid-read. Usually transient; if it persists, `runbook-reorg-recovery.md`. |
| `chain_halted` | 503 | An alarming reorg stopped the chain and only an operator clears it. `runbook-reorg-recovery.md`. |
| `no_custody_addresses` | 503 | **Nothing is registered as custody's.** Not "the platform holds nothing" — see below. |
| `custody_set_too_large` | 503 | Raise `INDEXER_CUSTODY_MAX_ADDRESSES`. It refuses rather than summing a page, because a page is a partial sum. |
| `address_unreadable` / `rpc_unavailable` | 503 | One or more balances could not be read. The aggregate refuses the WHOLE total rather than returning the addresses that answered — a short total is positive drift, and positive drift freezes on the strength of an RPC blip. Check `provider_health` and `runbook-rpc-provider-failover.md`. |

A 401 or 403 is a deploy fault, not a chain fault: the custody route is the one
read on the indexer that requires `indexer:read`. The ledger's grant is derived
from the `*_SCOPES` constants services export (`scripts/derive-grants.mjs`), so
the repair is in ledger's client, not in a hand-edit of
`IDENTITY_SERVICE_TOKEN_GRANTS` — `estate-verify.sh` runs `--check` and reverts
one.

### EMBER is expected to fail wherever Hearth has not launched

This is a decision, recorded in `compose/docker-compose.estate.yml` beside
`LEDGER_RECONCILE_ASSETS`, and it is not a bug to engineer around. If the chain
has not launched then no EMBER is backed by anything, which is
`docs/ecosystem/00-current-state.md` rather than an inconvenience. If EMBER
custody is zero the freeze costs nothing; if it is not zero, the platform is
holding a liability it cannot prove backing for and freezing is correct.

**The only legitimate exemption is removing EMBER from
`LEDGER_RECONCILE_ASSETS`.** That makes the asset stop being *checked* rather
than making it *look checked*, it is attributable in the manifest, and the freeze
it leaves behind stays until a clean observed run lifts it. Do not add a code
exemption; an `if (asset === 'EMBER')` is a check that cannot fail on the one
asset the whole arrangement exists for.

## `indexer` / drift != 0 — two numbers that disagree

The sign carries the meaning:

- **Positive** (`ledger_custody_total > indexer_observed_total`) — the ledger
  believes we hold coin the chain does not show. This is the shape of
  `convertCoinToEmber`: a liability minted with no on-chain movement behind it.
  Treat it as a solvency question, not a bookkeeping one.
- **Negative** — the chain shows more than the ledger claims. Usually a deposit
  the ledger has not credited yet, or an inbound transfer nobody recorded.

### Which side is wrong

- **Indexer side.** Is the indexer lagging (`indexer_lag_blocks`)? A drift that
  tracks lag is not a drift — it is a snapshot taken at two different times. Note
  that the aggregate is read at `head - confirmations + 1`, so a lag *shorter*
  than the depth cannot explain one.
- **The custody set.** `addresses` and `labelPrefixes` travel with every answer.
  If the count is lower than the number of deposit addresses the platform has
  handed out, the set is incomplete and the drift is an artefact of the set
  rather than of the money. **Known live gap: nothing writes a `treasury:` label
  today** — `micro-settlement` sweeps deposits to a pinned treasury address and
  holds no `indexer:write` grant, so swept coin is invisible to the aggregate and
  shows up here as positive drift.
- **Ledger side.** Unreconciled entries by age, and reservations older than 24h.
  An entry that was never reconciled is drift by definition.
- **Neither.** An on-chain movement nobody recorded: a manual sweep done with
  curl, a dust consolidation, a fee paid from the treasury.

## Fixing

If the chain moved and the ledger did not, the correction is a new balanced entry
under dual approval. Never edit a posting.

Record the reason code. A drift with no reason code is a drift that will be
rediscovered next quarter by somebody who does not know it was investigated.

## Proving the loop still works

`./scripts/verify-chain-backing.sh` drives the whole path on a disposable
database: a chain, the indexer's aggregate, the HTTP hop, and a real
`reconcileAsset` — then breaks each guard and asserts the refusal. Run it after
touching anything on this path. `estate-verify.sh` asserts the live half.
