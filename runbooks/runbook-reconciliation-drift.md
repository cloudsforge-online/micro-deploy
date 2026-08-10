# Reconciliation drift

**Triggered by** `LedgerReconciliationDrift - ledger_reconciliation_drift != 0 and on (asset) ledger_reconciliation_observed == 1` — SEV3 ticket
**And by** `AssetWithdrawalsFrozen - ledger_assets_frozen > 0` — **SEV2 page**, and this runbook is its only instruction
**Owner** ledger

The header used to name `ledger_reconciliation_drift_native`, a series nothing
has ever published, and it named only the ticket. The page that wakes somebody
points here too, and step 0 below is the step it needs.

## STEP 0: NAME THE FROZEN ASSETS. The page is a count and nothing else.

`ledger_assets_frozen` is the length of `listFreezes(...)` and carries **no
labels**. That is deliberate: the answer is a row in `asset_freezes`, not a label
Prometheus would carry for every asset the platform will ever list. This section
is the other half of that bargain — the query that turns the count into a list.
Run it before you read anything else on this page, because which assets are
frozen and **why** decides every step after it.

**Ask the ledger.** `GET /reconciliation` returns `{ runs, freezes }`, and the
freezes are the current state:

```sh
curl -s -H "authorization: Bearer $SERVICE_TOKEN" \
  http://ledger:4000/reconciliation | jq '.freezes'
```

```json
[
  {
    "assetCode": "LTC",
    "frozenAt": "2026-08-09T22:14:07.512Z",
    "reason": "reconciliation failed: no indexer observation for on-chain asset LTC (custody 41000000; chain holdings UNKNOWN, not zero; reason indexer_refused)",
    "runId": "0198f0c2-…"
  }
]
```

The route requires `ledger:read`. A 401 or 403 here is a token problem and not a
money problem — use the SQL below and deal with the token afterwards.

**When the ledger is the thing that is down,** which is one of the ways this
alert fires, go straight to the table:

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d ledger -c \
  "select asset_code, frozen_at, reason, run_id from asset_freezes order by asset_code;"
```

### `reason` is the field that decides the morning

It is written by reconciliation at the moment of the freeze and it is the string
`GET /reconciliation` and the console both show first. It comes in exactly two
shapes, and they are the same split the table in the next section makes:

| `reason` begins | What happened |
|---|---|
| `reconciliation failed: no indexer observation for on-chain asset …` | **Nobody could look.** No drift was measured, so there is no second number and there is nothing to hunt. The string ends `reason <code>`; the codes are below. |
| `reconciliation drift_exceeded: drift <n> (custody <a>, observed <b> …)` | **A real drift.** Two numbers were measured and they disagree, and the arithmetic that froze the asset is in the string — including, since the observed breakdown landed, which custody buckets the observed side came from. |

The trailing `reason <code>` is one of eight values, and they are about **this
platform's ability to ask**, not about what the chain said:

| code | Where the failure is |
|---|---|
| `no_credential`, `unauthorized` | Authentication in this estate. `no_credential` is micro-org#275's signature: a sweep that landed inside an identity restart. Both are a deploy fault, not a money fault. |
| `timeout`, `unreachable` | The path to the indexer. A refused connection, DNS, a socket hang-up, an open circuit breaker. |
| `indexer_refused`, `indexer_error` | The indexer answered and the answer was a refusal (4xx) or a server error (5xx). **This is the one that continues into the indexer's own code table further down** — ask it directly, as that section shows, and its refusal names the chain-level cause. |
| `not_configured` | This deployment has no indexer URL for the asset at all. Structural; it will not clear on its own. |
| `unusable_answer` | A 200 whose body is not a decimal-string total. A version skew, or something that is not the indexer on the far end of that URL. |

Do not confuse these eight with the indexer's own codes (`chain_not_followed`,
`history_unknown`, `address_unreadable` and the rest). Those are what the indexer
says when it *can* be asked, and they are reached through `indexer_refused` /
`indexer_error`. The table further down this page is theirs.

### Do NOT use `reconciliation_runs` for this

A freeze **outlives the run that wrote it.** It is lifted only by a later
*exactly-clean observed* run, so "the twenty most recent runs" and "what is
frozen right now" are different questions — and at 3am the plausible-looking one
is the wrong one. `asset_freezes` is the current-state answer; the runs table is
the history behind it. Two consequences worth knowing before you read a
timestamp:

- **`frozen_at` is not the onset.** Every freezing run re-upserts the row with
  `frozen_at = now()`, so it is when the freeze was last *reconfirmed*. To date
  the onset, take `run_id` into `reconciliation_runs` and walk backwards.
- **A frozen asset can be carrying an older run's reason.** A run whose
  unobservability is transient is *deferred* — it writes neither a freeze nor a
  lift — so an asset already frozen keeps the reason and `run_id` of the run
  that established it rather than being relabelled on the strength of a blip.

## STEP 1: there are two different mornings, and the `reason` you just read says which

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
| `family_not_supported` | 501 | This build can neither read nor derive that family's balances. Not fixable by waiting. `evm`, `ember` and `bitcoin` (which serves LTC) are supported; `solana` and `xrpl` are not. |
| `nothing_indexed` / `depth_not_walked` | 503 | The follower has not walked back to `head - confirmations + 1`. Backfill: `POST /v1/backfills/:chain/:network`. |
| `below_confirmation_depth` | 503 | The chain is younger than its own confirmation depth. Wait. |
| `head_diverged` | 503 | The node serves a different block than the indexer walked, or a reorg landed mid-read. Usually transient; if it persists, `runbook-reorg-recovery.md`. |
| `chain_halted` | 503 | An alarming reorg stopped the chain and only an operator clears it. `runbook-reorg-recovery.md`. |
| `no_custody_addresses` | 503 | **Nothing is registered as custody's.** Not "the platform holds nothing" — see below. |
| `custody_set_too_large` | 503 | Raise `INDEXER_CUSTODY_MAX_ADDRESSES`. It refuses rather than summing a page, because a page is a partial sum. |
| `history_not_walked` | 503 | **UTXO chains only.** Either the walked record has a hole below the confirmed height, or an address claims a history older than the record reaches. A hole loses receipts AND loses spends, so the total would be wrong in both directions at once. Backfill the range the message names: `POST /v1/backfills/:chain/:network`. |
| `history_unknown` | 503 | **UTXO chains only.** Nobody has stated from which height the address the message names could have had activity, and this service's record does not start at genesis — so coin it received before the record starts is invisible here. See below. |
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

### `history_unknown` on a UTXO chain (LTC)

Litecoin has no `eth_getBalance`. Stock Core keeps no address index, so an
address the node's own wallet does not own has **no balance the node will state,
at any height** — the indexer derives one instead, from the outputs it walked
that nothing has spent. That is only a balance if its record reaches back below
anything the address could ever have received, and the indexer cannot establish
that: it has no view below its own floor.

So the registrar states it. `micro-wallet` sends `freshlyDerived: true` when it
registers an address in the same request that minted the key, and the indexer
stamps its own head against it. An address with no claim is treated as "no
activity below block 0" — true of every address anywhere — which is why an
unclaimed address is answerable on a chain walked from genesis and refuses on
one that cold-started.

This refusal therefore means one of three things, and the message names the
address:

1. **A treasury address, which never carries a claim.** It is pinned by an
   operator and may be years old, so nothing can assert its past on its behalf.
   Supply the height yourself. Read the record floor rather than typing a
   number — the floor moves as the follower advances, and a literal copied out
   of a runbook is stale the day after it is written:
   ```sh
   docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d indexer -Atc \
     "select min(height), max(height), count(*) from blocks
       where chain='ltc' and network='mainnet' and status <> 'orphaned';"
   ```
   `count` must equal `max - min + 1`. If it does not, the record has a hole and
   the derivation will refuse `history_not_walked` whatever you claim — backfill
   the gap first. Then, with `<floor>` being that `min`:
   ```sh
   curl -sX POST -H "authorization: Bearer $SERVICE_TOKEN" \
     -H 'content-type: application/json' \
     -d '{"label":"treasury:ltc:mainnet","historyFromHeight":<floor>}' \
     http://indexer:4000/v1/watch/ltc/mainnet/<address>
   ```
   The floor is the *strongest* claim the record can accept, and for an address
   minted after the record started it is also unambiguously true. This line used
   to carry the literal `3155209`, which was never the floor: it is where the
   live follower took over from the `backfill:3154639-3155208` stream, so the
   stream's name had been read as the record's start. Claiming it was harmless —
   it is above the floor, so merely weaker — but it stated the record began 570
   blocks later than it does.

   **Understate rather than guess high.** A height that is too low only demands
   more coverage and can be refused; a height that is too high lets the
   derivation proceed with coin missing from it, which is positive drift and a
   freeze on a solvent asset. Re-registration takes the *lower* of the two, so a
   correction downwards works and one upwards is ignored.

   **Claim every watched row, not just the one you are chasing.** The derivation
   refuses if *any* address in the set has a null claim, so one unclaimed
   deposit row keeps the whole aggregate unanswerable.

2. **A deposit address registered by the retry job rather than the mint path.**
   Same repair, using the assignment's `assigned_at` to pick a height below it.

3. **The record genuinely does not reach back far enough.** Backfill to the
   height the addresses need — or, on a chain small enough for it, to genesis,
   after which no claim is needed by anyone.

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
  rather than of the money. **This was a known live gap until 2.5.0 and is no
  longer** — settlement registers its pinned treasury with the indexer under a
  `treasury:<chain>:<network>` label and books its balance as platform equity in
  the same movement, so swept coin is now on both sides. If the aggregate carries
  no `treasury:` label for a chain that has a pin, the registration did not
  happen: check `POST /v1/treasuries/:chain/:network/provision` (settlement) and
  see the note below.

  **Provisioning that treasury needs 2.5.2 or later.** The route forwards the
  operator's bearer token to custody's admin mint, and until micro-org#251 the
  shared HTTP client overwrote it with settlement's own service token — which
  does not carry `role:admin`, so the route answered 500 every time on 2.5.0 and
  2.5.1. On an older tag the treasury has to be minted against custody directly
  and pinned there.
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
