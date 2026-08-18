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

## The first time: the measured state, 2026-08-09 ~23:55Z

Both of this runbook's occurrences carry the date 2026-08-10 and they are hours
apart, so the times matter. This one is the day it was written, before any
backup had ever succeeded anywhere. The first successful set finished at
2026-08-10T00:17:30Z, twenty-two minutes after the commit.

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

## The second time: 2026-08-10T10:36Z to 2026-08-12T02:50Z (micro-org#434)

The rule fired again at **2026-08-10T10:36:21Z**, fourteen minutes after the app
stack was cut over from the chain host to the Windows/WSL host, and went on
firing correctly for **43 hours**. Nothing in the alerting plane was broken. The
estate had no backup and the only thing saying so was this ticket, unread.

Read that as the honest lesson: every fix below works, and none of them helps if
the alert is the only thing that knows. `scripts/estate-verify.sh` now asserts
the runner is up, scraped, fresh and verified, at the end of every deploy — the
one moment somebody is definitely looking. It is the same fact, said where it
gets read.

What actually happened is state 1 below, arrived at a new way: the runner was
**deployed and working** on the old host, and the migration moved everything a
deploy renders. `compose/docker-compose.backup.yml` is named by no release
manifest and composed by no script, so it was the one container left behind. Its
destination and miner-keys paths were compose defaults pointing at the OLD host,
which is why they are now required variables in `compose/mainnet.env` and
`compose/testnet.env` with no defaults at all.

Two things that closing it did not fix, both worth knowing before you trust the
green:

- **The six historical sets stayed behind on the chain host** and were relayed
  across afterwards. All eight sets now in `/home/savvaniss/cloudsforge-backups`
  were re-checked artefact by artefact against their own `MANIFEST.json`
  checksums on 2026-08-12 — 264 of 264 matching, zero failures — so the copy is
  proven and not assumed. If you move hosts again, move this directory *before*
  you conclude the migration is done.
- **The backups now share a machine with the data they protect.** The old layout
  had them on a different physical machine for free; this one does not. That is
  knowingly temporary and it is micro-org#338 **§6**, the section on the backup
  runner and its destination disk. (Not that issue's sixth summary bullet, which
  is the EMBER miner — the two are easy to confuse.) Until it is closed, read
  `backup_last_success_unixtime` as protection against deletion and corruption,
  and not against losing the host.

## Establish which of the three states you are in first

They have nothing in common except the empty vector, and two of them are not
about backups at all.

1. **No runner.** `docker ps -a --filter name=backup-runner` is empty. The
   container has never existed, or it existed and was removed — or, as in
   micro-org#434, the estate moved host and this one overlay did not come with
   it. This is a deploy gap, not a failure.

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
  up -d --no-deps backup-runner
```

Both `--env-file` flags, always. `--env-file` REPLACES the default rather than
adding to it, which is the defect micro-org#158 was: one file alone loses either
every service credential or the estate's public hostnames, and both fail
silently. And never omit the trailing service name — a bare `up -d` against these
files re-creates the whole estate.

`--no-deps` for a related reason. The overlay declares `depends_on: postgres`,
and without the flag compose reconciles the RUNNING postgres against what this
checkout says — which is not what the estate deployed, because
`release-deploy.sh` renders a pinned overlay that is not on this command line.
The flag is the difference between starting one container and recreating the
estate's database.

Three variables have **no default** and the overlay refuses to interpolate
without them. That is deliberate in each case, and two of the three are
micro-org#434:

- `CF_BACKUP_ENVIRONMENT` — one half of the cross-environment restore refusal.
- `CF_BACKUP_DESTINATION` — where the sets are written. It defaulted to
  `/home/malf/cloudsforge-backups`, a path on the CHAIN host, and stayed correct
  only until the estate stopped running there.
- `CF_MINER_KEYS` — same story, sharper edge: the two hosts do not hold the same
  miner-key files, so a default that silently resolved to an absent one would
  read as "backed up" to anybody who did not go looking.

A default is a guess about which host this is, and this container writes the
estate's only recovery point. All three answers live in `compose/mainnet.env`
and `compose/testnet.env`, tracked, where a host migration has to walk past them.

### The three ways it will refuse to start, all of them correct

The runner would rather not exist than produce a backup that cannot be restored
from, so read a refusal as the design working.

- **A custody keyring in its environment.** It exits before it has a logger, and
  names the variable rather than the value. Do not add an `env_file` to make the
  keyring available; the vault and the keyring on one medium is a plaintext key
  store with extra steps.
- **An implausible destination.** It writes a canary and checks the filesystem
  size, because a bind of a path the daemon cannot see does not fail — the
  container gets an empty directory in its own ephemeral layer, every write
  "succeeds", pg_dump exits 0, the checksums are correct and `backup_runs` says
  `succeeded`. Nothing in the runner would notice; the canary is what does.

  The mechanism worth knowing is snap confinement, and it is **not** the current
  host's: the OLD estate host ran the canonical snap docker, whose confinement
  grants `docker:home` but not `removable-media`, so binds outside `$HOME` were
  swallowed. That is why the destination was under `/home/...` there and is under
  `/home/savvaniss/...` here. Keep it inside the deploy user's home on any snap
  host; on this one (Docker Desktop 29.1.2) the constraint does not apply and the
  canary is still the check.
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

   That gauge is seeded at boot from the catalogue, exactly as
   `backup_last_success_unixtime` is above, and for a reason worth keeping: until
   2026-08-18 it was written **only** on the verify path, so every restart erased
   the estate's whole record of restore-provenness until the next 03:00 verify —
   up to fifteen hours after a midday deploy. A host reboot that day made the case
   concrete: sets verified every night from 08-14 to 08-18, `backup.verify` armed
   for the next night and not dead, and the gauge absent anyway, which read as a
   dead-lettered job. An absent one now carries its real meaning — either nothing
   has EVER been verified, or `backup.verify` is dead-lettered. Tell them apart
   with `select verified_at from backup_runs where verified_at is not null order
   by verified_at desc limit 1` and the `dead` flag on the `backup.verify` row in
   `jobs`.
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
