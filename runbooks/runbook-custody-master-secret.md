# Rotating the custody master secret

**Owner** custody · **Referenced by** `.gitignore:23`, `runbooks/runbook-restore-from-backup.md`
(§ RPO/RTO table, as custody's restore dependency) · **Closes** micro-org#25 item 2

`CUSTODY_MASTER_SECRET_V<n>` is the key-encryption key for every custodied private key and every
HD seed on the estate. Rotating it re-encrypts that material under a new version; it does not
change a single on-chain address, and no user-visible thing moves.

Two documents already pointed here before this file existed. That is why it exists.

---

## When to run this

- **An exposure.** The secret reached a transcript, a log, a public repository, a screenshot.
  Rotation is the whole remedy; nothing else reduces the exposure.
- **A rehearsal.** SD-06 asks for a quarterly rehearsal on testnet. A procedure nobody has
  performed is a procedure that does not work — every step below has been wrong at least once in
  some estate, and a rehearsal is how you find out which one here.
- **Never on a schedule alone.** Rotation is a live re-encryption over every custodied key. It
  earns its risk when there is a reason.

## What you need before you start

- Shell on the app host (`savva@192.168.1.129`, inside WSL — see the estate host memo).
- The current keyring file: `compose/secrets/custody.<estate>.env`, mode 0600, gitignored.
- 32 bytes of fresh entropy. `openssl rand -base64 32`. **Not** a memorable string: `env.ts`
  `assertMasterSecret` enforces base64-or-hex, exactly 32 decoded bytes, and an entropy floor
  calibrated over 200,000 samples, with an exact deny-list and no escape hatch. A placeholder is
  refused at boot, which is the guard that would have caught the V1 literal.

## The shape of the thing

The keyring holds **every** version, and `CUSTODY_KEY_VERSION` names the one used for new writes:

```
CUSTODY_MASTER_SECRET_V3=<old, still needed to READ existing ciphertext>
CUSTODY_MASTER_SECRET_V4=<new>
CUSTODY_KEY_VERSION=4
```

Removing the old version before the backlog is drained makes every row still encrypted under it
**permanently unreadable**. That is the one irreversible mistake available here, and step 5 exists
solely to prove it cannot be made.

---

## Procedure

### 1. Mint the new secret

```sh
openssl rand -base64 32
```

### 2. Add it beside the old one, and move the pointer

Edit `compose/secrets/custody.<estate>.env`. **Add**, never replace:

```
CUSTODY_MASTER_SECRET_V<n+1>=<the new value>
CUSTODY_KEY_VERSION=<n+1>
```

Keep every previous `CUSTODY_MASTER_SECRET_V<n>` line exactly as it is.

### 3. Restart custody

Through the release script, never a bare `docker compose up` — a bare up drops `mainnet.env` and
public hostnames degrade to `localtest.me`:

```sh
./scripts/release-deploy.sh <current-version>
```

New writes are now under the new version. Existing ciphertext is untouched and still readable,
because the old secret is still in the keyring.

### 4. Drain the backlog

The job in `jobs.ts` drains on its own every thirty seconds. To close the window now — which is
what you want during an incident, since the interval between "believed compromised" and "actually
retired" *is* the exposure:

```sh
docker exec cloudsforge-estate-custody-1 node src/reencrypt-cli.ts
```

It **exits non-zero while anything remains**, so it is safe in a loop or a deploy gate. Its
success is the same statement as "the old secret can now be removed".

```sh
until docker exec cloudsforge-estate-custody-1 node src/reencrypt-cli.ts; do sleep 10; done
```

### 5. Prove the backlog is empty before removing anything

Do not trust the exit code alone. Ask the database, which is the thing that would be lost:

```sh
docker exec cloudsforge-estate-postgres-1 psql -U cloudsforge -d custody -A -F' | ' -c "
  select 'custody_keys' t, key_version, count(*) from custody_keys group by 2
  union all
  select 'custody_seeds', key_version, count(*) from custody_seeds group by 2
  order by 1,2;"
```

Every row must name the new version and only the new version. If any older version appears, go
back to step 4 — **do not proceed**.

### 6. Retire the old secret

Only now, delete the `CUSTODY_MASTER_SECRET_V<n-1>` line, and redeploy as in step 3. Verify
custody comes back healthy; it will refuse to boot on a malformed or low-entropy keyring, which is
the intended failure and not a reason to weaken step 1.

### 7. Put the new keyring where losing the host cannot lose it

**The keyring is deliberately NOT in the automated backup.** `backup/setup-destination.sh` says so
in as many words, and the runner refuses to boot if the keyring is ever placed in its environment:
the destination holds the custody *vault* (ciphertext, artefact B) and the age-encrypted miner key,
and never artefact C. Ciphertext and the key that opens it must not share a resting place.

So this step is manual, and it is the step that actually protects the estate:

- write the new keyring to paper, and to an encrypted USB device, per
  `docs/custody-backup-restore.md` §4;
- store them apart from the host and from each other;
- record the date and the version rotated to — not the value — in the operations log.

Skipping this converts a host failure into unrecoverable ciphertext for every custodied key. The
automated backup will keep going green while that is true, because it is backing up the half that
is useless on its own.

---

## Rolling back

Before step 6, rollback is free: set `CUSTODY_KEY_VERSION` back to the old version and redeploy.
Material written under the new version stays readable, because the new secret is still present.

**After step 6 there is no rollback.** The old secret is gone and anything still under it is
ciphertext nobody can open. That is the entire reason step 5 asks the database rather than
believing a command.

## What rotation does not do

- It does not undo a disclosure. A secret that reached a public place stays there; rotation makes
  it worthless, which is the best available outcome and is not the same thing.
- It does not change any address, balance, or on-chain fact.
- It does not rotate the *testnet* keyring. The two estates resolve to separate keyrings by
  design, and CI asserts they are separate. Rotate each deliberately.
