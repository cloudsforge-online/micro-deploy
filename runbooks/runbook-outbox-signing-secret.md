# The outbox signing secret, and why rotating it is staged rather than swapped

## Read this first

This key signs and verifies **every outbox→inbox HTTP hop in the estate**. It is
one HMAC key shared by 24 services, which read it under seven different variable
names. There is not a key per service and there never was.

That is the whole reason a rotation is dangerous. A sender moved to a new key
while a receiver still holds only the old one does not raise an error anybody
sees: the receiver returns 401, the producer's outbox marks the delivery failed
and retries, and the estate goes on looking healthy while no event crosses. **A
silent partition looks exactly like a working estate.** Green containers are not
evidence here; a landed inbox row is.

If you are here because a rotation went wrong, skip to *Recovering from a
partition*.

## What it is, and where it lives

One key, seven names — the aliases exist because each consumer named its own
variable, not because the values differ:

| Variable | Read by |
| --- | --- |
| `OUTBOX_SIGNING_SECRET` | the 21 services that SIGN their outbox |
| `OUTBOX_ACCEPT_SECRETS` | admin-api, trade, wallet, settlement, worlds — the accept-list |
| `ACTIVITY_INGEST_SECRETS` | activity |
| `ANALYTICS_DELIVERY_SECRETS` | analytics |
| `COMMUNITY_INGEST_SECRETS` | community |
| `DEVPLATFORM_INGEST_SECRETS` | devplatform |
| `NOTIFY_INGEST_SIGNING_SECRET` | notify |
| `INBOUND_SIGNING_SECRET` | tessera |

They live in `compose/secrets/outbox.${CF_EMBER_NETWORK:-mainnet}.env`, mode
`0600`, in a directory gitignored whole. Mainnet and testnet hold **separate**
values and always must: one estate's key must not authenticate deliveries on the
other.

Not `tokens.env`, for two measured reasons: `estate-bootstrap.sh:506` rewrites
that file wholesale, and the testnet stack is brought up with `--env-file
compose/testnet.env`, which REPLACES the default `.env` rather than adding to it,
so a value there reaches exactly one of the two live stacks.

`environment:` **wins over** `env_file:` in compose. A line reinstated in a
service's `environment:` block silently overrides the file and the estate is back
on a public placeholder while this file still looks correct. `estate-verify.sh`
asserts every run that no signing secret is a literal in the compose file.

## Why it can be rotated at all: the verifier takes a list

`contracts/packages/events/src/index.ts:1412` — `verifyDelivery` accepts
`secrets: string | readonly string[]`, tries every candidate with a timing-safe
comparison (`:1444-1455`) and returns `keyIndex` naming which one matched.

**That `keyIndex` is the instrument this runbook depends on.** It is how you know
a rotation has finished rather than believing it has.

## Rotating — the four phases, in this order

Never skip phase 2. Signing with a key nobody accepts yet is the partition.

**Phase 1 — receivers can hold two keys.** Confirm every receiver plumbs a list.
`OUTBOX_ACCEPT_SECRETS` defaults to `[OUTBOX_SIGNING_SECRET]` when absent, so
deploying this is a no-op by construction.

**Phase 2 — publish the new key as ACCEPTED, still signing with the old.** In
`compose/secrets/outbox.<network>.env` set every accept-list variable to
`<new>,<old>` — newest first — and leave `OUTBOX_SIGNING_SECRET` on the old
value. Recreate the receivers. Nothing signs with the new key yet, so this phase
cannot break delivery; it only widens what is accepted.

**Phase 3 — move the signers.** Set `OUTBOX_SIGNING_SECRET` to the new value and
recreate the producers, in any order and at any pace. Every receiver already
accepts both, so a half-finished phase 3 is not a partition — that is the entire
point of phase 2.

**Phase 4 — drop the old key.** Only once phase 3 is complete everywhere. Set the
accept-lists to the new value alone and recreate the receivers. Do not do this on
the same day: the old key must stay accepted for longer than the longest outbox
retry backoff, or a delivery still retrying under the old key is dropped.

Generate the new value with `openssl rand -base64 48`. Never print it, never
paste it into a terminal that scrolls into a log, never put it in a commit
message.

## Events in flight

**Signatures are computed at DELIVERY time, not at enqueue time**
(`ledger/src/outbox.ts:297` — `signEvent(...)` is inside the relay loop; the
outbox table has no signature column). So a row that has been queued for an hour
is signed with whatever key the producer holds when it is finally sent, and there
is no such thing as a stored old-key signature waiting to be rejected.

What that leaves is a request already on the wire when a container restarts. It
is not lost: delivery is leased, the attempt fails, and the row is retried. Under
the phase ordering above the retry is accepted whichever key signed it, because
phase 2 put both in the accept-list before any producer moved.

The one way to lose an event is to run phase 4 too early.

## Verifying the rotation actually worked

Green containers prove nothing. Drive a real delivery:

```
./scripts/estate-verify.sh
```

The check that matters is *"indexer's relay signed it, wallet verified it, and it
is in wallet's inbox — THE MONEY BUS CARRIES"*. It inserts a row into indexer's
outbox, lets indexer's own relay sign and POST it, and asserts the row lands in
wallet's inbox. Nothing in the check signs anything, which is what makes it a
producer-to-consumer test rather than a test of `curl`.

`estate-verify.sh` reads the key from the **running indexer container**, not from
a file, so a rotation that reached the verifier but not the producer shows up as
a mismatch rather than a green run.

## Recovering from a partition

Symptom: services healthy, `outbox_deliveries.attempts` climbing, `last_error`
showing 401, inbox rows not appearing.

```
docker compose -f compose/docker-compose.estate.yml exec -T postgres \
  psql -qtA -U cloudsforge -d indexer \
  -c "select attempts, last_error from outbox_deliveries where delivered_at is null order by attempts desc limit 10"
```

Fix forward, do not roll back the signers one at a time. Put **both** keys in
every accept-list variable (phase 2), recreate the receivers, and the queued rows
drain on their own retries. Only then decide which key to settle on.

The old key may be deleted when no delivery has verified under it for longer than
the longest retry backoff — not when the change "looks done".

## What this replaced

`OUTBOX_SIGNING_SECRET` was a hardcoded 40-character placeholder on **54 lines**
of `compose/docker-compose.estate.yml`, in a repository `gh repo view` reports
PUBLIC. It cleared every check that existed: it was not one of the strings in any
`PLACEHOLDERS` set and it was longer than the 24-character floor, and the comment
above it said so approvingly. The control that was supposed to stop this was a
comment, and a comment is not a control.

The custody master secret failed in the same file, in the same shape, and its
runbook is `runbook-custody-master-secret.md`.
