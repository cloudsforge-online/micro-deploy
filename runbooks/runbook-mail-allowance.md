# Runbook — the mail allowance, and the two ways it goes

Covers `MailSentToReservedDomain` (sev2) and the `SMTP 535` family.

Read the first section before doing anything, because the most expensive mistake
this estate has made with mail was made three times and it was a diagnosis, not
an action.

## `SMTP 535` is almost never a bad password

The provider answers an exhausted daily allowance with

```
535 5.7.8 Your account has reached its daily sending limit ... retry in 19m21s
```

and `535` is *also* the bad-credentials reply. Two people have concluded the
credentials were wrong from the code alone while the relay was authenticated and
externally deliverable the whole time — SPF, DKIM and DMARC all passing, proved
by a relay test that reached an external inbox on 2026-08-04.

**Read the text after the code.** Then read
`notify_deliveries_awaiting_allowance`: a gauge above zero says the allowance is
spent and the deliveries are parked, not failed. Above zero for minutes is the
system working.

**Never provision new mainnet SMTP credentials in response to a 535.** That has
been proposed twice and would have rotated a working secret during an incident
it could not have caused.

## The allowance

Mailtrap free tier: **150 emails/day, 4000/month**, from
`no-reply@mail.cloudsforge.online` through `live.smtp.mailtrap.io:587`. The
figure was recorded as 250/day in three places until 2026-08-11 and was wrong.

Testnet has no SMTP at all — `SMTP_HOST` is empty, deliberately. Its failures
read `undeliverable/no_transport`, and that is a supported mode rather than a
fault.

## `MailSentToReservedDomain` — what it means and what to do

`notify` refuses to route email to a domain the standards reserve: `.test`,
`.example`, `.invalid`, `.localhost` (RFC 6761 §6) and the RFC 2606 §3
documentation domains. The rule is in `reserved.ts` and runs in `pipeline.ts`
*before a delivery row is written*. The mail adapter keeps its own guard as a
backstop.

**This alert fires when the backstop fires, which means the routing rule did not
run.** Three causes, in the order worth checking:

### 1. The running build does not have the rule

This is the one that has actually happened. Check the **container**, not the
repository:

```bash
docker inspect cloudsforge-estate-notify-1 \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}} {{.State.StartedAt}}'
```

A merged fix is not a deployed fix. The rule shipped in notify 2.4.0 and was
verified — on testnet. Mainnet's process was older, and between 2026-08-05 and
2026-08-11 it sent **1,535 of 1,552** deliveries to `beacon.test`, exhausting
the allowance repeatedly. Nothing anywhere said so; the estate found out from
the provider's dashboard reading 241 against a 150/day cap.

The settling query, against `cloudsforge-estate-postgres-1`, database `notify`:

```sql
select split_part(ct.address, '@', 2) as domain,
       count(*)                                        as rows,
       count(*) filter (where d.sent_at is not null)    as sent
from deliveries d
join channel_targets ct on ct.id = d.target_id
where d.channel = 'email'
  and d.created_at > now() - interval '7 days'
group by 1 order by 2 desc;
```

Anything under a reserved domain with a non-zero count is the leak.

### 2. A delivery row predates the rule

Harmless and self-clearing — the backstop refuses it permanently and does not
spend an attempt. If the alert clears on its own within an hour and the count is
small, this was it.

### 3. A caller builds an `OutboundMessage` some other way

Rare. Look for a code path that constructs a message without going through
`pipeline.ts`.

## Why the threshold is zero

Every other mail alert here is a rate, because some level of mail failure is
normal. This one is not. The estate's synthetic monitor registers roughly
**2,250 accounts a day** under `beacon.test`, so the correct value of this
counter is zero forever, and any increase means the thing that empties the
allowance in an afternoon has restarted. A rate threshold would wait for the
damage the alert exists to prevent.

It is sev2 rather than sev3 because the allowance is shared with real
recipients. A verification link written during an exhausted window is an account
that can never sign in, and with no real users yet, the first genuine signup is
precisely the one at risk.

## The residue

Beacon creates an account per journey and reaps none: 15,197 user rows and
12,975 `beacon.test` email channel targets on mainnet as of 2026-08-11. The
prune is

```sql
delete from users where email like 'beacon+%';
```

but the better fix is for the monitor to reuse a bounded pool of accounts —
creating 2,250 rows a day to prove registration works costs more than it proves.
Tracked in micro-org#390.

## The rule this cost us

**A ticket about mainnet behaviour is closed by a mainnet measurement, or it is
not closed.** micro-org#243 was closed on a testnet reading and mainnet kept
spending for two more days. The same failure shape is micro-org#384.
