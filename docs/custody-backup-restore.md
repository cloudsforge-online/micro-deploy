# Custody: backup, restore and key rotation

**Owner** platform · **Applies to** every environment that has ever minted a custody address

This is the procedure for keeping customer coins recoverable, and for getting them
back when something is lost. Every command below has been executed against a
throwaway custody — see [Appendix A](#appendix-a--the-rehearsal-that-was-actually-performed)
for the transcript. A runbook nobody has run is a wish, so the rehearsal is part
of the document rather than an appendix nobody reads.

> **THE ONE RULE.** Never print, echo, paste or commit a master secret, a private
> key, a mnemonic or an xprv. Public addresses and xpubs are safe. Every command
> here is written so that no key material reaches a terminal, a log or a
> transcript. Where a value must be handled, it is moved file-to-file and its
> presence is proved with a checksum or a length, never by displaying it.

---

## 1. The scheme, as it actually is

Read this section before doing anything else. Getting it wrong in either
direction — assuming the master secret derives addresses, or assuming the blobs
are self-contained — leads to a "backup" that restores nothing.

### 1.1 Two independent secrets, and they are not the same thing

| | **The keyring** | **The seeds** |
| --- | --- | --- |
| What it is | `CUSTODY_MASTER_SECRET_V<n>`, one per envelope version | A 24-word BIP-39 mnemonic per (user, family) |
| Where it lives | Environment, from a gitignored `env_file` | Encrypted, in the vault, at slot `seed:<uuid>` |
| Comes from | An operator running `openssl rand -base64 48` | `generateMnemonic(wordlist, 256)` — the system CSPRNG (`custody/src/hd.ts`, `custody/src/hd.ts`) |
| What it does | **Encrypts things at rest.** Nothing else | **Derives addresses.** Nothing else |
| Backed up by | The physical procedure in §4 | Being inside a blob the vault backup covers |

**`CUSTODY_MASTER_SECRET_V<n>` is a KEY-ENCRYPTION KEY. It is not the derivation
seed.** This distinction has been got wrong in this estate before and it changes
what every other statement means:

- Changing the keyring **changes no address.** Addresses are derived from the
  mnemonic (`custody/src/keys.ts`), which the keyring merely wraps.
- Losing the keyring makes every blob **permanently undecryptable** — and because
  the mnemonics are themselves blobs (`custody/src/keys.ts`), it destroys
  the recovery phrases too. There is no second copy of a mnemonic anywhere. The
  coins at those addresses can never be spent again by anyone.
- Leaking the keyring yields **no private key on its own.** It yields every
  private key to whoever also gets the vault. Treat a leak of both as loss of the
  coins.

### 1.2 The envelope

`custody/src/crypto.ts` is the whole encryption scheme. Per slot:

```
v<n>:base64( salt? || iv || tag || ciphertext )
```

- **AES-256-GCM.** IV 12 bytes, tag 16 bytes (`custody/src/crypto.ts`).
- **The data key is derived per slot**, `scrypt(secret_v<n>, salt)` → 32 bytes
  (`custody/src/crypto.ts`). One leaked data key never unlocks a second
  address.
- **The version stamp selects the SECRET, not just the salt**
  (`custody/src/crypto.ts`). This is what makes rotation possible at all.
  `decrypt` reads the stamp off the blob and picks the matching secret
  (`custody/src/crypto.ts`), so a keyring holding several versions reads
  blobs written under any of them.
- **Per-version parameters are frozen for ever** (`custody/src/crypto.ts`,
  `custody/src/crypto.ts`):

  | Version | scrypt cost | Salt |
  | --- | --- | --- |
  | v1 | N = 16 384 | Derived from the address: `cf:custody:v1:<address>` |
  | v2 and every version above it | N = 32 768 | 16 random bytes, carried in the envelope |

  Editing a released version's parameters does not re-encrypt anything. It makes
  every blob at that version undecryptable.
- **The slot name is authenticated** — `setAAD("<slot>|v<n>")`
  (`custody/src/crypto.ts`, `custody/src/crypto.ts`). Moving `key.enc`
  from one address's directory to another's fails the GCM tag instead of
  decrypting to a key that does not match the row. **This is why the vault must
  be restored with its directory names intact.**

### 1.3 What `CUSTODY_KEY_VERSION` selects

It is the **write** version only — the version new blobs are written under
(`custody/src/env.ts`). Reading is governed by the blob's own stamp. The
keyring is assembled by scanning the environment for `CUSTODY_MASTER_SECRET_V<n>`
by pattern rather than by name (`custody/src/env.ts`,
`custody/src/env.ts`), which is what makes a rotation a **deploy** rather
than a code change.

Two boot-time refusals worth knowing, because they are the difference between a
loud failure and a silent one:

- `CUSTODY_KEY_VERSION` set to a version with no secret behind it → refuses to
  start (`custody/src/env.ts`). Otherwise new addresses would be written
  under a key nothing holds.
- If `CUSTODY_KEY_VERSION` is absent it defaults to the **highest** version
  present (`custody/src/env.ts`). Adding `..._V3` therefore silently makes v3
  the write version. Set it explicitly anyway; an implicit write version is one
  nobody can see in a diff.

### 1.4 Where the blobs are

One directory per slot under `CUSTODY_DATA_DIR`, mode `0700`, each holding one
`key.enc` at `0600` (`custody/src/vault.ts`). A slot is a chain address, or
`seed:<uuid>` for an HD seed (`custody/src/vault.ts`). Writes are
`rename`-into-place, so a crash mid-rotation leaves the whole old blob or the
whole new one, never a truncated file.

**Nothing encrypted is in the database.** The database holds the row that says
which address belongs to whom, at which derivation path; the vault holds the key
material. You need both, plus the keyring.

### 1.5 The three artefacts, and why no two of them suffice

| Artefact | Holds | Alone it is |
| --- | --- | --- |
| **A.** Custody database | Ownership, chain, purpose, derivation path, `key_version` | A list of addresses you cannot spend |
| **B.** `CUSTODY_DATA_DIR` vault | Encrypted private keys, encrypted mnemonics | Ciphertext |
| **C.** The keyring file | `CUSTODY_MASTER_SECRET_V<n>` | 64 characters that unlock nothing |

A + B without C is unrecoverable. C without B is worthless. **A backup that puts
B and C on the same medium is not a backup with a key, it is a plaintext key
store with extra steps** — anyone who finds that medium has the coins.

Verified, both directions: see [Appendix A](#appendix-a--the-rehearsal-that-was-actually-performed),
where A + B with the wrong keyring recovered **0 of 10** blobs, and A + B + C
recovered **10 of 10**.

---

## 2. Routine backup

Run on the estate host. `$D` is the deploy checkout
(`/home/malf/dev/cloudsforge/deploy` on the estate host), `$P` the compose
project (`cloudsforge-estate` for mainnet, `cf-testnet` for testnet).

```bash
D=~/dev/cloudsforge/deploy; P=cloudsforge-estate
STAMP=$(date -u +%Y%m%dT%H%M%SZ); OUT=~/custody-backup/$STAMP
mkdir -p "$OUT" && chmod 700 "$OUT"

# ---- ARTEFACT A: the database
docker exec ${P}-postgres-1 pg_dump -U cloudsforge -d custody -Fc > "$OUT/custody-db.dump"

# ---- ARTEFACT B: the vault, directory names intact (§1.2: the slot name is authenticated)
docker run --rm -v ${P}_custody-keys:/vault:ro -v "$OUT":/out busybox:1.37 \
  tar -czf /out/custody-vault.tgz -C /vault/keys .

# ---- integrity, and a count you can check a restore against
sha256sum "$OUT"/custody-*.{dump,tgz} > "$OUT/SHA256SUMS"
tar -tzf "$OUT/custody-vault.tgz" | grep -c 'key\.enc$' > "$OUT/BLOB-COUNT"
docker exec ${P}-postgres-1 psql -U cloudsforge -d custody -tAc \
  "select 'keys='||count(*) from custody_keys" >> "$OUT/BLOB-COUNT"
docker exec ${P}-postgres-1 psql -U cloudsforge -d custody -tAc \
  "select 'seeds='||count(*) from custody_seeds" >> "$OUT/BLOB-COUNT"
cat "$OUT/BLOB-COUNT"     # blob count must equal keys + seeds
```

**Artefact C is deliberately not in that script.** The keyring is copied by hand,
to different media, by the procedure in §4. A backup script that also copied the
keyring would put B and C in one place on every run.

Cadence: A and B nightly, and **always immediately before a rotation**. C only
changes when it is rotated.

---

## 3. Disaster restore from cold media

The state this recovers from: the host is gone. You have the two files from §2 on
one medium and the keyring on another.

**Restore into a throwaway first if there is any doubt.** Everything below is
non-destructive to the artefacts.

```bash
# 0. Verify the media before trusting it.
cd /path/to/backup && sha256sum -c SHA256SUMS && cat BLOB-COUNT

# 1. Bring up postgres and the vault volume, then restore ARTEFACT A.
docker exec -i ${P}-postgres-1 psql -U cloudsforge -d postgres -c 'create database custody;'
docker exec -i ${P}-postgres-1 pg_restore -U cloudsforge -d custody --no-owner < custody-db.dump

# 2. Restore ARTEFACT B into the vault volume, as uid 1000, mode 0700.
docker run --rm -v ${P}_custody-keys:/vault -v "$PWD":/in busybox:1.37 sh -c \
  'mkdir -p /vault/keys && tar -xzf /in/custody-vault.tgz -C /vault/keys \
   && chown -R 1000:1000 /vault && chmod 700 /vault /vault/keys'

# 3. Put ARTEFACT C in place. Transcribe from paper or copy from the encrypted
#    stick; never echo it. Prove it arrived with a checksum, not with your eyes.
install -m 600 /media/keyring/custody.mainnet.env $D/compose/secrets/custody.mainnet.env
sha256sum $D/compose/secrets/custody.mainnet.env | cut -c1-16   # compare to the paper

# 4. Start custody and read the startup line.
docker compose -p $P -f $D/compose/docker-compose.estate.yml \
  -f $D/compose/docker-compose.release.yml up -d --wait custody
docker logs ${P}-custody-1 2>&1 | grep '"msg":"starting"'
```

The startup line reports `keyVersion` and `readableKeyVersions`
(`custody/src/index.ts`). **`readableKeyVersions` must contain every
version any restored blob carries.** Check the blobs' own stamps, which is one
command and does not decrypt anything:

```bash
docker exec ${P}-custody-1 sh -c \
  'cd /var/lib/custody/keys && for d in *; do head -c3 "$d/key.enc"; echo; done' | sort | uniq -c
```

### 3.1 The verification that actually proves a restore

A healthy container proves the keyring passed a *shape* check. It does not prove
it decrypts anything. **Drive one real signature**, or run the full check in
§5.3, which decrypts every blob and re-derives its public address from the
recovered private key. Address equality is the proof: it shows the recovered
plaintext is genuinely the spending key for that address.

Record the wall-clock time against the 1 h RTO in
`runbooks/runbook-restore-from-backup.md`. A drill that exceeds its RTO changes
the RTO or changes the method — it is never just noted.

---

## 4. The physical backup — what the owner must do

This is the half no script can do. The trade, stated plainly: **paper survives a
disk failure and is readable by anyone who finds it.** The disk is the more
likely failure; the paper is the more likely compromise. Do both copies, in two
different physical places.

Do it at the machine's own console, **not over SSH** — a value read over SSH is in
the scrollback of a second computer, and, if an agent is driving that session, in
a transcript file on disk. That is not hypothetical: see §7.

### 4.1 What goes on which medium

| Medium | Contents | Never on this medium |
| --- | --- | --- |
| **Paper 1**, home safe | Keyring value(s), per environment. Checksum, filename, date. The passphrase for USB 2 | Any blob, any database dump |
| **USB 2**, encrypted, off-site (relative's house, bank box) | `gpg -c` of the keyring file | The passphrase that opens it |
| **USB/disk 3**, off-site | Artefacts A + B from §2 — database dump and vault tarball | **The keyring. Ever.** |

The rule in one line: **the vault and the keyring must never share a medium, a
backup set, a cloud bucket or a filesystem.** Either one alone is safe to lose to
a thief. Together they are the coins.

Paper 1 and USB 2 hold the same secret in two forms, so they may not live in the
same building either. Disk 3 may live anywhere, because on its own it is
ciphertext.

### 4.2 The procedure

1. **Print the value with a checksum**, so a mis-transcription is caught now
   rather than discovered years later:

   ```bash
   cd ~/dev/cloudsforge/deploy
   f=compose/secrets/custody.mainnet.env
   grep '^CUSTODY_MASTER_SECRET_V' "$f"      # at the console only
   sha256sum "$f" | cut -c1-16               # the check — write this down too
   ```

2. **Write it out by hand, in block capitals.** It is 64 base64 characters per
   version. Base64 mixes case **and the case is significant**; mark the ambiguous
   glyphs (`0`/`O`, `1`/`l`/`I`) explicitly. Add the checksum, the filename, the
   environment (mainnet or testnet — they are different keyrings), the date, and
   the words "custody master secret — these are coins".

3. **Verify the paper before you trust it.** Transcribe it *back* from the paper
   into a scratch file and compare by checksum, never by eye:

   ```bash
   sha256sum /tmp/from-paper.env | cut -c1-16   # must equal step 1
   shred -u /tmp/from-paper.env
   ```

   A copy you have not read back is handwriting, not a backup.

4. **Second copy, encrypted, to USB 2**, with a passphrase used nowhere else:

   ```bash
   gpg -c --cipher-algo AES256 -o /media/usb/custody.mainnet.env.gpg "$f"
   ```

   The passphrase goes on Paper 1 — which is why Paper 1 and USB 2 live apart.

5. **Repeat per environment.** Mainnet and testnet hold different keyrings by
   design. Testnet is only worth the paper if that estate holds blobs; check
   before bothering.

6. **The miner coinbase keys are in the same position and are not covered by any
   of the above.** `~/dev/cloudsforge/miner-keys/{mainnet,testnet}/coinbase-key.json`
   hold a **plaintext** private key each, unencrypted and unversioned. They cannot
   be rotated without abandoning the balance at the address, so the paper copy is
   the only recovery path there will ever be. Same procedure, same discipline.

   They are also **bind-mounted read-write into the miner containers** at `/minerdata`,
   readable and writable by uid 1000 inside them — so container compromise reaches
   these keys without needing container escape. Tracked as **#206**.

7. **A `FORESIGHT_HOUSE_ADDRESS` key, if one is ever created, belongs on this list
   from the moment it exists.** It signs `stake(uint8)` calls, which custody has no
   shape for (`custody/src/signing.ts`), so it is a hot key outside custody
   with exactly the miner keys' properties — plaintext on disk, unrotatable without
   abandoning the address the public disclosure names. Back it up by §4.2 **before**
   funding it, and cap the exposure by leaving only a working balance there. The full
   argument and the operator procedure are in
   [`house-seed.md`](./house-seed.md) §2.

---

## 5. Key rotation

Rotate when the keyring is exposed, suspected exposed, or on a schedule. The
machinery exists precisely so that a compromise is survivable
(`custody/src/reencrypt.ts`).

> ### THE STEP THAT DESTROYS FUNDS IF SKIPPED
>
> **Every blob must be re-encrypted under the new version BEFORE the old secret
> is removed.** Replacing the secret without draining is not a rotation — it is
> every blob permanently undecryptable and every coin permanently unspendable,
> with no remedy, no support path and no vendor.
>
> The failure is silent at the moment you make it. The service boots, `/readyz`
> is green, new addresses mint correctly. It surfaces only when something tries to
> *spend* an old address. Demonstrated in [Appendix A](#a4-the-fatal-mistake-demonstrated):
> loading only the new secret while the blobs still carried the old stamp
> recovered **0 of 10**, with `no master secret for envelope version v1`.
>
> This is exactly the step an improviser omits, because everything looks fine
> without it.

### 5.1 Preconditions

```bash
D=~/dev/cloudsforge/deploy; P=cloudsforge-estate; OLD=2; NEW=3
# 1. TAKE A BACKUP FIRST (§2). The drain rewrites every blob in place.
# 2. Record what you are about to rotate.
docker exec ${P}-postgres-1 psql -U cloudsforge -d custody -tAc \
  "select key_version, count(*) from custody_keys group by 1 order by 1;
   select 'seeds', key_version, count(*) from custody_seeds group by 2 order by 2;"
docker exec ${P}-custody-1 sh -c \
  'cd /var/lib/custody/keys && for d in *; do head -c3 "$d/key.enc"; echo; done' | sort | uniq -c
```

Blob count must equal keys + seeds. Note the numbers; you will check them again
at the end.

### 5.2 The rotation

```bash
# ---- 1. Add the new secret. LEAVE THE OLD ONE IN PLACE. Never echoed.
umask 077
printf 'CUSTODY_MASTER_SECRET_V%s=%s\n' "$NEW" "$(openssl rand -base64 48)" \
  >> $D/compose/secrets/custody.mainnet.env
# ---- 2. Move the WRITE version. Reading is unaffected: it follows the blob's stamp.
sed -i "s/^CUSTODY_KEY_VERSION=.*/CUSTODY_KEY_VERSION=$NEW/" $D/compose/secrets/custody.mainnet.env
cut -d= -f1 $D/compose/secrets/custody.mainnet.env    # names only — confirm V$OLD and V$NEW both present

# ---- 3. Restart. New blobs are written at v$NEW; every old blob still decrypts.
docker compose -p $P -f $D/compose/docker-compose.estate.yml \
  -f $D/compose/docker-compose.release.yml up -d --force-recreate custody
docker logs ${P}-custody-1 2>&1 | grep '"msg":"starting"'
#   readableKeyVersions MUST list both. If it lists only one, STOP.

# ---- 4. DRAIN. The job does this every 30s by itself (custody/src/jobs.ts);
#         run the CLI to do it now and get a definitive exit code.
docker exec ${P}-custody-1 node --import tsx src/reencrypt-cli.ts; echo "exit=$?"
```

`reencrypt-cli` **exits non-zero while anything remains**
(`custody/src/reencrypt-cli.ts`), so `exit=0` is the same statement as "the
old secret can now be removed". It is restartable and cannot lose a key: per row
it writes the new blob first, then updates the row, and decrypts by the stamp the
blob carries rather than by the row (`custody/src/reencrypt.ts`). The
cost of a crash is doing one row twice.

The seeds are drained too (`custody/src/reencrypt.ts`) — a mnemonic is the
master key for every address of a (user, family), and rotating the keys but not
the thing they were derived from would be half a rotation.

```bash
# ---- 5. Confirm the finish line, three independent ways.
curl -s localhost:4107/metrics | grep custody_key_version_backlog   # must be 0
docker exec ${P}-postgres-1 psql -U cloudsforge -d custody -tAc \
  "select count(*) from custody_keys where key_version<$NEW and status<>'retired'"   # 0
docker exec ${P}-custody-1 sh -c \
  'cd /var/lib/custody/keys && for d in *; do head -c3 "$d/key.enc"; echo; done' | sort | uniq -c
#   every blob must read v$NEW:
```

`GET /v1/admin/rotation` (`custody/src/server.ts`) reports the same number for
an operator without shell access.

```bash
# ---- 6. ONLY NOW remove the old secret, and only if step 5 showed zero.
sed -i "/^CUSTODY_MASTER_SECRET_V$OLD=/d" $D/compose/secrets/custody.mainnet.env
docker compose -p $P -f $D/compose/docker-compose.estate.yml \
  -f $D/compose/docker-compose.release.yml up -d --force-recreate custody
docker logs ${P}-custody-1 2>&1 | grep '"msg":"starting"'
#   readableKeyVersions must now be [$NEW] alone.

# ---- 7. Back up the NEW keyring to paper and USB before you walk away (§4).
#         Until you do, the estate has one copy of it, on one disk.

# ---- 8. Sweep the WHOLE MACHINE for the retired secret. Step 6 changed a file;
#         it did not change any container that was created from that file
#         earlier, in this project or any other. See §5.5 — this is not optional.
```

A retained old secret is not a lesser secret — it decrypts every blob not yet
re-encrypted (`custody/src/env.ts`). It gets the same paper treatment for
as long as it exists, and it is destroyed the day it stops being needed.

### 5.3 The verification that proves a rotation

Backlog zero says the rows were updated. It does not say the blobs decrypt under
the new secret. Prove that directly: decrypt every blob and re-derive its public
address from the recovered private key.

```bash
docker exec -i ${P}-custody-1 node --import tsx --input-type=module - <<'EOF'
import postgres from 'postgres'
import { ethers } from 'ethers'
import { Keypair } from '@solana/web3.js'
import * as bitcoin from 'bitcoinjs-lib'
import xrpl, { Wallet as XrplWallet } from 'xrpl'
const { Keyring } = await import('/app/src/crypto.ts')
const { FileVault, seedSlot } = await import('/app/src/vault.ts')
const { ECPair, bitcoinNetwork } = await import('/app/src/chains.ts')
const { isValidMnemonic } = await import('/app/src/hd.ts')
const secrets = new Map()
for (const [n, v] of Object.entries(process.env)) {
  const m = /^CUSTODY_MASTER_SECRET_V([0-9]+)$/.exec(n); if (m && v) secrets.set(Number(m[1]), v)
}
const ring = new Keyring(secrets, Number(process.env.CUSTODY_KEY_VERSION))
const vault = new FileVault(process.env.CUSTODY_DATA_DIR || '/var/lib/custody/keys')
const sql = postgres(process.env.CUSTODY_DATABASE_URL, { max: 4, onnotice: () => {} })
const addr = (f, c, nw, k) =>
  f === 'evm' || f === 'ember' ? new ethers.Wallet(k).address
  : f === 'solana' ? Keypair.fromSecretKey(Buffer.from(k, 'base64')).publicKey.toBase58()
  : f === 'bitcoin' ? bitcoin.payments.p2wpkh({
      pubkey: Buffer.from(ECPair.fromWIF(k, bitcoinNetwork(c, nw)).publicKey),
      network: bitcoinNetwork(c, nw) }).address
  : XrplWallet.fromSeed(k, { algorithm: xrpl.ECDSA.secp256k1 }).classicAddress
let ok = 0, bad = 0
for (const r of await sql`select address, chain, network, family from custody_keys where status <> 'retired'`) {
  try { addr(r.family, r.chain, r.network, ring.decrypt(r.address, await vault.read(r.address))) === r.address
        ? ok++ : (bad++, console.log('MISMATCH', r.address)) }
  catch (e) { bad++; console.log('FAIL', r.address, e.message) }
}
let sok = 0, sbad = 0
for (const s of await sql`select id from custody_seeds`) {
  try { isValidMnemonic(ring.decrypt(seedSlot(s.id), await vault.read(seedSlot(s.id))))
        ? sok++ : (sbad++, console.log('BAD CHECKSUM', s.id)) }
  catch (e) { sbad++; console.log('FAIL seed', s.id, e.message) }
}
console.log(`keys ${ok} ok / ${bad} bad · seeds ${sok} ok / ${sbad} bad`)
await sql.end(); process.exit(bad + sbad === 0 ? 0 : 1)
EOF
```

It prints counts, public addresses and pass/fail. **It never prints key material,
and it must not be modified to.** Anything other than `0 bad` is a SEV1: stop, do
not remove the old secret, and restore from the §2 backup you took at step 5.1.

**Run it after step 6, not before, and read the first line it prints.** Run while
the old secret is still loaded it passes on a blob that is still encrypted under
that old secret — the keyring simply reaches for the version the envelope names
and finds it. That run proves the vault is readable; it does not prove the
rotation happened. Only the run where the script reports it holds the new version
alone distinguishes the two. On the local estate 2026-08-10 both runs were
performed deliberately: the first passed with `[2, 3]` loaded, the second passed
with `[ 3 ]`, and only the second is quoted as the proof.

The counts may be higher than the drain reported — 875 keys + 880 seeds drained,
1045 + 1030 verified. A live estate mints while you work, and everything minted
after `CUSTODY_KEY_VERSION` moved is written at the new version by definition.
That is why the drain converges instead of chasing its own tail, and a count that
grew is expected rather than alarming. A count that *shrank* is not.

### 5.4 Recovering from a skipped drain

This is not hypothetical. On 2026-08-05 the local estate was found in exactly this
state: **509 blobs stamped `v1:` with only a V2 secret loaded** — the old secret
had been removed without draining. Every one of those blobs was unreadable by the
service, and every address behind them unspendable.

If you find yourself here, do not panic and do not `down -v`. The blobs are
intact; only the secret that opens them is missing. Recovery is possible **if and
only if the old secret still exists somewhere**:

1. **Find the old secret.** In this estate's case it was the placeholder literal
   that had been committed to the public compose file and was still readable in
   git history:

   The variable name is held in `var` rather than written out twice, and that is
   not a style preference. CI fails any tracked file where a
   `CUSTODY_MASTER_SECRET_V<n>` is followed by a value, and the `sed` below spelled
   the name out ahead of `*//` — which is that shape exactly, so this recovery
   procedure failed the build for being *about* the secret. The guard is right and
   is left alone; the document stops looking like the defect instead.

   ```bash
   umask 077
   var=CUSTODY_MASTER_SECRET_V1
   git show <commit>^:compose/docker-compose.estate.yml \
     | grep -m1 "^ *$var:" \
     | sed -E "s/^ *$var: *//" | tr -d '\n' > /tmp/.old-secret
   ```

   Other places to look, in order: the paper backup (§4), the encrypted USB, the
   pre-rotation copy of the secrets file, a container that has not been recreated
   since (`docker inspect` shows its baked env). **If none of them has it, the
   coins are gone and nothing in this document changes that.**

2. **Back up first** (§2). You are about to rewrite every blob.

3. **Drain out of band.** The recovered secret usually cannot go in the env file —
   a placeholder is refused by the boot guard (§8), which is working as intended.
   So build the keyring by hand and call the real `reencryptOnce`, passing the old
   secret through the environment of a single command rather than writing it
   anywhere:

   ```bash
   docker exec -i -e "CF_RECOVERED=$(cat /tmp/.old-secret)" ${P}-custody-1 \
     node --import tsx --input-type=module - <<'EOF'
   import postgres from 'postgres'
   import { Logger } from '@cloudsforge/telemetry'
   const { Keyring } = await import('/app/src/crypto.ts')
   const { FileVault } = await import('/app/src/vault.ts')
   const { reencryptOnce, remainingCount } = await import('/app/src/reencrypt.ts')
   const secrets = new Map()
   for (const [n, v] of Object.entries(process.env)) {
     const m = /^CUSTODY_MASTER_SECRET_V([0-9]+)$/.exec(n); if (m && v) secrets.set(Number(m[1]), v)
   }
   secrets.set(1, process.env.CF_RECOVERED)          // the version the lost blobs carry
   const TARGET = Number(process.env.CUSTODY_KEY_VERSION)   // the version the SERVICE holds
   const ring = new Keyring(secrets, TARGET)
   const sql = postgres(process.env.CUSTODY_DATABASE_URL, { max: 4, onnotice: () => {} })
   const deps = { sql, vault: new FileVault('/var/lib/custody/keys'), keyring: ring,
                  logger: new Logger({ service: 'custody-recovery', level: 'error', version: 'recovery', env: 'production' }) }
   console.log('remaining', await remainingCount(sql, TARGET))
   for (;;) { const r = await reencryptOnce(deps)
     if (r.keys === 0 && r.seeds === 0) break
     console.log(`keys=${r.keys} seeds=${r.seeds} failures=${r.failures} remaining=${r.remaining}`) }
   console.log('done, remaining', await remainingCount(sql, TARGET)); await sql.end()
   EOF
   shred -u /tmp/.old-secret
   ```

   **`TARGET` must be a version the running service actually holds.** Draining to
   a version whose secret is not in the service's environment converts a partial
   outage into a total one — the blobs become unreadable by the service that needs
   them. Check the startup line's `readableKeyVersions` first.

4. **Verify with §5.3**, then rotate properly per §5.2 to get off the recovered
   secret, which is by definition a burned one.

Performed on the local estate 2026-08-05: 262 keys + 247 seeds re-encrypted,
**0 failures**, backlog 0, and afterwards 283/283 keys and 268/268 seeds verified
readable under the service's own keyring.

### 5.5 The rotation is not finished when the file changes

Steps 1–7 above rotate a **file** and re-create **one** container. That is not the
same as removing the retired secret from the machine, and on 2026-08-10 the
difference was live on the workstation estate: the rotation of §5.2 had completed,
every check in §5.5 was zero, §5.3 passed with the new version alone — and three
containers were still holding retired key material.

Two mechanisms, both of which survive a correctly performed §5.2:

1. **Compose bakes the environment at container *create* time.** A container
   created from the secrets file before the rotation keeps the old value in its
   `Config.Env` for as long as the container object exists. `docker restart`
   re-reads nothing; only `--force-recreate` does.

2. **A second compose *project* can read the same secrets file.** Scoping the
   rotation to `-p cloudsforge-estate` reaches nothing in `-p cf-erasure`, even
   though both were brought up from this repository's own
   `docker-compose.estate.yml` with the same `--env-file` pair.

The quiet case is the one-shot `*-migrate-1` containers. They run for seconds,
exit 0, are never looked at again, and carry a **full copy of the keyring** in
their config indefinitely. On 2026-08-10 `cloudsforge-estate-custody-migrate-1`
was still holding V1 — the secret that had been *publicly disclosed*, four days
after that was resolved and long after V1 stopped being in any secrets file.

So finish every rotation with a sweep of the whole machine. Fingerprints only:

```bash
for c in $(docker ps -a --format '{{.Names}}'); do          # -a: STOPPED ONES TOO
  out=$(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | grep '^CUSTODY_MASTER_SECRET_V' \
        | while IFS='=' read -r n v; do
            printf '%s=%s ' "$n" "$(printf '%s' "$v" | sha256sum | cut -c1-12)"
          done)
  [ -n "$out" ] && printf '%-40s %-9s %s\n' \
    "$c" "$(docker inspect "$c" --format '{{.State.Status}}')" "$out"
done
#   The retired fingerprint must appear NOWHERE. Not in a stopped container,
#   not in another project, not in a migrate container.
```

It prints names, container states and 12-character SHA-256 fingerprints, never a
value — which is also what makes it safe to paste the output into an issue.

Clearing what it finds:

- **Exited one-shot migrate containers:** `docker rm` them. They are artefacts;
  the next deploy creates them again with current environment.
- **A running container in another project:** re-create it on the new file. If it
  owns custody data, that is a full §5.2 rotation of *its* estate, not a
  re-create — check `custody_keys`/`custody_seeds` counts and the vault file
  count before you decide which. `cf-erasure` held 0 keys, 0 seeds and an empty
  vault, so a plain re-create was correct there and would have been destructive
  had any of the three been non-zero.

**`CF_PORT_BASE` is a shell variable, not an entry in either `--env-file`.** A
second project on one host must publish on a different base, so re-creating one
of its containers with the estate's base fails with
`Bind for 127.0.0.1:4107 failed: port is already allocated`. It appears in no
compose file; recover it from the published ports of that project's *siblings*
(`docker ps --format '{{.Names}}\t{{.Ports}}'`) and pass it on the command line.

---

## 6. What breaks, precisely, if the keyring is lost

- Every custody address becomes unspendable, for ever.
- Every HD seed becomes unrecoverable, so no user can ever be given their
  recovery phrase — the phrase exists only inside the encrypted blob.
- Deposits already made stay visible on chain, provably owned by an address
  nobody can sign for.
- The database and the vault survive and are worthless. **Backing up the volume
  and not the keyring is the same as backing up nothing.**

---

## 7. Handling discipline, and why it is written down here

A master secret is compromised by being *displayed*, far more often than by being
stolen. On 2026-08-05 two agent sessions read live keyring files and the values
landed in transcript `.jsonl` files on disk; three of the estate's four keyrings
had to be rotated as a result. Nothing was stolen and no coin moved — the values
were simply printed, and a printed secret is an exposed secret.

So, for humans and agents alike:

- **Never `cat`, `echo`, `grep -r` or interpolate a secrets file** in a session
  whose output is recorded. Move values file-to-file (`cp`, `install -m 600`,
  `printf ... >> file`) and prove them with `sha256sum`, `cut -d= -f1` (names
  only) or a character count.
- **`docker exec ... env` prints the keyring.** Filter it:
  `env | grep -o '^CUSTODY_MASTER_SECRET_V[0-9]*'` prints the names alone.
- **Rotate on exposure, not on proof of theft.** A rotation costs one drain. The
  alternative costs the coins.
- Grep your own transcripts before assuming you are clean:
  `grep -rlF -f <(cut -d= -f2- secrets/custody.mainnet.env) ~/.claude/projects/`
  — write the pattern file at `umask 077` and delete it afterwards.

### 7.1 The 2026-08-05 exposure, for the record

Scanned rather than assumed. Of the estate's four keyrings, **three** were found
verbatim in agent transcript files on disk:

| Keyring | Exposed | Where |
| --- | --- | --- |
| Estate host, mainnet | **Yes**, 4 occurrences | one subagent transcript |
| Local estate, mainnet | **Yes**, 2 occurrences | one subagent transcript |
| Local estate, testnet | **Yes**, 2 occurrences | the same transcript |
| Estate host, testnet | No | — |

The values were not found in git, in shell history, or in any deployment log —
the exposure is confined to those two files. The estate-host mainnet keyring was
rotated to V3 the same day (Appendix B). The two local ones are recorded as
outstanding in Appendix B.3.

**The V1 placeholder that predates all of this remains readable in public git
history for ever**, and that is now more than a historical note: it was the only
reason the local estate's 509 orphaned blobs could be recovered at all (§5.4). It
still protects nothing on the estate host, where no blob has carried a `v1:` stamp
since the first drain — but any old snapshot of a vault taken before that drain is
plaintext to anybody who reads the repository. **Destroy pre-rotation vault
backups rather than filing them.**

---

## 8. The boot guard is NOT in the shipped image

`custody/src/env.ts` (`assertMasterSecret`) refuses a master secret that
is not base64/hex, carries under 32 bytes, falls below a measured entropy floor,
or contains a placeholder marker. Verified 2026-08-05 against the image the estate
host actually runs, `ghcr.io/cloudsforge-online/micro-custody:1.0.0`, built
2026-08-04:

| Symbol | Working tree | Shipped image |
| --- | --- | --- |
| `assertMasterSecret` | present | **absent** |
| `entropyPerChar`, `MIN_SECRET_BYTES`, `SECRET_MARKERS` | present | **absent** |
| `requiredSecret`, `PLACEHOLDERS` (the old 10-string deny-list) | present | present |
| `Keyring`, `encryptAs`, `reencryptOnce`, `collectMasterSecrets` | present | present |

So open issue #25 is right: **the guard exists only in the working tree.** A
deploy of the current release can still boot custody on any 32-character string
that is not one of ten literals. The rotation machinery, by contrast, *is* in the
shipped image — which is why the estate-host rotation in Appendix B could be
performed with the deployed release and no rebuild.

Until custody is rebuilt and re-released, the only thing standing between this
estate and a placeholder keyring is the operator. Generate with
`openssl rand -base64 48`, and check the startup line before walking away.

---

## Appendix A — the rehearsal that was actually performed

Executed 2026-08-05 against a **throwaway** custody: a dedicated
`postgres:17-alpine` container on `127.0.0.1:55432`, a vault under
`/tmp/custody-rehearsal/vault`, and freshly generated throwaway secrets. **The
live database, the live vault and the live keyring were not touched.** All
production code paths were the real ones — `provisionAddress`, `FileVault`,
`Keyring`, `src/index.ts` and `src/reencrypt-cli.ts`, unmodified.

### A.1 Session A — a custody that exists before the disaster

Six addresses minted through `provisionAddress`, across five chains and both
schemes, producing 6 key blobs + 4 seed blobs = **10 blobs, all stamped `v1:`**.

```
minted  ethereum  mainnet  hd_bip44    0x052E650bE704c5D37cA06EC13b10Bc8cccF83c04
minted  bitcoin   mainnet  hd_bip44    bc1qky63mqwllsp3fyz33xzwuzwusc8pfdfpa2svwt
minted  litecoin  mainnet  hd_bip44    ltc1qshueh8v43znrydntdgmkj2zqs3d536qq8g069u
minted  solana    mainnet  hd_bip44    DbBMJhwaPMa5sALdT43QNs6QiYNBnfXYsNWvwyDHdDPg
minted  xrp       mainnet  hd_bip44    rssYXjkbftwKJHcTgT7o4r1YSr5dtSmjdY
minted  ethereum  testnet  flat_random 0x42fC2dAdb7A9247F84171Ee547083Ac3e47Fa432
```

Cold artefacts taken per §2: `custody-db.dump`, `custody-vault.tgz`, and the
keyring copied to a separate directory standing in for separate media.

### A.2 The disaster, and the restore

Database dropped (`drop database ... with (force)`), vault directory `rm -rf`'d.
Verified gone: 0 databases named `custody_rehearsal`, no vault directory. Then
restored from the three cold artefacts alone: **6 keys, 4 seeds, 10 blobs**.

**Negative control first** — artefacts A + B restored, but with a freshly
generated wrong keyring:

```
RESULT keys 0/6 recovered · seeds 0/4 recovered
      (all: "Unsupported state or unable to authenticate data")
```

**Then with the cold keyring:**

```
keyring: writeVersion=v1 readableVersions=[1]
PASS  v1: ethereum  hd_bip44    0x052E650bE704c5D37cA06EC13b10Bc8cccF83c04
PASS  v1: bitcoin   hd_bip44    bc1qky63mqwllsp3fyz33xzwuzwusc8pfdfpa2svwt
PASS  v1: litecoin  hd_bip44    ltc1qshueh8v43znrydntdgmkj2zqs3d536qq8g069u
PASS  v1: solana    hd_bip44    DbBMJhwaPMa5sALdT43QNs6QiYNBnfXYsNWvwyDHdDPg
PASS  v1: xrp       hd_bip44    rssYXjkbftwKJHcTgT7o4r1YSr5dtSmjdY
PASS  v1: ethereum  flat_random 0x42fC2dAdb7A9247F84171Ee547083Ac3e47Fa432
PASS  v1: seed evm      24-word phrase, BIP-39 checksum valid, 1 address re-derived identically
PASS  v1: seed bitcoin  24-word phrase, BIP-39 checksum valid, 2 addresses re-derived identically
PASS  v1: seed solana   24-word phrase, BIP-39 checksum valid, 1 address re-derived identically
PASS  v1: seed xrp      24-word phrase, BIP-39 checksum valid, 1 address re-derived identically

RESULT keys 6/6 recovered · seeds 4/4 recovered
```

Every address was re-derived from its recovered private key and compared;
every mnemonic was checked against its BIP-39 checksum and used to re-derive
its children. **This is a session that decrypted addresses it did not generate.**

The real service was then booted against the restored state
(`node --import tsx src/index.ts`), reaching ready in 4 s:

```
{"msg":"starting","schemaVersion":7,"keyVersion":1,"readableKeyVersions":[1]}
{"msg":"listening","port":4599}
/readyz → {"ready":true,...,"postgres":"pass"}
custody_key_version_backlog 0
```

### A.3 The rotation drill

```
re-encryption starting  writeVersion=2 readableVersions=[1,2] remaining=10
re-encryption complete  keys=6 seeds=4 failures=0 remaining=0     exit=0
envelope stamps on disk: 10 × v2:
```

Then with the old secret removed, the new one alone:

```
keyring: writeVersion=v2 readableVersions=[2]
RESULT keys 6/6 recovered · seeds 4/4 recovered
```

### A.4 The fatal mistake, demonstrated

Loading only the new secret while every blob still carried the old stamp — that
is, replacing the keyring without draining:

```
RESULT keys 0/6 recovered · seeds 0/4 recovered
FAIL  v1: seed evm  no master secret for envelope version v1 — set CUSTODY_MASTER_SECRET_V1
```

Ten blobs, zero recoverable. On the live estate that number is every address the
platform holds.

### A.5 Teardown

Throwaway container removed, working directory and every throwaway secret shredded.

---

## Appendix B — the live rotation, performed by following §5

Executed 2026-08-05 on the estate host (`miner`, `192.168.1.42`), mainnet estate,
after the rehearsal above and by following §5 step for step. Trigger: the keyring
was found in an agent transcript (§7.1).

### B.1 The record

| Step | Result |
| --- | --- |
| Preconditions (§5.1) | 222 keys + 213 seeds, **435 blobs all `v2:`**, backlog 0 |
| Backup (§2) | `~/custody-backup/20260805T085122Z` — 437 blobs / 223 keys / 214 seeds, `SHA256SUMS` written |
| Add V3, keep V2, `CUSTODY_KEY_VERSION=3` | file holds `V2` + `V3`; V3 is 64 base64 chars from `openssl rand -base64 48` |
| Restart | `keyVersion:3, readableKeyVersions:[2,3]` — both loaded, container healthy |
| **Drain** (`src/reencrypt-cli.ts`) | `writeVersion=3 readable=[2,3] remaining=386` → `keys=129 seeds=137 failures=0 remaining=0`, **exit 0** |
| Verify backlog | rows: keys `3\|223`, seeds `3\|214`; disk: **437 × `v3:`**; metric `custody_key_version_backlog 0` |
| Full decrypt check (§5.3) | **keys 223 ok / 0 bad · seeds 214 ok / 0 bad** |
| Remove V2, restart | `keyVersion:3, readableKeyVersions:[3]` — the exposed secret is gone |
| Final decrypt check under V3 alone | **keys 224 ok / 0 bad · seeds 215 ok / 0 bad** |

No customer key was lost, no service went unhealthy, and total elapsed time from
first precondition query to final verification was **under 10 minutes**.

### B.2 Two things the rehearsal did not predict

- **The drain competes with the background job, and the arithmetic looks wrong.**
  The CLI reported `remaining=386` at start but only re-encrypted 266 blobs itself.
  The recurring `custody.reencrypt` job (`custody/src/jobs.ts`, every 30 s,
  batch 50) had already taken the rest. This is correct behaviour and the counters
  are per-process, not per-rotation. **Judge completion by `remaining=0` and the
  exit code, never by comparing the two numbers.**
- **The estate mints addresses during the rotation.** The blob count rose from 435
  to 439 across the window. New blobs are written at the new version immediately
  after the restart, so they need no drain — which is exactly why the write version
  moves *before* the drain rather than after.

### B.3 The local estate, finished 2026-08-10

The **local estate's** mainnet and testnet keyrings were exposed by the same
incident (§7.1). They stayed unrotated for five days behind a blocker worth
naming, because it is the kind that looks permanent and is not: the committed
`compose/docker-compose.estate.yml` requires `compose/secrets/outbox.mainnet.env`,
which did not exist in the local checkout, so `docker compose up` refused before
it started — and a keyring change only takes effect on container **re-creation**.
A missing file two directories away from custody held a key rotation shut.

Both are now rotated, on 2026-08-10, and the record is micro-org#144.

- **Mainnet, V2 → V3, full §5.2.** Backup first (`vault.tar`, 4139 entries).
  Drain: 875 keys + 880 seeds, **0 failures**, remaining 0. Then all three §5.5
  checks zero, old secret removed, `readableKeyVersions:[3]` alone, and §5.3 run
  against the new version by itself: **1045 keys ok / 0 bad, 1030 seeds ok / 0
  bad**. Every key here is ember/EVM, so that proof exercised one of the four
  address families; the host's data exercises the rest.
- **Testnet, replaced outright, no drain.** Correct precisely because it
  encrypted nothing: 0 containers in project `cf-testnet`, no
  `cf-testnet_custody-keys` volume, no local testnet postgres. It is also a
  different secret from the host's testnet keyring, which was never exposed. The
  retired value was deliberately **not** backed up — nothing decrypts with it, so
  a backup would only be one more copy of exposed material.

**What the rotation did not reach, and §5.5 now exists for.** With all of the
above green, a sweep of every container on the machine found the retired
mainnet V2 still baked into a *running* `cf-erasure-custody-1` from a second
compose project, into its exited migrate container, and — worse — found the
publicly disclosed **V1** still baked into the estate's own exited
`custody-migrate-1`. Nothing in §5.2 as written would ever have looked there.
