# Nothing has ever backed this estate up

**Triggered by** `BackupNeverRun - absent(backup_last_success_unixtime) for 30m`
**Severity** SEV3 - ticket · **Owner** platform

## What it means

There is no series saying when a backup last succeeded. Not an old one — none.

The page this pairs with, `BackupAgeExceeded`, reads
`time() - backup_last_success_unixtime > 129600`. Subtraction needs something to
subtract, so with no series it produces an empty vector, and an empty vector
never crosses a threshold. The sev2 page on the estate's recovery point is
therefore green in exactly the state it exists to catch. This rule is what makes
that state say something.

The ledger's stated RPO is zero. Read this alert as "the RPO is currently
unbounded", because that is what it measures.

## The measured state, 2026-08-10

Against the mainnet Prometheus and the deploy host, not assumed:

| Question | Answer |
| --- | --- |
| Metric names in the estate containing `backup` | 0, of 1,329 |
| `backup-runner` in `docker ps -a` | absent |
| Contents of the backup destination | `.` and `..` |
| Rows in `backup_runs` with `state = 'succeeded'` | none |

So on the day this runbook was written the answer to every question below was
"the runner has never been started". If that is still true, skip to *Starting the
runner*.

## Establish which of the three states you are in first

They have nothing in common except the empty vector, and two of them are not
about backups at all.

1. **No runner.** `docker ps -a --filter name=backup-runner` is empty. The
   container has never existed, or it existed and was removed. This is a deploy
   gap, not a failure.

2. **A runner nobody scrapes.** The container is up and
   `up{job="backup-runner"} == 0`. Check that first — from inside the Prometheus
   container, `wget -qO- http://backup-runner:4130/metrics`. Prometheus joins the
   estate network as an external network, so a name that does not resolve means
   the runner is in a different compose project rather than that it is down.

   This state was the estate's for the whole life of the rule and is worth
   knowing why: `backup-runner` is defined only in
   `compose/docker-compose.backup.yml`, is built rather than pinned to a digest,
   and is named by no release manifest — so `render-prometheus-targets.py`, which
   walks the manifest, cannot emit a target for it however healthy it is. It has
   a static job in `prometheus/prometheus.yml` for that reason. If somebody
   deletes that job because "the target list is generated", this alert comes
   back and the page above goes quietly green again.

3. **A runner that has never succeeded.** The container is up, it is scraped, and
   the gauge is still absent. That is the interesting case, and it means the
   catalogue has no succeeded row either — the gauge is seeded at boot from
   `backup_runs.finished_at`, so a runner that has ever completed a set publishes
   a value within seconds of starting. Go to *When runs are failing*.

## Starting the runner

It is **not** part of a release deploy. `scripts/release-deploy.sh` renders
`docker-compose.estate.yml` plus the pinned release overlay and nothing else, so
it neither starts this container nor stops it.

Bring it up with the same env-file set the deploy uses, and **name the service**:

```sh
docker compose -p cloudsforge-estate \
  --env-file compose/mainnet.env --env-file compose/estate/tokens.env \
  -f compose/docker-compose.estate.yml \
  -f compose/docker-compose.backup.yml \
  up -d backup-runner
```

Both `--env-file` flags, always. `--env-file` REPLACES the default rather than
adding to it, which is the defect micro-org#158 was: one file alone loses either
every service credential or the estate's public hostnames, and both fail
silently. And never omit the trailing service name — a bare `up -d` against these
files re-creates the whole estate.

`CF_BACKUP_ENVIRONMENT` has no default and the overlay refuses to interpolate
without it. That is deliberate: it is one half of the cross-environment restore
refusal and must never be guessed.

### The three ways it will refuse to start, all of them correct

The runner would rather not exist than produce a backup that cannot be restored
from, so read a refusal as the design working.

- **A custody keyring in its environment.** It exits before it has a logger, and
  names the variable rather than the value. Do not add an `env_file` to make the
  keyring available; the vault and the keyring on one medium is a plaintext key
  store with extra steps.
- **An implausible destination.** It writes a canary and checks the filesystem
  size. Docker here is the canonical snap and cannot see `/data` at all, so a
  bind of a path it cannot see silently becomes an ephemeral directory in which
  every write succeeds and nothing survives the container. The destination is
  `/home/malf/cloudsforge-backups` — the same bytes, reached through a path the
  daemon can see.
- **A `pg_dump` that does not match the server.** A version-skewed client does
  not produce worse backups; it produces files that look like backups and cannot
  be restored.

## When runs are failing

`backup_runs` is the record and it is more useful than the logs:

```sql
select id, kind, state, queued_at, finished_at, left(error, 200)
  from backup_runs
 where environment = 'mainnet'
 order by queued_at desc
 limit 20;
```

Rows sitting at `queued` with no `running` among them means nothing is claiming —
the runner is down or was never started, and the queue is behaving correctly by
holding the work. Rows at `failed` carry the reason in `error`, already stripped
of any DSN a Postgres tool echoed.

The failure most worth recognising is the vault cross-check: a run refuses when
the custody tarball holds fewer blobs than `custody_keys + custody_seeds` has
rows. It is not a tolerance and it must not be relaxed. An empty or partial vault
mount produces a valid checksum, a plausible size and a green row, and nothing is
red until somebody tries to recover a customer's coins from it.

## Clearing it properly

One hand-run backup makes this alert stop, which is exactly the wrong outcome if
it is treated as the fix: the gauge then holds a value, `BackupAgeExceeded` takes
over, and in 36 hours it pages — correctly — on an estate that still has no
scheduled backups.

The real close is three things, and the alert only proves the first:

1. The runner is deployed and claiming, so `backup.run` recurs on its own
   schedule. `backup_settings.schedule_enabled` must be true; a disabled schedule
   re-enqueues but skips, which is honest and is still no backup.
2. A restore has proven a set. `backup_last_verified_unixtime` is the gauge for
   that, `backup_runs.verified_at` is the row, and until one is stamped every set
   is a hypothesis. A backup nobody has restored is a wish.
3. The `age` identity that decrypts the miner coinbase key exists somewhere that
   is not this host, and somebody has read the paper copy recently enough to know
   it is legible.

`runbook-restore-from-backup.md` is the other half of this — what to do once
there is something to restore, and what the RPO and RTO targets are.

## What this alert is not

- **Not `BackupAgeExceeded`.** That one means a backup exists and is stale. This
  one means no backup has ever been recorded. They are mutually exclusive by
  construction — one needs the series present, the other needs it absent — and
  Alertmanager's page-suppresses-ticket rule keys on `alertname` as well as
  `service`, so neither hides the other.
- **Not a reason to publish a zero for the gauge.** The runner deliberately emits
  no sample until a run has succeeded. `backup_last_success_unixtime 0` would be
  a series claiming the last backup finished in 1970 — an age of fifty-six years,
  which satisfies any staleness threshold anyone would write and therefore reads
  as a backup that once happened. None has.
- **Not a page.** Every fix for it is a daylight change: deploy a container,
  correct a scrape config, read a failed run. A page nobody can act on at three
  in the morning is how an on-call learns to silence a group, and the group this
  would be silenced with holds the money pages.
