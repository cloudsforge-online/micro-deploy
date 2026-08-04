# The telemetry plane

[![ci](https://github.com/cloudsforge-online/micro-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/cloudsforge-online/micro-deploy/actions/workflows/ci.yml)
![licence](https://img.shields.io/badge/licence-MIT-97CA00)
![runbooks](https://img.shields.io/badge/runbooks-17-EF6C00)

AD-20, built. A **parallel** stack: it runs beside the existing eighteen-container
estate without touching it, shares no port, no container name and no volume with
it, and joins exactly one of its networks — read-only, to scrape Beacon.

Nothing under `repos/` or in the root `docker-compose.yml` is modified by
anything here, and `down.sh` removes only what this project created.

> **Why this is first, and not last.** The only way to prove a decomposition did
> not break behaviour is to compare traces, error rates and journey results
> across the cutover. Instrument afterwards and the baseline is gone. This lands
> in P2, before the first repository is split.

---

## Bringing it up

```sh
cd micro/deploy
cp .env.example .env      # optional; every value has a working default
make up                   # telemetry plane
make gateway              # telemetry plane + Traefik
make check                # every validation, offline
make estate               # confirm the existing estate is still healthy
make down                 # stop, keeping 15d of metrics and 30d of logs
make clean                # stop and delete all telemetry history
```

`make up` runs `up.sh`, which writes the two credential files, regenerates the
dashboards from the validated palette, warns if the existing estate is not
running, and then brings compose up. Bare `docker compose -f
compose/docker-compose.telemetry.yml up -d` also works once `up.sh` has run
once — it is the credential files that need creating, not the containers.

---

## The estate environment

Twenty-one of the twenty-two domain services and **all fifteen browser
surfaces**, running together, each service with its own database and its own
one-shot migrator.

```sh
cd micro/deploy
./scripts/estate-up.sh             # build, migrate, bootstrap, gateway, verify
```

or by hand, in the one order that works:

```sh
export CF_WEB_APEX=cloudsforge.localtest.me
docker compose -f compose/docker-compose.estate.yml up -d --build --wait
./scripts/estate-bootstrap.sh      # THE MANUAL ADMIN UPDATE, then the tokens
docker compose -p cfmicro \
  -f compose/docker-compose.telemetry.yml \
  -f compose/docker-compose.gateway.yml \
  -f compose/docker-compose.estate-gateway.yml up -d
./scripts/estate-verify.sh         # drives real flows and asserts real effects
```

Host ports are `4100 + the service's index in micro-org's registry` (`portFor`,
`cfctl.ts:868`) — derived from the one list that orders every repository rather
than picked, because a hand-chosen port has already collided twice here. They
bind to `127.0.0.1` only. The frontends continue that sequence at 4126.

Derived means **positional**, which is the sharp edge: a row inserted into the
middle of that registry moves every port below it. That has happened — a 46→70
sweep of the registry moved **sixteen of the thirty-nine** host ports pinned
here, and nothing reported it, because the comment claiming a guard named a
script that did not exist. `make check-web` (`scripts/web-check.py`) now
recomputes all of them by *executing* micro-org's registry and goes red on any
disagreement, including for the ports `estate-verify.sh` drives — where a port
that has moved onto another service does not fail, it passes against the wrong
container.

### The fifteen frontends, and the hostnames that make them a product

Until they joined, this file defined 22 domain services and **no frontend
container at all**. `docs/ecosystem/22-browser-journeys.md` §8.7 named the
consequence: 318 browser scenarios specified, 86 of them tier T3 needing the
estate, and **not one of them able to run**.

They are reachable two ways, and only one of them is a product:

| | Address | What works |
| --- | --- | --- |
| Direct | `127.0.0.1:4126` … `:4141` | the bundle, its assets, its 404 semantics |
| Through the gateway | `https://hub.$CF_WEB_APEX` and the other fourteen | **all of the above plus every API call the page makes** |

The distinction is not cosmetic. `cloudsforgeHosts()` reads
`window.location.hostname`, strips a known subdomain to derive the apex, and
rebuilds every sibling host as `https://<sub>.<apex>` — **no port**
(`ui/packages/ui/src/surfaces.ts`). A bundle opened on `127.0.0.1:4126`
therefore resolves identity to `http://localhost:4001`, which nothing here
serves. The loopback ports are for debugging one bundle; the hostnames are the
environment.

`CF_WEB_APEX` defaults to `cloudsforge.localtest.me`, a public wildcard that
resolves to `127.0.0.1`, so no `/etc/hosts` entry and no `sudo` are needed. TLS
is Traefik's self-signed default: right for loopback, wrong to ship. `curl -k`,
and `playwright-core`'s `ignoreHTTPSErrors`.

**A surface and its own API share an origin, and the gateway is what makes that
true.** Every frontend compares origins to decide its API base
(`resolveApiBase`), so served from its registry host it sends every request
*relative*: hub-web asks `https://hub.<apex>/v1/dashboard`, not hub-api's own
hostname — which it does not have one of. `gateway/dynamic/estate-web.yml`
routes `/v1` on each surface host to that surface's service, and everything else
to the bundle. Seven services are wired this way; the rest of the surfaces are
served with no `/v1` router at all, deliberately, because a router pointing at a
container that is not running answers 502 and that reads as "the service fell
over" rather than "there is no such service here".

### Cross-surface sign-in, and the variable that was set nowhere

`IDENTITY_HANDOFF_ORIGINS` defaulted to `''` and no compose file in this
repository set it. `isAllowedOrigin` is `env.handoffOrigins.includes(origin)`
over an empty array (`identity/src/handoff.ts:32`), so `createHandoffCode`
returned null for **every** origin and `POST /auth/handoff` answered 403 to
everyone. A person could sign in at Hub and reach **no other surface** — which
is where most of the 86 tier-T3 scenarios go on their second step.

Nothing caught it because nothing in this repository had ever minted a hand-off
code: identity's own suite sets the variable in `testsupport.ts:47`, so the
empty-by-default case was only ever exercised by a deployment, and there had
never been one. It is now set on identity to the fifteen surface origins this
file serves, and `estate-verify.sh` drives the whole hand-off — mint at Hub,
redeem at Market, and prove a code minted for one origin is refused from
another.

### One Postgres, a database per service — and why that is dev-only

`compose/estate/initdb.sql` creates one database per service on a **single**
Postgres server. Rule 1 of 03 §2 is that a service owns exactly one database and
reads no other; that rule is about **ownership**, and it is kept — every service
has its own database, its own migrator, its own connection string, and no grant
to anything else. What is shared is the server process, not the data.

**Production isolation is a separate requirement and this does not meet it.** In
production each of these is its own instance with its own failure domain, backup
schedule and credentials; here a noisy neighbour takes down all of them. The
compromise is deliberate: twenty-one Postgres containers on a laptop is a boot
time long enough that nobody runs the environment, and an environment nobody runs
is the condition this work exists to end. The one thing it must never become is a
shared *schema* — separate databases, not separate schemas, so a stray
cross-service join fails rather than succeeds.

### The bootstrap is a real step, not folklore

A fresh estate **cannot issue its own first credential**. `POST /service-tokens`
requires the `admin` role, `users.roles` defaults to `'{}'`, no route in identity
grants a role, and admin-api's bootstrap endpoint returns 501 deliberately. So
the first admin is a direct `UPDATE` against identity's database.
`scripts/estate-bootstrap.sh` owns that step and names it, instead of leaving it
buried in a verification script where a production runbook cannot find it.

> **The ten-minute cliff.** identity issues service tokens with a 600-second TTL
> (`identity/src/tokens.ts:28`) and nothing re-mints one. wallet built the seam —
> `const token = () => env.serviceToken` (`wallet/src/index.ts:90`) is a function
> called per request precisely so a short-lived token could rotate — but it
> returns a static environment string, and its own comment says the rotation
> waits for "when identity starts minting them". Ten minutes after the bootstrap,
> service-to-service calls in the money tier begin failing 401 until it is run
> again. The fix belongs in identity and the service repos, not here.

### What the environment still cannot do, and who owns each

Written down rather than left to be rediscovered. None of these is a defect in
this repository, and none is worked around here.

| What | Where it lives | Evidence |
| --- | --- | --- |
| **No scenario executes a bundle.** `estate-verify.sh` fetches every asset a page references and checks the design system reached the CSS, but nothing here runs JavaScript. A module that throws on line one passes every check. | `micro-beacon` — the tier-3 harness in `docs/ecosystem/22` §4 | by construction: this is a bash script |
| **`micro-admin-api` cannot be rebuilt.** Its Dockerfile copies the `runtimepkgs` build context and **not** `contractspkgs`, so the `@cloudsforge/contracts-events` import added in its `24fb2c7` cannot resolve. `pnpm typecheck` fails in the image and takes the whole `up --build` with it. | `micro-admin-api` | `src/server.ts(122,66): error TS2307: Cannot find module '@cloudsforge/contracts-events'`; `admin-api/Dockerfile` has no `COPY --from=contractspkgs` |
| **`indexer` is behind a profile** and so is `explorer.<apex>/v1`. | `micro-indexer` | `profiles: [indexer]` and the note above it |
| **~~micro-org's registry is 12 repositories short.~~ FIXED, and it moved sixteen ports.** The registry was swept from 46 rows to 70, so every surface here derives a port now. But the rows went in *mid-list* rather than appended, and the port is the index — so eleven frontends slid +4, `tessera` went 4140 → **4125**, and the four late surfaces were reordered. Recomputed here, all 39 at once. | closed | `make check-web` |
| **Three registry services have no container here.** `emberkin` (4122), `foresight` (4123) and `aetherholm` (4124) now have registry rows and derived ports, but this compose file defines only their *frontends*. `web-check.py` reports them rather than failing: this file is not obliged to serve every deployable, and a red nobody intends to clear is a red everybody ignores. | this repo | `make check-web`, the "no container in this compose file" note |
| **`foresight-admin` has no surface-registry row**, so its hostname is the one in this estate that was chosen rather than read. | `micro-ui` | no `foresight-admin` key in `ui/packages/ui/src/surfaces.ts` |
| **A missing asset 404s with `text/html`.** Every frontend's `nginx.conf` states the opposite intent ("a JavaScript request answered with HTML fails with a syntax error that names the wrong file"), but `error_page 404 /index.html` is server-level and catches the `/assets/` location's `=404` too. The status is right, so a browser still refuses to execute it; the content type is not. | the fifteen `*-web` repos | `curl -i http://127.0.0.1:4126/assets/nope.js` |
| **The Traefik Docker provider has never worked here.** v3.2.3 pins its Docker API version to 1.24; Docker Desktop's daemon refuses anything under 1.40. Label-based discovery — the gateway's stated design — is dead, and every route comes from the file provider. Neither `DOCKER_API_VERSION` nor v3.3.7 changes it; both were tried. | this repo, unfixed on purpose — see the note in `compose/docker-compose.gateway.yml` | `ERR ... client version 1.24 is too old`, every ten seconds, since the gateway first started |

### The relay cannot authenticate, so two consumers can never be fed

**`event_subscriptions` has no column for a credential, and the relay sends
none.** `identity/src/outbox.ts:320` attaches exactly `cf-signature` and
`cf-event-id`; the table is `(topic, url, active, created_at)`
(`identity/src/migrations.ts:58`). Two consumers gate their bus intake behind a
scoped token, so no subscription row can ever work for them:

| Consumer | Route | Demands | Consequence |
| --- | --- | --- | --- |
| `analytics` | `POST /ingest` | `authenticate()` + `SCOPE_INGEST` before it reads a byte (`analytics/src/server.ts:468`) | `identity.user.registered` is "the denominator of every onboarding cohort" (`analytics/src/catalogue.ts:307`) and never arrives — **every onboarding metric in the estate is structurally zero** |
| `admin-api` | `POST /v1/events` | `authenticate()` + `admin:audit:write` (`server.ts:554`, `scopes.ts:52`) | the audit mirror for all 26 `AUDITED_TOPICS` is never fed, so 17 §7 claim 9 cannot pass |

Measured rather than predicted: seeding the analytics row first produced
`attempts=67, last_error=POST http://analytics:4000/ingest → 401` against an
empty analytics inbox. The rows are therefore **not written**, because a
permanent 401 retry loop is worse than a named gap. `activity` and `notify`
verify the signature and nothing else, which is why the erasure drill has always
worked and these two never could.

The fix is a capability nothing has: a credential per subscription, exchanged at
`POST /service-tokens/exchange` like every other caller — or a change to those
two routes. It belongs to the outbox in `micro-identity` (and every producer's
copy of it), `micro-analytics` and `micro-admin-api`.

### Two things asked for here that could not be done

* **A transactional bootstrap against `platform_role_grants`, asserting that a
  re-run fails.** `grep -rn platform_role_grants identity/src/` returns nothing:
  the table does not exist in the working tree. Writing the procedure now would
  mean shipping a bootstrap against a schema that is not there, which stops the
  estate rather than hardening it. It is one commit's work the day the migration
  lands, and `scripts/estate-bootstrap.sh` §3 is where it goes.
* **A hard template failure when `CF_WEB_APEX` is unset.** Rejected on evidence:
  the file provider is all-or-nothing (below), so a template error to announce a
  missing *web* variable would also delete the `/internal` refusal. The loud
  failure lives in `scripts/estate-up.sh` instead, which refuses to start
  anything when the variable is empty **or when the two files that read it
  disagree** — that second case is the one no single-file check could catch.

### One malformed file in `gateway/dynamic/` deletes every route

Found by making the mistake. The file provider is **all-or-nothing**: a template
error in *one* file publishes no configuration from *any* file in the directory.
`estate-web.yml` had an unclosed conditional, and the visible result was that
`public-api.yml` and `policy.yml` were gone too — so `/internal`, a
priority-100000 security refusal, silently stopped existing and answered 404
instead of 502. Traefik logs it **once**, at startup, in a line that names one
file and says nothing about the others.

The mistake itself is worth naming: **a Go template action inside a YAML comment
is still an action.** The provider renders the whole file before anything parses
YAML, and it does not know what a comment is. `estate-verify.sh` therefore ends
by asserting `/internal` on a surface host — the cheapest possible canary for
"this directory did not load", at the cost of one request.

### What the verification proves

Not that containers started. `estate-verify.sh` checks `/livez` and `/readyz` for
all 21 services as a floor — a service that cannot answer cannot be in any flow —
and then drives flows and asserts effects:

| Flow | What is asserted |
| --- | --- |
| JWKS over a real socket | ledger verifies a token identity signed, fetched over the network rather than from an in-process stub |
| The bootstrap gap | a non-admin is refused (403), and the direct `UPDATE` is the only way through |
| Money | a balanced `deposit_credited` posts (201), the same idempotency key replays (200, not a double post), an **unbalanced journal is refused**, the trial balance still balances, and the money lands on the subject's account |
| Events | a sign-in writes an outbox row, the relay signs it, activity's inbox accepts it, and it appears in that user's own feed |
| Erasure | a deletion crosses the bus and **both** activity and notify drop the subject's rows to zero |
| **The fifteen surfaces** | each page carries the release this compose file asked for (a stale artefact is named as one), every asset it references is 200, its CSS carries `--cf-ember` so the design system survived the `link:` symlink into `../ui`, its entry chunk is over 50 kB, an enumerated route survives a hard refresh, and **an address it does not own answers 404 while still serving the shell** |
| **The gateway** | all fifteen bundles on their registry hostnames, seven services' `/v1` behind their own surface's host, `pay.` → wallet and `vault.` → custody with Hub's origin allowed on both, and `/internal` still refused at priority 100000 |
| **Sign-in** | `hub.<apex>/account/login` is served, `POST nimbus.<apex>/auth/handoff/redeem` reaches identity, and a real CORS preflight from Hub's origin is answered with that origin |
| **Cross-surface SSO** | a code minted at Hub for Market is redeemed at Market and yields a session; the same code is refused from a foreign origin; an origin off the allowlist is refused a code at all |

`indexer` is behind a compose profile and skipped by default — not because its
code is wrong, but because every service here builds from a **working tree**, and
micro-indexer currently has uncommitted work whose `pnpm typecheck` fails inside
the Dockerfile. That is the argument for the release manifest, below: an
environment built from working trees is only ever as green as every checkout on
the machine.

---

## Releases

A release is a file, not a tag. micro-org owns the format and the generator; this
repository owns the **consumer**, which did not exist.

```sh
# in micro-org — generates releases/<version>.yaml from each repo's
# package.json version and its git HEAD, and refuses a dirty checkout
pnpm cfctl release 2026.08.1

# here — render it, verify every image, deploy, roll back
./scripts/release-deploy.sh 2026.08.1 --dry-run
./scripts/release-deploy.sh 2026.08.1
./scripts/release-deploy.sh --rollback
```

`release-render.py` turns a manifest into a compose **overlay** that pins
`image:` per service and removes `build:` with `!reset`, so a release deploy
cannot silently fall back to building from a working tree. Migrators are pinned
to the same image as their service — a migrator running a different build from
the service that then asserts its schema is the oldest way to brick a deploy.

Deploy and rollback are the same code path with a different manifest, which is
the point: a rollback that is a different procedure from a deploy is a procedure
nobody has practised.

Two things are refused rather than warned about, because both are the failure the
format exists to prevent:

- **A manifest that pins nothing.** "All 0 images exist" is a true sentence and a
  useless one.
- **An image that cannot be pulled.** Checked before anything is changed. A
  `denied` here is usually the GHCR visibility trap — a package that inherited a
  private repository's visibility — rather than a missing image, and the script
  says so.

The overlay also **warns about services this environment runs that the release
does not name**. That is the silent hole the manifest format calls out by name:
it is how a service gets left on an old image while everything around it moves.

---

## Port allocation

Everything is in **9xxx**, which was verified clear against `lsof -iTCP -sTCP:LISTEN`
and `docker ps` before it was chosen. The existing estate holds 3000–3003,
4001–4006, 4010–4011, 5432, 8080–8081, 8545–8549, 8645–8649 and 18545.

| Host | Container | Component | |
| --- | --- | --- | --- |
| `127.0.0.1:9090` | 9090 | Prometheus | metrics, rules, alert evaluation |
| `127.0.0.1:9091` | 3000 | Grafana | the operator pane |
| `127.0.0.1:9092` | 3100 | Loki | raw log stream |
| `127.0.0.1:9093` | 9093 | Alertmanager | routing, grouping, inhibition |
| `127.0.0.1:9094` | 3200 | Tempo | traces |
| `127.0.0.1:9095` | 80 | Traefik | HTTP, redirects to TLS |
| `127.0.0.1:9096` | 443 | Traefik | TLS termination |
| `127.0.0.1:9097` | 8082 | Traefik | Prometheus metrics |
| `127.0.0.1:9098` | 13133 | OTel collector | health check |
| `127.0.0.1:9099` | 8889 | OTel collector | Prometheus exposition |
| `127.0.0.1:9317` | 4317 | OTel collector | **OTLP gRPC** — services |
| `127.0.0.1:9318` | 4318 | OTel collector | **OTLP HTTP** — browsers |

**Every port is bound to `127.0.0.1`.** This is an operator plane, not a public
surface, and the estate already treats pay, keyvault and postgres this way. A
Grafana on `0.0.0.0` with a default password is one port-scan from being the
worst thing on the host. Reach it over SSH, or through the gateway with real
auth in front.

---

## Networks

Three, per AD-17, plus one attachment to the existing estate.

| Network | Docker name | Who is on it |
| --- | --- | --- |
| `edge` | `cf-micro-edge` | gateway, and anything it routes to |
| `app` | `cf-micro-app` | services, and the telemetry backends |
| `vault` | `cf-micro-vault` | custody, ledger, settlement — **`internal: true`** |
| `estate` | `stack_default` | **external.** Prometheus and Alertmanager only |

**Custody is unreachable from `app` structurally, not by rule.** A container
attached only to `cf-micro-vault` has no route to a container attached only to
`cf-micro-app`; there is no firewall anyone has to remember to write, and no
label anyone can add to defeat it. `vault` is additionally `internal`, so nothing
on it can reach the internet — custody has no business making an outbound call,
and the indexer's twelve RPC providers are precisely why the indexer is a
separate service (AD-07).

Prometheus joins `stack_default` so it can scrape `beacon:4011`. Joining an
external network does not create, modify or remove it; the estate's compose file
is untouched and unaware.

---

## What each component is for

**`otel-collector`** — the only component that knows where telemetry goes.
Services speak OTLP to it and hold no backend address, which is what makes
adopting a commercial APM later a change to one exporter block rather than a
re-instrumentation of 38 repositories. It also does the redaction, the address
truncation and the tail sampling, so those policies are enforced once rather
than in every service.

**`prometheus`** — metrics, recording rules and alert evaluation. Exemplar
storage is on, which is what makes "p99 spiked" one click from the trace that was
slow.

**`tempo`** — traces. Object-storage-backed with no index to operate. Its
metrics generator remote-writes span metrics and service graphs back into
Prometheus, which is where the upstream-call latency panels come from without
anyone instrumenting a service pair by hand.

**`loki`** — the raw log stream. **Loki holds the stream; Lantern holds the
triage view.** Lantern is not replaced: it groups errors into issues by
normalised fingerprint — "this failure, 1,240 times, first seen 09:12" rather
than 1,240 rows — and it owns browser errors. Error grouping is the product; log
search is the commodity. Buy the commodity, keep the product. That division is
also what makes Lantern's 7-day retention acceptable.

**`alertmanager`** — routing, grouping and inhibition. Every alert opens a
**Beacon incident** as well as being delivered, because Beacon already owns
incident open/close, hysteresis, the timeline and the status page. Two incident
systems is two records to reconcile at the worst possible moment.

**`grafana`** — one pane over all three signals, with the trace↔log↔metric links
wired in provisioning rather than left to whoever opens the panel.

**`gateway` (Traefik)** — label-based discovery, which is what deletes eighteen
`container_name:` entries and every fixed host port and makes `deploy.replicas`
legal at all. It owns TLS, CORS, and the `/internal` refusal.

### The `/internal` refusal moved, and so did its invariant

This paragraph used to say that `/internal` was refused by a path rule in
`deploy/cloudflared/config.example.yml`, "asserted by a CI job that parses that
YAML (`.github/workflows/ci.yml:155`)". **Neither of those existed.** There was
no `cloudflared/` directory in this repository, and `ci.yml` had a single job in
it running `scripts/surface-routes.py`. Two other files repeated the same claim
(`gateway/dynamic/policy.yml:13`, `compose/docker-compose.gateway.yml:17`), so
the estate's record of where this control lived cited a file and a check that
were never written — which is exactly the defect `surface-routes.py`'s check 4
exists to catch, sitting one directory outside what that check reads.

Both copies are real now, and the invariant is asserted in both places. AD-17
moved routing and TLS to the gateway, so the **mechanism** moved — and the
invariant had to move with it, or a check keeps passing against a file nothing
reads any more, which is worse than no check at all.

It is now a router in `gateway/dynamic/policy.yml` at priority 100000, pointed at
an unreachable service. It is a *route*, not a middleware, because a middleware
chain cannot refuse a request. It lives in a policy file rather than in a label
because **a service must not be able to relax the rule that constrains it.**

Verified behaviour:

```
/internal          -> 502      //INTERNAL/x     -> 502
/internal/credit   -> 502      /Internal        -> 502
/internalisation   -> 404      (correctly NOT matched)
```

502 rather than 403: a 403 confirms the path exists to whoever is probing, and
502 is exactly what an unreachable upstream looks like from outside the box —
which is what `/internal` should look like.

---

## Retention, and what each number costs

| Signal | Value | Why this number |
| --- | --- | --- |
| Prometheus, raw | **15d** | Long enough to work an incident and its week-on-week comparison. Beyond that, nobody queries raw 15-second resolution — they query a trend, which is what the downsampled series is for. Also bounded at 8GB, because a monitor that fills the disk it shares with Postgres has taken the platform down. |
| Prometheus, downsampled | **400d at 5m** | Two consumers: capacity trends, and the 90-day uptime bars on the public status page. 400 days is not arbitrary — it matches Beacon's `BEACON_ROLLUP_RETENTION_DAYS=400`, so the status page's history and Grafana's agree. |
| Tempo | **7d, tail-sampled** | Enough to debug last week. Older than that, the question is answered by metrics and the audit plane, not by re-reading a span. Traces are the highest-volume signal and the one with the steepest cost curve, which is why sampling is aggressive and retention is short. |
| Loki | **30d** | Longer than traces because a log line is small and because "when did this start" is asked of logs far more often than of traces. Shorter than the audit plane, deliberately: logs are best-effort, can be dropped by the memory limiter under load, and must never be the system of record for anything. |

**Losing telemetry is not a business event.** None of it is backed up beyond
object-storage durability, and that is a decision, not an omission: the ledger's
RPO is zero and Prometheus's is a day.

### The 400-day line needs saying plainly

**Prometheus cannot downsample.** AD-20 writes "15d raw, 400d downsampled" as
though it were a configuration value; there is no such flag. Prometheus has one
retention for all data at one resolution.

What is implemented instead: `prometheus/rules/slo.yaml` records a `cf:ds5m:*`
family at 5-minute resolution — roughly 1/20th the sample volume — and the
long-horizon panels read those. They are also exactly what gets shipped when a
remote-write store lands, which is why `--web.enable-remote-write-receiver` is
already on.

To actually keep 400 days, one of these is required and none is free: Thanos or
Mimir (a second stateful system, and 13-operational-model.md §13's whole argument
against a broker applies), or Prometheus's own retention raised to 400d with the
storage bill and query cost that implies. **The recommendation is Mimir at the
point the 90-day uptime bars need real history**, and until then the 5m rollups
serve the trend panels honestly. This is the largest gap between AD-20 as written
and AD-20 as built.

---

## Secrets

No secret is in any committed file. `.env` is gitignored; `up.sh` reads it and
writes two credential *files* which are mounted:

| File | Read by | Mechanism |
| --- | --- | --- |
| `prometheus/secrets/beacon_token` | Prometheus | `http_headers: files:` on the Beacon scrape |
| `alertmanager/secrets/{page,ticket}_webhook_url` | Alertmanager | `url_file:` on each receiver |

Files rather than environment variables, because a credential in an environment
variable is a credential in `docker inspect`, in every crash dump and in the
process table.

**Unconfigured is a supported mode.** With nothing set, alert delivery falls back
to the Beacon incident receiver — a degradation you can see (no acknowledgement,
no escalation) rather than a failure that stops the plane from starting.

### Beacon costs one thing more than AD-20 predicted

AD-20: *"Beacon emits Prometheus format explicitly so that adopting a scraper
costs a scrape config rather than a rewrite, and nothing has ever scraped it."*

The scrape config is written and it works. It costs a scrape config **and a
credential**: Beacon gates `/metrics` behind the same auth as every other route
(`infra/beacon/src/server.js:373`), which is correct — an open `/metrics`
publishes the shape of the estate to anyone who can reach the port — but it is a
step the decision record does not mention.

`BEACON_TOKEN` is **empty on the running estate**, so the scrape returns 401
until an operator sets it in the estate's `.env` *and* sets the same value as
`CF_BEACON_TOKEN` here. `BeaconScrapeFailing` fires on exactly this, and its
runbook lists the four causes in likelihood order.

This was verified rather than assumed: with a token set on both sides, the target
scrapes green and `beacon_up` lands in Prometheus. The configuration is right;
the estate is missing one variable.

---

## Divergences from the specification, and why

These are places where the documents and the code disagree, and the code wins
because a rule referencing a metric nobody publishes evaluates to empty and
alerts on nothing — silently, which is the failure mode this whole plane exists
to prevent.

| 13-operational-model.md says | `@cloudsforge/telemetry` emits | Used here |
| --- | --- | --- |
| `http_server_requests_total` | `http_requests_total` | the library's |
| `http_server_request_duration_seconds` | `http_request_duration_ms` (**milliseconds**) | the library's |
| `jobs_dead_lettered_total` | `jobs_dead_total` | the library's |
| `jobs_inflight` | `http_requests_in_flight`; jobs expose `jobs_pending` / `jobs_overdue` | the library's |
| `jobs_lease_expired_total` | not emitted | `jobs_overdue` as the proxy, noted in the panel |

The document is using the OTel semantic-convention spelling and the library is
not. **One of the two must change**, and this is a decision for the architect,
not for a deploy directory: renaming the library's metrics is a P2 change to one
package, while amending the document is free. The library is what these
dashboards and rules reference either way.

### Metrics that do not exist yet

The money and chain rules reference metrics that `ledger`, `wallet`,
`settlement`, `custody` and `indexer` must emit. Those services are P4/P5 and are
not written. Those rules are the **contract**: a service that does not emit
`ledger_trial_balance_delta` fails an alert that is already deployed and already
has a runbook, rather than shipping and being instrumented afterwards.

`MoneyMetricContractMissing` is the rule that stops this being a silent gap.
`absent()` inverts the default: not publishing the metric is itself the alert.
Without it, a missing metric and a healthy ledger look identical — which is
precisely the estate's current condition, where no metrics scraped anywhere
presents as no alerts firing.

---

## Dashboards

Five of the nine are built: Platform overview, Service detail (templated by
`$service`), Money integrity, Deposits & withdrawals, Chain health. Business,
Product funnels, Custody & security and Developer platform need `analytics`,
`billing`, `custody` and `devplatform` — **all four of which now exist**, are built
and are green. This said "none of which exist", which was true when it was written
and is false for every one of them today; those four dashboards are buildable work
rather than a blocked dependency. `micro-devportal-web` caught the devplatform half
of it; the other three were wrong in the same sentence.

**They are generated, not hand-written.** `grafana/build-dashboards.py` reads
`grafana/theme/palette.json` and writes fixed colours into every panel, because
Grafana has no mechanism for registering a custom named palette — a colour is
either one of Grafana's own names or a hex literal in each panel. Forty panels of
hand-typed hex is forty chances to drift, and the palette is validated rather
than decorative: ember↔gold sit at ΔE 2.8 under deuteranopia, which is the
difference between two series and one.

The generator also enforces the rules, not just the values:

- **`timeseries()` takes one unit and has no second-axis argument.** Two measures
  of different scale become two panels sharing the dashboard's time range. Rate
  and error ratio are two panels; CPU and memory are two panels; hashrate and
  difficulty would be two panels.
- **Categorical colours are assigned by NAME, in slot order, never cycled.**
  Passing a ninth series raises rather than generating a hue. Keying by name is
  the palette's "colour follows the entity, not its rank" rule: filtering a chart
  down to three chains does not recolour the survivors.
- **Quantiles take the sequential ember ramp**, not three categorical hues. p50,
  p95 and p99 are one measurement at increasing severity, and lightness says so.
- **Status marks ship icon + label + colour** — `● pass`, `▲ skip`, `■ fail`.
  Colour never carries meaning alone, because the surface a colourblind operator
  reads under stress is the one that is red.
- **A missing reading renders as `▲ no data answered`**, never as an empty cell.
  An empty chart and a failed chart must not look the same, and on the Money
  integrity dashboard a trial balance that is *absent* must not read as balanced.

The Money integrity dashboard's first panel is the trial balance, at 56px, with
no warning band — there is no amount by which double-entry is allowed to be
wrong. Its alert is `LedgerTrialBalanceNonZero`, SEV1, paging, with no error
budget.

To regenerate: `make dashboards`. Provisioned dashboards are read-only in the UI
on purpose — a panel edited in the browser is a change no repository has, lost on
the next deploy, and discovered when somebody opens it during an incident.

---

## Alerts

Twenty rules, and **every one carries a `runbook_url` that resolves to a file in
`runbooks/`**. `make check-runbooks` fails the build otherwise. An alert without
a runbook is deleted, not silenced, because an unactionable page teaches the
on-call to ignore pages.

Page (user-visible failure or irreversible money risk): trial balance non-zero,
stuck withdrawal, custody unreachable, indexer lag past the confirmation depth,
sustained chain height spread, a critical Beacon journey failing twice
consecutively, fast Tier-1 SLO burn, gateway 5xx above 5%, backup age past 36h.

Ticket (everything else): reconciliation drift, frozen deposit addresses,
dead-lettered jobs, overdue jobs, slow SLO burn, Beacon scrape failing, a
telemetry component down, a stale journey, failing conformance vectors, a Beacon
target down, and a missing metric contract.

A metric says "p99 is high"; a journey says "a user cannot withdraw". Page on the
second.

---

## Layout

```
compose/
  docker-compose.telemetry.yml   the plane
  docker-compose.gateway.yml     Traefik, label discovery
  env/*.env                      one file per service, no secrets, no fan-out
otel/collector.yaml              redaction, truncation, tail sampling, three exporters
prometheus/
  prometheus.yml                 scrape config, incl. Beacon
  rules/slo.yaml                 SLIs, burn rates, 5m rollups
  rules/alerts.yaml              20 rules, every one with a runbook
  targets/services.yaml          file_sd, generated from the release manifest
tempo/tempo.yaml                 7d, metrics generator
loki/loki.yaml                   30d, label cardinality bounded
alertmanager/alertmanager.yml    routing, grouping, 3 inhibit rules
gateway/dynamic/policy.yml       /internal refusal, CORS, security headers
grafana/
  build-dashboards.py            the palette, applied by construction
  theme/palette.json             the validated values, as data
  dashboards/*.json              generated; provisioned read-only
  provisioning/                  datasources with trace<->log<->metric links
runbooks/*.md                    17, one per alert that needs one
scripts/check-runbooks.py        the runbook rule, as a build failure
```

### Per-service env files, and why the fan-out had to go

The estate's compose hands eight services all 64 variables through one
`env_file: .env`. That is how the game container holds the custody master
secret — not because anyone decided it should, but because one list was easier
than eight. `compose/env/` makes it impossible by construction: **a variable a
container was never given cannot leak from it.** The collector needs three
variables and receives three.

This is the highest-severity item in the estate and close to free.

## Verifying a gateway change, and one way to waste an hour

**Never ship a change to `gateway/dynamic/*.yml` without booting Traefik against it.** A failure
rejects the whole directory: it is not a partial outage, nothing is routed.

```bash
rm -rf ~/gw-check && mkdir -p ~/gw-check       # a FRESH directory, under $HOME - see below
cp gateway/dynamic/*.yml ~/gw-check/
docker run --rm -d --name gwtest -v ~/gw-check:/dyn:ro \
  traefik:v3.2.3 --providers.file.directory=/dyn --entrypoints.websecure.address=:443 --log.level=DEBUG
sleep 6 && docker logs gwtest 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "Error while building|providerName=file"
docker rm -f gwtest
```

An `ERR Error while building configuration` line means the directory was rejected. Silence means it
loaded — but **read the `Configuration received` line too**, because a directory that loads is not
the same as a directory that routes. See below.

**Under `$HOME`, not `/tmp`.** Docker Desktop on macOS does not share `/tmp`, so
`-v /tmp/gw-check:/dyn:ro` mounts an **empty** directory and Traefik cheerfully reports no errors
about the two files it cannot see. That produces a clean run that has verified nothing, which is
worse than a failure. Check with
`docker run --rm -v ~/gw-check:/dyn:ro --entrypoint /bin/sh traefik:v3.2.3 -c 'ls /dyn'` before
believing any result.

**Do not pass `-e CF_API_HOST` unless you are testing an override.** The recipe here used to, and
that is exactly how the next two defects survived: the check supplied a value the deployment did
not, so it proved something the deployment could not do. `CF_API_HOST` now lives in
`compose/env/traefik.env`, which is the file the gateway actually loads.

### Two ways a route map is dead without being wrong

Both of these were live in this repository, and neither is visible from reading the file.

1. **Go templating runs before YAML parsing.** A dynamic file is rendered as a Go `text/template`
   *first*. So `rule: "Host(`{{ env \"CF_API_HOST\" }}`)"` — perfectly valid YAML — reaches the
   template engine with literal backslashes and fails with ``unexpected "\" in operand``. And a
   template failure **rejects the whole directory**: every public router *and* `policy.yml`'s
   `/internal` refusal, gone together. Single-quoted YAML scalars need no escaping and avoid it.

2. **An undefined `{{ env "X" }}` renders empty, silently.** The router still loads. Its rule
   becomes ``Host(``) && PathPrefix(...)`` — valid, and matching no request ever sent. Traefik logs
   nothing at all. The public API is dead and the configuration looks correct.

`make check-gateway` catches both statically, and goes red if either is reintroduced. It is not a
substitute for booting Traefik; it is what makes booting it optional for a small change.

**Copy to a fresh directory first.** Bind-mounting the working tree directly gave a reproducible
false failure: Docker Desktop's file sharing served a stale cached view of a directory that had been
edited several times in quick succession, so the container was reading a version of the file that no
longer existed on disk. It failed 3 runs out of 3 against the working tree and passed 3 out of 3
against a byte-identical copy - same md5, both files - which is what proved it.

The error it produced pointed at a line ninety lines away from any edit and blamed a construct that
was correct. Every hypothesis drawn from it was wrong, because the input was a ghost. If a gateway
error does not survive a fresh copy, it is not real.

---

## Provenance

The code in this repository was written by **Claude Opus 5** and **Claude Fable 5**, assets
generated with **FLUX 2 Pro**, under human direction and review.
