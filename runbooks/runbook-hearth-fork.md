# Hearth nodes disagree

**Triggered by** `ChainHeightSpreadSustained - beacon_chain_height_spread > 3 for 15m`
**Severity** SEV2 - page · **Owner** chain

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
