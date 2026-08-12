# The backup contains no miner coinbase key

**Triggered by** `MinerCoinbaseKeyUnbacked - backup_secrets_included == 0 for 30m`
**Severity** SEV3 - ticket · **Owner** platform

## What it means

Backups are running, they are recent, and the one artefact in the set that
cannot be rebuilt from anything is not in them.

Every other thing this runner writes has a second source of truth. A database
dump can be re-dumped from the cluster. A volume archive can be re-made from the
volume. A vault blob can be re-read from custody. The miner coinbase key is the
exception, and `docs/custody-backup-restore.md` §4.2 step 6 states the exception
plainly: the key "cannot be rotated without abandoning the balance at the
address, so the paper copy is the only recovery path there will ever be."

Measured on mainnet 2026-08-12, the balances behind that sentence:

| Address | Host that mines to it | EMBER |
| --- | --- | --- |
| `0x980d52a868d41a34a186ce890874c8e547975b45` | chain host, `192.168.1.42` | 65,099.909467 |
| `0x2098b519aaf94e704534c6de35c5c516723dcca8` | app host, `192.168.1.129` | 10,292.892017 |

Losing either key abandons that balance. There is no recovery, no rotation and
no support channel.

`BackupAgeExceeded` and `BackupNeverRun` cannot see this. They watch whether a
run finished and how old it is, and a run that quietly omits one artefact
finishes on time.

## Why this rule exists: it already happened, for weeks, silently

micro-org#206's first half was fixed by sealing the plaintext `coinbase-key.json`
into a scrypt + AES-256-GCM `coinbase-keystore.json`. That was the right fix and
it broke the backup in the way that looks most like success.

`run.ts` asked for `<dir>/<env>/coinbase-key.json` **by name**. On the app host
the seal left only the keystore, so the read took the `ENOENT` branch — whose
warning read *"nothing to encrypt"* and whose comment read *"On an estate with no
miner this is normal."* The estate has two miners.

Measured on mainnet 2026-08-12, before the fix:

| Question | Answer |
| --- | --- |
| Rows in `backup_artefacts` | 264 |
| …of kind `database` | 240 |
| …of kind `files` | 16 |
| …of kind `vault` | 8 |
| …of kind `secrets` | **0, ever** |
| `BackupAgeExceeded` / `BackupNeverRun` during that period | green |

The runner now resolves its source instead of being told it — keystore first,
plaintext as a fallback — and publishes `backup_secrets_included` so the state
above has a name.

## Establish which state this is

Two states fire this rule, and they need opposite responses. One command
separates them:

```bash
ssh savva@192.168.1.129 'wsl -d Ubuntu-24.04 -- \
  docker exec cloudsforge-estate-backup-runner-1 sh -c "printf %s \${#BACKUP_AGE_RECIPIENT}"'
```

**`0` — no recipient.** Go to *State 1*. This is the expected state as of
2026-08-12.

**`62` — a recipient is set.** Go to *State 2*.

Never print the variable itself and never print a key file. The length is the
whole diagnostic. (`BACKUP_AGE_RECIPIENT` is a *public* key and would be safe to
print; the habit of printing what is beside it is not.)

## State 1 — `BACKUP_AGE_RECIPIENT` is unset

There is no path in this system that writes a private key unencrypted, and that
is deliberate: the fallback that writes plaintext "just this once" fires exactly
when configuration is broken, which is exactly when nobody is watching. So with
no recipient, nothing is written and the runner seeds this gauge to `0` at boot
rather than making the estate wait a night to hear it.

**This is owner action, and it must not be done on the estate.** The identity
that can decrypt must never exist on a host the backups are on — that is the
entire control. §1.5's rule is that an artefact and the key that opens it must
not share a medium.

1. On a machine that is **not** the app host and **not** the chain host, with
   `age` installed:

   ```bash
   age-keygen -o cloudsforge-backup-identity.txt
   ```

   The file it writes contains an `AGE-SECRET-KEY-1…` line. That is the identity.
   It goes wherever the estate's paper and encrypted USB already live
   (`docs/custody-backup-restore.md` §4.1). It does not go in a password manager
   that syncs to the estate, in a repository, in a chat message, or in a
   terminal that scrolls into a transcript.

2. `age-keygen` prints the matching **public** recipient to stderr, and it is
   also the `# public key:` comment line in the file. It looks like
   `age1` followed by 58 characters. That half is not a secret.

3. On the app host, set it in the environment's env file — not in compose, which
   is committed:

   ```bash
   # /home/savvaniss/dev/cloudsforge/compose/estate/tokens.env  (gitignored, 0600)
   CF_BACKUP_AGE_RECIPIENT=age1…
   ```

4. Redeploy the backup overlay with `scripts/release-deploy.sh`. A bare
   `docker compose up` drops `mainnet.env`.

5. Confirm, without printing anything:

   ```bash
   ssh savva@192.168.1.129 'wsl -d Ubuntu-24.04 -- \
     docker exec cloudsforge-estate-backup-runner-1 sh -c "printf %s \${#BACKUP_AGE_RECIPIENT}"'
   ```

   Expect `62`. The runner refuses to start on a malformed value — `assertAgeRecipient`
   rejects anything that is not `age1` + 58 bech32 characters, so a truncated
   paste fails at boot and not after a write.

6. Run a full backup and check the gauge goes to 1. The alert clears at the next
   evaluation.

## State 2 — a recipient is set and there is still no key

The runner looked and found neither file. Read the manifest warning from the
last run; it names both paths it tried.

```bash
ssh savva@192.168.1.129 'wsl -d Ubuntu-24.04 -- \
  docker logs --since 48h cloudsforge-estate-backup-runner-1' 2>&1 | grep -i "NO MINER COINBASE KEY"
```

Then check what the runner can actually see. **Filenames only — never `cat` one
of these files:**

```bash
ssh savva@192.168.1.129 'wsl -d Ubuntu-24.04 -- \
  docker exec cloudsforge-estate-backup-runner-1 find /miner-keys -maxdepth 3'
```

The expected tree, measured 2026-08-12:

```
/miner-keys
/miner-keys/mainnet/coinbase-keystore.json      652 bytes, 0600
/miner-keys/secrets/coinbase-passphrase          64 bytes, 0600
/miner-keys/testnet/coinbase-keystore.json      652 bytes, 0600
```

An empty or shallow tree means the bind mount is wrong. `CF_MINER_KEYS` is a
**required** variable with no default in `compose/mainnet.env` and
`compose/testnet.env` — deliberately, because the two hosts do not hold the same
miner-key files and a default cannot tell which host it is on. It should read
`/home/savvaniss/dev/cloudsforge/miner-keys` on the app host.

A tree that is present but holds neither candidate filename means the miner's
key moved again. Find where, and update `minerKeySources()` in
`backup/src/secrets.ts` — that function is the single place the names live, and
it is covered by a test asserting exactly which file wins.

## What is in the artefact, and why the passphrase is in it too

One `age`-encrypted artefact per environment, `kind = 'secrets'`, `publicRef`
set to the coinbase address. Inside the ciphertext is a JSON envelope tagged
`cloudsforge.miner-coinbase.v1`:

| Field | Meaning |
| --- | --- |
| `format` | `cloudsforge.miner-coinbase.v1` |
| `environment` | `mainnet` or `testnet` |
| `address` | the public coinbase address, same value as `publicRef` |
| `source` | `keystore` or `plaintext` — which file it came from |
| `keystore` | verbatim contents of `coinbase-keystore.json` (when `source` is `keystore`) |
| `key` | verbatim contents of `coinbase-key.json` (when `source` is `plaintext`) |
| `passphrase` | the scrypt passphrase that opens the keystore |
| `passphraseFrom` | the path it was read from, so recovery knows where to put it back |
| `recovery` | the two-sentence procedure, carried inside the artefact |

**The passphrase travels with the keystore on purpose**, and it is worth
understanding before someone "fixes" it. A keystore backup without its
passphrase is a backup of nothing: the passphrase is 64 bytes in one 0600 file
on one machine, covered by no cron, no timer and no runner. Backing up the
keystore alone produces a green `secrets` artefact that cannot be opened, which
is worse than no artefact — it reads as recovered until the day it is needed.

Yes, this collapses two factors into one. The protection becomes the age
recipient alone. That is the right trade here because the recipient's private
half never exists on either host, so the pair is no more reachable from a host
compromise than the keystore alone was — and because the alternative is a
durability control that does not work.

If a passphrase-less source is ever backed up, the manifest carries
`NO_PASSPHRASE_WARNING`, which says in as many words that the artefact does not
make the key recoverable.

## Proving it, which cannot be done on the estate

`backup_secrets_included == 1` says an artefact was written. It does not say the
artefact opens.

The estate holds no age identity by design, so it can verify a `secrets`
artefact no further than its checksum. A real proof of recovery is:

1. Copy the `.age` file to the machine that holds the identity.
2. `age -d -i <identity> <file>` and parse the JSON.
3. Re-derive the address from the recovered key and compare it to the envelope's
   `address` and the artefact's `publicRef`.

**Compare addresses, never keys.** The address is public and on chain; printing
it costs nothing. A key comparison means a key on a screen.

Until step 3 has been done once, treat this as an untested backup.

## The gap this alert does not cover

The runner runs on the **app host** and mounts the app host's `miner-keys`. The
chain host's key — `0x980d…5b45`, holding 65,099.909467 EMBER, six times the app
host's balance — is on a different machine with no runner on it, and no value of
`BACKUP_AGE_RECIPIENT` changes that.

So `backup_secrets_included == 1` means *the app host's* coinbase key is in the
set. It says nothing about the chain host's. That is tracked on micro-org#206
and needs an owner decision between two options: run a second backup runner on
the chain host, or copy the chain host's sealed keystore and passphrase into the
app host's `miner-keys` tree so one runner covers both. The second is less
machinery and puts the chain host's passphrase on a second machine; the first is
more machinery and does not.

Do not close micro-org#206 on this alert going green.

## See also

- `runbooks/runbook-backup-never-run.md` — the alert for the other side of this:
  no backup at all, rather than a backup missing one thing.
- `runbooks/runbook-restore-from-backup.md` — the full restore procedure.
- `runbooks/runbook-seal-miner-coinbase-key.md` — how the keystore that this
  backs up was made, and how to make another one.
- `docs/custody-backup-restore.md` §4.1, §4.2 step 6, §1.5.
