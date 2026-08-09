# Hearth nodes disagree

**Triggered by** nothing. **No alert can reach this page today** — see below.
**Severity** SEV2 · **Owner** chain

## Nothing pages you into this runbook, and that is deliberate (2026-08-10)

`ChainHeightSpreadSustained - beacon_chain_height_spread > 3 for 15m` used to,
and it was retired because it could not fire on any day of its life:
`beacon_chain_height_spread` is registered by nothing, so the expression always
evaluated over an empty vector. Writing the metric would not have helped either.
A spread is max height minus min height across nodes, and **exactly one Hearth
full node runs in this estate** (`cf-hearth-seed`); one node's spread is 0 by
construction, forever, whatever the chain is doing. The rule is gone rather than
green so that the alert list stops claiming forks are covered.

The procedure below is kept because a fork is still a real incident with a real
response. What changed is only how you arrive here: **by hand.** Today a fork is
noticed by a deposit that will not confirm, by `beacon_conformance_vectors`
showing a consensus-rule divergence, or by an operator comparing block hashes
after something else looked wrong.

Restore the alert when — and only when — there are at least two Hearth full
nodes per network **and** beacon registers the gauge over them. Two nodes with
no metric is the retired rule again; one node with a metric is worse, because it
reports agreement it never checked.

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
