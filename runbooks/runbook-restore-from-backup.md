# Restore from backup

**Triggered by** `BackupAgeExceeded - no successful backup in 36h; and the quarterly drill`
**Severity** SEV2 for the alert; scheduled for the drill · **Owner** platform

## The alert is on AGE, not on failure

A backup job that silently stops firing produces no failure to alert on. If
`backup_last_success_timestamp_seconds` is stale, the first question is whether
the job ran at all - not whether it errored.

## Two things are needed and either alone is useless

Custody restores require **both** the encrypted volume snapshot and the master
secret, which is deliberately excluded from every backup and lives in a password
manager or KMS. A snapshot without the secret is noise.

## RPO and RTO

| Service | RPO | RTO | Method |
| --- | --- | --- | --- |
| `ledger` | 0 | 30 min | WAL archiving off-host, plus PITR |
| `custody` | 0 | 1 h | Encrypted volume snapshot, plus the separately-held master secret |
| `wallet`, `settlement`, `billing`, `identity` | 5 min | 1 h | WAL archiving, plus PITR |
| `indexer` | 24 h | 4 h | Nightly dump. **Rebuildable from chain** - the RPO is a convenience |
| Prometheus / Tempo / Loki | 24 h | best-effort | Not backed up. Losing a week of traces is not a business event |

## Verify, every time

Restore into an isolated environment and check four things: identity can mint a
token; the ledger's trial balance is 0; custody can decrypt one known address
using the separately-held master secret; the indexer resumes from its checkpoint.

Record the wall-clock time against the RTO. **A drill that exceeds its RTO
changes the RTO or changes the method - it is never just noted.**

A copy on the same disk as the original is not a backup, and a backup nobody has
restored is a hypothesis.
