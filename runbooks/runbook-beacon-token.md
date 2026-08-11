# The Beacon break-glass token

**Triggered by** `Rotation; a suspected compromise; the value appearing in a transcript or a public file`
**Severity** SEV2 if exposed · **Owner** platform

Two lines of `compose/docker-compose.estate.yml` have pointed here since Beacon
was added. This page did not exist until 2026-08-10, which is when it was first
needed.

## Read this first

`BEACON_TOKEN` is **inbound break-glass**, not an outbound service credential.
It is a static shared secret, like `ANALYTICS_TOKEN`, and it is deliberately
**not** minted by identity. Beacon's own header, quoted in
`compose/docker-compose.estate.yml`, says why it is checked *before* the
identity token:

> when identity is the thing that has broken, a Beacon that could only be read
> with an identity token would be a Beacon nobody can read.

So the usual advice — "rotate it through identity, the estate has a mechanism
for this" — does not apply, and following it would destroy the one property this
token exists to have.

Do not confuse it with `BEACON_SERVICE_CREDENTIAL`, set a few entries below it in
the same service block, which *is* a long-lived `cfsc_…` identity credential —
`estate-bootstrap.sh` mints it under the third name `BEACON_IDENTITY_CREDENTIAL`.
Three names, two kinds, one service. Rotating the wrong one leaves the leak open
and takes the trial-balance journey down.

## THE FOUR HOMES, AND WHY YOU MUST NOT GREP FOR THEM

    compose/estate/tokens.env            BEACON_TOKEN         mode 600
    .env                                 CF_BEACON_TOKEN      mode 600
    prometheus/secrets/beacon_token      the whole file       mode 640
    alertmanager/secrets/beacon_token    the whole file       mode 640

plus the environment of the running `beacon` container, which is a *copy* made
at container-create time and is the reason a rotation is not finished when the
files are right.

That list was produced by **measurement, not by grep**: a fingerprint sweep of
every source file and all 158 container environments on the host. Two of the
four are not `BEACON_TOKEN=` anywhere and would be invisible to a text search —
they are bare values in a file whose *name* is the only clue. A grep-derived
list is how a rotation ends with one consumer still holding the retired value.

To re-derive it, do not print anything:

    make check-residue ROOTS=/home/savvaniss

The last two files are read **per request**, not at start-up: Prometheus's
`http_headers.x-beacon-token.files` and Alertmanager's
`authorization.credentials_file`. Editing them takes effect immediately with no
restart. That is what makes the window below short.

## There is no accept-list, so there is a window

`verifyDelivery` in `contracts/packages/events` takes a *list* of secrets, so an
outbox endpoint can accept old and new for a window and rotate with no gap.
**Beacon does not.** `BEACON_TOKEN` is one value, so between "the token files hold the new value" and "the Beacon container
holds the new value" every scrape and every alert delivery gets a 401.

Measured on 2026-08-10: about **fifteen seconds**, the time to recreate one
container. Nothing pages, and this is the number to check before you assume that
is still true —

    BeaconScrapeFailing   expr: up{job="beacon"} == 0   for: 10m

so the gap has forty times the slack it needs. If that `for:` is ever shortened,
this procedure has to gain an accept-list first.

## Rotate

Every command below is run on the host. **The new value is generated there,
never printed, never pasted into a terminal, and never put on a command line** —
an argument is readable in `/proc/<pid>/cmdline` by every account on the box for
the life of the process.

### 1. Recover the invocation from the container, not from a compose file

    docker inspect cloudsforge-estate-beacon-1 --format \
      '{{index .Config.Labels "com.docker.compose.project.config_files"}}
       {{index .Config.Labels "com.docker.compose.project.environment_file"}}
       {{index .Config.Labels "com.docker.compose.project.working_dir"}}'

On 2026-08-10 that gave `docker-compose.estate.yml` +
`docker-compose.release.yml`, env files `mainnet.env` + `estate/tokens.env`,
working directory `compose/`. Use what it says today. Compose bakes environment
at **create** time, so a recreate that omits an `--env-file` does not fail — it
silently rebuilds the container against different values.

### 2. Write the new value into the four homes

    umask 077
    openssl rand -base64 48 | tr -d '\n' > ~/work/new-beacon-token

then edit the two env lines and overwrite the two token files. Do it with a
script that prints `sha256 | cut -c1-12` fingerprints and refuses if a variable
matched zero times or twice — a rotation that silently updated three of four
places looks exactly like one that updated four.

Do **not** leave a `.bak` beside the file you edited. That is how
`.env.bak-pre-grafana-156` came to hold a live beacon token and two other live
credentials for weeks; keep backups outside the deploy tree and shred them when
the rotation is declared good.

### 3. Recreate Beacon, and only Beacon

Beacon is an app-stack container, so this runs on the **app host**
`savva@192.168.1.129` inside WSL — not on `192.168.1.42`, which since the
chain-host split runs only the chain daemons, the Hearth seeds and the EMBER
miners and has no `beacon` service to recreate.

    cd /home/savvaniss/dev/cloudsforge/deploy/compose
    docker compose -p cloudsforge-estate \
      --env-file mainnet.env --env-file estate/tokens.env \
      -f docker-compose.estate.yml -f docker-compose.release.yml \
      up -d --no-deps --force-recreate beacon

`--no-deps` because an unrelated `*-migrate` exiting 1 aborts the whole command
otherwise, and `--force-recreate` because compose will not otherwise re-read the
environment for a container whose image and config hash have not changed.

It prints an orphan warning naming `cloudsforge-estate-gateway-1`. That is
expected — the gateway is in this project and is not defined by these two files.
**Never answer it with `--remove-orphans`.**

## Prove it, both ways

Two consumers present the token two different ways, and a rotation that only
tested one has tested half of it. Feed the credential to `curl` through a `-K`
config on **stdin** so it never reaches argv:

    # Prometheus's path: a custom header
    printf 'header = "x-beacon-token: %s"\n' "$(cat ~/work/new-beacon-token)" |
      docker run --rm -i --network cloudsforge-estate_default curlimages/curl \
        -s -o /dev/null -w '%{http_code}\n' -K - http://beacon:4000/metrics

    # Alertmanager's path: `credentials_file` sends Authorization: Bearer
    #   ... -X POST -H 'Content-Type: application/json' -d '<webhook body>' \
    #       http://beacon:4000/api/alerts/webhook

Run each with the **new** value and with the **retired** one. The rotation is
proved when the new answers `200` and the old answers `401` on **both**. Run a
third with a random string as a canary: a probe that cannot fail proves nothing,
and one that returns `000` for everything looks like a pass.

Then, after one scrape interval:

    curl -s http://127.0.0.1:9090/api/v1/targets | \
      python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["activeTargets"]; \
                  print(sum(1 for t in d if t["health"]=="up"), "of", len(d))'

37 of 37 on mainnet, and the `beacon` target's `lastScrape` must be **after** the
recreate. A target that is `up` from a scrape thirty seconds ago is telling you
about the old token.

## Finish it

    make check-residue ROOTS=/home/savvaniss
    docker ps -a --filter name=cloudsforge-estate --filter status=exited

Exited `*-migrate-1` containers hold a frozen copy of the environment they were
created with, and two rotations in a row ended with a retired secret in one.
`docker rm` any that predate the rotation. Mainnet had none on 2026-08-10;
testnet's twenty-eight hold testnet's own token and are a separate job.

Shred the working files. The new value being in `~/work` at mode 600 is not a
disclosure, but it is a copy, and copies are what the sweep above exists to find.

## Record

- **2026-08-10** — rotated on mainnet under micro-org#156, after the value was
  found in agent transcripts. Four homes updated, one container recreated, new
  accepted and retired refused on both `/metrics` and `/api/alerts/webhook`,
  37/37 targets up. `.env.bak-pre-grafana-156` — which held the live token at
  mode 600 — deleted. Testnet not rotated: its token is a different value and
  the environment was stopped at the time.
- **2026-08-11 — testnet rotated.** The reason recorded above expired: testnet
  moved to the app host and runs there, 48 containers healthy. A token left
  unrotated because nobody could reach the environment is a different thing
  from one left unrotated while the environment serves public `*-testnet`
  hostnames through Cloudflare.

  **Testnet has ONE home, not four**, and that is the finding worth keeping. A
  fingerprint sweep before touching anything:

      compose/estate/tokens.env             BEACON_TOKEN      2bed6b31ffe6   mainnet
      .env                                  CF_BEACON_TOKEN   2bed6b31ffe6   mainnet
      prometheus/secrets/beacon_token       whole file        2bed6b31ffe6   mainnet
      alertmanager/secrets/beacon_token     whole file        2bed6b31ffe6   mainnet
      compose/estate/tokens.testnet.env     BEACON_TOKEN      b7fbe985d0e7   TESTNET, alone

  The two secrets files hold **mainnet's** token. So nothing scrapes testnet's
  beacon and nothing routes its alerts — which is why the rotation had no 401
  window to manage at all, and is also a gap somebody should decide about on
  purpose rather than discover during an incident. Filed nowhere yet; it
  belongs with micro-org#370, which is about beacon having no error budget.

  Rotated to `b524bff0b9ae`, recreating **only** `cf-testnet-beacon-1` with the
  env files the container's own labels name (`testnet.env` +
  `tokens.testnet.env`, project `cf-testnet`). Proved by measurement:

      file fp == container fp                     MATCH
      /metrics with the new token                 200
      /metrics with a wrong token                 401
      /metrics with no token                      401
      all five MAINNET homes still agree          2bed6b31ffe6, untouched

  The backup was kept **outside** the deploy tree and shredded, for the reason
  this runbook already gives about `.env.bak-pre-grafana-156`.
