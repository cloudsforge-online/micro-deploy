# A secret was printed into a log, a transcript, or a terminal

**Severity: treat as compromised.** Not "probably fine because the file is local".
A secret that has been written to a file you did not choose the retention of is
spent. Rotate it. The reasoning below is about ORDER, never about whether.

This runbook exists because it has already happened twice:

* **micro-org#144** — three of four custody keyrings were printed into agent
  transcripts during routine inspection. Rotated V2→V3, verified 224/224 keys and
  215/215 seeds readable under V3 alone.
* **The outbox sweep that produced this file** — `SMTP_PASS`,
  `CF_GRAFANA_ADMIN_PASSWORD` and `CF_BEACON_TOKEN` were found in
  `~/.claude/projects/**/*.jsonl`, and a placeholder-shaped signing key was found
  live in the accept-list of six variables across 44 containers.

---

## THE COMMAND THAT CAUSES THIS

Four commands print **every variable in an environment**, including the ones you
were not looking at:

    printenv
    env
    docker inspect <container>
    docker compose config

There is nothing wrong with wanting the information. The defect is that the
output goes somewhere permanent — a transcript, a CI log, a scrollback buffer, a
pasted snippet — and the ninety variables you did not need go with it.

**The rule: never run a command that prints a whole environment. Ask for the one
variable, and ask for a property of it rather than its value.**

    # NO — prints ninety values to a file that is kept
    docker inspect cloudsforge-estate-wallet-1 | grep -i secret
    printenv | grep TOKEN

    # YES — answers the question without disclosing the answer
    # The name is held in `var` because CI fails any tracked file where one of
    # these variables is followed by a value, and `NAME=` ahead of an awk body is
    # that shape exactly — this page failed the build for being ABOUT the secret.
    var=OUTBOX_SIGNING_SECRET

    docker inspect cloudsforge-estate-wallet-1 \
      --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | grep -c "^$var="                             # is it set?

    docker inspect cloudsforge-estate-wallet-1 \
      --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | awk -F= -v v="$var" '$1==v{print length($2)}'   # how long?

    scripts/check-secret-hygiene.py --live cloudsforge-estate  # is it FIT?

The questions you actually have — *is it set*, *is it the same in both
networks*, *is it a placeholder*, *did it leak* — are all answerable without the
value. `scripts/check-secret-hygiene.py` answers all four and is written so that
it cannot print a value even by accident; it correlates by truncated SHA-256
instead.

**This applies to reports too.** A finding names the VARIABLE and the LOCATION.
A report that quotes the secret it is warning about has reproduced the leak into
another kept file — which is precisely how #144 grew.

---

## IF IT HAS ALREADY LEAKED

### 1. Find out what else did

One command, no investigation:

    scripts/check-secret-hygiene.py \
      --transcripts ~/.claude/projects /private/tmp \
      --against compose/secrets/*.env compose/estate/tokens.env compose/.env

It searches for the values of every secret currently deployed and reports the
variable names, file paths and file MODES that contain them. Values are held in
memory and never written.

**Then widen it, because transcripts are not where the worst copy is.** The
sweep above looks in the two directories a leak was once found in. The copy that
outlives a rotation is a backup of the file being rotated — `.env.bak-*`,
`tokens.env.bak-*` — sitting beside the original with the retired value in it,
and on 2026-08-10 one of those held the *live* beacon token. `make check-residue`
is the same command with the whole home directory as its root:

    make check-residue                      # ROOTS defaults to $HOME
    make check-residue ROOTS="/home/malf /srv"

It prunes the three chain data directories by name. Do not remove that pruning
to "be thorough": unpruned, this walk takes over ten minutes, and the version of
this step that is too slow to run is the version that gets skipped.

**Read the mode on every hit.** A live token in a file only the operator can
read is residue to be deleted; the same token in a mode-644 file is a disclosure
to every account on the host, and the report says `WORLD-READABLE` when it is
(micro-org#340).

### 2. Rotate, in this order, and never any other

The multi-key shape exists for exactly this and is the reason a rotation need not
be an outage. `contracts/packages/events/src/index.ts` takes
`string | readonly string[]` and tries every candidate timing-safely:

> *"`secrets` is a list because rotation must not require both ends to change in
> the same instant: an endpoint publishes a new secret, accepts both for a
> window, then drops the old one."*

    ADD      → put the NEW key in the ACCEPT list beside the old one
    CUT OVER → move the SIGNING variable to the new key
    VERIFY   → prove the new key is accepted everywhere (below)
    REMOVE   → only now, drop the old key from the accept list

**Never remove an old key before proving the new one is accepted everywhere.** A
sender on the new key talking to a receiver that has not been restarted is a 401
on the money tier.

### 3. Restart ROLLING, with `--no-deps`

A project-wide `up -d` re-evaluates the whole dependency graph, and on this host
that reliably fails partway with `No such container: <id>` — leaving fifteen
services in `Created` and the estate down. It happened during the sweep that
produced this file and cost a testnet outage.

    # WRONG on a live estate — takes the whole graph down if it stalls
    docker compose -p cloudsforge-estate -f ... up -d

    # RIGHT — one service at a time, dependency graph untouched
    for s in activity admin-api analytics community devplatform notify …; do
      docker compose -p cloudsforge-estate \
        -f compose/docker-compose.estate.yml -f compose/docker-compose.release.yml \
        up -d --no-deps "$s"
      sleep 4
      docker ps --filter "name=cloudsforge-estate-${s}-1" --format '{{.Status}}'
    done

Removing a key from an ACCEPT list is backward-compatible — every producer is
already signing with the key that remains — so a rolling restart is safe and a
simultaneous one buys nothing.

If a service is stuck in `Created` because the graph stalled, `docker start` it
directly; that bypasses the stale dependency reference.

### 4. Verify before declaring it done

    # nothing anywhere still carries the old key
    scripts/check-secret-hygiene.py --live cloudsforge-estate cf-testnet

    # and no receiver started rejecting signatures
    docker logs cloudsforge-estate-activity-1 --since 5m 2>&1 \
      | grep -ciE 'invalid_signature|unauthoriz'

Both must be zero.

---

## COMPOSE VARIABLES ARE INTERPOLATED, SO SOURCE THE TOKENS

`docker-compose.estate.yml` reads `MARKET_SERVICE_TOKEN: ${MARKET_SERVICE_TOKEN:-}`.
That is shell interpolation, not an `env_file:`, and `compose/testnet.env` does
not contain the tokens. Bringing testnet up with `--env-file compose/testnet.env`
alone therefore renders every service token EMPTY, and `market` refuses to start
with *"MARKET_SERVICE_TOKEN is required"*. Source both:

    set -a; . ./estate/tokens.env; . ./testnet.env; set +a
    docker compose -p cf-testnet -f docker-compose.estate.yml \
                                 -f docker-compose.release.testnet.yml up -d

---

## THE PLACEHOLDER THAT PASSES THE PLACEHOLDER CHECK

Every service rejects placeholder secrets at boot with an **exact-match set of
eight strings** (`notify/src/env.ts`; beacon, faucet, custody and market carry
their own copies). An exact-match set only rejects the placeholders somebody
thought of.

`estate-only-outbox-secret-` + fourteen zeros was in the accept list of six
variables on both networks and 44 containers. Forty characters, so it cleared
every length gate; not one of the eight, so it cleared every placeholder gate.
`verifyDelivery` is *"the check that stands between an unauthenticated POST and a
handler that credits money"* — anyone who guessed the string could sign an event
the money tier would accept.

`check-secret-hygiene.py` is **shape-based** for this reason. A placeholder does
not become safe by being one nobody has enumerated yet. Run it before a deploy:

    make check-secrets
