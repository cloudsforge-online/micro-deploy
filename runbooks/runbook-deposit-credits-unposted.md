# Deposit credits claimed and never posted to the ledger

**Triggered by** `DepositCreditsUnposted - wallet_deposit_credits_pending > 0 for 20m`
**Severity** SEV3 - ticket · **Owner** wallet

## What it means

A deposit credit row whose `ledger_entry_id` is still null is **money that
arrived on chain, was claimed by wallet, and has not been posted to the ledger.**
The owner cannot see it. A balance is whatever the ledger says it is, and the
ledger has not been told.

It is the mirror image of `DepositAddressUnwatched`, one step further down the
same path:

```
address assigned ─→ address watched ─→ deposit seen ─→ CREDIT CLAIMED ─→ posted
                    └ DepositAddressUnwatched                            └ THIS
```

The claim-then-post ordering is deliberate and this state is its cost. wallet
commits the local row **before** it posts, so a crash between the two leaves a
visible, queryable, retriable row. The reverse would leave a ledger entry wallet
does not know it made, which the next redelivery would double. So a pending
credit is not corruption — nothing is lost, nothing is double-counted, and
`postCredit` sends `credit_key` as the ledger's idempotency key, so re-posting
one that in fact landed replays rather than doubles.

It is a ticket and not a page because `deposit.post` retries the entire backlog
every five seconds on its own. A non-zero reading that clears is the system
working. **Twenty minutes is about 240 passes**, so a firing alert means the same
posting has been refused 240 times: it is not a queue draining slowly, and it
will not fix itself.

## Step 1 — why are the postings being refused

The count says how much. This says why, and it is the only step that matters
before you touch anything:

```sh
docker logs cloudsforge-estate-wallet-1 --since 30m 2>&1 \
  | grep 'deposit credit posting failed'
```

Every line carries `creditId` and `err`. The retry job logs and moves on rather
than throwing, so the batch continues and the row stays — which means a
persistent per-credit failure is visible here and **nowhere else**. If this
returns nothing while the gauge is non-zero, go to step 3.

`err` is the ledger's refusal, and the code decides the morning:

| code | Status | What it means |
|---|---|---|
| — connection refused / timeout | — | The ledger is down or unreachable. Nothing is wrong with the credits. `TelemetryComponentDown` / the ledger's own health are the alerts to read; this one clears by itself once the ledger is back. |
| `retired_asset` | 400 | The deposit is denominated in a unit the ledger has wound down. It will never post as it stands and no amount of retrying changes that. Escalate to ledger — this is a decision, not a fault. |
| `unknown_account` | 400 | The subject or purpose in the posting does not resolve. A wallet/ledger schema disagreement; do not work around it here. |
| `invalid_entry` / `unbalanced_entry` | 400 | The entry wallet built is malformed. A bug in `postCredit`, not in the data. |
| `idempotency_key_reuse` | 409 | **The credit key was used with a different body.** Two different deposits produced the same `credit_key`, or one deposit's amount changed between attempts. Read the entry the ledger already has under that key before doing anything else. |
| `idempotency_in_flight` | 409 | A concurrent attempt holds the key. Transient by construction; it will clear on the next pass. |
| `unauthenticated` / `forbidden` | 401/403 | wallet's service token is expired, or its grant lost `ledger:post` — that is the scope `POST /entries` is gated on, and it is the one this path needs. A deploy fault, not a money fault. Grants derive from the `*_SCOPES` constants services export (`scripts/derive-grants.mjs`), so repair there rather than hand-editing `IDENTITY_SERVICE_TOKEN_GRANTS`, which `estate-verify.sh --check` reverts. |

**`asset_frozen` cannot appear here, and if you are also holding
`AssetWithdrawalsFrozen`, that is not the cause.** `assertNotFrozen` in ledger's
`entries.ts` returns immediately unless the entry kind is a withdrawal kind, and
`deposit_credited` is not one. A reconciliation freeze stops money going out; it
does not stop money being recorded as having come in. Chasing the freeze here
costs an hour and finds nothing.

## Step 2 — name the credits

The gauge is a scalar by design: every unposted credit has the same repair, and
the per-row answer belongs in the database rather than in a Prometheus label
carried for every credit the platform will ever take. This is that query.

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d wallet -c \
  "select id, user_id, asset_code, amount, chain, network, tx_hash, credited_at
     from deposit_credits
    where ledger_entry_id is null
    order by credited_at;"
```

Read the **spread**, not just the count:

- **One asset, one chain** — the refusal is about that asset. `retired_asset`
  and a ledger that will not accept the unit look like this.
- **One user** — almost always a per-row data problem, not an outage.
- **Everything, all at once, starting at one timestamp** — the ledger was
  unreachable from that moment. Compare `credited_at` against the ledger's
  restart.
- **Oldest row much older than the rest** — one poisoned credit that has been
  failing since long before this alert, with a healthy backlog behind it. That
  one row is the ticket; the rest will drain the moment it stops throwing.

Total exposure, which is what an incident write-up needs:

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d wallet -c \
  "select asset_code, count(*), sum(amount)::text as minor_units
     from deposit_credits where ledger_entry_id is null group by asset_code;"
```

Amounts are integer **minor units** of that asset. Do not divide by anything to
put it in a report; state the unit.

## Step 3 — the gauge is non-zero and nothing is in the logs

Then the retry job is not running, and the credits are not being attempted at
all. `deposit.post` is a leased recurring job on the wallet runner.

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d wallet -c \
  "select kind, key, run_at, attempts, max_attempts, dead, locked_by, locked_until, last_error
     from jobs where kind = 'deposit.post';"
```

- **`dead = true`** — it exhausted `max_attempts` and was **deliberately not
  re-armed**. That is the design, not a bug: silently rescheduling a job that
  has failed its whole budget hides a permanent fault behind a busy loop. The
  reason is in `last_error`. `JobDeadLetterGrowth` fires on the same event
  (`increase(jobs_dead_total[15m]) > 0`); `runbook-dead-letter-drain.md`.
- **No row at all** — the boot seed never ran, which means the wallet runner did
  not start. Nothing else in this estate enqueues `deposit.post`.
- **`run_at` far in the past with `locked_by` set and `locked_until` stale** — a
  replica died holding the lease. `runbook-lease-expiry-storm.md`.
- **Row healthy and `attempts` climbing** — the handler is throwing before it
  reaches a per-credit `try`, so nothing ever logs `deposit credit posting
  failed`. That is a wallet bug, and the stack trace is in the runner's own log
  lines rather than on that one.

`JobQueueOverdue` and `JobDeadLetterGrowth` fire on the same evidence and are
worth reading beside this alert.

## Fixing it

**There is no manual sweep, and no dual approval, because there is nothing to
correct.** Every one of these rows is a posting that has not happened yet. Make
the posting possible and the job posts them.

- **Ledger was down** — nothing to do. The backlog drains within a couple of
  passes of it coming back, and the alert resolves itself.
- **A refusal that is about the credit** (`retired_asset`, `unknown_account`) —
  the repair is in ledger or in wallet's posting, and it is a code or
  configuration change. The credits wait, intact, until it lands.
- **One poisoned row blocking nothing** — it does not block anything. The loop
  catches per credit and continues, so the rest of the backlog drains around it.
  Resist deleting it: it is the evidence.

**Never set `ledger_entry_id` by hand.** It is the only record that the money was
posted, and writing an entry id the ledger did not issue makes the credit
invisible to this alert while leaving the user's balance short — the exact
failure this rule exists to catch, now unwatchable. If a credit genuinely must
not be posted, that is a ledger correction under dual approval, and it is a new
balanced entry rather than an edit.

## If `{{ $value }}` reads exactly 500

Then you are looking at a wallet older than micro-org#326, and **the number is
not the backlog**. The gauge was `(await pendingCredits(db, 500)).length` — a
capped page — so it saturated at 500 and reported the same value for a backlog of
five hundred and one of fifty thousand. The condition is still real; the size is
not. Get the real number from the query in step 2, which never had a limit.
