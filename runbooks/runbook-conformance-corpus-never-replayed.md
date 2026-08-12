# The conformance corpus is not being replayed

**Triggered by** either of two rules in `cf.ticket.conformance`:

| Alert | Expression | Means |
| --- | --- | --- |
| `ConformanceCorpusNeverReplayed` | `absent(beacon_conformance_suites) or sum(beacon_conformance_suites) == 0 for 1h` | no suite has **ever** completed |
| `ConformanceCorpusStale` | `time() - beacon_conformance_last_run_timestamp_seconds > 36 * 3600 for 1h` | a suite completed once and **stopped being replayed** |

**Severity** SEV4 - ticket · **Owner** chain

Read the alert name first. The two are about the same gap at different points in
its life, and after 2026-08-12 the second is overwhelmingly the more likely: a
scheduled runner exists now, so `sum(...) == 0` cannot come back short of a
database restore, while a runner that has quietly stopped is an ordinary thing
for a container to do.

## What it means

Nothing has compared the estate against the recorded corpus — either never, or
not lately. This is not a divergence; it is the absence of the check that would
find one.

The alert beside this one, `HearthConformanceVectorsFailing`, reads
`beacon_conformance_vectors{result="failed"} > 0`. Beacon publishes vector
counts only for suites that have actually run, so when no suite has run there
are no series and that rule is green — green because nobody looked. This rule
exists to make that state say something.

## It was the wire that was missing, not the corpus and not the recorder

Both ends were built correctly on 2026-08-04 and were never joined. That is the
history this alert was born in, and it is worth knowing because it tells you
where to look now.

| Piece | Where | State |
| --- | --- | --- |
| The corpus and the comparison | `micro-conformance` — 47 recorded interactions across eight scenarios | built |
| The publisher | `conformance/src/publish.ts`, reached by `compare --beacon` | built |
| The recording route | `POST /v1/conformance` in `micro-beacon` | built, and gateway-routed |
| The gate input | `beacon/src/gate.ts`, per suite | built |
| **Something that runs the comparison on a schedule** | `conformance-runner`, `deploy/compose/docker-compose.conformance.yml` | **built 2026-08-12 — this was the gap** |

`conformance/src/publish.ts` stated it in its own header, found on 2026-08-04 by
grepping the whole estate for `/v1/conformance`: no caller existed — not in that
repository, not in any CI workflow, not in any deploy script. `conformance_runs`
was empty from the day the table was created until 2026-08-12, and the gate
reported `conformance_never_run` for all of it.

So the first question is still not "which suite failed". It is **"what was
supposed to run this, and did it stop?"** — and the answer to "what" is now a
named container, which is the whole difference this ticket made.

## The runner

One container on the mainnet estate, `cloudsforge-estate-conformance-runner-1`.
It runs `deploy/conformance-runner/replay.sh loop`: pin the checkout to
`origin/main`, install with the pnpm the repository pins, compare, publish to
beacon, sleep a day, repeat — and it replays **immediately on start**, so a
deploy is followed by the replay that certifies it.

```sh
docker logs --tail 50 cloudsforge-estate-conformance-runner-1
docker ps --filter name=conformance --format '{{.Names}}  {{.Status}}'
```

A healthy log ends in `no breaking difference; next replay in 86400s` and, above
it, `published 8/8 suites to http://beacon:4000`.

It has **no healthcheck and exports no metrics of its own, deliberately**. A
runner that reports itself healthy while publishing nothing is the failure this
whole ticket was; what is monitored instead is the freshness of the result —
`beacon_conformance_last_run_timestamp_seconds`, which only a real published run
can move. That is `ConformanceCorpusStale` above, and it catches a runner that
dies, wedges, loses its account or silently stops comparing, without this
container having to be honest about itself.

Two failure modes are worth knowing before you read the log:

- **The install.** `--frozen-lockfile`, with the pnpm version read out of the
  checkout's `packageManager` field, and `CI=true` because pnpm will not purge a
  `node_modules` directory unattended. The install output is tailed into the
  container log when it fails.
- **The account.** `CONFORMANCE_ACCOUNT` (`CF_CONFORMANCE_ACCOUNT` in
  `compose/estate/tokens.env`). Five of the eight suites sign in; without a
  working account they skip, beacon refuses to derive `pass` from zero
  comparisons, and the suites go to `skip` rather than silently green.

## If `ConformanceCorpusStale` is what fired

A suite completed at some point and has not been replayed in over 36 hours,
against a 24-hour schedule. The label tells you which suite; the count tells you
which shape of failure.

1. **All eight suites stale, at about the same age.** The runner stopped. Read
   its log and its status as above. Restart it with:

   ```sh
   cd /home/savvaniss/dev/cloudsforge/deploy
   export DOCKER_CONFIG=/tmp/dockercfg-nocreds   # see the compose header
   docker compose -p cloudsforge-estate \
     --env-file compose/mainnet.env --env-file compose/estate/tokens.env \
     -f compose/docker-compose.estate.yml -f compose/docker-compose.conformance.yml \
     up -d --no-deps conformance-runner
   ```

   It replays on start, so a successful restart clears this within a scrape or
   two. If it does not, the replay is failing before it publishes — the log says
   where, and `scripts/conformance-replay.sh` runs the same thing in the
   foreground.

2. **One or two suites stale while the rest are fresh.** The runner is fine and
   the corpus stopped covering something. A suite dropped or renamed in
   `micro-conformance` keeps its last row in `conformance_runs` for ever, and
   beacon keeps publishing it. That is a true signal — a gate that quietly
   narrowed — and the fix is to delete the orphaned row once you have confirmed
   the rename was intended, not to widen the alert.

3. **Every suite stale by exactly the same amount, and growing in lockstep with
   nothing in the runner log.** Suspect the clock, not the corpus: this rule is
   `time() - <timestamp>` and a Prometheus host whose clock has jumped will
   produce exactly this.

## Confirm which of the three cases you are in (`ConformanceCorpusNeverReplayed`)

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

From the deploy checkout, through the same container definition the schedule
uses — so a hand replay cannot drift from the scheduled one:

```sh
./scripts/conformance-replay.sh                 # compare and publish
./scripts/conformance-replay.sh --no-publish    # compare only; nothing reaches beacon
```

That is `replay.sh once` in a throwaway container, and it exits with the
comparison's status.

Directly from a `micro-conformance` checkout, if you need to compare against a
different apex or an unmerged corpus:

```sh
pnpm -s cfconf compare --beacon https://beacon.<apex>/
```

The token is the same credential Prometheus and Alertmanager present. It is
`BEACON_TOKEN` in `compose/estate/tokens.env` on this estate and
`CF_BEACON_TOKEN` in `deploy/.env` on the older host — get that wrong in a
compose file and the bring-up fails at interpolation, which is the good outcome.
Pass it in the **environment**, never as `--beacon-token` on a command line:
`ps` shows an argv to everything sharing the namespace, and every log that
captures a command keeps it.

One run is posted **per scenario**, not one per estate, and that grain is
load-bearing: a single row summing eight scenarios lets a broad corpus be
certified by its narrowest one.

Beacon derives `pass`/`fail`/`skip` from the counts itself. A reporter cannot
declare its own `pass`, and two CHECK constraints refuse a `pass` with zero
comparisons or alongside a breaking difference — so a hand replay cannot produce
a green row without having actually compared something.

## Clearing it properly

A hand replay silences `ConformanceCorpusNeverReplayed` for as long as the rows
exist, which is exactly the wrong outcome if it is treated as the fix: the next
question the estate cannot answer is "has the corpus been replayed *since the
last release*", and one manual row a month ago answers it wrongly.

**That is why `ConformanceCorpusStale` exists**, and it is the rule this section
used to prescribe: a never-ran check can be silenced for ever by one run, so the
alert had to become a check on the *age* of the newest run once a scheduled
runner existed. Both halves landed on 2026-08-12 — the runner in
`docker-compose.conformance.yml`, the staleness rule and the
`beacon_conformance_last_run_timestamp_seconds` series it reads.

So a hand replay is now a diagnostic, not a close. It answers "can this estate
be compared at all right now", and the alert it silences comes back in 36 hours
if the thing that was supposed to keep replaying is still not doing it. **Close
this by getting the runner running again**, not by replaying once.

## What this alert is not

- **Not `HearthConformanceVectorsFailing`.** That one means a comparison ran and
  found a breaking difference. These two mean no comparison ran, or none ran
  lately. Only the first of the three is about the chain.
- **Not a reason to publish a zero into `beacon_conformance_vectors`.** Beacon
  deliberately refuses to, and the refusal is the point: a
  `beacon_conformance_vectors{result="failed"} 0` would read as "zero failing
  vectors" — a positive claim of correctness made by a suite that never ran.
- **Not a release blocker on its own.** It is sev4 because an unenforced gate is
  a process failure, not an outage. It becomes a blocker the moment a Hearth
  release is cut against it, because at that point the gate the release policy
  names has no input.
