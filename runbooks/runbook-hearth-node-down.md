# A Hearth node is down or isolated

**Triggered by** `beacon_chain_peers == 0, or HearthConformanceVectorsFailing`
**Severity** SEV3 - ticket · **Owner** chain

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
