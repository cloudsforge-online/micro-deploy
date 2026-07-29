# Incident communications

**Triggered by** `BeaconCriticalJourneyFailing; every SEV1 and SEV2`
**Severity** Any · **Owner** incident commander

## A journey failing is user-visible failure

A metric says "p99 is high"; a journey says "a user cannot withdraw". This alert
is the second kind, which is why it pages.

Beacon's journey grid before Grafana: the journey names what broke, and the
service dashboards tell you why.

## First five minutes

- **0-60s, any severity.** Acknowledge the page - this stops escalation. Open the
  Beacon incident. Note the `cf.request_id` or `trace_id` from the alert.
- **SEV1 minute 1.** Declare in the channel and name yourself incident commander.
  The commander decides and does not debug; in a SEV1 the commander is never also
  the operations lead.
- **SEV1 minute 2.** Money integrity dashboard first, always.
- **SEV1 minute 3.** Deploy annotation. Roll back if correlated, before diagnosing.
- **SEV1 minute 4.** If money movement is implicated, freeze withdrawals.
- **SEV1 minute 5.** Post the first public update.

## Public updates

Written by the on-call operator in `admin-web`, stored on the Beacon incident -
one incident, two audiences, one write. An automated incident opens with a
**generic** template ("We are investigating elevated errors affecting Wallet"),
never the alert text, which carries internal target names.

| Sev | First update | Cadence | Final |
| --- | --- | --- | --- |
| SEV1 | 15 min | every 30 min, even "no change" | resolution note within 1h; public review in 5 working days |
| SEV2 | 30 min | every 60 min | resolution note |
| SEV3 | only if user-visible for over 30 min | every 2h | resolution note |
| SEV4 | not published | - | - |

Never publish latency numbers, error rates, internal target names, replica counts
or journey step names. Those are an availability map for an attacker.
