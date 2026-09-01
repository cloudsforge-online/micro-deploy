# The custody master secret, and how to rotate it without losing a key

## Read this first

`CUSTODY_MASTER_SECRET_V<n>` is the **key-encryption key**. It is not a key that signs
or authenticates anything — it is the key that every custodied private key and every HD
seed on the estate is encrypted *under*. There is one per version, and the estate holds
the versions it can still read.

Two facts decide everything below, and they point in opposite directions:

- **Losing it is unrecoverable.** The vault is ciphertext. Without the keyring it is
  ciphertext for ever, and no backup of the vault changes that.
- **Rotating it is safe, restartable, and cannot lose a key** — because
  `micro-custody`'s re-encryption pass writes the new blob before it updates the row,
  and re-reads the blob's own stamp rather than the row's. That is not a claim about
  care; it is a property of the order of two writes.

So the dangerous operation here is not rotation. It is **removing an old secret too
early**, and the whole procedure exists to make that moment observable.

> **If you are here because a secret is believed compromised**, go to *The incident
> path*. If you are here because a restore is failing, the keyring is what you are
> missing — go to *The gap that is still open*.

## Where it lives

| | |
| --- | --- |
| **File, on the host** | `compose/secrets/custody.<network>.env`, gitignored, mode 0600 |
| **In the cluster** | `Secret/secret-custody` in `cloudsforge-estate`, built by `scripts/k8s-secrets.py` |
| **Keys in it** | `CUSTODY_KEY_VERSION`, and one `CUSTODY_MASTER_SECRET_V<n>` per readable version |
| **Read by** | `custody` only. No other service holds it, and none should. |

`CUSTODY_KEY_VERSION` is the **write** version. Every `CUSTODY_MASTER_SECRET_V<n>`
present is a **readable** version. A rotation is the interval in which both are true of
different numbers.

**The value is validated, not trusted.** `custody/src/env.ts` `assertMasterSecret`
requires base64-or-hex, exactly 32 decoded bytes, and an entropy floor calibrated over
200,000 samples, plus an exact deny-list that normalises punctuation and case. There is
no escape hatch — no `NODE_ENV` exemption, no `CUSTODY_ALLOW_*`. A placeholder does not
start the service.

## Rotating

Generate with `openssl rand -base64 32`. **Never print it**, never paste it into a
terminal that scrolls into a log, never put it in a commit message. Compose it into the
file from an environment variable rather than typing it on a command line — see
`runbook-outbox-signing-secret.md`, which makes the same point for the same reason.

### 1. Add the new secret, leave the old one

In `compose/secrets/custody.<network>.env`, add `CUSTODY_MASTER_SECRET_V<n+1>` and
**leave `CUSTODY_MASTER_SECRET_V<n>` exactly where it is**. Do not change
`CUSTODY_KEY_VERSION` yet.

```sh
./scripts/k8s-secrets.py --network mainnet            # names only — check V<n+1> appears
./scripts/k8s-secrets.py --network mainnet --apply
kubectl rollout restart deploy/custody -n cloudsforge-estate
```

Nothing is written under the new version yet. This step only widens what can be read.

### 2. Move the write version

Set `CUSTODY_KEY_VERSION=<n+1>`, apply, restart. From this moment **new** keys and seeds
are written under V`<n+1>` and every existing blob still decrypts under V`<n>`.

### 3. Drain the backlog

The job in `custody/src/jobs.ts` drains it on its own every thirty seconds, and that is
the normal path. To close the window deliberately — a rehearsal, or an incident:

```sh
kubectl exec -n cloudsforge-estate deploy/custody -- node dist/reencrypt-cli.js
```

It loops until a pass does no work, and **exits non-zero while anything remains**, so it
is safe in a loop or a deploy gate: the command succeeding is the same statement as *the
old secret can now be removed*.

Ask the database directly rather than trusting a log line:

```sh
kubectl exec -n cloudsforge-estate postgres-1 -c postgres -- \
  psql -U postgres -d custody -At -c \
  "select key_version, count(*) from custody_keys group by 1
   union all
   select key_version, count(*) from custody_seeds group by 1 order by 1"
```

`custody_keys_version_idx` is a partial index on exactly the stragglers, so this is cheap
and the finish line is observable.

### 4. Only now, remove the old secret

When — and only when — nothing remains below `<n+1>`, delete
`CUSTODY_MASTER_SECRET_V<n>` from the file, apply, restart. **That is the moment the old
secret stops mattering**, and the moment a compromise of it becomes recoverable.

Removing it on a partial run loses every key still on the old version, irrecoverably.
That is the one failure this whole procedure is shaped to prevent, which is why step 3
has a non-zero exit code and a query rather than a progress bar.

## Verifying a rotation actually finished

Three checks, and the third is the one that matters:

1. `CUSTODY_KEY_VERSION` is `<n+1>` in the running pod.
2. The keyring holds `CUSTODY_MASTER_SECRET_V<n+1>` and no longer holds V`<n>`.
3. **Every row is at `<n+1>`** — the query in step 3, returning one version and nothing
   else.

Measured on 2026-09-01, as an example of what a finished rotation looks like:
`CUSTODY_KEY_VERSION=4`, the keyring holds `CUSTODY_MASTER_SECRET_V4` alone, and
`custody_keys` and `custody_seeds` are 325 and 254 rows, **all at v4**.

## The incident path

If a secret is believed compromised, the interval between it being retired and it
*having* to be retired is exactly the exposure. Run steps 1–4 back to back, using the
CLI in step 3 rather than waiting for the job, and do not stop at step 2 — a new write
version with the old secret still readable has not reduced the exposure at all.

`SDR-03` says to treat any custody host compromise as unrecoverable. That advice is
older than this pass: it was written when there was no way to retire a secret, so a
compromised one stayed load-bearing for ever. With steps 1–4 available, a compromise of
the *secret* is recoverable. A compromise of the *host* still is not, because the host
also holds the vault.

## The gap that is still open

**The keyring is not in any automated backup, and the backup runner records that it is
not.** Verified 2026-09-01 on the newest mainnet set:

```
MANIFEST.json  →  custodyKeyringIncluded: false
secrets/       →  miner-coinbase-mainnet.json.age      (and nothing else)
```

The **vault** is backed up — `BACKUP_CUSTODY_VAULT_DIR`, the `custody-keys` PVC. The
**key that decrypts it** is not. Lose the host and every backed-up vault entry is
unrecoverable ciphertext, and the backup will have gone green every day while that was
true.

The off-host copy is made by hand — on paper and an encrypted USB, `docs/custody-backup-restore.md`
§4 — and nothing checks that it exists or that it is current. **After every rotation,
that copy is stale until it is redone**, and step 4 above is the point at which the old
copy stops being able to open the vault.

This is micro-org#25 item 3, and it is the last box on that issue. Note what it is and
is not: not a confidentiality problem — an **availability** one, and the only single
point of unrecoverable loss left in the estate.

> **Why the automated fix is not obvious.** Writing the KEK into the same backup set as
> the ciphertext it protects defeats the purpose: one stolen backup then yields both
> halves. Any real fix has to put the keyring somewhere the vault backup is not, which is
> a design decision rather than a configuration change — and it is why this has stayed
> open rather than being quietly patched.

## Related

- `docs/DISCLOSURE-custody-master-secret-v1.md` — why the V1 disclosure is accepted
  rather than rewritten. Short version: the disclosed value is a zero-entropy
  placeholder, not a key, and no row anywhere is encrypted under V1.
- `docs/custody-backup-restore.md` §4 — the manual off-host copy.
- `runbook-restore-from-backup.md` — names this runbook as custody's restore dependency,
  which is exactly the gap above.
- `runbook-outbox-signing-secret.md` — the same staged shape for a different key, and the
  reason staging is never skipped.
