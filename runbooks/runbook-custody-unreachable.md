# Custody is unreachable

**Triggered by** `CustodyUnreachable - up{job="custody"} == 0 for 2m`
**Severity** SEV1 - page · **Owner** security

## What it means

Signing is unavailable. Custody is **permanently single-replica** (AD-18) and
that is accepted, written down rather than discovered - one container per
address, which blocks any multi-host move.

## The correct degradation

- Deposits still land. Nothing about receiving needs custody.
- Withdrawals and sweeps **queue**. They must not fail.
- That degradation belongs on the public status page, not in a user's inbox three
  hours later. Post it.

## Checks

1. Is the process down, or is it the per-address containers? Custody's
   container-per-address model hits host limits before anything else does -
   `custody_addresses_total` is a capacity panel, not a business one.
2. Is the encrypted volume mounted and decryptable?
3. Is the master secret present in the environment? It is deliberately excluded
   from backups; a restored host will not have it.
4. Confirm the queue is queuing, not failing: `settlement_sweep_pending` should
   climb, `jobs_dead_total` should not.

## Do not

Do not attempt key recovery to work around an outage. Break-glass needs two
operators, a signed incident record and a hardware-token challenge each, and it
is not a workaround for a restart.
