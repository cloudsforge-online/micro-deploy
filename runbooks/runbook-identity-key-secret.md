# The identity key-encryption key, and the MFA factors that have no backup

**Triggered by** `Rotation; a suspected compromise; the value appearing in a transcript or a public file`
**Severity** SEV1 if lost or exposed · **Owner** identity

## Read this first

**`IDENTITY_KEY_SECRET` does not sign tokens.** Tokens are RS256 under per-`kid`
keys from `signing_keys`, published through JWKS, and identity already has full
`kid` rotation. That part is not this.

This is the **key-encryption key that wraps those signing keys and every TOTP
seed at rest** (`identity/src/keyEnvelope.ts`). Replacing it without the drain
below does not invalidate anything — it **destroys** it:

- every `signing_keys.private_jwk_enc` becomes undecryptable. Identity bootstraps
  a fresh key, so live sessions keep verifying only until the old `kid` leaves
  JWKS. Recoverable.
- every `mfa_factors.secret_enc` becomes undecryptable. **Not recoverable.** A
  TOTP seed exists in that blob and in the user's authenticator app, and nowhere
  else in the world. There is no backup, no re-issue and no reset that does not
  mean "every user with MFA is locked out and must re-enrol".

A rotation done as "just a compose change" is therefore a permanent, silent
destruction of every second factor on the platform. #188.

## What makes it rotatable

Since `micro-identity@1.2.0` the version stamped on a blob selects a **secret**,
not just a salt:

    IDENTITY_KEY_SECRET_V1, IDENTITY_KEY_SECRET_V2, …   with IDENTITY_KEY_VERSION naming the writer

`open` picks the secret by the stamp the blob itself carries, so every version
any stored blob might need can be held at once. The unsuffixed
`IDENTITY_KEY_SECRET` is still accepted as v1, because every blob written before
that release is stamped `v1:` under it.

The values live in `compose/secrets/identity-key.<network>.env`, mode 0600,
gitignored, **one file per network** — the two networks must not share a value.

## Rotating it

Four steps, and **step 3 is the one that gets skipped**.

    # 1. Add the new secret. Leave the old one in place. Nothing changes yet.
    #    compose/secrets/identity-key.<network>.env
    #      IDENTITY_KEY_VERSION=<n+1>
    #      IDENTITY_KEY_SECRET_V<n>=…      <- keep
    #      IDENTITY_KEY_SECRET_V<n+1>=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-48)

    # 2. Cut over. New blobs seal under <n+1>; old ones still open under <n>.
    make estate-up            # or: docker compose $(ESTATE) … up -d identity

    # 3. DRAIN. Re-seal every existing blob under the new version.
    docker exec <identity-container> node --import tsx src/rewrap-cli.ts
    #    Repeat until it reports  remainingBelowTarget: 0  and exits 0.

    # 4. ONLY NOW remove IDENTITY_KEY_SECRET_V<n> from the file, and restart.
    docker exec <identity-container> node --import tsx src/rewrap-cli.ts --verify
    #    Must report  unreadable: 0  and  remainingBelowTarget: 0.

**Omitting step 3 orphans every blob that was never rewritten**, and removing the
old secret afterwards makes that permanent. It has already happened once in this
estate — 509 blobs, readable again only because an old secret happened to survive
in public git history. That is luck, not a recovery procedure, and for a TOTP
seed there is no luck available.

`rewrap-cli.ts` exits non-zero if anything is undrained or unreadable, so gate on
it. It prints counts and version numbers only, never a key or a seed.

## Verifying

    # every blob opens under what the process now holds
    docker exec <identity> node --import tsx src/rewrap-cli.ts --verify

    # the envelope version actually in the database
    docker exec <postgres> psql -U cloudsforge -d identity -At \
      -c "select v||' x'||n from (select substring(private_jwk_enc from 1 for 3) v, count(*) n from signing_keys group by 1) s"

    # nothing placeholder-shaped or leaked is left
    make check-secrets

An end-to-end MFA check, which is the only one that proves the seeds survived:
enrol a TOTP factor, activate it, sign in again and answer the challenge. If the
keyring could not open what it sealed, activation fails.

## If it leaked

Rotate immediately, by the four steps above — do not reason about whether the
exposure mattered. This is cheap **only because the drain exists**: a leaked
`IDENTITY_KEY_SECRET_V2` was burned and replaced within the hour on 2026-08-05,
1/1 blobs drained, zero unreadable.

The most common way it leaks is an unredacted render:

    docker compose … config | grep IDENTITY        # ← puts the value in the transcript

Redact before printing — counts and truncated hashes only. See
`runbook-secret-leaked-to-transcript.md`.

## If the drain was skipped and the old secret is gone

- **Signing keys**: recoverable. Delete the unreadable `signing_keys` rows;
  identity bootstraps a fresh active key. Sessions signed by the lost `kid` fail
  once it leaves JWKS, so expect a wave of re-authentication.
- **TOTP seeds**: not recoverable. The factors must be removed and every affected
  user must re-enrol. Treat as a SEV1 with user comms — see
  `runbook-incident-comms.md`.
