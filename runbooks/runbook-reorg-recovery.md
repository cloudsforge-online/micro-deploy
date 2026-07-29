# Chain reorganisation beyond the policy depth

**Triggered by** `indexer_reorg_depth past the configured depth`
**Severity** SEV2 · **Owner** indexer

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
