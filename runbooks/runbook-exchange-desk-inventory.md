# The exchange desk is out of stock

**Triggered by** `ExchangeDeskInventoryLow - wallet_desk_inventory at or below a tenth of its 30d peak for 30m`
**and by** `ExchangeDeskInventoryShort - increase(wallet_money_operations_total{route="conversion",outcome="desk_short"}[1h]) > 0`
**Severity** SEV3 (Low) / SEV2 (Short) - ticket · **Owner** wallet

## What it means

Forge Exchange does not match one user against another. A conversion is filled
out of the platform's own stock — an `exchange`/`inventory` account per asset in
the ledger, **funded by hand**. When it runs out, every conversion into that
asset is refused with a 409 that deliberately does not say why, and the desk
cannot refill itself.

The two rules are the same fact at two different times:

```
desk funded ─→ conversions fill ─→ inventory falls ─→ EMPTY ─→ user refused
                                   └ ...Low                    └ ...Short
```

`ExchangeDeskInventoryLow` is the one you want to be woken by. It reads the
gauge, so it fires before anybody is turned away.
`ExchangeDeskInventoryShort` reads the refusal counter, so by the time it
fires somebody has already been refused — but it is not redundant, and it is not
a weaker version of the first. **It is the only rule that can see an asset the
desk holds no account in at all.** No account means no balance row, means no
series, means `wallet_desk_inventory` cannot fall below anything for that asset
and the silence is indistinguishable from health.

Neither is a page. Nothing is broken and nothing is lost: the shortfall is
checked inside the ledger transaction that would post the conversion, with the
balance row locked, so a refused conversion leaves no partial state. What is
happening is that a product has stopped working, and only a person can restart
it.

## Step 1 — what is in the desk

The gauge is in **whole units** (`28432.78`, not wei) and is published only for
assets that have an account. The authoritative read is the admin route:

```sh
curl -sS -H "Authorization: Bearer $ADMIN_BEARER" \
  https://api.cloudsforge.online/wallet/v1/admin/exchange-desk | jq
```

`requireAdmin`, so a service token will not do — every service principal is
refused on this route whatever scopes it holds. Log in as the operator to get a
bearer.

If the gateway is not answering, read the ledger directly. This is the same
number the route computes:

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d ledger -c \
  "select a.asset_code, b.amount
     from accounts a join balances b on b.account_id = a.id
    where a.subject = 'exchange' and a.purpose = 'inventory'
    order by a.asset_code;"
```

`amount` there is in **smallest units** — EMBER has 18 decimals, LTC 8, SHARD 0.
The gauge and the route both convert; this query does not.

**An asset that returns no row is the case the second rule exists for.** The
desk was never funded in it, so it has never been able to fill a conversion into
it, and no gauge will ever say so.

## Step 2 — is it draining, or was it never funded

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d ledger -c \
  "select e.kind, e.occurred_at, e.actor, p.direction, p.amount
     from postings p
     join accounts a on a.id = p.account_id
     join journal_entries e on e.id = p.entry_id
    where a.subject = 'exchange' and a.purpose = 'inventory'
    order by e.occurred_at desc limit 20;"
```

- **`liquidity_seed` rows only** — the desk has been funded and never traded
  out of. If the alert is firing, the funding itself was small, or somebody drew
  it back out (`direction` tells you which way).
- **`conversion` rows draining it steadily** — the product is working and the
  desk is sized too small for the demand it is now getting. Fund it, and read
  step 4 before choosing the number.
- **No rows at all** — never funded. Go to step 3.

Rate, if you need to argue about sizing:

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d ledger -c \
  "select occurred_at::date, count(*) from journal_entries
    where kind = 'conversion' group by 1 order by 1 desc limit 14;"
```

## Step 3 — fund it

One route, `requireAdmin`, and it is reversible by the same route with
`direction: "out"`:

```sh
curl -sS -X POST https://api.cloudsforge.online/wallet/v1/admin/exchange-desk/funding \
  -H "Authorization: Bearer $ADMIN_BEARER" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: desk-topup-$(date +%Y%m%d)-1" \
  --data-binary @- <<'JSON'
{
  "sourceAccount": "platform",
  "assetCode": "EMBER",
  "amount": "10000000000000000000000",
  "reason": "topping up the EMBER desk after ExchangeDeskInventoryLow",
  "direction": "in"
}
JSON
```

`amount` is a string of **smallest units**. `reason` is required and is written
into the journal entry — write the one a person reading the ledger in a year
would need, not "topup".

`sourceAccount` is `"platform"` or `"user:<uuid>"`, and the choice is the whole
decision:

- **`platform`** debits the platform's own treasury equity account in that
  asset. This is what you want. Equity is not overdraft-exempt, so a treasury
  that has never held the asset cannot seed a desk in it — that refusal is
  correct, and it means a cold estate has to get the asset into the treasury
  first.
- **`user:<uuid>`** debits **a real person's available balance.** Both fundings
  this estate has ever booked did this, from the two miner accounts, and both
  were the operator moving their own coins. Do not do it with anybody else's.
  There is no consent step on this route; the gate is that a human being has to
  press it, which is exactly why `fundDesk` is not automated and will not be.

A typo in `sourceAccount` is refused with `unknown_source` (422) rather than
silently opening an account nobody can spend out of.

## Step 4 — how much

There is no target in the code, deliberately, and this alert does not invent
one. It fires at a tenth of **whatever the desk last held**, which is the last
decision somebody made, not a recommendation.

Size it against step 2's conversion rate and against what the platform can
afford to have sitting in a desk rather than in the treasury. Both numbers are
real; neither is in this repository.

**Do not fund it "enough that the alert stops".** The threshold is relative:
funding to just above a tenth of the old peak clears the alert and leaves the
desk in exactly the state that produced it, and the 30-day window means the old
peak is still in scope for a month.

## Why this cannot be automated

Every question on this page ends at a person:

- The desk is refilled from the treasury or from a user's balance. A service
  principal able to call `fundDesk` is a machine that can debit a user without
  that user's session, which is strictly worse than the human gate.
- How much the desk should hold is a business decision. Nothing in this service
  holds it, and a hard-coded number would be wrong for every asset but one.
- The refusal is already safe. A dry desk costs conversions; it does not cost
  anybody money, and it is not an outage that has to be resolved before somebody
  wakes up.

`requireAdmin` on both routes is therefore the design and not an omission.
micro-org#501 is where that was decided and what these two rules were added
against.

## What you cannot learn from the alert

`ExchangeDeskInventoryShort` **does not carry the asset**, on purpose. Which
asset the platform's book is short in is a trading signal — it is what somebody
would need in order to size an order against the desk — and it is precisely what
the user-facing 409 withholds. `/metrics` is bound to loopback with no gateway
route today, but a Prometheus series outlives the deployment decision that made
it safe. Read the asset off `wallet_desk_inventory` or off the admin route in
step 1; both are gated.

If wallet is ever given a public route, `wallet_desk_inventory` moves or that
route excludes `/metrics`. The same sentence is in `money.ts` beside the sampler.
