# The conformance corpus has never been replayed

**Triggered by** `ConformanceCorpusNeverReplayed - absent(beacon_conformance_suites) or sum(beacon_conformance_suites) == 0 for 1h`
**Severity** SEV4 - ticket · **Owner** chain

## What it means

Nothing has compared the estate against the recorded corpus. This is not a
divergence; it is the absence of the check that would find one.

The alert beside this one, `HearthConformanceVectorsFailing`, reads
`beacon_conformance_vectors{result="failed"} > 0`. Beacon publishes vector
counts only for suites that have actually run, so when no suite has run there
are no series and that rule is green — green because nobody looked. This rule
exists to make that state say something.

## It is the wire that is missing, not the corpus and not the recorder

Both ends were built correctly and were never joined. Establish which half you
are looking at before touching anything.

| Piece | Where | State |
| --- | --- | --- |
| The corpus and the comparison | `micro-conformance` — 60 recorded interactions across eight scenarios | built |
| The publisher | `conformance/src/publish.ts`, reached by `compare --beacon` | built |
| The recording route | `POST /v1/conformance` in `micro-beacon` | built, and gateway-routed |
| The gate input | `beacon/src/gate.ts`, per suite | built |
| **Something that runs the comparison on a schedule** | — | **this is the gap** |

`conformance/src/publish.ts` states it in its own header, found on 2026-08-04 by
grepping the whole estate for `/v1/conformance`: no caller exists — not in that
repository, not in any CI workflow, not in any deploy script. `conformance_runs`
has been empty since the table was created and the gate has reported
`conformance_never_run` for its entire life.

So the first question is not "which suite failed". It is **"what was supposed to
run this, and did it stop, or was it never there?"**

## Confirm which of the three cases you are in

The expression has two arms deliberately, because they mean different things.

1. **`absent(beacon_conformance_suites)`** — beacon is not publishing the metric
   at all. That is a beacon problem, not a conformance one: check the scrape
   first (`up{job="beacon"}`), then that beacon is on a build that publishes it.
   `BeaconScrapeFailing` will usually be firing beside this.

2. **`sum(...) == 0` with the series present** — beacon is up and seeding
   `pass`, `fail`, `skip` and `error` at zero, which it does on every scrape
   whether or not anything has run. This is the real case, and it means zero
   rows in `conformance_runs`.

3. Neither, and it cleared on its own — a replay landed. Nothing to do.

Telling 1 from 2 matters because `sum()` over an empty vector produces no series
and never crosses `== 0`; without the `absent()` arm case 1 would be silent, in
exactly the way this rule was written to stop.

## Replaying it by hand

From a `micro-conformance` checkout, against a running estate:

```sh
pnpm -s cfconf compare --beacon https://beacon.<apex>/ --beacon-token "$BEACON_TOKEN"
```

The token is the same credential Prometheus and Alertmanager present; on the
deploy host it is in `deploy/.env` as `CF_BEACON_TOKEN` and in the container's
environment as `BEACON_TOKEN`. Do not paste it into a shell history you keep —
`--beacon-token` also reads `BEACON_TOKEN` from the environment, which is the
better of the two.

One run is posted **per scenario**, not one per estate, and that grain is
load-bearing: a single row summing eight scenarios lets a broad corpus be
certified by its narrowest one.

Beacon derives `pass`/`fail`/`skip` from the counts itself. A reporter cannot
declare its own `pass`, and two CHECK constraints refuse a `pass` with zero
comparisons or alongside a breaking difference — so a hand replay cannot produce
a green row without having actually compared something.

## Clearing it properly

A hand replay silences this alert for as long as the rows exist, which is
exactly the wrong outcome if it is treated as the fix: the next question the
estate cannot answer is "has the corpus been replayed *since the last release*",
and one manual row a month ago answers it wrongly.

The real close is a scheduled runner. When one is added, this alert becomes a
staleness check rather than a never-ran check, and the expression should move
from `sum(...) == 0` to something over the age of the newest run. That is a
change to make **when the runner exists** and not before — a staleness threshold
against a corpus nothing replays fires continuously and gets silenced, which is
how a rule stops being read.

## What this alert is not

- **Not `HearthConformanceVectorsFailing`.** That one means a comparison ran and
  found a breaking difference. This one means no comparison ran. They are
  mutually exclusive and only one of them is about the chain.
- **Not a reason to publish a zero into `beacon_conformance_vectors`.** Beacon
  deliberately refuses to, and the refusal is the point: a
  `beacon_conformance_vectors{result="failed"} 0` would read as "zero failing
  vectors" — a positive claim of correctness made by a suite that never ran.
- **Not a release blocker on its own.** It is sev4 because an unenforced gate is
  a process failure, not an outage. It becomes a blocker the moment a Hearth
  release is cut against it, because at that point the gate the release policy
  names has no input.
