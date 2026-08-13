# Disclosure: `CUSTODY_MASTER_SECRET_V1` in public git history

**Decision date** 2026-08-13 · **Decided by** the estate owner · **Issue** micro-org#25 item 1
**Disposition** accepted and documented; public history deliberately NOT rewritten

---

## What is disclosed

`CUSTODY_MASTER_SECRET_V1` was committed as a hardcoded literal into `micro-deploy`, which is a
public repository. It remains readable and always will:

```
git show 19d71b5:compose/docker-compose.estate.yml
  :557  CUSTODY_MASTER_SECRET_V1: "estate-only-custody-master-secret-v1-0000"
  :576  (the same value again, in the custody-migrate block)
```

> The quotes are this document's, not the original commit's. Without them this line matches the CI
> guard that keeps a keyring out of this repository, and a document *about* the disclosure would
> fail the build for containing the disclosure. Reproducing the value is deliberate — it is already
> public, and seeing that it is a plain English placeholder rather than 32 random bytes is most of
> the argument below.

`19d71b5` is an ancestor of `origin/main`. Removing a secret from `HEAD` is not removal, and this
document exists so that nobody has to rediscover that.

## Why it is accepted rather than rewritten

Three findings, each verified rather than assumed, on 2026-08-13.

**1. The disclosed value is a zero-entropy placeholder, not a key.** It is the literal string
`estate-only-custody-master-secret-v1-0000`. It is not 32 bytes of anything. `custody/src/env.ts`
`assertMasterSecret` now requires base64-or-hex, exactly 32 decoded bytes, and an entropy floor
calibrated over 200,000 samples, and it carries an exact deny-list that normalises punctuation and
case so `estate-only` / `ESTATE_ONLY` / `estateonly` are one rule. **This value would fail to start
the service today.** There is no escape hatch — no `NODE_ENV` exemption, no `CUSTODY_ALLOW_*`.

**2. Nothing anywhere is encrypted under V1.** The census, taken directly from both estates:

```
MAINNET   custody_keys   key_version 4 = 278 rows
          custody_seeds  key_version 4 = 250 rows
TESTNET   custody_keys   key_version 2 = 26 rows
          custody_seeds  key_version 2 = 5 rows
```

Every row on both networks is at a version above V1, and no row at any lower version survives. The
keyring rotations that got them there are recorded in micro-org#339 (V3→V4) and its predecessors.
**No ciphertext in this estate can be opened by the disclosed string.**

**3. Rewriting history would not undo the publication.** A force-push breaks every existing clone
and fork, changes every commit SHA after the rewrite point — which release manifests reference —
and does not retract anything already fetched, mirrored or scraped. It would buy the removal of one
`git show` away from a string that opens nothing.

## What was considered and rejected

- **Rewriting public history** (`git-filter-repo` / BFG + force-push). Rejected on the grounds
  above: high blast radius, no security gain, and GitHub may retain unreachable objects regardless.
- **Doing nothing and leaving it undocumented.** Rejected because the next reader finds a secret in
  a public repository with no record of whether it matters, and has to redo this work under time
  pressure to find out.

## What this decision does NOT cover

- It says nothing about any **future** disclosure. A real 32-byte secret reaching a public place is
  a different event with a different answer, and the answer there is rotation —
  `runbooks/runbook-custody-master-secret.md`.
- It does not close micro-org#25. Item 3 — that the keyring has no off-host copy — remains open,
  and it is the item that can still lose every custodied key. See §4 of
  `docs/custody-backup-restore.md`; that copy is made by hand, on paper and an encrypted USB, and
  the automated backup goes green whether or not it exists.

## Were real funds ever custodied under V1?

No. Deposit provisioning never worked while V1 was current, so no user deposit key was ever minted
under it; the only V1-era material was the estate's own faucet, treasury and deployer keys on
testnet EMBER. This was previously recorded as inference. It is now also true by construction: the
census above shows no V1 row of any kind survives on either network.
