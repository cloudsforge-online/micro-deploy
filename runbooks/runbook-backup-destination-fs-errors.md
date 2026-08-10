# ext4 has recorded an error on the disk that holds every backup

**Triggered by** `BackupDestinationFilesystemErrors - backup_destination_fs_errors > 0 for 5m`
**Severity** SEV2 - page · **Owner** platform

## What it means

The filesystem the backup runner writes to has told the kernel it could not
complete something. `backup_destination_fs_errors` is ext4's own `errors_count`,
read out of the **superblock** — so it survived the last reboot, it survives a
remount, and it does not reset when the container restarts. It only ever rises.

It is not a disk-health metric. It is the *absence* of one, wearing the only
shape that was available.

## Why this metric exists at all, and what it cannot tell you

`/dev/sdb` — 3.6 TB, mounted at `/data`, and as of 2026-08-10 the estate's only
backup destination — is a **MARVELL 88SE9230 virtual disk**. It has no SMART:

```
$ sudo smartctl -H /dev/sdb
SMART support is: Unavailable - device lacks SMART capability.
```

That is settled, not open. The controller is bound to **`ahci`**, not to a RAID
driver — `/sys/class/scsi_host/host2/proc_name` is `ahci`, `lsmod` shows no
`mv*` and no `megaraid_sas` — so the card assembles its array in **firmware** and
hands the kernel one ordinary SATA device. The member disks are not devices Linux
has ever seen. **There is no `-d` type that can work and none should be tried;**
`-d megaraid,0` did not fail because it was mistuned, it failed because
`/dev/megaraid_sas_ioctl_node` belongs to a driver this card will never load. The
only routes to member health are Marvell's own `mvcli`, which is in no Ubuntu
archive, or reflashing the controller to AHCI mode, which destroys the array and
every backup on it. `/dev/sda`, the root disk, *does* report SMART and reads
PASSED — the contrast is the point.

So for this disk, **reallocated sectors, pending sectors, power-on hours and the
overall assessment are permanently unknown**, and so is whether the array is
redundant or striped. In the striped case one member failure loses all 4 TB.

What is left is ext4's own counter, and its limits have to be stated or this
alert will be over-read in both directions:

- It counts errors **ext4 itself** detects — I/O and metadata errors it handles.
  A read error on file *data*, returned straight to the caller, is not one.
- It **predicts nothing**. A disk days from failure reads zero here until the
  first failure. SMART's value was prediction and that value is genuinely lost.
  This is a smoke alarm, not a thermometer.
- A non-zero count does **not** mean "a disk is dying". On a firmware array the
  member is invisible; all this says is that ext4 was handed something it could
  not complete. That could be a member, the controller, a cable, or the firmware.

It is still strictly more than the estate had before it, which was nothing.

## First: is the data still readable?

Before anything about hardware. The question this alert actually raises is
whether the backups on that volume can still be restored from, and the runner
will write another set onto the same volume tonight.

1. **Read the counter and its timestamps yourself.** World-readable, no root:

   ```sh
   for f in errors_count first_error_time last_error_time \
            first_error_func last_error_func first_error_block last_error_block; do
     printf '%s: %s\n' "$f" "$(cat /sys/fs/ext4/sdb1/$f)"
   done
   ```

   `*_error_time` are unix seconds. `first` far in the past with `last` recent
   means a filesystem that has been unhappy for a while and nobody was watching —
   which was the state this alert was built to end. `*_error_func` names the ext4
   function, and is the one field that distinguishes a metadata problem from a
   data one.

2. **Check the kernel log for what the block layer saw.** ext4's counter is a
   summary; `dmesg` has the I/O errors underneath it.

   ```sh
   sudo dmesg -T | grep -iE 'sdb|ext4|I/O error|EXT4-fs error' | tail -50
   ```

3. **Verify a backup set rather than assuming.** The manifest carries a SHA-256
   per artefact, so this is a real answer and not a hopeful one — see
   `runbooks/runbook-restore-from-backup.md` for the restore-side drill.
   `backup_last_verified_unixtime` and `backup_runs.verified_at` record when one
   was last proven.

4. **Do not run `fsck` on a mounted filesystem.** It will report garbage and can
   make a recoverable filesystem unrecoverable. `tune2fs -l /dev/sdb1` is safe
   while mounted and shows `Filesystem state:` — `clean` or
   `clean with errors`. An unmount of `/data` also takes the chain data with it
   (`/data/chains` holds the Bitcoin, Litecoin and Dogecoin block stores), so an
   offline `e2fsck` is a scheduled maintenance window, not a first response.

## Then: stop making it worse

If step 1–3 say the sets are damaged or the errors are recent and climbing:

- **Do not let the nightly run overwrite the good sets.** Retention prunes the
  oldest, so the fastest way to lose the last readable backup is to let two more
  runs succeed onto a failing volume. `backup_settings.schedule_enabled = false`
  pauses the schedule honestly — it still enqueues and skips, which shows in
  `backup_runs`.
- **Get a copy off this host.** This is the remedy that does not depend on the
  disk being sound, and it is the one thing micro-org#207 asks for that no metric
  can supply. Note that `/data2` is `sdb2` — the **same physical device** — so a
  second copy there buys nothing at all against this failure.

## Clearing it

The counter does not decrement. `tune2fs -f -e ...` and an offline `e2fsck -f`
are what reset it, and both are a maintenance window on a filesystem that also
holds the chain. **Do not clear it to silence the alert** — the reset is part of
a repair that has been decided on, not a step in triage. Until then, silence the
alert in Alertmanager with an expiry and a link to the incident, so the silence
lapses rather than becoming permanent.

Once the filesystem has been repaired and remounted, the gauge follows on the
next scrape: it is read from `/sys` at scrape time and nothing is cached.

## What this alert is not

- **Not a SMART substitute.** Nothing here reports the array level, member
  health, or how close the disk is to failing. Those are still unknown and
  micro-org#207 stays open on them.
- **Not a claim that the counter is zero when the series is missing.** The runner
  publishes **no sample** when the counter cannot be read, because a zero is a
  claim ext4 has not made. The two states that produce an absent series are
  already covered elsewhere: a runner nobody scrapes fires `BackupNeverRun`, and
  a destination that is not the real backup disk stops the runner from booting at
  all (`src/disk.ts` writes a canary and checks the filesystem size, because
  snap-packaged Docker turns a bind it cannot see into an ephemeral directory in
  which every write "succeeds"). The residue — the backup disk reformatted as
  something that is not ext4 — is a deliberate host change.
- **Not about free space.** That is `backup_destination_free_bytes`, and the two
  bounds that protect the chain from this system are in `backup_settings`
  (`ceiling_bytes`, `min_free_bytes`), checked before a run writes its first byte.

## Related

- `runbooks/runbook-restore-from-backup.md` — proving a set, and the RPO/RTO
  targets this disk is the medium for.
- `runbooks/runbook-backup-never-run.md` — the other half of the backup page:
  no series at all rather than a bad value.
