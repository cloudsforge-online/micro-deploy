# The estate: backup, restore and what it does not protect

**Owner** platform · **Applies to** both estates, now on the **app host**
`savva@192.168.1.129` (inside WSL Ubuntu-24.04)

> **THE HOST CHANGED UNDER THIS DOCUMENT — read this before you run anything.**
> Every path below of the form `/home/malf/…` and every reference to the host
> `miner` (`192.168.1.42`) was written when one machine ran everything. Since
> the chain-host/app-host split:
>
> | | where it is now |
> | --- | --- |
> | Both estates (`cloudsforge-estate`, `cf-testnet`), their Postgres, the gateways, the telemetry plane | app host `savva@192.168.1.129`, deploy tree `/home/savvaniss/dev/cloudsforge/deploy` |
> | `bitcoind`, `litecoind`, `dogecoind` (host processes, datadirs `/data/chains`), the Hearth seeds, the EMBER miners | chain host `malf@192.168.1.42`, deploy tree `/home/malf/dev/cloudsforge/deploy` |
>
> `docker ps` on the chain host now returns five containers, none of them an
> estate service. **A dump taken there backs up nothing.** Substitute
> `/home/savvaniss` for `/home/malf` in every command below unless the step is
> explicitly about `/data/chains`, which did not move.
>
> **The backup disk did not move either, and this is an open gap.** The
> dedicated destination this document is built around —
> `/dev/sdb1` bind-mounted at `/home/malf/cloudsforge-backups`, §3 — is physically
> in the chain host. Measured 2026-08-11: the app host has no
> `cloudsforge-backups` mount at all; `/home/savvaniss/backups` exists but is a
> directory on the root filesystem (`/dev/sdf`, 1.0 T, 11 G used), not a separate
> device. So the "never write a backup to the same disk as the data" property
> that §3 spends a page establishing is **not currently held on the machine that
> now has the data**. Restoring the property — either an off-host pull or a
> second device on the app host — is unfinished work, not something this document
> can assert.
>
> `scripts/pull-custody-backup.sh` still defaults to `--host malf@192.168.1.42`
> for the same reason. It fails loudly rather than silently (the project is not
> there, so the remote step aborts and nothing is pulled), but it has not been
> re-pointed, and re-pointing it is not a one-word change: the app host answers
> ssh with `cmd.exe`, so the remote `bash` blocks need a
> `wsl -d Ubuntu-24.04 -- bash -lc` wrapper first.

This is the procedure for getting the estate's data back. Its companion is
[`custody-backup-restore.md`](./custody-backup-restore.md), which covers the custody
keyring and is **not** superseded by anything here: the two documents divide at a
line drawn in §1.3, and neither can do the other's job.

Every command below has been executed. The transcript is
[Appendix A](#appendix-a--the-rehearsal-that-was-actually-performed), which is part
of the document rather than an appendix nobody reads, because **a backup nobody has
restored is a wish** — this estate's own hard-won phrase, and the reason the
rehearsal is the deliverable rather than the code.

> **THE ONE RULE, inherited unchanged.** Never print, echo, paste or commit a master
> secret, a private key, a mnemonic or an xprv. Public addresses, xpubs and checksums
> are safe. Every verification here proves a recovery by **re-deriving a public
> address and comparing it**, never by displaying what it was derived from.

---

## 1. What is backed up, and what is deliberately not

### 1.1 The inventory, measured rather than assumed

One `postgres:17-alpine` container per compose project, each holding **29
databases** — not one database server per service, which is what the service
topology suggests and which would have been the wrong thing to build against.

| | mainnet (`cloudsforge-estate`) | testnet (`cf-testnet`) |
| --- | --- | --- |
| Running containers | 46 → **49** (2026-08-11) | 47 → **49** (2026-08-11) |
| Databases | 29 | 29 |
| Total database size | 284 MB | 245 MB |
| Custody vault | 502 blobs, 4.0 MB | 17 blobs, 144 KB |
| Studio assets | 8.2 MB | 8.2 MB |

Tessera's sprite mount is a **bind**, not a volume:
`/home/malf/dev/cloudsforge/deploy/compose/estate/world-assets`, **152 MB / 394
files**, shared by both projects. It was previously believed to be a mount holding
one README; it is not, and a backup that skipped it on that belief would have lost
the entire sprite set.

**PGDATA is on ANONYMOUS docker volumes** (mainnet `5f3ca4f6…b208`, 383 MB; testnet
`2d3686a7…5d9f`, 343 MB). They carry no `<project>_` prefix, so they do not appear
in a filtered `docker volume ls` and a `docker compose down -v` would destroy both
clusters with no named handle to have backed up. That is a reason to hold logical
dumps rather than to rely on the volumes.

### 1.2 What is excluded, and why that is a decision rather than an oversight

**`/data/chains` — 553 GB of Bitcoin, Litecoin and Dogecoin chain data — is never
backed up.** It is public blockchain data, reconstructible from the network by any
node, and it is load-bearing for native chain observation. Copying 553 GB to protect
something the internet already holds would consume the entire budget and protect
nothing. It is recorded in every manifest's `excluded` array with that reason, so its
absence reads as a choice.

`/data/wallets` (630 MB of old altcoin wallets) is excluded on the owner's statement
that they are non-functional and hold no coins. They are **not deleted** — there is
1.4 TB free, nothing is gained, and a `wallet.dat` is exactly the artefact where a
mistaken recollection is unrecoverable.

### 1.3 The line between this document and the custody one

| Artefact | Where it goes | Which document |
| --- | --- | --- |
| 29 databases per estate | `/data/cloudsforge-backups` | this one |
| Custody vault (**ciphertext**) | `/data/cloudsforge-backups` | this one |
| Miner coinbase keys (**encrypted**) | `/data/cloudsforge-backups` | this one |
| File state (sprites, studio assets) | `/data/cloudsforge-backups` | this one |
| **`CUSTODY_MASTER_SECRET_V<n>`** | **paper + encrypted USB, two buildings** | [custody §4](./custody-backup-restore.md#4-the-physical-backup--what-the-owner-must-do) |
| **The `age` identity** | **never on this machine** | §4 below |

The rule in one line, and it is the same rule in both documents: **the ciphertext and
the thing that opens it must never share a medium.** Either alone is safe to lose to a
thief. Together they are the coins.

---

## 2. What this protects against — and what it does not

The estate's databases live on `/dev/sda2`. Backups are written to `/dev/sdb1`, a
genuinely separate physical device with 1.4 TB free. That closes the gap the custody
rehearsal named: backups no longer sit on the same disk as the thing they back up.

**It closes nothing else, and the admin panel says so in those words.**

| Covered | Not covered |
| --- | --- |
| Failure of the disk holding the databases | Loss of the machine — theft, fire, flood, a dead board |
| An accidental `DROP`, a bad migration, a service corrupting its own data | Ransomware, or an operator with write access to both disks |
| Rehearsing a restore, which is free and safe | An `rm -rf` on this host, which removes both copies |
| | **Any off-site retention whatsoever** |

There is no NAS, no object store, no network mount, and no `rclone`, `restic` or
`borg` installed. The server and its backups are one machine in one room. The panel
renders these as two lists rather than a status, deliberately: a status invites a
green tick, and a green tick is a claim this estate cannot support. An operator who
*believes* they have off-site backups and does not is worse off than one who knows
they have none, because the first will not act.

**The backup disk's own health is unverifiable.** `/dev/sdb` is a `MARVELL Raid VD`
and passes no SMART through; see issue #207. `/dev/sda` reports `PASSED`.

---

## 3. THE TRAP THAT MAKES A BACKUP DISAPPEAR SILENTLY

Read this before pointing anything at `/data`.

**Docker on this host is the Canonical snap.** Snap confinement grants `docker:home`
and not `removable-media`, so `/data` is outside what containers can see — and the
failure is silent in both directions:

```bash
docker run --rm -v /data/cloudsforge-backups:/backups alpine:3.20 \
  sh -c 'echo hello > /backups/canary.txt; ls /backups'      # prints canary.txt
ls -l /data/cloudsforge-backups/canary.txt                    # No such file or directory
```

The container reported success and listed the file it had written. Nothing reached the
disk. A nested path mounts as an **empty directory** with a stale timestamp. A nightly
backup pointed at `/data` would go green every night and produce nothing.

**The fix, applied and permanent.** `/data/cloudsforge-backups` is bind-mounted under
`/home`, which the snap can see. The bytes still live on `sdb1`:

```
/data/cloudsforge-backups /home/malf/cloudsforge-backups none bind,nofail,x-systemd.requires-mounts-for=/data 0 0
```

```bash
findmnt -no SOURCE,TARGET /home/malf/cloudsforge-backups
# /dev/sdb1[/cloudsforge-backups] /home/malf/cloudsforge-backups
```

**Always mount `/home/malf/cloudsforge-backups` into a container, never `/data/…`.**
The runner carries a startup canary check for exactly this, and refuses to run if its
destination cannot be proved real — because a runner that cannot see its own
destination will otherwise report successful backups for ever. Issue #204.

### 3.1 The boot hazard that came with the disk, now fixed

`/etc/fstab` mounted `/data` with `defaults 0 1` — no `nofail`, fsck pass 1. An
absent or dirty `sdb1` would have dropped the host into emergency mode and taken
**both estates** down, for a disk nothing was reading. Now:

```
/dev/disk/by-uuid/075822a7-… /data ext4 defaults,nofail,x-systemd.device-timeout=30 0 2
```

`systemctl show data.mount -p RequiredBy` is now **empty** — that is the property that
matters — and `findmnt --verify` reports 0 errors. Verified before any reboot, because
an fstab mistake is one of the few changes here that can make the machine unbootable.
Issue #205.

---

## 4. The environment gate, and the defect it exists for

**On 2026-08-05 the estate seeder ran `docker compose` against the MAINNET project
regardless of the target it was given, twice.** A testnet action recreated a mainnet
container. The same defect on a restore path overwrites real balances with test ones,
irreversibly.

The lesson is precise, and it is **not** "validate the parameter": the parameter was
validated and then ignored. A target that is passed in is a target that can be passed
wrongly. So the environment is a **fact on both sides**, and a restore compares two
discovered facts, neither of which is a request field:

1. **In the artefact.** `MANIFEST.json` carries `environment` and the cluster's
   `system_identifier` from `pg_control_system()`, written when the backup is taken.
2. **In the estate.** `estate_identity` is one row, claimed once at first boot from
   `ADMIN_API_ESTATE_ENVIRONMENT` and **immutable by trigger** thereafter. `admin-api`
   refuses to start if its configured environment disagrees with the row, so a
   mis-pointed compose file is a container that will not boot rather than a wrong
   restore six weeks later.

Four independent gates then stand between an operator and a cross-environment restore:

| # | Where | What it refuses |
| --- | --- | --- |
| 1 | `requestRestore`, `admin-api/src/backups.ts` | Produces the readable sentence |
| 2 | `restore_runs_environment_matches()`, migration 10 | **Copies** the environment off the backup, refuses a mismatch, refuses an approval naming a different backup, refuses a backup that did not succeed. In the schema, so it holds against psql |
| 3 | `restore_runs_live_is_confirmed`, a CHECK | A live row cannot exist without both an approval and a typed confirmation |
| 4 | The runner, `deploy/backup` | Re-reads `MANIFEST.json` on disk and refuses before touching a byte |

Four gates for one decision is not theatre. Gate 2 survives a route rewrite, gate 3 a
direct database write, and gate 4 survives **this entire service being unavailable** —
which, during the disaster a restore exists for, is the likely case.

There is no override flag, and adding one would defeat the control.

### 4.1 A restore is never one click

`POST /v1/restores` accepts `mode: 'verify'` and **refuses `mode: 'live'` outright**,
naming the route to use instead. The only door to a live restore is the approval
queue: `estate.restore`, two distinct operators (`approvals_no_self_approval`), and a
phrase the requesting operator must type exactly —

```
restore mainnet from 2026-08-05T09:00:00Z
```

It names **what** is being restored, **from when**, and **into which environment**,
and it is captured at *request* time so the second operator can see precisely what
they are signing. One approval authorises exactly one restore, for ever
(`restore_runs_one_live_per_approval`).

`verify` needs none of that, and the asymmetry is load-bearing rather than lenient. A
verify restores into a throwaway scratch database and drops it. If the only available
restore were the terrifying one, no restore would ever be rehearsed and every backup
would stay a wish. **Making the safe one cheap is what makes the dangerous one rare.**

---

## 5. Routine backup

Triggered from the admin panel, or on the schedule in `backup_settings` (default
daily). Nothing here needs a shell. The panel shows size, age, checksum status, and
**whether a restore of that set has ever been verified** — a set with `verifiedAt`
null is shown as *never verified*, prominently, rather than as an absence.

Retention is `retention_copies` (default 14) under a hard `ceiling_bytes` (default
200 GiB, schema roof 1 TiB) and a `min_free_bytes` floor (default 100 GiB). The roof
is below the free space on `sdb1` **on purpose**: the setting cannot be used to fill
the disk. At ~1.1 GB of live estate state against 1.456 TB free, the headroom is about
a thousandfold and retention can be generous.

The equivalent by hand, when the panel is not available:

```bash
P=cloudsforge-estate; OUT=/home/malf/cloudsforge-backups/manual/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT/db" && chmod 700 "$OUT"
for d in $(docker exec ${P}-postgres-1 psql -U cloudsforge -d postgres -tAc \
           "select datname from pg_database where not datistemplate order by datname"); do
  docker exec ${P}-postgres-1 pg_dump -U cloudsforge -d "$d" -Fc > "$OUT/db/$d.dump"
done
( cd "$OUT/db" && sha256sum *.dump > ../SHA256SUMS )
docker run --rm -v ${P}_custody-keys:/vault:ro -v "$OUT":/out busybox:1.37 \
  tar -czf /out/custody-vault.tgz -C /vault/keys .          # directory names intact — custody §1.2
```

**The keyring is deliberately not in that script**, and never will be. See §1.3.

---

## 6. The miner coinbase keys

The Hearth miners hold their reward key **natively, in plaintext**, in a 240-byte
JSON file at mode 0600. The mainnet coinbase `0x980d…5b45` held **9,332.079 EMBER** of
genuinely mined coin at block 1733. It cannot be rotated without abandoning the
balance, so there is no remedy for losing the file.

It is backed up, and it is **encrypted before it is written**, with `age`, to a
recipient whose private identity **never exists on this host**:

```bash
age -r "$BACKUP_AGE_RECIPIENT" -o secrets/miner-coinbase-mainnet.json.age < "$src"
```

`BACKUP_AGE_RECIPIENT` is a *public* key — safe in compose, safe in a log. If it is
unset the artefact is **skipped and recorded as skipped**; it is never written in the
clear. That fallback is the whole failure mode, so it does not exist.

The consequence, stated plainly: **this host cannot read its own key backup.** A
compromise of the machine yields ciphertext. It also means the periodic self-check can
only prove the ciphertext is *intact*, by checksum — proving it *decrypts* requires
the offline identity and is an operator's job, not a job's.

Verification is by **address comparison**, never by comparing keys:
`backup_artefacts.public_ref` records the address and is constrained to
`^0x[0-9a-fA-F]{40}$`, so the column cannot hold a 64-hex private key even if a caller
tries to put one there.

**The plaintext-at-rest problem itself is NOT fixed** — backing the file up preserves
the exposure alongside the durability. That is issue #206 and belongs to whoever owns
the miner; doing it carelessly stops a running miner.

---

## Appendix A — the rehearsal that was actually performed

Executed 2026-08-05 on the estate host. **The live cluster was never written to.**
Sources were read; every restore went into a dedicated throwaway
`postgres:17-alpine` on `127.0.0.1:55432`. Afterwards: 29 mainnet databases still
present, 46 mainnet containers still healthy — the pre-rehearsal figures exactly.

### A.1 The backup

Five live mainnet databases, chosen to include the money-bearing ones:

```
custody       95,962 bytes      ledger      90,372      identity  2,343,405
wallet       154,817            admin_api   38,443
environment: mainnet    clusterSystemId: 7670192594363031586    artefacts: 5
```

`SHA256SUMS` written; `MANIFEST.json` carrying the environment marker and the
`/data/chains` exclusion.

### A.2 The negative control — the environment gate

Artefact says `mainnet`; the runner claims `testnet`:

```
REFUSED: artefact environment=mainnet, this runner is testnet — not a byte was touched
```

And in the database, against a caller writing raw SQL rather than using a route:

```
insert into restore_runs (backup_run_id, environment, mode, requested_by)
  values (<a mainnet backup>, 'testnet', 'verify', 'user:…');
ERROR: REFUSED: that backup was taken in the mainnet estate and this is the testnet estate
```

Repeated with `environment` set to `'mainnet'` to try to *agree* with the artefact —
refused identically, because the column is overwritten from the backup before the
comparison. **A caller cannot supply an environment that helps them.**

### A.3 The restore

Media verified first — `sha256sum -c` OK on all five. Restored into scratch databases
over TCP **from outside the container, with a password**: testing from inside gives a
false pass, because `pg_hba.conf` trusts `127.0.0.1` within the container.

```
DATABASE     SCRATCH                    RESTORED     SOURCE  RESULT
custody      scratch_verify_custody          790        790  PASS
ledger       scratch_verify_ledger           744        744  PASS
identity     scratch_verify_identity       34099      34101  MISMATCH
wallet       scratch_verify_wallet          1045       1045  PASS
admin_api    scratch_verify_admin_api         13         13  PASS
```

The restored data is real, not an empty schema: `custody_keys=257`,
`custody_seeds=245`, `ledger accounts=28`.

### A.4 The mismatch, run down rather than waved away

`identity` was investigated instead of being accepted as noise, and it is **not** a
restore defect:

```
TABLE                              LIVE   RESTORED  RESULT
users                              2585       2577  DRIFT +8 since the dump
sessions                           2606       2606  EQUAL
refresh_tokens                     2614       2614  EQUAL

restored copy: users=2577, orphaned sessions=0
```

`identity` is a live, actively-written database; eight users registered between the
dump and the comparison. The restored copy has **zero orphaned sessions**, so the dump
is a coherent transactional snapshot.

**Two lessons, both now encoded in the runner:**

- A live-vs-restored row comparison is not a valid integrity check for a hot backup.
  It produces false alarms on every busy database, and false alarms train an operator
  to ignore the real one. Counts must come from *inside* the dump's snapshot.
- `n_live_tup` is an **estimate** from the stats collector, not a count, and needs an
  `ANALYZE` after restore to be even approximately right.

The honest checks are the per-artefact SHA-256, a zero exit from `pg_restore`, and
**referential integrity of the restored copy** — the orphan probe above.

### A.5 The miner keys, recovered on a different machine

Keypair generated in the host's tmpfs, the private identity moved off and `shred`ed
from the host, both key files encrypted to the public recipient. Then, on a **separate
machine**, checksums verified and the keys recovered:

```
PASS  mainnet  recovered key re-derives 0x980d52a868d41a34a186ce890874c8e547975b45
      manifest recorded                 0x980d52a868d41a34a186ce890874c8e547975b45
PASS  testnet  recovered key re-derives 0x91a11854b364178ed96054d8a6e9be1dbd751d33
      manifest recorded                 0x91a11854b364178ed96054d8a6e9be1dbd751d33

RESULT  miner keys 2 recovered / 0 failed
```

Two negative controls, both correct:

```
OK:   the host cannot decrypt it — no identity exists on this machine
PASS: the wrong identity recovered 0 of 1
```

**No key was printed at any point.** Every PASS above is an address comparison.

### A.6 Teardown

Throwaway cluster removed with every scratch database in it; the hand-made rehearsal
tree deleted so it cannot be mistaken for a real backup set; the throwaway `age`
identity and every recovered plaintext shredded from the recovering machine.

### A.7 What this rehearsal did NOT prove

Stated because a rehearsal that overstates itself is worse than none:

- **No live restore has ever been performed.** Every restore above went into a
  throwaway. The destructive path is exercised by tests and by the schema's refusals,
  not by having overwritten a live database.
- **The custody vault tarball was not restored in this rehearsal.** That path is
  proven separately and in full by `custody-backup-restore.md` Appendix A, which
  recovered 6 keys and 4 seeds from cold artefacts.
- **The `age` decryption of a miner key has never been done with the real production
  identity**, because that identity does not exist yet. §6 is proven with a throwaway
  recipient; generating the real one, off this machine, is an owner action.
- **24 of the 29 databases per estate were not exercised**, only the five above.
- **Nothing has been proven off-site**, because there is no off-site.
