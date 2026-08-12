# Seal a miner coinbase key

**Not triggered by an alert.** A procedure, run once per host per network.
**Owner** platform · **Related** micro-org#206

Turns a plaintext `coinbase-key.json` into a scrypt + AES-256-GCM
`coinbase-keystore.json` without changing the address, so the mined balance is
not abandoned.

This lived as an untracked `.tmp-seal-mainnet.sh` in a workspace root until
2026-08-12. It is here because a procedure that touches the only key material in
the estate with no recovery path should not be a file somebody happens to still
have.

## When you need this

- A new mining host is being brought up.
- A key is still plaintext at rest on some host. Check by filename only:

  ```bash
  ssh malf@192.168.1.42 'ls -l /home/malf/dev/cloudsforge/miner-keys/*/'
  ```

  `coinbase-key.json` present and no `coinbase-keystore.json` beside it means
  unsealed.

Both estate mining hosts were sealed on 2026-08-11:

| Host | Network | Address |
| --- | --- | --- |
| chain, `192.168.1.42` | mainnet | `0x980d52a868d41a34a186ce890874c8e547975b45` |
| chain, `192.168.1.42` | testnet | `0x91a11854b364178ed96054d8a6e9be1dbd751d33` |
| app, `192.168.1.129` | mainnet | `0x2098b519aaf94e704534c6de35c5c516723dcca8` |
| app, `192.168.1.129` | testnet | `0xfba76ee8ed2787a6efd23f8e1bc649a7cd23c15e` |

Addresses are public and on chain. They are safe here; nothing else on this page
is.

## Rules that hold for every step

- **Never print a key or a passphrase.** Addresses, byte counts and
  `sha256sum | cut -c1-12` fingerprints only. A fingerprint of a 64-byte random
  value proves two files match without disclosing either.
- **Generate the passphrase on the host, into a file, with `umask 077`.** Never
  type one, never paste one, never let one reach a terminal that scrolls into a
  transcript or a log.
- **Do not delete the plaintext key at the end.** See *Afterwards*.
- The keystore's `address` field is plaintext by design and is not a secret. It
  is what makes the backup's `publicRef` constraint satisfiable without touching
  the ciphertext.

## The procedure

Set these for the host and network you are sealing. `IMG` must be the digest or
`sha-` tag of the hearth-node image the miner is actually running — read it from
the running container, not from the repo.

```bash
IMG=ghcr.io/cloudsforge-online/hearth-node:sha-fcc2738c3ca6931fbbbe58b2be4db0931bbda748
NET=mainnet
KEYS=/home/malf/dev/cloudsforge/miner-keys/$NET
SECRETS=/home/malf/secrets
PASSFILE=$SECRETS/ember-coinbase-$NET.pass
EXPECT=0x980d52a868d41a34a186ce890874c8e547975b45
```

On the app host the equivalents are
`KEYS=/home/savvaniss/dev/cloudsforge/miner-keys/$NET` and
`PASSFILE=/home/savvaniss/dev/cloudsforge/miner-keys/secrets/coinbase-passphrase`
— one passphrase covering both networks there, per-network files on the chain
host. The backup runner tries all three layouts (`minerKeySources()` in
`backup/src/secrets.ts`), so either is fine; do not invent a fourth.

### 0. Preconditions

```bash
[ -f "$KEYS/coinbase-key.json" ] || { echo "FATAL: no plaintext key at $KEYS"; exit 1; }
BEFORE=$(sha256sum "$KEYS/coinbase-key.json" | cut -c1-12)
echo "plaintext fingerprint BEFORE: $BEFORE"
python3 -c 'import json,sys;print("address in file:", json.load(open(sys.argv[1]))["address"])' "$KEYS/coinbase-key.json"
echo "expected:        $EXPECT"

if [ -f "$KEYS/coinbase-keystore.json" ]; then
  echo "STOP: a keystore already exists. Sealing again would overwrite it."
  ls -l "$KEYS/coinbase-keystore.json"
  exit 3
fi
```

The address in the file must equal `$EXPECT`. If it does not, you are about to
seal the wrong network's key — stop.

The existing-keystore check is a hard stop and not a prompt. Overwriting a
keystore whose passphrase has been lost destroys the key with no error message.

### 1. The passphrase

```bash
umask 077
mkdir -p "$SECRETS"; chmod 700 "$SECRETS"
if [ -s "$PASSFILE" ]; then
  echo "passphrase already present, reusing it"
else
  openssl rand -base64 48 | tr -d '\n' > "$PASSFILE"
  echo "generated a new passphrase"
fi
chmod 600 "$PASSFILE"
echo "length: $(wc -c < "$PASSFILE") bytes"
echo "fingerprint: $(sha256sum "$PASSFILE" | cut -c1-12)"
```

48 random bytes base64-encoded is 64 characters, which is what `wc -c` should
report. `openssl rand` and not a human-chosen string: this passphrase is never
typed, so it has no reason to be memorable and every reason to be uniform random.

Reuse rather than regenerate is deliberate. A second run of this procedure after
an interrupted first must not strand the keystore the first run may have written.

### 2. Seal

```bash
docker run --rm \
  -v "$KEYS":/minerdata \
  -v "$PASSFILE":/run/coinbase.pass:ro \
  -e HEARTH_COINBASE_PASSPHRASE_FILE=/run/coinbase.pass \
  -e HEARTH_NO_TTY=1 \
  --entrypoint node "$IMG" bin/hearth.js minerkey seal --data /minerdata --no-color
```

The passphrase is a **file** mount and not an argument, because `/proc/<pid>/cmdline`
is world-readable. `HEARTH_NO_TTY=1` stops the CLI prompting into a
non-interactive shell and hanging.

### 3. Prove the seal did not touch the plaintext

```bash
AFTER=$(sha256sum "$KEYS/coinbase-key.json" | cut -c1-12)
echo "plaintext fingerprint AFTER: $AFTER"
[ "$BEFORE" = "$AFTER" ] && echo "UNTOUCHED: YES" || echo "UNTOUCHED: NO  <-- STOP"
ls -l "$KEYS"
```

`NO` here means the only recovery path was modified by a step that had no
business writing to it. Stop and establish what changed before doing anything
else.

### 4. Prove the keystore derives the same address

This is the step the whole procedure exists for. A keystore that opens to a
different address is a new key, and the mined balance stays at the old one.

```bash
docker run --rm \
  -v "$KEYS":/minerdata:ro \
  -v "$PASSFILE":/run/coinbase.pass:ro \
  -e HEARTH_COINBASE_PASSPHRASE_FILE=/run/coinbase.pass \
  -e HEARTH_COINBASE_SOURCE=keystore \
  -e HEARTH_NO_TTY=1 \
  --entrypoint node "$IMG" bin/hearth.js minerkey verify --data /minerdata --address "$EXPECT" --no-color
echo "verify exit: $?"

docker run --rm \
  -v "$KEYS":/minerdata:ro \
  -v "$PASSFILE":/run/coinbase.pass:ro \
  -e HEARTH_COINBASE_PASSPHRASE_FILE=/run/coinbase.pass \
  -e HEARTH_COINBASE_SOURCE=keystore \
  -e HEARTH_NO_TTY=1 \
  --entrypoint node "$IMG" bin/hearth.js minerkey status --data /minerdata --no-color
```

Exit 0 on `verify`, or the seal has not succeeded no matter what step 2 printed.
Mounts are `:ro` from here on — verification must not be able to modify what it
is verifying.

### 5. Point the miner at the keystore

Set `HEARTH_COINBASE_SOURCE=keystore` and the passphrase file mount on the miner
itself, and restart it. Confirm from the running container, not the repo:

```bash
docker inspect <miner-container> --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1 | grep HEARTH_COINBASE
```

Then confirm the next block is credited to `$EXPECT` and not to a new address.
That is the only end-to-end proof that the miner is reading the keystore.

## Afterwards

**Do not delete `coinbase-key.json`.** It is the only recovery path that exists
if the passphrase is lost, and with `HEARTH_COINBASE_SOURCE=keystore` the miner
no longer reads it. Deleting it converts one 0600 file on one disk from "the
backup" into "nothing", which is the wrong direction for an issue about a key
having no backup.

It becomes safe to delete when — and only when — a `secrets` artefact containing
the keystore **and** its passphrase has been decrypted off-host and shown to
re-derive `$EXPECT`. See `runbooks/runbook-miner-coinbase-key-backup.md`, which
is also where the reasons the backup may be empty are written down.

## Related

- `runbooks/runbook-miner-coinbase-key-backup.md` — getting the sealed keystore
  into a backup that can actually be opened.
- `docs/custody-backup-restore.md` §4.2 step 6 — why this key has no rotation
  path, and what that costs.
