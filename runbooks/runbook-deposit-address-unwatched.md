# Deposit addresses the indexer is not watching

**Triggered by** `DepositAddressUnwatched - wallet_deposit_addresses_unwatched - wallet_deposit_addresses_unobservable > 0 for 30m`
**Severity** SEV3 - ticket · **Owner** wallet

## What it means

Addresses have been handed to users and the indexer has not been told to watch
them. **An unwatched deposit address produces no deposit events**, so money sent
to one is on the chain, is not seen, and is credited to nobody until somebody
notices — which, without this alert, is when the user complains.

It is a ticket and not a page because it is a backlog and not a stop: the money
is not lost, the addresses are recoverable, and crediting resumes for every past
deposit once the address is registered and the indexer backfills it. It becomes
urgent by volume, not by nature.

## Read both gauges, never just the first

```
wallet_deposit_addresses_unwatched{chain}     the backlog
wallet_deposit_addresses_unobservable{chain}  of those, how many are on a chain
                                              the indexer follows no source for
```

The subtraction in the expression is the whole rule. An address on a chain
nobody follows is an **owner's decision**, not a defect — today the estate runs
`INDEXER_CHAINS=ember:mainnet`, so seven of the eight chains wallet derives
addresses for are legitimately unobservable and always will be until someone
gives the indexer a provider. Alerting on those would fire continuously, get
silenced, and take the real signal with it.

So a firing series means: **addresses on a chain the indexer DOES follow, still
unregistered after thirty minutes.** `deposit.watch` runs every 30 seconds, so
that is about sixty failed attempts. It is not a queue draining slowly.

Two companion gauges answer "why is this chain unobservable", and they must be
read in this order:

```
wallet_chain_observability_unknown{chain}   1 = we could not ask
wallet_chain_observable{chain}              0/1 = the answer, if we could ask
```

A `0` on `observable` while `observability_unknown` is `1` does **not** mean the
chain is unfollowed. It means the indexer did not answer. The two have opposite
repairs, and a gauge cannot say *unknown*, which is why the never-answered fact
has its own series.

## Diagnose in this order

1. **Is it one chain or all of them?** `wallet_deposit_addresses_unwatched` by
   `chain`. All chains at once is the indexer client, not the addresses.

2. **Is the indexer answering wallet at all?** Check
   `wallet_chain_observability_unknown` — a 1 anywhere means wallet could not
   ask, and that is the finding. `HttpClient` opens its circuit breaker **per
   client, not per route**, so one route failing repeatedly takes down every
   question wallet asks the indexer, including the observability gate on the
   deposit path itself. That gate fails closed, so a wedged client **refuses
   good deposits on a healthy chain**. This has happened: eleven assignments on
   chains `watched_addresses_chain_ck` does not admit made `POST /v1/watch/...`
   answer 500 every thirty seconds, the circuit stayed open, and EMBER deposits
   were refused as collateral damage. The job now skips an unobservable chain
   rather than retrying it, which is what stops that recurring — if you are
   seeing it again, that skip is what to check first.

3. **Is `deposit.watch` running?** It is a `stream` job on the wallet runner.
   A dead or unleased runner shows here as a backlog that only grows. Check
   `jobs_*` for `deposit.watch` and `JobQueueOverdue` beside this alert.

4. **Is registration failing per address?** `deposit address registration
   failed` in wallet's logs, with `assignmentId` and `chain`. The job logs and
   leaves the row rather than throwing, so the batch continues and the next pass
   retries — a persistent per-address failure is visible here and nowhere else.

## Fixing it

- **Indexer follows no source for the chain** — that is the answer, not the
  fault, and the backlog is `unobservable`. Giving the indexer a provider is the
  same action that reopens deposits for that chain; both happen together.
- **The chain is followed and registration 500s** — check
  `watched_addresses_chain_ck` in the indexer admits that chain. A chain custody
  derives addresses for and the indexer refuses to watch is a schema mismatch
  between two services, and it is the shape that caused the collateral outage
  above.
- **The runner is not running the job** — that is `runbook-lease-expiry-storm.md`
  and `runbook-dead-letter-drain.md`'s territory, not this one.

There is no manual sweep step here and no dual approval. Registration is
idempotent and touches no money; it only makes future and past deposits visible.

## What this replaced, and why the old runbook is gone

This alert was `DepositAddressFrozen` on `wallet_deposit_address_frozen > 0`,
with `runbook-frozen-deposit-address.md` behind it. **That state does not exist
in this estate and cannot arise.** `deposit_address_assignments_status_ck` admits
exactly `active`, `rotated` and `retired`; `frozen` in micro-wallet means
"cannot send, can still receive", which is the opposite of a crediting stop.

The frozen-address condition was **forge-pay's**, and micro-wallet exists to
close it: the address row carried its own high-water mark, a rotation left the
old mark behind, every probe read a regression, and crediting stopped for ever.
The retired runbook's step 2 was "compare against the address's high-water mark".
micro-wallet has no high-water mark — a rotation is a new row, and credits key on
`(chain, network, txHash, logIndex)`. It was deleted rather than kept, because a
procedure for a state that cannot occur costs an operator time in the one moment
they have none. It is in git history at the commit that removed it.
