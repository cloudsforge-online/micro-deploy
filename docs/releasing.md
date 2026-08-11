# Releasing

What is deployed right now, and the one rule that governs how it changes.

---

## Which machine, before anything else

**Every command in this document runs on the APP HOST.** The estate is two
machines now, joined by WireGuard, and running a release step on the wrong one is
not a no-op — the chain host has a `deploy` checkout of its own, real Bitcoin,
Litecoin and Dogecoin daemons, and no app stack.

| Host | Reach it by | Deploy checkout | What is there |
| --- | --- | --- | --- |
| **app** `savva@192.168.1.129` | `ssh savva@192.168.1.129` then `wsl -d Ubuntu-24.04` | `/home/savvaniss/dev/cloudsforge/deploy` | Both estates: `cloudsforge-estate` and `cf-testnet`, ~50 and ~48 containers, both gateways, Postgres, the telemetry plane. **This document.** |
| **chain** `malf@192.168.1.42` | `ssh malf@192.168.1.42` | `/home/malf/dev/cloudsforge/deploy` | `bitcoind`, `litecoind`, `dogecoind` and the Hearth seed — host processes, not containers, datadirs under `/data/chains`. Also two EMBER miners. Nothing here is released by `release-deploy.sh`. |

The app host is inside WSL, so an `ssh` alone does not land you in the right
filesystem:

```sh
ssh savva@192.168.1.129
wsl -d Ubuntu-24.04
cd /home/savvaniss/dev/cloudsforge/deploy
```

Until 2026-08-11 every path in this document read `malf@192.168.1.42` and
`/home/malf/dev/cloudsforge/deploy`, because for a while that was where
everything was. It is not any more, and the paths below were corrected in place
rather than deleted — the chain-host paths that remain are labelled as such.

---

## Naming a release

**A release name is `<year>.<month>.<sequence>`: `2026.08.21`.** That is the
**twenty-first release cut in August 2026** — not 21 August. It was cut on
2026-08-11. The `<version>` placeholder everywhere below takes that shape.
Per-repository `package.json` versions are still semver and are a different
thing; the estate release is the manifest `org/releases/<version>.yaml`, and that
name is what an operator quotes.

**A release name cannot be sorted. Never derive "the latest" or "the previous"
from a directory listing.** Two separate things break it:

- The sequence is **not zero-padded**, so `2026.08.21` sorts *before*
  `2026.08.6` as a string.
- `org/releases/` holds **two incomparable lineages**. The semver-shaped estate
  releases in this document's history — `2.3.0` through `2.5.19` — are not old
  names for the same scheme, they are a second scheme the estate also used, and
  no comparison of a date-shaped name with a semver-shaped one means anything.

`2026.08.12` looks like the successor of `2026.08.11`, and in time it is. It was
also six days behind `2.5.19`, and deploying it rolled 45 services back — the
indexer by 87 commits. Nothing failed: every container was healthy, every image
existed, `--dry-run` was green and every digest was a real digest of a real
artifact. It was found five days later, by reading
`org.opencontainers.image.version` off the running containers and not believing
it. **Order by the manifest's `generated` field**, which is the only one that
orders the two lineages against each other. `micro-org`'s `release-order.test.ts`
now makes a backwards manifest a build failure rather than a deploy
(micro-org#384).

**`./scripts/release-deploy.sh --list` does not order them either**, and this
document claimed it did until 2026-08-11. It runs `ls -1` over the directory, so
what it prints is alphabetical: the last line today is `2026.08.9`, which is
twelve releases old, and `2.3.0` is first. It is a list of what exists, not a
history. To find the newest, read the `generated` field:

```sh
grep -H '^generated:' ../org/releases/*.yaml | sed 's|.*/||' | sort -k2 | tail -5
```

The last line of that is the newest release, whichever lineage it belongs to.

---

## What is deployed

Do not read a version out of this document. The table that used to sit here went
stale three times and was wrong on the day each of those releases went out; the
command below is the only answer that cannot age.

Both estates read the same number, which is the rule below. They are allowed to differ
in one situation only — a release being proved on testnet before it reaches
mainnet, which is step 3 below deploying the manifest to testnet and step 5
deploying **the same manifest** to mainnet afterwards. Testnet ahead of mainnet,
during a release, is expected. Testnet *behind* mainnet, or either estate reading
two numbers at once, is not.

A table here sat at `2.3.0` while both estates moved to `2.4.0` and testnet to
`2.5.1`, which is the argument for the command below rather than for a table.

Ask the hosts, on the app host:

```sh
# testnet
docker ps --filter "label=com.docker.compose.project=cf-testnet" \
  --format '{{.Image}}' | cut -d: -f2 | sort | uniq -c

# mainnet
docker ps --filter "label=com.docker.compose.project=cloudsforge-estate" \
  --format '{{.Image}}' | cut -d: -f2 | sort | uniq -c
```

Two lines of output is correct: one count for the release version, one for
`17-alpine`. **Three or more lines means the estate is mid-release or a deploy
was skipped, and the version you think is live is not the version that is
serving people.**

---

## The rule: one version across the whole estate

> "from now on all container services will be on the same version, if you do a
> change to one, you will update the version to be the same to all, and then
> deploy them"
>
> — the owner, and this is not negotiable

So: **a one-line change to one service is a forty-six version bump and a
forty-six container deploy.** Not the changed service. All of them.

### Why, when it looks like waste

Because the alternative was measured, and this is what it measured.

Before 2.3.0, mainnet ran **forty-five services across thirteen different
versions** — thirteen at 1.2.0, nine at 1.0.0, five at 1.3.0, and singletons
scattered from 1.0.1 up to 1.5.0. Every one of those numbers was defensible
when it was set: that service changed, that service got deployed, the others
did not need to. Thirteen locally correct decisions, and the result is an
estate with **no version at all**. "What is on mainnet?" had no answer. It had
thirteen answers, and a question about any behaviour that crosses two services
could not be answered without reading both tags and then reading what each of
those tags contained.

That is the real cost, and it is not a tidiness cost. It is that

- **a bug report cannot be reproduced.** "It happens on mainnet" describes
  thirteen versions of mainnet. Which one has the defect is a research task
  before it is a debugging task.
- **a rollback is not a rollback.** Going back means going back to thirteen
  different places, and no record says which thirteen.
- **the shared library defeats the whole scheme.** Every browser surface links
  `@cloudsforge/ui`, and `publish-image.yml` checks it out with no `ref:`, so
  every surface built at any time compiles against ui@main. Two surfaces on
  different tags are not two versions of a stable thing — they are two
  different builds of the *same* ui source, frozen at different moments. The
  tag says they differ by feature. They also differ by library, invisibly.
- **testnet stops being a test.** If testnet is uniform and mainnet is not,
  testnet is not a rehearsal of mainnet. It is a rehearsal of an estate that
  does not exist.

One number for the whole estate costs a few minutes of `docker compose pull`
per release. It buys the ability to say what is running, in one word, and to
put it back.

### What this means in practice

- Never deploy a single service to fix a single thing. Bump everything.
- Never leave a release half-applied. Forty-six pulled, forty-six up.
- **`docker ps` is the source of truth, never a merged commit.** GHCR tags are
  immutable, so pushing does not deploy and merging does not deploy. The
  version bump is the deploy mechanism; the container is the evidence.
- Testnet first, always, and looked at in a browser. Then mainnet at the same
  version — **the same version as the code that was just merged, not a subset
  of it.**

---

## Cutting a release

### 1. Bump every deployable

Forty-six `package.json` files, all to the same new version. Commit and push to
`main` in each repository; CI publishes
`ghcr.io/cloudsforge-online/micro-<repo>:<version>` from the `publish` job.

**Push `micro-ui` first and let it finish.** `publish-image.yml` checks out the
ui package with no `ref:`, so every frontend image built after that point links
against whatever is on ui@main. Push a frontend before the ui change lands and
that image is built against the old library while claiming the new tag.

Wait for 46/46 green, then confirm the images actually exist in GHCR before
touching a host. A green CI run and a published package are not the same claim;
the `publish` job has returned a transient `403 Forbidden` pushing to GHCR more
than once. Re-run the failed job (`gh run rerun <id> --failed`) — **never**
`gh run delete`; red runs stay in the history.

### 2. Cut the manifest

The manifest is generated from the repositories, not written by hand. In
`micro-org`:

```sh
cfctl release <version>            # reads each package.json + git HEAD
                                   # refuses a dirty checkout
cfctl release --verify <version>   # every image it names exists in GHCR
```

That writes `org/releases/<version>.yaml`, and **that one file is what both
estates deploy** — testnet in step 3, mainnet in step 5, the same file, not a
second one cut in between. A manifest cut twice is two releases wearing one name,
and the second one is the one nobody proved.

**This step used to read "Bump the design overlay", and that is the defect this
document was carrying** (micro-org#414). `compose/docker-compose.design.yml`
pinned all seventy-four testnet image lines by hand, was bumped here before every
release, and was passed as a fourth `-f` by the hand-typed command that used to
be step 3. It was last bumped on 2026-08-08, at `2.5.4`, because every testnet
deploy since has gone through `release-deploy.sh` — which reads a manifest and
has never heard of that overlay. Seventeen releases later the file still said
`2.5.4` and the document still said to use it.

On 2026-08-11 somebody followed it. Applying a one-variable change to `mint` with
the command this document prescribed rolled that service from `2026.08.21` back
to `2.5.4` — about a hundred and forty commits — in under twelve seconds, with a
green `up -d` and a healthy container. `mint-migrate` then ran the **old**
migrator against the live testnet schema and reported `from: 7, to: 7,
applied: []`, which is the only reason it cost nothing; an old migrator with
something to undo would have been a data event, and `--rollback` puts images
back, not schemas.

So the overlay is **deleted**, not regenerated. Its job was to prove a release on
testnet before mainnet, and that job is step 3 below: the same manifest, deployed
to testnet first. A file that no script passes cannot be kept current by
discipline — it was already seventeen releases stale while every check in this
repository was green. Its header carried the per-release record of what each tag
changed, `2.3.0` through `2.5.4`; that is in git history at `cdbc887` and the
releases since are recorded in their manifests and in the issues that cut them.
`scripts/check-docs-prescribe-deployed-overlays.py` now fails the build if a
document prescribes an image-pinning overlay that no deploy path passes, so this
particular file cannot come back quietly.

**If you are reading this on the app host, delete the copy there too.**
`/home/savvaniss/dev/cloudsforge/deploy/compose/docker-compose.design.yml` was
`scp`'d there by the step this replaced; the host is not a checkout, so removing
it from the repository does not remove it from the host, and a `-f` typed from
memory still finds it.

### 3. Testnet

Testnet gets **the same script as mainnet with two variables changed**, and
nothing else:

```sh
cd /home/savvaniss/dev/cloudsforge/deploy           # app host
ESTATE_ENV=compose/testnet.env \
TOKENS_FILE=compose/estate/tokens.testnet.env \
  ./scripts/release-deploy.sh <version>
```

`--dry-run` renders the overlay and proves every image exists without touching a
container, and is worth a first pass. `--rollback` deploys the previous manifest
by the same code path.

That command is immune to all three of the traps recorded below, and they are
recorded rather than deleted because each one is still live on anything typed by
hand — the chain node below, and any `docker compose` an operator reaches for
during an incident:

- it passes **both** `--env-file` flags itself, and refuses the crossed pair
  (`check-env-files-agree.sh`, micro-org#238) before it renders anything;
- it passes **no** `--remove-orphans`;
- it pins from the manifest, so there is no overlay to be stale.

It also does more than the old command did: it pulls every image in full and
proves each one exists before replacing a single container, derives the apex and
the gateway env file from the estate's own env file rather than the shell,
rewrites Prometheus's target list, reloads its rules, and ends by running
`check-tunnel-origin.sh` for **this** environment — which the four-overlay
command never did.

**The chain node is the one thing that command does not declare.**
`docker-compose.testnet-chain.yml` declares the `litecoind -regtest` node this
environment indexes, and `release-deploy.sh` composes only the estate file and
the rendered release overlay. Bring it up on its own, from `compose/`:

```sh
docker compose --env-file testnet.env --env-file estate/tokens.testnet.env \
  -p cf-testnet \
  -f docker-compose.testnet-chain.yml \
  up -d
```

Naming only that file is safe: compose acts on the services it was given and
leaves the other ~48 in the project alone. It is idempotent, so it costs nothing
to run and leaves a node that was already up exactly as it was.

Skipping it does not fail, and that is the trap: the node has
`restart: unless-stopped` and keeps running from before. What you lose is the
declaration, and that is how it got lost the first time. It was created by a
hand-typed `docker run`, belonged to no project, appeared in no `ps`, and on
2026-08-08 was reasonably mistaken for the host's **real Litecoin mainnet node**.
Read that file's header before touching either process; the two are not copies
and stopping the wrong one takes mainnet Litecoin indexing down.

**The gateway is checked by the deploy now, and was not before.**
`release-deploy.sh` finishes by running `./scripts/check-tunnel-origin.sh` for
the environment it just deployed, so a 502 is on the last line of the deploy
instead of in somebody's browser. To run it alone:

```sh
cd /home/savvaniss/dev/cloudsforge/deploy           # app host
./scripts/check-tunnel-origin.sh testnet
```

The testnet gateway *was* a **separate compose project** (`cftestnet`, no hyphen)
from the services it serves (`cf-testnet`), so no command in this section brought
it up, listed it, or noticed its absence. It went missing twice —
2026-08-05 and 2026-08-08 — with every service healthy and every public
`*-testnet` hostname answering 502 both times, because cloudflared reports an
unreachable origin as 502. `make estate-gateway-testnet` starts it and runs the
same check.

**Neither gateway has that defect any more.** On 2026-08-10 the mainnet gateway
was moved out of the telemetry plane's project into `cloudsforge-estate`, the
project of the ~50 services it serves; on 2026-08-11 the testnet gateway followed
into `cf-testnet` alongside its ~48. Both are now listed by a `ps` on the project
an operator would actually type (micro-org#257). Two consequences for anybody
deploying, and they apply to **both** environments:

- **Never pass `--remove-orphans` to a `cloudsforge-estate` or `cf-testnet`
  invocation that does not include the two gateway compose files.** The gateway
  is in that project now and is not defined by `docker-compose.estate.yml`, so
  compose will offer to remove it — and it prints the invitation as a warning
  listing the ~50 estate containers as orphans when you run it the other way
  round. `release-deploy.sh` passes no such flag and is unaffected.
- `make estate-gateway` and `make estate-gateway-testnet` bring each up in the
  right project and then run `check-tunnel-origin.sh` for that environment, so
  the target proves its own claim.

The project name comes from **one** place, `CF_GW_PROJECT` in
`compose/testnet.env`, which the Makefile reads and the three scripts
(`estate-up.sh`, `gateway-reload.sh`, `estate-verify.sh`) already derived. It is
still a separate variable from `CF_PROJECT` even though the two now hold the same
string — four entry points reading one value is the property that was missing,
not the value itself.

**Both `--env-file` flags, every time you type a `docker compose` yourself, and
this is not style.** `--env-file` *replaces* the default `.env` rather than
adding to it, and `compose/.env` is a symlink to **mainnet's** tokens. Drop the
flags and compose still runs, happily: `CF_PORT_BASE` falls back to `4`, so
testnet's containers are recreated bound to **mainnet's host ports**, and every
credential is read from mainnet's token file. What you see is `Bind for
127.0.0.1:4133 failed: port is already allocated` on whichever service collides
first — by which point compose has already recreated most of the stack with the
wrong environment, and it stops half-way, leaving testnet down.

The recovery is the correct command: re-run it with both flags and compose
recreates every container that does not match, which is all of them. Nothing
persistent is harmed — the databases are volumes and are not touched — but it
is several minutes of testnet being down for a flag.

This is why the release path is a script and not a command in a document.
`release-deploy.sh` builds that flag pair itself, from `ESTATE_ENV` and
`TOKENS_FILE`, and refuses the two that name different estates. It cannot be
half-typed. Everything above about `--env-file` therefore applies to the chain
node command, to a rolling restart out of a runbook, and to whatever you reach
for at 3am — not to steps 3 and 5.

**Testnet is not paused any more.** It moved to the app host and came back up on
2026-08-11, 48 containers healthy, and its operator password was rotated the same
day — `runbooks/runbook-beacon-token.md` and
`runbooks/runbook-estate-administrator-password.md` record both. What is left of
the warning that used to stand here is a standing rule rather than a one-off: any
environment brought up after a long stop must have its operator password rotated
**before** the hostnames answer, because `estate-admin@example.test` once held a
password that `estate-bootstrap.sh` defaulted to in a **public** repository, and
`up -d` does not re-run the bootstrap, so none of the refusals added since it
protect an existing row. `compose/estate/tokens.testnet.env` carries no `ESTATE_ADMIN_PASSWORD`
line today, so the seed and verification scripts will refuse to run against
testnet until it does. The procedure, and why it recreates nothing, is
`runbooks/runbook-estate-administrator-password.md`; the exposure is
micro-org#276 item 3.

Then **open it in a browser.** Not `curl`. A page that returns 200 with a
correct `<h1>` can still be scrolled to the wrong place, have its last footer
link covered by the consent banner, or throw on line one of a module — all
three of those shipped, and all three passed automated checks that only fetched
bytes.

### 4. Back up mainnet first

`release-deploy.sh` does **not** take a backup, and a release runs every
service's migrator against a live production database. `--rollback` puts the
images back; it does not put a schema back.

```sh
P=cloudsforge-estate; OUT=/home/savvaniss/backups/pre-<version>; mkdir -p "$OUT/db"
for d in $(docker exec ${P}-postgres-1 psql -U cloudsforge -d postgres -tAc \
    "select datname from pg_database where datistemplate=false and datname<>'postgres'"); do
  docker exec ${P}-postgres-1 pg_dump -U cloudsforge -d "$d" -Fc > "$OUT/db/$d.dump"
done
```

When that loop was last timed it was 28 databases, 129M, about a minute; there
are more databases now, so budget more. There is no version of
this release that is worth skipping it for. Restore is
`docs/estate-backup-restore.md`.

### 5. Mainnet

The manifest from step 2, unchanged. Do not cut a new one here — the release
mainnet runs must be the release testnet proved, and `cfctl release` reads
whatever the repositories say at the moment it is run.

```sh
cd /home/savvaniss/dev/cloudsforge/deploy           # app host — NOT 192.168.1.42
./scripts/release-deploy.sh 2026.08.21
```

Defaults it uses: `BASE=compose/docker-compose.estate.yml`,
`OVERLAY=compose/docker-compose.release.yml`,
`ESTATE_ENV=compose/mainnet.env`, `TOKENS_FILE=compose/estate/tokens.env`,
`RELEASES=../org/releases`. It also takes `--list`, `--dry-run` and
`--rollback`. Step 3 is this same command with the two testnet variables in
front of it; mainnet is the defaults, which is why mainnet needs no variables and
no overlay of any kind.

### 6. Confirm

Run the two `docker ps` commands at the top of this document. Two lines each.
Anything else is not this release.

---

## When a deploy fails on `denied`, and what it usually is not

This bit 2.3.0 and will bite again, so it is written down rather than
remembered.

The mainnet deploy aborted before changing anything, with:

```
FAIL ghcr.io/cloudsforge-online/micro-explorer-web:2.3.0 — denied: denied
1 of 45 image(s) cannot be pulled. NOT DEPLOYING.
```

**Nothing was wrong with that image.** The package was public, the tag existed,
`cfctl release --verify` had passed all forty-six minutes earlier, testnet was
already running that exact image, and `docker manifest inspect` on the same ref
on the same host succeeded seconds later. Re-running the deploy unchanged
worked.

The cause is at `scripts/release-deploy.sh:223`: one `docker manifest inspect`
per image, **no retry**, in a loop that fires forty-five authenticated requests
at GHCR back to back. GHCR occasionally answers one of them `denied` under that
burst. It is an availability answer, not an authorization fact. Same family as
the transient `403 Forbidden` the `publish` job returned on `pricing` and `site`
in this same release, which also cleared on a plain re-run.

The trap is that the script's own comment says a `denied` here is *"usually the
GHCR visibility trap"* — a package that inherited a private repository's
visibility. That is a real failure, it needs a human, and it never clears by
itself. But it is the **rarer** of the two, so the message sends you to check
settings that are already correct.

So:

1. Do not change any visibility setting yet. Check the package first —
   `gh api /orgs/cloudsforge-online/packages/container/<name> --jq .visibility`
   — and check the tag is listed.
2. If both are fine, run the exact same deploy command again. The pre-flight
   check runs before anything is touched, so a failed run changed nothing and a
   retry is free.
3. If the **same** ref fails twice, then it is real: visibility, or an image
   that was never published because its `publish` job was red.

Tracked as micro-org#242, with the fix: retry each inspect a few times and only
call it `denied` after the last attempt, which would let the script tell the two
cases apart instead of guessing.

**Do not let this become a habit of re-running failed production deploys without
reading the failure.** The check is right to refuse; a half-applied release is
the thing it exists to prevent. Read which ref failed, and why, every time.

---

## Related

- `docs/estate-backup-restore.md` — taking the estate down and bringing it back
- `docs/custody-backup-restore.md` — the custody service specifically, which
  has its own ordering constraints
- `compose/docker-compose.testnet-chain.yml` — the regtest Litecoin node testnet
  indexes, the one file step 3's script does not compose
- `scripts/check-docs-prescribe-deployed-overlays.py` — what now stops this
  document prescribing an overlay nothing deploys
- `compose/docker-compose.design.yml` — **deleted 2026-08-11** (micro-org#414).
  It pinned testnet by hand and stopped being bumped at `2.5.4` when the deploy
  path became `release-deploy.sh`. Its per-release record of `2.3.0` through
  `2.5.4` is in git history at `cdbc887`
- `runbooks/runbook-estate-administrator-password.md` — the operator credential,
  which is a step in the testnet bring-up above and not a step in any release
