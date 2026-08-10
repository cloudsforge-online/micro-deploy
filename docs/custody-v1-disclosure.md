# The publicly disclosed V1 custody master secret — disposition

**Decision: accept and document. Do not rewrite history.**
Recorded 2026-08-10, closing item 1 of cloudsforge-online/micro-org#25.

---

## 1. What was disclosed

`CUSTODY_MASTER_SECRET_V1` — the key-encryption key for every custodied private
key and every HD seed on the estate — was committed as a hardcoded literal into
`compose/docker-compose.estate.yml` in this repository, which is public. It
appears twice in commit `19d71b5` (the service block and the `custody-migrate`
block), and `19d71b5` is an ancestor of `origin/main`.

The value is not reproduced here. It is already published; writing it into a
second file in the same public repository in order to document that it is
published would add a copy and remove nothing. `git show 19d71b5` is the
reference.

It is low-entropy and hyphenated, which matters for anyone scanning: **a search
for a high-entropy string will not find it.** That is recorded in micro-org#25
because the first scan for it came back clean and was wrong.

## 2. The decision, and why it is not "rewrite history"

Rewriting history would be destructive, irreversible, and would not undisclose
the value.

- **It does not un-publish anything.** The commit has been public since it was
  pushed. Clones, forks, mirrors, CI caches and anyone's `git fetch` all retain
  it, and GitHub serves an unreferenced commit by SHA long after a force-push. A
  secret that has been public is public; the only remedy that has ever worked on
  one is rotation, and rotation is done (§3).
- **It would break the things that make this estate auditable.** Release
  manifests, runbooks and several hundred issue comments cite commit SHAs.
  Rewriting `main` changes every SHA after `19d71b5`, so the cost lands entirely
  on the record of what was deployed when — which is the evidence this estate
  keeps using to answer exactly this kind of question.
- **The security benefit is zero, not small.** There is no threat model in which
  an attacker can read `origin/main` today, could not read it yesterday, and is
  stopped by a force-push.

So the value stays readable, permanently, and the control is that it decrypts
nothing. **Any material ever encrypted under V1 is treated as compromised,
permanently** — that is not a mitigation to be argued down, it is the assumption
everything below is built on.

This decision is reversible in principle: the owner may still choose to rewrite
history. It would cost the audit trail and deliver nothing, which is why it is
not the default.

## 3. Written statement: all V1-derived material has been rotated

Measured on the estate host, 2026-08-10.

| Check | Result |
| --- | --- |
| Key versions custody can read | `readableKeyVersions:[3]` — V1 and V2 are not loaded and cannot be |
| Master secrets present in the container | `CUSTODY_MASTER_SECRET_V3` only |
| Write version | `CUSTODY_KEY_VERSION=3` |
| Vault blobs by envelope version | **507 of 507 stamped `v3:`** — zero `v1:`, zero `v2:` |
| `custody_keys` by `key_version` | 261, all version 3 |
| `custody_seeds` by `key_version` | 246, all version 3 |
| Rows behind the write version | `keys_behind=0, seeds_behind=0` |
| `key_exports` | 0 rows |

507 blobs = 261 keys + 246 seeds, so the vault and the database agree about what
exists, and every one of them is on V3.

**Nothing on this estate is decryptable with the disclosed V1 secret.** The
rotations that got here are recorded in micro-org#25 (V1→V2), micro-org#144
(V2→V3 on the local estate) and this file's §3 measurement for the host.

Two consequences that are easy to miss and are not covered by the table:

- **Pre-drain vault snapshots are plaintext to anyone who reads this repository.**
  Any vault backup taken while blobs were still stamped `v1:` is decryptable with
  a value on the public internet. `docs/custody-backup-restore.md` §4 says to
  **destroy** pre-rotation vault backups rather than filing them. That instruction
  exists because of this disclosure.
- **Removing a secret from the keyring is not the same as removing it from the
  machine.** A container created earlier still holds the old value in its baked
  environment, in this compose project or another one. `docs/custody-backup-restore.md`
  §5.5 is the machine-wide sweep; it found the disclosed V1 still sitting in an
  exited `custody-migrate-1` container after the file had been clean for days.

## 4. Were real funds ever custodied under V1?

Recorded rather than inferred, because micro-org#25 asked for exactly that and
the inference gets harder to make with time.

Deposit provisioning did not work at all during the V1 period, so no user deposit
key was minted under it. The V1-era keys were the estate's own faucet, treasury
and deployer keys on testnet EMBER. No third-party funds were held under V1.

This is now moot for confidentiality — every blob has been re-encrypted under V3
and V1 is unloadable — but it is the answer to "was anyone else's money exposed",
and the answer is no.

## 5. The rule this leaves behind

**A credential-shaped literal in a tracked file is a disclosure at the moment it
is pushed, not at the moment someone notices.** Everything after that is cleanup,
and cleanup cannot make it private again.

Enforced, not merely written down:

- `micro-deploy` CI fails the build on any `CUSTODY_MASTER_SECRET_V<n>` given a
  value in a tracked file, and asserts mainnet and testnet resolve to separate
  keyrings.
- custody refuses to boot on a placeholder — `assertGeneratedSecret` in
  `@cloudsforge/secrets`: base64-or-hex, ≥32 decoded bytes, a measured entropy
  floor, normalised marker match, no `NODE_ENV` exemption and no `CUSTODY_ALLOW_*`.
  Verified against the running image by starting it with the V1 literal and
  watching it refuse (micro-org#25, 2026-08-08).
- New key material is generated with `openssl rand -base64 48`, never typed,
  never pasted, never put in a commit message.
