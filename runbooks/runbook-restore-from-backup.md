# Restore from backup

**Triggered by** `BackupAgeExceeded - time() - backup_last_success_unixtime > 129600 (36h); and the quarterly drill`
**Severity** SEV2 for the alert; scheduled for the drill · **Owner** platform

## The alert is on AGE, not on failure

A backup job that silently stops firing produces no failure to alert on. If
`backup_last_success_unixtime` is stale, the first question is whether the job
ran at all - not whether it errored.

The metric was `backup_last_success_timestamp_seconds` in this runbook and in
the rule until 2026-08-10, and nothing had ever exported it (micro-org#310). The
gauge that exists is `backup_last_success_unixtime`, published by the backup
runner and seeded at boot from `backup_runs`.

## NONE OF THE BELOW EXISTS YET, AND SAYING SO IS THE POINT

Measured on the estate host on 2026-08-05, not assumed: `crontab -l` reports no
crontab for the operating user, `systemctl list-timers` lists no backup unit,
and `lsblk` shows one 447G root disk carrying every Docker volume. There is no
snapshot, no WAL archive, no off-host copy, and **no restore has ever been
performed**. The `BackupAgeExceeded` alert this runbook is triggered by has
nothing to fire on because nothing has ever succeeded.

Still true on 2026-08-10, and now stated by an alert rather than by a paragraph:
`deploy/backup` is built and `compose/docker-compose.backup.yml` is a complete
overlay, but no `backup-runner` container has ever been started and the
destination directory is empty. `BackupNeverRun` is the rule that says so, and
`runbook-backup-never-run.md` is what to do about it. **Read that one first if
this alert is not firing** — an absent series cannot page, so silence here is not
evidence of a backup.

Everything from here down is the TARGET. Read it as the design, and read the
paragraph above as the state. A runbook that describes a regime the estate does
not have is worse than no runbook: it is a false answer to "are we covered".

## Two things are needed and either alone is useless

Custody restores require **both** the volume holding the encrypted blobs and the
master-secret keyring, and the keyring is deliberately excluded from any backup
of that volume. A snapshot without the keyring is noise; the keyring without the
snapshot restores nothing.

Where the keyring actually is, how to copy it and how to rehearse getting it
back is `runbook-custody-master-secret.md`. It is a separate runbook because it
is the half that is doable today with no infrastructure at all.

**The custody restore itself — the backup commands, the restore commands, the
verification that proves a restored keyring actually decrypts, and the rehearsal
transcript — is `../docs/custody-backup-restore.md`.** Unlike the rest of this
runbook, that procedure has been executed: a throwaway custody was destroyed and
recovered from cold artefacts alone, and the same document was then used to
perform a live key rotation.

## RPO and RTO — the target, not the state

| Service | RPO | RTO | Method |
| --- | --- | --- | --- |
| `ledger` | 0 | 30 min | WAL archiving off-host, plus PITR |
| `custody` | 0 | 1 h | Volume snapshot, plus the separately-held master-secret keyring |
| `wallet`, `settlement`, `billing`, `identity` | 5 min | 1 h | WAL archiving, plus PITR |
| `indexer` | 24 h | 4 h | Nightly dump. **Rebuildable from chain** - the RPO is a convenience |
| Prometheus / Tempo / Loki | 24 h | best-effort | Not backed up. Losing a week of traces is not a business event |

## Verify, every time

Restore into an isolated environment and check four things: identity can mint a
token; the ledger's trial balance is 0; custody can decrypt one known address
using the separately-held keyring; the indexer resumes from its checkpoint.

Record the wall-clock time against the RTO. **A drill that exceeds its RTO
changes the RTO or changes the method - it is never just noted.**

A copy on the same disk as the original is not a backup, and a backup nobody has
restored is a hypothesis.
