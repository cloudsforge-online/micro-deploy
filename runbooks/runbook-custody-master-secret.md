# The custody master secret, and the keys that have no backup

**Triggered by** `Rotation; a suspected compromise; the quarterly restore rehearsal; loss of the estate host`
**Severity** SEV1 if lost or exposed · **Owner** platform

> **The full procedure — routine backup, disaster restore, rotation, and the
> recovery path when a drain was skipped — is `../docs/custody-backup-restore.md`.
> It has been rehearsed end to end against a throwaway custody and used to perform
> a live rotation; this runbook is the incident-time summary of it.**

## Read this first

**The estate is one home server.** Measured 2026-08-05: no crontab, no backup
systemd timer, one 447G root disk carrying every Docker volume. Everything below
is written so that the first restore is not attempted for the first time during
the incident that needs it.

What has changed since that measurement, and what has not — read both halves
before you rely on either:

- **Artefacts A and B are now copied off the host, nightly.** From 2026-08-10,
  `scripts/pull-custody-backup.sh` runs at 03:30 from the operator's workstation
  and pulls the database dump and the vault tarball. It pulls rather than being
  pushed, so the host holds no credential for the destination and cannot reach
  it. See `../docs/custody-backup-restore.md` §2.1.
- **A restore HAS been performed** — end to end, against a throwaway custody,
  database dropped and vault deleted, recovered from cold artefacts alone. See
  Appendix A of the same document.
- **Artefact C, the keyring, is still not backed up anywhere.** That is the
  owner's job, at the machine's console, by §4 — and until it is done, the
  nightly off-host copy recovers **nothing**. A + B without C is a list of
  addresses nobody can spend. This is the live gap; it is micro-org#25 item 3.

## What the keyring is, and what it is not

`CUSTODY_MASTER_SECRET_V<n>` is the KEY-ENCRYPTION KEY. `custody/src/crypto.ts`
derives a per-address AES-256-GCM key from it with scrypt and encrypts the
private key at rest; the version stamped on each blob selects which secret
decrypts it.

**It does not derive addresses.** Addresses come from a per-(user, family) BIP-39
mnemonic generated from the system CSPRNG (`custody/src/keys.ts`,
`custody/src/hd.ts`). The mnemonic is then encrypted under the keyring and
stored like any other blob. So:

- Losing the keyring does not change any address. It makes every stored key and
  every stored mnemonic **permanently undecryptable**, which means the coins at
  those addresses can never be spent again. There is no second copy: the
  mnemonics are inside the blobs.
- Exposing the keyring does not by itself yield a private key. It yields every
  private key to anyone who ALSO obtains the blobs - a disk, a volume backup, a
  stray `docker cp`, a container escape. Treat exposure as loss of the coins.

As of 2026-08-10, after the V3 → V4 rotation of the same day, the mainnet estate
holds **261 addresses and 246 seeds**, every one on `key_version` 4 with 507 of
507 vault blobs stamped `v4:`; the testnet estate holds none and is on its own
separate keyring at V2. (Mainnet held 198 and 189 on 2026-08-05 — this number
grows, so check it rather than quoting it.) The rotation record, with the
verification that proves it, is `../docs/custody-backup-restore.md` Appendix B.4.

**Every version below V4 is retired and destroyed.** V1, V2 and V3 decrypt
nothing that exists on either machine and none of them is loadable anywhere.
The V1 secret was additionally published in this repository's history. The disposition of that disclosure — accept and
document, not rewrite history — is recorded in `../docs/custody-v1-disclosure.md`
with the measurements behind it.

## Where it lives

| | |
| --- | --- |
| Mainnet | `~/dev/cloudsforge/deploy/compose/secrets/custody.mainnet.env` |
| Testnet | `~/dev/cloudsforge/deploy/compose/secrets/custody.testnet.env` |
| Mode | `0600`, in a `0700` directory, owned by the operating user |
| Read by | `compose/docker-compose.estate.yml`, anchor `x-custody-secrets`, as an `env_file:` whose path interpolates `CF_EMBER_NETWORK` |
| In git | **No.** `compose/secrets/` is ignored as a directory |

The two environments hold **different** keyrings, and CI asserts they resolve to
different files. One compromise must not take both.

It is deliberately NOT in `compose/estate/tokens.env`, which is the estate's
other gitignored secrets file: `scripts/estate-bootstrap.sh` replaces that
file wholesale on every run (`mv "$tmp" "$TOKENS_FILE"`). A master secret there
would be silently replaced by a routine bootstrap, and a replaced master secret
is not a rotation - it is every blob undecryptable, with no way back.

## Physical backup - the procedure

The trade, stated plainly: **a secret written on paper survives a disk failure
and is readable by anyone who finds it.** The disk is the more likely failure and
the paper is the more likely compromise. Do both of the copies below, in two
different physical places, and accept that the paper is now as valuable as the
coins.

Do this at the machine's own console, not over SSH. A value read over SSH is in
the scrollback of a second computer.

1. **Print the value with a checksum**, so a mis-transcription is caught rather
   than discovered years later:

   ```
   cd ~/dev/cloudsforge/deploy
   f=compose/secrets/custody.mainnet.env
   grep '^CUSTODY_MASTER_SECRET_V' "$f"          # the lines to copy
   sha256sum "$f" | cut -c1-16                   # the check, copy this too
   ```

2. **Write it out by hand, in block capitals, on paper.** It is 64 base64
   characters per version. Base64 mixes case and the case is significant; mark
   the ambiguous glyphs (`0`/`O`, `1`/`l`/`I`) explicitly. Write the checksum, the
   filename, the date and the words "custody master secret - these are coins".

3. **Verify the paper before you trust it.** Transcribe it BACK from the paper
   into a scratch file and compare - never by eye:

   ```
   sha256sum /tmp/from-paper.env | cut -c1-16    # must equal step 1
   shred -u /tmp/from-paper.env
   ```

   A copy you have not read back is not a backup, it is handwriting.

4. **Second copy, encrypted, off the machine.** A USB stick, `gpg -c` with a
   passphrase you have not used anywhere else:

   ```
   gpg -c --cipher-algo AES256 -o /media/usb/custody.mainnet.env.gpg "$f"
   ```

   The passphrase goes on the paper from step 2 - which is why the paper and the
   stick live in different places.

5. Repeat for `custody.testnet.env` if the testnet estate ever holds anything
   worth keeping. Today it holds nothing and the honest answer is not to bother.

## The rehearsal - a restore somebody has actually performed

Quarterly, and the first time as soon as possible. It is about twenty minutes
and it is the only thing that turns a hope into a backup.

1. Transcribe the paper copy into `/tmp/rehearsal.env`. Compare the checksum -
   `cut -c1-16` of `sha256sum` - against the paper. **If it differs, stop:** the
   paper copy is wrong and that is the finding.
2. Move the live keyring aside and put the transcribed copy in its place.
3. `docker compose ... up -d --wait custody` and read the startup line:
   `readableKeyVersions` must list every version any stored blob carries.
   Booting proves the value passes `assertMasterSecret`. It does not yet prove it
   decrypts anything.
4. **Drive one real signature.** A faucet drip calls `POST /v1/sign`
   (`faucet/src/custodyclient.ts`), which decrypts a stored blob under the
   restored keyring. A successful drip is the proof; a healthy container is not.
5. Restore the original file, restart, and record the wall-clock time. A
   rehearsal that fails changes the procedure - it is never just noted.

## Rotation, and when the old secret may be deleted

The keyring is versioned so a compromise is survivable. `custody/src/reencrypt.ts`
holds the full sequence; in short: add `CUSTODY_MASTER_SECRET_V<n+1>`, leave
`V<n>` in place, set `CUSTODY_KEY_VERSION=<n+1>`, restart, and watch
`GET /v1/admin/rotation` reach zero. **Only then delete `V<n>`.** Deleting it
early loses every key still on it.

A retained old secret is not a lesser secret: it decrypts every blob that has not
been re-encrypted yet. It gets the same paper treatment for as long as it exists,
and it is deleted the day it stops being needed.

## The miner keys are in the same position and are not covered by any of it

`/home/malf/dev/cloudsforge/miner-keys/{mainnet,testnet}/coinbase-key.json` hold
the coinbase keys that every mined EMBER pays out to. Measured: a 240-byte JSON
file, mode `0600`, containing `address` and a **plaintext 66-character
`privateKey`**. Not encrypted, not versioned, not backed up, on the same single
disk as everything else.

They are simpler than the custody keyring and strictly more urgent, because they
hold value today:

- The same paper procedure applies, and the same checksum discipline. One line
  each, and a mined balance behind it.
- There is no rotation. A miner key cannot be rotated without abandoning the
  balance at its address, so the paper copy is the ONLY recovery path there will
  ever be.
- Encrypt the file at rest if the coinbase key is not needed at every boot. Until
  then, a plaintext private key on a network-reachable host is the accepted risk,
  and it should be written down as one rather than left unstated.

## What breaks, precisely, if the keyring is lost

- Every custody address becomes unspendable, for ever. 198 of them today.
- Every HD seed becomes unrecoverable, so no user can ever be given their
  recovery phrase - the phrase only exists inside the encrypted blob.
- Deposits already made are visible on chain, provably owned by an address
  nobody can sign for. There is no remedy, no support path and no vendor.
- The database and the blobs survive and are worthless without it. Backing up
  the volume and not the keyring is the same as backing up nothing.
