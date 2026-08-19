# micro-deploy

[![ci](https://github.com/cloudsforge-online/micro-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/cloudsforge-online/micro-deploy/actions/workflows/ci.yml)
![licence](https://img.shields.io/badge/licence-MIT-97CA00)
![runbooks](https://img.shields.io/badge/runbooks-35-EF6C00)

> ### The estate runs on Kubernetes
>
> Since **07:44 UTC on 2026-08-19**, every public request is served by k3s on a
> Hyper-V Linux VM — `cf-k8s`, `192.168.1.171`. No WSL, no Docker Desktop. The
> compose estate this repository grew up around is **stopped**, and the app
> host's `Cloudflared` service is Stopped and Disabled.
>
> - **Operating it** — start, stop, deploy, reboot, move to another machine:
>   [`docs/kubernetes-operations.md`](docs/kubernetes-operations.md)
> - **Why it is shaped this way**, and what the cutover did:
>   [`docs/kubernetes-migration.md`](docs/kubernetes-migration.md)
>
> **Deploys are `./scripts/k8s-deploy.sh` run on the VM**, not
> `release-deploy.sh` run here. Everything below still describes the compose
> estate: accurate for how a release is *cut*, and for rolling back, but it is
> no longer how the live estate is deployed.

---

## The telemetry plane

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

## Standing up a new host

Two things bite a fresh machine before anything in this repository runs, and
both of them used to be undiscoverable from the documentation.

### The sibling checkouts, under names that are not their repository names

This repository is not self-contained. Several scripts read files out of
**sibling repositories**, and they read them under directory names that are
**not** the repository names — `micro-contracts` has to be checked out as
`contracts`, `micro-ui` as `ui`. Cloning either with git's default name leaves
the tooling failing exactly as if it had never been cloned.

```sh
cd micro/deploy
./scripts/provision-siblings.sh            # clone what is missing
./scripts/provision-siblings.sh --check    # report only; non-zero if a required one is absent
./scripts/provision-siblings.sh --all      # also the optional asset repositories
```

`estate-bootstrap.sh` runs the `--check` form in its pre-flight, so a missing
prerequisite is now a named line before anything is created rather than a
`FileNotFoundError` from the middle of a run that has already minted
credentials. `make check-siblings` holds the table to the scripts in CI — a row
that nothing reads, and a read that has no row, both fail the build.

| directory | repository | needed by | absent |
|---|---|---|---|
| `org` | `micro-org` | `release-deploy.sh` reads `../org/releases/<version>.yaml` | **required** — no deploy and no rollback |
| `contracts` | `micro-contracts` | `estate-bootstrap.sh` reads the audited topic list | **required** — bootstrap dies with a traceback |
| `ui` | `micro-ui` | `surface-routes.py`, `seed/beacon.mjs` | **required** — `estate-up.sh` refuses |
| `analytics` | `micro-analytics` | `estate-bootstrap.sh` reads `EVENT_TOPICS` | degrades — analytics is never subscribed, silently |
| `runtime` | `micro-runtime` | `make check-backup`, the `runtimepkgs` build context | degrades — nothing can be built from source |
| `brand`, `emberkin-assets`, `aetherholm-assets`, `tessera-assets` | `micro-*` | seeded market cover images; the source of `CF_WORLD_ASSETS` | optional — listings get no cover, `/world-assets/` 404s |

The asset repositories **do** have upstreams and are clonable like any other
(micro-org#350 recorded them as unreproducible state on one machine; they are
not). The world art itself is a separate step: `materialise.py` in
`micro-tessera-assets` writes a set, and `CF_WORLD_ASSETS` points at it —
unmounted, the compose gate calls a 404 "the supported default".

### Docker's credential helper, on the Windows/WSL app host

`docker` inside a WSL distro is Docker Desktop's integration, so
`~/.docker/config.json` there is the **Windows** config and its `credsStore`
names a helper that needs an interactive Windows logon session. Over
`ssh → wsl -d Ubuntu-24.04` there is not one, and docker consults the helper on
*every* pull — including anonymous ones. The estate's GHCR packages are public
and never needed a credential at all.

Measured on the app host on 2026-08-10:

```
docker-credential-desktop.exe list  → exit 1, "A specified logon session does not exist."
docker pull …                       → exit 1, "error getting credentials - err: exit status 1"
DOCKER_CONFIG=$HOME/.docker-cf docker pull …  → exit 0
```

`release-deploy.sh` now detects this itself and routes around it, so a deploy
over ssh needs no prior knowledge. It **exercises** the helper rather than
looking for it: the helper binaries are all on `PATH` through WSL's Windows
interop, so a presence check passes on the very host that cannot deploy.

Note that `DOCKER_CONFIG` also selects the CLI's *plugin* directory. Where the
compose plugin is user-scoped (a dev Mac, `$HOME/.docker/cli-plugins`) moving it
takes `docker compose` away with it; the fallback inherits the original's plugin
directory and the script asserts `docker compose` still answers before going on.

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
running, and then brings compose up.

**Bring the telemetry plane up with `up.sh`, not with a bare `docker compose`.**
The bare form fails on `required variable CF_GRAFANA_ADMIN_PASSWORD is missing a
value`, and the variable it names is not the problem: compose takes its project
directory from the first `-f`, so it reads `.env` from **`compose/`** — and
`compose/.env` is a symlink to `estate/tokens.env`. It does not miss this
directory's `.env` so much as silently load a different file, one that has never
carried a Grafana password. `up.sh` sources `.env` into the environment first.
If you must run compose by hand, pass `--env-file .env` explicitly.

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
docker compose --env-file .env -p cfmicro \
  -f compose/docker-compose.telemetry.yml up -d
# --env-file is not optional: compose would otherwise read compose/.env, which
# is a symlink to estate/tokens.env and carries no CF_GRAFANA_ADMIN_PASSWORD.
# The gateway is in the ESTATE's project, not the telemetry plane's, so that
# `docker compose -p cloudsforge-estate ps` lists it — micro-org#257.
docker compose -p cloudsforge-estate \
  -f compose/docker-compose.gateway.yml \
  -f compose/docker-compose.estate-gateway.yml up -d gateway
./scripts/estate-verify.sh         # drives real flows and asserts real effects
```

Host ports are `4100 + the service's index in micro-org's registry` (`portFor`,
`cfctl.ts`) — derived from the one list that orders every repository rather
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
| Direct | `127.0.0.1:4126` … | the bundle, its assets, its 404 semantics |
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

**`cloudsforge.localtest.me` is the LOCAL apex and never a public endpoint.**
The deployed apexes are these, and the testnet hostname shape is the part that
is easy to get wrong:

| | Mainnet | Testnet |
| --- | --- | --- |
| Surface host | `<surface>.cloudsforge.online` | **`<surface>-testnet.cloudsforge.online`** |
| Site apex | `cloudsforge.online` | `testnet.cloudsforge.online` |
| JSON-RPC | `https://rpc.cloudsforge.online` | `https://rpc-testnet.cloudsforge.online` |
| Chain id | **7411** (`0x1cf3`) | **7412** (`0x1cf4`) |
| P2P | `wss://p2p.cloudsforge.online/p2p` (only `/p2p` is routed) | `wss://p2p-testnet.cloudsforge.online/p2p` (only `/p2p` is routed) |
| Tunnel origin | `http://127.0.0.1:9081` (`cloudflared/config.mainnet.operator.yml`) | `http://127.0.0.1:9181` (`cloudflared/config.testnet.public.yml`) |

**Testnet hostnames are SINGLE-LABEL.** `<surface>.testnet.cloudsforge.online`
is dead and cannot be revived without Advanced Certificate Manager: Cloudflare's
Universal SSL is `*.cloudsforge.online` plus the apex, a wildcard matches exactly
one label, so a two-label name fails the handshake at the edge before a request
reaches this estate (`gateway/dynamic/tls.yml`). `testnet.cloudsforge.online`
survives because it is itself one label. `envLabel()` and `splitEnvLabel()` in
`ui/packages/ui/src/surfaces.ts` are the composer and its inverse, and
`scripts/check-apex-prefix.py` reads `ENV_LABELS` from that module so there is
one list rather than two that drift.

Five hosts serve **no HTML by design** and correctly answer `404` at `/` —
`nimbus`, `account`, `api`, `pay` and `vault` (`servesUi: false`). Never link a
person to them. On `api.<apex>` only `/v1/…` is routed; an unmatched path such
as `/` or `/livez` answers `404` from Traefik's default, with no upstream
involved.

`worlds-api.<apex>` used to be a sixth. **It is gone** — the game API was folded
INTO `api.`, not out of it, and the hostname never had a DNS record on either
network. Its gateway router, its registry row, its tunnel ingress entries and
its TLS probe were all removed on 2026-08-05. Several earlier comments in this
repository described the fold in the opposite direction; if you find another
one, it is wrong.

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
over an empty array (`identity/src/handoff.ts`), so `createHandoffCode`
returned null for **every** origin and `POST /auth/handoff` answered 403 to
everyone. A person could sign in at Hub and reach **no other surface** — which
is where most of the 86 tier-T3 scenarios go on their second step.

Nothing caught it because nothing in this repository had ever minted a hand-off
code: identity's own suite sets the variable in `testsupport.ts`, so the
empty-by-default case was only ever exercised by a deployment, and there had
never been one. It is now set on identity to the fifteen surface origins this
file serves, and `estate-verify.sh` drives the whole hand-off — mint at Hub,
redeem at Market, and prove a code minted for one origin is refused from
another.

### The combined view, and the one grant that leaves the estate

micro-org#459 retired the testnet **frontends** and kept the testnet **estate**.
There is one set of bundles now: a reader opens `hub.cloudsforge.online`, picks
Testnet in the bar, and the same bundle re-points its reads at
`hub-testnet.cloudsforge.online`. Three bundles do this — hub, explorer and
network — and each has a `src/lib/viewed.ts` that decides where a read goes.
Every other surface switches network by **navigating**, so its reads are
same-origin wherever it lands.

Those three reads are cross-origin, carry the reader's bearer, and come from a
hostname of the *other* environment — which nothing in the `cf-cors` allowlist
named, by construction: that list is "every surface on **this** environment's own
hostnames". So the testnet gateway answered the preflight `HTTP/2 200` with
`access-control-allow-credentials: true` and **no** `access-control-allow-origin`,
every testnet page in the merged frontend read "cannot reach the server", and the
services behind them were healthy throughout. Nothing server-side records a
refusal, because the refusal happens in the browser.

`CF_VIEW_ORIGIN_SUFFIX` closes it, and it is the only value in this repository
that grants a credentialed read to pages on hostnames the estate rendering it does
not serve. **It is set in `compose/env/traefik.testnet.env` and nowhere else.**
The asymmetry is the security property: testnet accepts reads from the mainnet
frontends; mainnet accepts nothing from testnet, because a page on a
worthless-coin hostname reading a credentialed mainnet response moves real value
and has no product reason to exist. Deriving it from `CF_WEB_SUFFIX` instead
would grant both directions from one edit in a file both gateways mount, which is
what the deleted hard-coded mainnet block already was.

Three guards hold it, because one line in the wrong file is a live grant:

| where | what it refuses |
| --- | --- |
| `surface-routes.py` check 10 | an origin that is not a `servesUi` surface, not already in this environment's own allowlist, or not a bundle with a `viewed.ts` — checked in both directions, so a fourth bundle that gains one fails here before anybody opens it |
| `surface-routes.py` check 6 | the variable set in any file other than its own, or missing from that one. `ENV_VARS_SET_IN_ONE_FILE` inverts the usual rule and asserts the asymmetry rather than tolerating it |
| `estate-up.sh` preflight 2b | a suffix equal to this environment's own — a no-op that reads like a grant — or one outside `CF_WEB_APEX`, which would hand a signed-in reader's token to a domain nobody here controls |

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
> (`identity/src/tokens.ts`) and nothing re-mints one. wallet built the seam —
> `const token = () => env.serviceToken` (`wallet/src/index.ts`) is a function
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
| **~~`foresight-admin` has no surface-registry row.~~ FIXED, then RETIRED.** It was given a row in `micro-ui`, which fixed the apex derivation that had been breaking sign-out. At P13 the panel folded into `micro-admin-web` as `/foresight`, so the row, the gateway routers, the CORS origin, the container and two tunnel hostnames all went together — `surface-routes.py` checks 1, 2 and 5 are what make that simultaneous. Every surface hostname in this estate is now read from the registry. | closed | `make check-surfaces`, and 48 tunnel hostnames rather than 50 |
| **A missing asset 404s with `text/html`.** Every frontend's `nginx.conf` states the opposite intent ("a JavaScript request answered with HTML fails with a syntax error that names the wrong file"), but `error_page 404 /index.html` is server-level and catches the `/assets/` location's `=404` too. The status is right, so a browser still refuses to execute it; the content type is not. | the fifteen `*-web` repos | `curl -i http://127.0.0.1:4126/assets/nope.js` |
| **The Traefik Docker provider has never worked here.** v3.2.3 pins its Docker API version to 1.24; Docker Desktop's daemon refuses anything under 1.40. Label-based discovery — the gateway's stated design — is dead, and every route comes from the file provider. Neither `DOCKER_API_VERSION` nor v3.3.7 changes it; both were tried. | this repo, unfixed on purpose — see the note in `compose/docker-compose.gateway.yml` | `ERR ... client version 1.24 is too old`, every ten seconds, since the gateway first started |

### The relay cannot authenticate, so two consumers can never be fed

**`event_subscriptions` has no column for a credential, and the relay sends
none.** `identity/src/outbox.ts` attaches exactly `cf-signature` and
`cf-event-id`; the table is `(topic, url, active, created_at)`
(`identity/src/migrations.ts`). Two consumers gate their bus intake behind a
scoped token, so no subscription row can ever work for them:

| Consumer | Route | Demands | Consequence |
| --- | --- | --- | --- |
| `analytics` | `POST /ingest` | `authenticate()` + `SCOPE_INGEST` before it reads a byte (`analytics/src/server.ts`) | `identity.user.registered` is "the denominator of every onboarding cohort" (`analytics/src/catalogue.ts`) and never arrives — **every onboarding metric in the estate is structurally zero** |
| `admin-api` | `POST /v1/events` | `authenticate()` + `admin:audit:write` (`server.ts`, `scopes.ts`) | the audit mirror for all 26 `AUDITED_TOPICS` is never fed, so 17 §7 claim 9 cannot pass |

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

> **What is deployed right now, and the rule that governs it, is
> [`docs/releasing.md`](docs/releasing.md).** One version across the entire
> estate — a change to one service is a version bump and a deploy for all
> forty-six. That document says what mainnet and testnet are running today, and
> why thirteen simultaneous versions on mainnet was the thing worth ending.

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

**By digest when the manifest has one** (micro-org#295). A tag is a mutable
pointer and this estate moves it: `publish-image.yml` republishes the
package.json version on every push to `main` or `release/**`, so an unmerged
release branch leaves `main` on the previous version and the next merge
republishes the *previous* release's tag from a different commit — measured on
six repositories on 2026-08-09 (micro-org#288). `cfctl release` records the GHCR
index digest each tag resolved to at cut time, and an entry that carries one is
rendered as `image@sha256:…` rather than `image:tag`. `--verify` and
`docker compose up` are two separate resolutions of the same mutable name and
only the first was ever checked; pinning by digest is a property the *file* has,
which is what holds at 3am during a rollback.

Three consequences, all deliberate:

- **An entry with no digest is still rendered by tag, unchanged.** Every manifest
  cut before 2026-08-09 has none, and those files *are* the rollback path. Their
  render is byte-identical to what it was before digests existed.
- **A mixed manifest renders.** `cfctl release` warns and succeeds with a partial
  digest set when a release is cut minutes before some images publish, so the
  overlay names, in its footer, exactly which entries are still pinned by a
  mutable name.
- **A digest-pinned entry can never fall back to a local build.** `docker compose`
  pulls a digest and `docker compose build` cannot use one — which agrees with the
  `build: !reset null` already on every entry rather than fighting it. The
  rendered file says so in its own header.

`micro-identity@sha256:d82f87dc…` does not say `2.5.7`, so each digest-pinned
entry carries the tag twice: in a comment for whoever opens the file, and in the
label `online.cloudsforge.release.image` for `docker compose config`, which
re-emits from a parsed model and drops every comment in it.

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

### The scrape list is rendered from the same file, at the same moment

`prometheus/targets/services.yaml` was the literal `[]` from the telemetry
plane's first deploy until 2026-08-09. Prometheus reported **8 active targets**
on mainnet — seven of them the monitoring stack watching itself, plus Beacon,
which was `down` — while the estate ran 48 services. Every rule that reads an
estate metric therefore evaluated against no data, money rules included, and a
rule with no series is indistinguishable from a rule that is satisfied. Two
incidents this month were found by a person while a rule for exactly that
condition sat deployed and unfireable (micro-org#308).

`render-prometheus-targets.py` now renders that file from the release manifest,
called twice by `release-deploy.sh`: once in pre-flight with `--check`, which
refuses the deploy if the release cannot be described to Prometheus, and once
after `up -d`, which writes it. **A release that cannot be monitored does not
ship.** The second call warns rather than fails — by then the containers are
already running, and refusing to write a file is not a reason to leave an
operator staring at a half-deployed estate; it prints
`make prometheus-targets RELEASE=<version>` instead.

It costs no restart. `file_sd` is re-read every 30s, so the new list is live
within half a minute of being written and Prometheus is never bounced during a
deploy.

The rule for **who gets scraped** is: *a service is scraped at the port its own
health check probes `/readyz` on.* Rule 4 of `docs/ecosystem/03` §2 makes
`/livez`, `/readyz` and `/metrics` a single obligation, so a service that has one
has all three, on the same listener. Three alternatives were rejected against
measurements taken on the live estate on 2026-08-09:

- **`kind: service` from the manifest** is wrong in both directions: `lantern`
  and `beacon` are `kind: ops` and do serve metrics, and `analytics` is
  `kind: service` and answers 401.
- **A uniform in-container port 4000** is wrong for `foresight` (4021) and
  `tessera` (4022), which would have been two permanently red targets for two
  healthy services.
- **Probing `/metrics` at render time** makes the target list depend on
  liveness: a service that happens to be restarting during a deploy is silently
  dropped from monitoring, and a service that has never come up correctly is
  never added. The list must describe what *should* be scraped.

The result was verified end to end rather than reasoned about: all 26 emitted
services answered `/metrics` with 200 and a Prometheus body, and all 18 web
deployables answered nothing on any port.

Nothing in `prometheus/targets/` is committed — see the README in that directory.
A generated file in git is a second answer to "what is running", and the estate
already lost that argument once with the `API_PREFIXES` array.

### The `tier` label, and where the mapping lives

`rules/slo.yaml` holds Tier 1 to 99.95% and Tier 2 to 99.5%, and it used to pick
Tier 1 out with `service=~"ledger|wallet|settlement|custody|indexer|pricing|billing"`.
That regex had **already drifted**: `13-operational-model.md` §8 lists `billing`
as Tier 2. Nobody noticed, because the expression it filtered had no series in it
to filter. Selecting on a hardcoded list of names was the exact failure the
`tier` label exists to prevent, in the file that defines the label's meaning.

The map is `prometheus/tiers.yaml`, and the renderer **fails the deploy** on a
scrapable service missing from it rather than defaulting it to Tier 2 — a money
service quietly held to an objective ten times looser than its own is worse than
a deploy that stops. Three reasons for that location:

- **`docs/` is not checked out on the deploy host.** Re-measured 2026-08-11,
  after the chain-host/app-host split moved both estates: the deploy host is now
  `savva@192.168.1.129` (inside WSL), and `/home/savvaniss/dev/cloudsforge`
  contains `contracts`, `deploy`, `miner-keys`, `org` and `ui` — no `docs`. The
  original 2026-08-09 measurement named `/home/malf/dev/cloudsforge` and read
  "`org` and `deploy` and nothing else"; that host now runs only the chain
  daemons and the Hearth seed, and its checkout has since grown to thirty
  repositories, so both halves of that sentence have expired. The conclusion has
  not: §8 cannot be the runtime source of a value the renderer needs, because
  the file it lives in is not on the machine that renders.
- **A tier is a property of a service, not of a release.** Putting it in the
  manifest would make it a property of the release, and manifests are generated,
  say "do not hand-edit", and are the rollback path.
- **It sits beside its only consumer.** `rules/slo.yaml`, `prometheus.yml` and
  the renderer are all in this repository.

§8 stays authoritative for what a tier *means* and what each one is held to;
this file is the membership, in the one place that can read it.

---

## Port allocation

Everything is in **9xxx**, which was verified clear against `lsof -iTCP -sTCP:LISTEN`
and `docker ps` before it was chosen. The existing estate holds 3000–3003,
4001–4006, 4010–4011, 5432, 8080–8081, 8545–8549 and 8645–8649.

**18545 is no longer in that list**, and 8648 is about to join it. 18545 was never
bound by anything: it was the port the testnet tunnel sent `rpc.<apex>` to, back
when that one hostname skipped the gateway. Every ingress rule now ends at Traefik,
so the tunnel needs no chain port at all. 8648 is Hearth's WebSocket P2P transport
— the one a Cloudflare Tunnel can carry, where the raw TCP peer port 8646 cannot —
and it is reached the same way 8545 is, across the host from the gateway.

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
slow. Its estate targets are **generated from the release manifest** at deploy
time and re-read from `file_sd` every 30s; three services whose `/metrics` is
gated behind a header token (`beacon`, `analytics`, `lantern`) have jobs of their
own instead, because Prometheus attaches credentials per **job** and not per
target.

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
YAML (`.github/workflows/ci.yml`)". **Neither of those existed.** There was
no `cloudflared/` directory in this repository, and `ci.yml` had a single job in
it running `scripts/surface-routes.py`. Two other files repeated the same claim
(`gateway/dynamic/policy.yml`, `compose/docker-compose.gateway.yml`), so
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
writes the credential *files* which are mounted:

| File | Read by | Mechanism |
| --- | --- | --- |
| `prometheus/secrets/beacon_token` | Prometheus | `http_headers: files:` on the Beacon scrape |
| `prometheus/secrets/analytics_token` | Prometheus | `http_headers: files:` on the analytics scrape |
| `prometheus/secrets/lantern_token` | Prometheus | `http_headers: files:` on the lantern scrape |
| `alertmanager/secrets/beacon_token` | Alertmanager | `authorization: credentials_file:` on the Beacon incident receiver |
| `alertmanager/secrets/{page,ticket}_webhook_url` | Alertmanager | `url_file:` on each receiver |

Both `beacon_token` files hold the same value, and they are two files because
they are two read-only mounts into two containers — mounting Prometheus's secrets
directory into Alertmanager to save the copy would hand Alertmanager the
analytics and lantern tokens as well, three credentials to deliver one.

**None of these files is tracked, and `up.sh` creates every one of them.** They
used to be committed empty, because Prometheus refuses to start when a `files:`
path is absent and Alertmanager fails a `credentials_file` the same way, so a
tracked empty file was how the plane was kept startable. It also made "no secret
is in any committed file" a property of nobody having run `git add` yet: on
2026-08-10, `git status` in the mainnet host's checkout listed five *tracked,
modified* files, and the modification was three real service tokens. One
`git add -A` from a public repository. `up.sh` buys the startability instead, and
`.gitignore` now refuses the paths outright, so a credential cannot be staged.

Filling them is an operator step — put the value in `.env` as `CF_BEACON_TOKEN`,
`CF_ANALYTICS_TOKEN` or `CF_LANTERN_TOKEN` and run `./up.sh`. Each value already
exists in the corresponding container's own environment on the estate.

**`up.sh` will not empty a file it has nothing to fill it with.** A variable
missing from `.env` leaves the existing credential alone and says so on stderr;
this used to be a bare redirect, so a run with `CF_ANALYTICS_TOKEN` unset erased
a token an operator had written by hand and took the scrape down (micro-org#321).
Putting the value in `.env` rather than in the file is therefore the durable
form, and writing the file by hand still works.

Files rather than environment variables, because a credential in an environment
variable is a credential in `docker inspect`, in every crash dump and in the
process table.

**Unconfigured is a supported mode.** With nothing set, alert delivery falls back
to the Beacon incident receiver — a degradation you can see (no acknowledgement,
no escalation) rather than a failure that stops the plane from starting.

### A second copy of this tree carries no credentials

Wanting a scratch copy of this tree is reasonable. Validating a gateway change
against a config you are free to break, reproducing a deploy failure without
touching the checkout that deploys, keeping a known-good tree beside a suspect
one — all of it is ordinary. **Copying the credential files into it is not, and
`cp -r` does exactly that.**

`/home/malf/gwvalidate/` was that copy, taken on 2026-08-05 to validate a gateway
change. No `.git`, so nothing would ever reconcile it. Nothing referenced it — no
process, no cron entry, no mount. It carried `compose/estate/tokens.env`, ten
`compose/env/*.env`, both Alertmanager webhook files and a `beacon_token`, and it
sat there for a week on a network-reachable host.

It held nothing live by the time it was found, and that was luck rather than
design: postgres, the custody keyring, the administrator password and bitcoind's
`rpcauth` had all rotated in the intervening week for unrelated reasons. Before
the first of those it was a second live copy of every service token and the
operator password (micro-org#430).

**The rule: a scratch tree is a clone, not a copy.**

```sh
git clone https://github.com/cloudsforge-online/micro-deploy /home/you/scratch
```

A clone cannot carry a credential, because none of them is tracked — that is the
whole point of the section above. Everything a scratch tree is usually wanted for
works without them:

| you want to | you do not need secrets, because |
| --- | --- |
| validate a gateway or compose change | `docker compose config` renders with `${VAR}` unset; the check targets in the `Makefile` all run against an unfilled tree |
| diff a suspect tree against a known-good one | `git diff` against a tag or a remote branch reads the tracked files, which is where changes live |
| reproduce a deploy failure | `release-deploy.sh` reads its env from `ESTATE_ENV`/`TOKENS_FILE`, so point them at the live paths rather than copying the files inward |

If you genuinely need a filled tree — the case is rarer than it feels — it is a
**second live copy of the estate's credentials** and it has to be treated as one:
made deliberately, `chmod 700`, and destroyed with `shred -u` the moment the task
that needed it is finished, not the next time somebody notices it.

`make check-stray-secrets` is what notices. It looks for the thirteen names the
live credential set uses anywhere outside this tree, reads nothing, and prints
paths only, so it is safe to run anywhere and safe in a public log. It is in
`make check` and it is in CI, and it runs on both hosts as part of a rotation.

### Beacon costs one thing more than AD-20 predicted

AD-20: *"Beacon emits Prometheus format explicitly so that adopting a scraper
costs a scrape config rather than a rewrite, and nothing has ever scraped it."*

The scrape config is written and it works. It costs a scrape config **and a
credential**: Beacon gates `/metrics` behind the same auth as every other route
(`infra/beacon/src/server.js`), which is correct — an open `/metrics`
publishes the shape of the estate to anyone who can reach the port — but it is a
step the decision record does not mention.

### Why Beacon was the one red target, and it was two faults

This section used to say `BEACON_TOKEN` was "empty on the running estate". It is
not, and has not been for some time: `docker exec cloudsforge-estate-beacon-1
printenv BEACON_TOKEN` on 2026-08-09 returns a 44-character value. The estate was
not missing a variable. **This** side was, and there was a second fault in front
of it that the token could never have been reached through.

- **Wrong port.** The scrape config named `beacon:4011`, and the connection was
  refused: `dial tcp 172.20.0.51:4011: connect: connection refused`. 4011 is
  Beacon's own default bind port, but the estate's compose sets `PORT: 4000` on
  every service through the `x-common-env` anchor, and the container's
  `printenv PORT` reads 4000. The scrape config was written against the service's
  documented default rather than against the environment it runs in.
- **Empty credential file.** `prometheus/secrets/beacon_token` was 0 bytes on the
  host. Even at the right port the scrape would have returned 401 — which is why
  fixing the port alone would have moved the target from `down` to `down` with a
  different reason.

And a third, found while fixing the second: **`up.sh` wrote that file `chmod
600`**, and Prometheus runs as the image default `nobody` (uid 65534, verified
with `docker exec cfmicro-prometheus-1 id`). Owner-only, for an owner that is not
in the container. An operator who did set `CF_BEACON_TOKEN` got the same dead
scrape as one who did not, reading `unable to read headers file
/etc/prometheus/secrets/beacon_token`. It is 0644 now, with the reasoning at the
line.

The port is fixed here. Supplying the value is an operator step, because it must
not pass through a commit — put it in `.env`, which is gitignored, and let
`up.sh` write both files:

```sh
# on the deploy host; the value is never printed
printf 'CF_BEACON_TOKEN=%s\n' \
  "$(docker exec cloudsforge-estate-beacon-1 printenv BEACON_TOKEN)" >> .env
./up.sh
```

`analytics` and `lantern` gate `/metrics` the same way, with `ANALYTICS_TOKEN`
and `LANTERN_TOKEN` into `CF_ANALYTICS_TOKEN` and `CF_LANTERN_TOKEN`. Writing the
secret file directly still works and survives the next `up.sh` — but only `.env`
survives a fresh clone.

Then **restart Prometheus rather than reloading it**, if `prometheus.yml` itself
changed. It is a single-*file* bind mount, and `git checkout` replaces the file
rather than writing through it, so the container keeps the inode it started with
and `POST /-/reload` re-reads the old config from the operator's point of view
while reporting success. Measured on 2026-08-09: after checking the branch out,
`docker exec cfmicro-prometheus-1 grep -c 'beacon:4000' /etc/prometheus/prometheus.yml`
returned 0 and the target list was unchanged; `docker restart cfmicro-prometheus-1`
returned 1 and applied it. `prometheus/targets/` and `prometheus/rules/` are
*directory* mounts and have no such problem, which is why a deploy re-rendering
the scrape list needs no restart at all.

**The rule was right; the estate had no path from a right rule to a person.**
`BeaconScrapeFailing` had been firing continuously since 2026-08-05T21:07:58Z,
which `/api/v1/alerts` shows, and it resolved at 15:53 on 2026-08-09 when the
port was corrected. It had been reaching an Alertmanager whose `beacon-incident`
receiver — the one every alert in the file routes to — pointed at
`http://beacon:4011/api/alerts/webhook`, **the same wrong port**. From inside the
Alertmanager container:

```
http://beacon:4011/api/alerts/webhook   can't connect: Connection refused
http://beacon:4000/api/alerts/webhook   HTTP/1.1 401 Unauthorized
```

The port is corrected in all three places. The 401 was not, and a 401 on every
alert is the same silence with a better error message: Beacon gated that route on
an `x-beacon-token` header, and Alertmanager's `http_config` offers `basic_auth`,
`authorization` and `oauth2` and no way to set an arbitrary header — at any
version, so the upgrade to v0.28.1 did not help and could not have. The
credential could not be attached here at all.

That half is fixed too (micro-org#311). Beacon accepts the same break-glass token
in either `x-beacon-token` or `Authorization: Bearer` (micro-beacon#10), so the
`beacon-incident` receiver presents it with
`authorization: { type: Bearer, credentials_file: … }` and `up.sh` writes the
file. It is the same secret with the same scopes, and it is still not an
administrator — Beacon's suite pins that by POSTing an adminOnly route with the
token as a bearer and asserting 403.

The alternatives were minting a service principal for Alertmanager — a second
credential with the same power, and one that expires during exactly the outage it
exists for — and putting a proxy in front of the route, a new component whose
failure mode is silence, in the plane whose job is to end silence. The cost of
what was chosen is that an `Authorization` header is copied into more places than
a custom one: proxy logs, client libraries, curl transcripts.

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

### Metrics that do not exist yet — now measured rather than assumed

This said the money and chain metrics were missing because `ledger`, `wallet`,
`settlement`, `custody` and `indexer` "are P4/P5 and are not written". All five
are written, deployed and scraped, and 1,307 distinct metric names are in
Prometheus as of 2026-08-09. The contract is still not met, and now it can be
checked instead of predicted. Against the live label catalogue:

| Rule | Metric it reads | In Prometheus |
| --- | --- | --- |
| `LedgerTrialBalanceNonZero` | `ledger_trial_balance_delta` | **yes**, 1 series, value 0 |
| `IndexerLagPastConfirmationDepth` | `indexer_lag_blocks` | **yes**, 2 series (`ltc`, `ember`) |
| `IndexerLagPastConfirmationDepth` | `indexer_confirmation_depth` | no — no metric name contains `confirmation` |
| `WithdrawalStuck`, `MoneyMetricContractMissing` | `withdrawal_stuck_total` | no — no metric name contains `stuck` |
| `LedgerReconciliationDrift` | `ledger_reconciliation_drift_native` | no — the exported name is `ledger_reconciliation_drift{asset}` |
| `DepositAddressFrozen` | `wallet_deposit_address_frozen` | no — nearest is `wallet_deposit_addresses_unwatched` |
| `BackupAgeExceeded` | `backup_last_success_timestamp_seconds` | no — no metric name contains `backup` |
| `JobDeadLetterGrowth` | `jobs_dead_total` | no — services export `community_jobs_dead`, `notify_deliveries_dead` |
| `ChainHeightSpreadSustained` | `beacon_chain_height_spread` | no, and Beacon **is** scraped now |
| `HearthConformanceVectorsFailing` | `beacon_conformance_vectors` | no, likewise |

Nothing here was rewritten to match. `ledger_reconciliation_drift` is per-asset
and the rule expects one native-denominated number; `wallet_deposit_addresses_unwatched`
counts a different condition from frozen. Silently repointing a money alert at a
near-neighbour is how an alert comes to mean something nobody has agreed to. The
list is filed as an issue against micro-org, service by service, with the
measurement beside each one.

`MoneyMetricContractMissing` is the rule that stops this being a silent gap, and
it is now doing exactly that: it is firing on `absent(withdrawal_stuck_total)`
while the other two names in its expression have data. Before the scrape list
existed it fired on all three at once and meant nothing, because a rule with no
series and a rule with a real gap were the same alert.

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
  prometheus.yml                 scrape config; the plane, and the 3 gated services
  rules/slo.yaml                 SLIs, burn rates, 5m rollups
  rules/alerts.yaml              20 rules, every one with a runbook
  tiers.yaml                     which services are Tier 1; the only copy
  targets/services.yaml          file_sd; GENERATED at deploy, gitignored
tempo/tempo.yaml                 7d, metrics generator
loki/loki.yaml                   30d, label cardinality bounded
alertmanager/alertmanager.yml    routing, grouping, 3 inhibit rules
gateway/dynamic/policy.yml       /internal refusal, CORS, security headers
grafana/
  build-dashboards.py            the palette, applied by construction
  theme/palette.json             the validated values, as data
  dashboards/*.json              generated; provisioned read-only
  provisioning/                  datasources with trace<->log<->metric links
runbooks/*.md                    34: one per alert that needs one (31 rules),
                                 plus the ones an operator opens directly and
                                 no alert fires for — rollback, restore,
                                 incident comms
scripts/check-runbooks.py        the runbook rule, as a build failure
scripts/render-prometheus-targets.py    release manifest -> file_sd
scripts/check-prometheus-targets-render.py   and the check on that
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

It asks (2) of **every** `compose/env/traefik*.env`, not of mainnet's alone, and the difference is
`CF_VIEW_ORIGIN_SUFFIX`: a variable that is per-environment by design was reported as a dead route
because this check knew one environment. *Which* file each variable belongs in is
`surface-routes.py` check 6's question — it asks every variable of every file, and inverts itself
for the ones in `ENV_VARS_SET_IN_ONE_FILE` — so there is no second, weaker copy of that rule here.

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
