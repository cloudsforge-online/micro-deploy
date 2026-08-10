# The Postgres password, and why rotating it is one ordered operation

## Read this first

Every stateful service in the estate reaches one Postgres as the role
`cloudsforge`. That role's password appears in **56 connection strings** in
`compose/docker-compose.estate.yml`, plus the `POSTGRES_PASSWORD` on the
`postgres` service itself — 57 places, one value.

Two facts make this different from every other secret in this repository, and
both of them bite in the same direction:

1. **Postgres does not read `POSTGRES_PASSWORD` after the first boot.** The
   official image consumes it only when it initialises an *empty* data
   directory. On a volume that already exists — which is every real estate — the
   server keeps whatever password the role currently has, no matter what compose
   says. Change the variable alone and you have not rotated anything; you have
   simply told 22 services to authenticate with a password the server has never
   heard of.
2. **A role cannot hold two passwords at once.** The estate's usual rotation
   shape — add the new secret to an accept-list, let receivers adopt it, then
   drop the old one — is *not available here*. There is no staged window. The
   change is atomic at the server and everything else must be made to agree with
   it in one controlled operation.

So the sequence is: **change the role, update every string, recreate, verify**,
with the rollback ready before you start.

**Removing or breaking this value does not fail closed — it stops the estate.**
Twenty-two services boot, fail every query, and sit `unhealthy`. That is an
outage, not a safe refusal.

## Where the value lives

It is **not** a literal in the compose file any more. It was, in a **public**
repository, identical on both networks (micro-org#157). It is now an
interpolation variable, supplied per network from a gitignored, mode-0600 file:

| Network | Env file | Also reachable as |
| --- | --- | --- |
| mainnet | `compose/estate/tokens.env` | `compose/.env` (a symlink) |
| testnet | `compose/estate/tokens.testnet.env` | — |

The variable is `CF_POSTGRES_PASSWORD` and it is declared `:?` in the compose
file — **compose refuses to render** if it is missing, naming the variable. That
is deliberate: a default would let an estate come up with a password the server
rejects, which is the outage above wearing a disguise.

It is an *interpolation* variable rather than an `env_file:` entry because the 56
connection strings need it substituted into the middle of a URL, and `env_file:`
only ever reaches a container's own environment. That is why it is passed with
`--env-file` and why **both** files must always be passed.

**Bring an estate up with `scripts/release-deploy.sh`, not by hand.** The raw
two-file invocation is written out here so the mechanism is legible, and it is
what the deploy script runs:

    docker compose --env-file compose/<net>.env \
                   --env-file compose/estate/tokens[.testnet].env \
                   -f compose/docker-compose.estate.yml \
                   -f compose/docker-compose.release[.testnet].yml up -d

Typed by hand it has two failure modes that both present as this page's symptom.

`--env-file` **replaces** the default `.env`, it does not add to it. Passing only
the network file silently drops every credential in the tokens file.

And the two paths are *independent arguments*: nothing in compose objects to a
`<net>.env` and a tokens file that name **different estates**. That combination
is the subject of micro-org#238 and it is refused by
`scripts/check-env-files-agree.sh`, which `release-deploy.sh` and
`estate-bootstrap.sh` both call before they render — and which a hand-typed
`docker compose` never reaches. Ask it directly before running one:

    ./scripts/check-env-files-agree.sh compose/testnet.env compose/estate/tokens.env
    # FATAL: these two --env-file paths name different estates.

## Rotating it

Do testnet first, always. It is the same operation on the same compose file, so
a testnet run is a real rehearsal and not a similar-looking one.

**Generate the new password URL-safe.** It is substituted into a URL, so a value
containing `:` `/` `?` `#` `@` or `%` must be percent-encoded or it will corrupt
all 56 strings. `openssl rand -hex 24` is 48 hex characters, well clear of the
24-character floor, and needs no encoding.

    openssl rand -hex 24 | sed 's/^/CF_POSTGRES_PASSWORD=/' \
      >> compose/estate/tokens.testnet.env

Never `echo` it. Confirm it by fingerprint only:

    grep '^CF_POSTGRES_PASSWORD=' <file> | cut -d= -f2- | tr -d '\n' \
      | sha256sum | cut -c1-12

### The ordered operation

1. **Keep the old value.** Write it to a mode-0600 file outside the tree. Without
   it there is no rollback, because after step 3 nothing in the repository knows
   the old password.
2. **Prove the render first.** With the *old* value in the variable, the compose
   file must render **byte-identically** to the deployed one:
   `docker compose … config --format json | sha256sum`. If it does not, the
   refactor is wrong and this is not the moment to discover that.
3. **Change the role.** Piped on stdin, never as an argument — an argument is
   visible in `ps` and in the shell history:

       printf "ALTER ROLE cloudsforge PASSWORD '%s';" "$NEW" \
         | docker exec -i <project>-postgres-1 psql -U cloudsforge -d postgres

   Existing connections are **not** dropped; only new ones are affected. That is
   the grace that makes step 4 survivable, and it is also why a half-finished
   rotation can look fine for minutes.
4. **Recreate every service** with the command above, so all 56 strings carry the
   new value. Use `--wait`.
5. **Verify** — see below. Only then delete the old-value file.

### Rollback

Valid at any point, and it is a single step: put the old value back in the role,
then restore the tokens file and recreate.

    printf "ALTER ROLE cloudsforge PASSWORD '%s';" "$OLD" \
      | docker exec -i <project>-postgres-1 psql -U cloudsforge -d postgres

The old password is not compromised *by the rollback* — it was already published,
which is why it is being rotated — so a rollback is an availability measure and
must be followed by another attempt, not left in place.

## Verifying

Green containers are weak evidence: a service with a warm pool keeps serving
until it needs a new connection. Check the database layer directly.

- **Every service is healthy, counted exactly.** `grep -c healthy` also matches
  `unhealthy`; count with `grep -cx healthy` or an exact-match format string.
- **A fresh connection authenticates** — this is the assertion that actually
  proves the rotation, because it cannot be satisfied by a stale pool:

      docker exec <project>-postgres-1 pg_isready -U cloudsforge -d postgres

- **No service is logging authentication failures.** `password authentication
  failed for user "cloudsforge"` in any service log has **two** causes, and only
  the first belongs to a rotation:

  1. That container is still carrying an old string and was not recreated.
  2. **The estate was brought up with the other estate's tokens file.** The
     password is not old, it is *the other network's*, and every other signal
     says the deploy was correct — see below.

- **When the failure is EVERY migration at once, suspect the second cause first.**
  A half-finished rotation leaves some containers working. A crossed pair leaves
  none: on 2026-08-07 a testnet bring-up with `--env-file estate/tokens.env`
  (mainnet's) failed all 29 migrations with this one line, all 29 services stayed
  in `Created` behind `service_completed_successfully`, and the 17 frontends
  stayed up and healthy — so the estate looked two-thirds alive. Every banner
  said testnet, because the project name came from the file that was right
  (micro-org#238).

  The obvious hands-on check *passes* in this state and sends the diagnosis the
  wrong way: `pg_hba.conf` grants `trust` on `local` and `127.0.0.1/32` and only
  reaches `scram-sha-256` on `host all all all`, so `psql -U cloudsforge` from
  inside the postgres container succeeds while every container on the docker
  network fails. Do not read that success as "the role is fine, so the password
  must be stale".

  Establish which cause it is by asking the guard about the pair that was
  actually used — it is a pure function of the two paths and touches no secret:

      ./scripts/check-env-files-agree.sh "$ESTATE_ENV" "$TOKENS_FILE"

  Exit 1 names both halves. Then bring the estate up again through
  `scripts/release-deploy.sh`, which runs that guard itself.
- **The two networks differ.** Compare the two fingerprints; they must not match.
  Never print the values to compare them.

## Related

- `runbooks/runbook-secret-leaked-to-transcript.md` — the general staged shape,
  which this one is the documented exception to.
- `runbooks/runbook-outbox-signing-secret.md` — the accept-list rotation that *is*
  available when a credential can hold two values at once.
- `runbooks/runbook-restore-from-backup.md` — if a rotation is attempted against
  a server whose volume was replaced mid-operation.
