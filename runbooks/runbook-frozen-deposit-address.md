# A deposit address is frozen

**Triggered by** `DepositAddressFrozen - wallet_deposit_address_frozen > 0`
**Severity** SEV3 - ticket · **Owner** wallet

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
