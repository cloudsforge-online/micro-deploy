# The analytics pepper, and the erasure that depends on it

**Triggered by** `Rotation; a suspected compromise; the value appearing in a transcript or a public file`
**Severity** SEV1 if exposed · **Owner** analytics

## Read this first

**`ANALYTICS_PSEUDONYM_KEY` is not a transport credential. It derives stored
pseudonyms**, and `subject_keys.lookup_key` — a primary key — is a pure function
of it:

    lookup_key  = HMAC(pepper, "cf.analytics.lookup.v1|"  || subject)
    subject_key = HMAC(pepper, "cf.analytics.subject.v1|" || subject || "|" || salt)

Replace the pepper without the ring below and every returning subject derives a
**new** lookup key. So one person silently becomes two pseudonyms, their prior
events are orphaned from them, and — the part that matters —
**erasure by subject stops reaching pre-rotation rows**. That is a GDPR failure,
not an analytics-quality one: a deletion request can no longer be honoured for
data the platform still holds. #189.

## THERE IS NO DRAIN HERE, AND THERE CANNOT BE

This is the one place the estate's normal rotation pattern does not apply, so do
not go looking for the equivalent of `identity`'s `rewrap` — it does not exist and
its absence is deliberate.

custody and identity rotate by **re-encrypting** every stored blob under the new
key. A pseudonym is **derived**, not encrypted. Recomputing `lookup_key` under a
new pepper needs the raw `subject`, and this service never stores one: there is no
`user_id` column, `events_subject_shape` refuses a row holding one,
`FORBIDDEN_COLUMNS` is asserted against the real migrated schema, and HMAC does
not run backwards.

**If someone proposes a migration that re-derives the mappings, it is inventing
them.** `analytics/src/rotation.test.ts` contains a test that sweeps every text
column of every table and fails if any value contains a raw subject, precisely so
this cannot be "fixed" later by quietly storing the identifier that would make a
drain possible.

## What makes it rotatable anyway

No drain is *needed*, because nothing here ever recovers a subject from a stored
value — ingest and erasure are both **handed** the raw subject by their caller
(erasure gets it from `identity.user.deleted`'s `payload.userId`).

So the pepper is a **ring**: the newest mints, and a lookup derives a candidate
under *every* pepper held and matches on any of them.

    ANALYTICS_PSEUDONYM_KEY_V1, ANALYTICS_PSEUDONYM_KEY_V2, …
    ANALYTICS_PSEUDONYM_VERSION   names the one that mints

A mapping minted under the old pepper therefore stays reachable from the subject,
so linkability survives and **erasure still reaches pre-rotation rows**. An
erasure tombstone written under an old pepper also still blocks re-minting under
the new one, so a rotation cannot undo an erasure.

Values live in `compose/secrets/analytics-pepper.<network>.env`, mode 0600,
gitignored, **one file per network** — sharing one value made testnet pseudonyms
derivable from mainnet's, which was half of #189.

## Rotating it

    # 1. Add the new pepper and make it the writer. KEEP the old one.
    #    compose/secrets/analytics-pepper.<network>.env
    #      ANALYTICS_PSEUDONYM_VERSION=<n+1>
    #      ANALYTICS_PSEUDONYM_KEY_V<n>=…     <- keep, see step 3
    #      ANALYTICS_PSEUDONYM_KEY_V<n+1>=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-48)

    # 2. Cut over.
    make estate-up            # or: docker compose $(ESTATE) … up -d analytics

    # 3. WAIT. There is no command for this step.
    #    The old pepper stays until retention has pruned every mapping that
    #    predates the rotation — up to ANALYTICS_EVENT_RETENTION_DAYS.
    docker exec <postgres> psql -U cloudsforge -d analytics -At -c \
      "select count(*) from subject_keys where pepper_version < <n+1> and erased_at is null"

    # 4. Only when that reads 0 may ANALYTICS_PSEUDONYM_KEY_V<n> be removed.

**Removing the old pepper while that count is non-zero silently breaks erasure
for exactly those rows**, which is the #189 regression arriving by the back door.
It produces no error: ingest carries on, the service stays healthy, and a
deletion request simply stops reaching data that is still there.

This is the honest cost of the design. A compromised pepper keeps some value to
an attacker for the retention window, and that is better than the two
alternatives — breaking erasure, or storing the identifiers that would allow a
drain.

## Rotating it when the table is empty

If `subject_keys` holds no rows, no mapping references the old pepper and it can
be removed immediately. This was true on both networks on 2026-08-05, which is
the only reason that rotation was clean. **Measure it; do not assume it.**

## Verifying

    # mappings still tied to an older pepper — the gauge that gates step 4
    select count(*) from subject_keys where pepper_version < <current> and erased_at is null;

    # the migration that added the column
    select max(version) from schema_migrations;      -- >= 9

    make check-secrets

The behavioural check that matters is an **erasure of a pre-rotation subject**:
publish `identity.user.deleted` for a subject minted before the cut-over, then
confirm `subject_keys` holds a tombstone with `subject_key` and `salt` both NULL.
`analytics/src/rotation.test.ts` asserts this, in both directions.

## If it leaked

Rotate by the steps above, and accept that step 3 takes as long as it takes.
Redact every rendered config before printing it — an unredacted
`docker compose … config | grep` is how the identity KEK leaked on 2026-08-05.
See `runbook-secret-leaked-to-transcript.md`.
