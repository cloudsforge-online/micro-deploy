# Releasing

What is deployed right now, and the one rule that governs how it changes.

---

## What is deployed

| Environment | Compose project | Version | Containers | Deployed |
| --- | --- | --- | --- | --- |
| **Testnet** | `cf-testnet` | **2.5.1** | 46 services + `postgres:17-alpine` | 2026-08-07 |
| **Mainnet** | `cloudsforge-estate` | **2.4.0** | 45 services + `postgres:17-alpine` | 2026-08-05 |

Each estate reads ONE number, which is the rule below. The two numbers differ
here, and that is the release in progress rather than the drift this rule
exists to prevent: 2.5.x is being proved on testnet before it reaches mainnet,
which is what the design overlay is for (`compose/docker-compose.design.yml`).
Testnet ahead of mainnet is expected during a release and is not a finding.
Testnet *behind* mainnet, or either estate reading two numbers at once, is.

This table went stale at 2.3.0 while both estates moved to 2.4.0 and testnet to
2.5.1, which is the argument for the command below rather than for a table.

Check it, do not trust this table:

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

### 2. Bump the design overlay

`deploy/compose/docker-compose.design.yml` pins all seventy-four testnet image
lines explicitly. Bump them in the repository, add a header section saying what
the release carries and why, then copy the file to the host — **the host is not
a checkout and does not pull.**

```sh
scp deploy/compose/docker-compose.design.yml \
    malf@192.168.1.42:/home/malf/dev/cloudsforge/deploy/compose/
```

### 3. Testnet

```sh
cd /home/malf/dev/cloudsforge/deploy/compose
docker compose --env-file testnet.env --env-file estate/tokens.testnet.env \
  -p cf-testnet \
  -f docker-compose.estate.yml \
  -f docker-compose.release.yml \
  -f docker-compose.design.yml \
  pull
# then the same command with: up -d --remove-orphans
```

**Both `--env-file` flags, every time, and this is not style.** `--env-file`
*replaces* the default `.env` rather than adding to it, and `compose/.env` is a
symlink to **mainnet's** tokens. Drop the flags and compose still runs, happily:
`CF_PORT_BASE` falls back to `4`, so testnet's containers are recreated bound to
**mainnet's host ports**, and every credential is read from mainnet's token
file. What you see is `Bind for 127.0.0.1:4133 failed: port is already
allocated` on whichever service collides first — by which point compose has
already recreated most of the stack with the wrong environment, and it stops
half-way, leaving testnet down.

The recovery is the correct command: re-run it with both flags and compose
recreates every container that does not match, which is all of them. Nothing
persistent is harmed — the databases are volumes and are not touched — but it
is several minutes of testnet being down for a flag.

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
P=cloudsforge-estate; OUT=/home/malf/backups/pre-<version>; mkdir -p "$OUT/db"
for d in $(docker exec ${P}-postgres-1 psql -U cloudsforge -d postgres -tAc \
    "select datname from pg_database where datistemplate=false and datname<>'postgres'"); do
  docker exec ${P}-postgres-1 pg_dump -U cloudsforge -d "$d" -Fc > "$OUT/db/$d.dump"
done
```

For 2.3.0 that was 28 databases, 129M, about a minute. There is no version of
this release that is worth skipping it for. Restore is
`docs/estate-backup-restore.md`.

### 5. Mainnet

The manifest is generated from the repositories, not written by hand. In
`micro-org`:

```sh
cfctl release <version>          # reads each package.json + git HEAD
                                 # refuses a dirty checkout
```

That writes `org/releases/<version>.yaml`. Then on the host:

```sh
cd /home/malf/dev/cloudsforge/deploy
./scripts/release-deploy.sh <version>
```

Defaults it uses: `BASE=compose/docker-compose.estate.yml`,
`OVERLAY=compose/docker-compose.release.yml`,
`ESTATE_ENV=compose/mainnet.env`, `TOKENS_FILE=compose/estate/tokens.env`,
`RELEASES=../org/releases`. It also takes `--list`, `--dry-run` and
`--rollback`.

Mainnet does **not** get `docker-compose.design.yml`. That overlay is testnet
only.

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
- `compose/docker-compose.design.yml` — the testnet overlay header carries the
  per-release record of what each tag changed and why
