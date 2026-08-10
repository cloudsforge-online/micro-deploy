# The estate administrator's password, and why rotating it recreates nothing

## Read this first

This is **not a service credential.** Every other secret in this directory is a
value some container reads at boot, which is why every other rotation here ends
in `--force-recreate`. This one is the password of **one account row**, and the
reflex that serves the rest of the estate is wrong here in a way that costs an
outage rather than preventing one.

The account is the operator `scripts/estate-bootstrap.sh` registers —
`estate-admin@example.test`, handle `estateadmin` — a row in the `users` table
of the **`identity` database**, holding `{player,admin}` and the estate's one
`bootstrap` grant in `platform_role_grants`. The password is stored there as a
hash. `ESTATE_ADMIN_PASSWORD` in the tokens file is a **copy for the scripts
that sign in as that account**, and nothing else.

So:

- **It appears in no compose file.** Measured on the mainnet host 2026-08-10:
  a name-only scan of every running container's environment found **zero**
  carrying `ESTATE_ADMIN_PASSWORD` or `ADMIN_PASSWORD`. The telemetry overlay's
  `GF_SECURITY_ADMIN_PASSWORD` is Grafana's own local admin — a different
  credential, from `CF_GRAFANA_ADMIN_PASSWORD`, with a different rotation.
- **Nothing is recreated, restarted, or redeployed.** No `up -d`, no
  `--force-recreate`, no release. A deploy is the most dangerous thing in this
  estate and this procedure does not need one; adding it because the other
  rotations have one is how a credential change becomes a change window.
- **There is no window of disagreement to manage.** The postgres password has
  57 copies that must all move together. This has two: the row and the tokens
  file, and only the second is ever read by anything other than a sign-in.

**The rotation goes through identity's own `POST /auth/password`, not through
SQL.** That route requires the *current* password, which means the rotation
itself proves the old value worked — no privileged side channel, no `UPDATE
users`, and the audit line lands in identity's log with `audit:
password_change`. Writing a hash into the table by hand would skip session
revocation, skip the password policy, and skip the audit record.

**Removing this value fails closed, and that is the design.** All five readers
take `ADMIN_PASSWORD` or `ESTATE_ADMIN_PASSWORD` with **no fallback** and exit
rather than guess. An absent value stops a verification run; it does not
degrade one. The line in `estate-verify.sh` used to have a default, and on
mainnet that default was the operator's real password.

## When to do it

- **It was published, printed, or pasted.** This is not hypothetical: until
  2026-08-09 `estate-bootstrap.sh` defaulted `ADMIN_PASSWORD` to a literal in a
  **public** repository, mainnet was bootstrapped without setting the variable,
  and so the estate's only administrator held that string while
  `https://api.cloudsforge.online/v1/auth/login` answered from the open
  internet. A login with it returned 200 and an access token carrying
  `roles: ["player","admin"]`. That is micro-org#276, and mainnet's rotation is
  the reason this runbook exists.
- **After any run that could have captured it** — see
  `runbook-secret-leaked-to-transcript.md`. `docker inspect` and a shell
  history are both places this has ended up before.
- **On the testnet restart**, which has not happened. See the last section; it
  is the one open item on micro-org#276.

It is *not* rotated on a schedule. A rotation that nobody can verify afterwards
is worse than a stable value, and the verification below needs a running estate.

## Where the value lives

Nowhere in this repository. It is written on the host only, in the same
gitignored, mode-0600 files as every other estate token:

| Network | File | Also reachable as | Holds it today |
| --- | --- | --- | --- |
| mainnet | `compose/estate/tokens.env` | `compose/.env` (a symlink) | **yes** |
| testnet | `compose/estate/tokens.testnet.env` | — | **no** — see below |

Unlike `CF_POSTGRES_PASSWORD` it is **not** a `${VAR:?}` interpolation: no
compose file mentions it, so a missing value cannot stop a render and compose
will never tell you it is gone. The thing that tells you is a script refusing to
start.

**Everything that reads it, all with no fallback:**

| Reader | What it does with it |
| --- | --- |
| `scripts/estate-verify.sh` | signs in as the operator to mint an admin token — the witness this runbook verifies with |
| `scripts/estate-bootstrap.sh` | creates the account in the first place, and writes the value out |
| `scripts/seed/lib.mjs` | the shared sign-in for the seed scripts |
| `scripts/ember-seed.js` | ember's seed run |
| `scripts/foresight-market-journey.mjs` | the foresight market journey |

**And one reader outside this repository, which a rotation will lock out.**
`ui/scripts/footer-audit.ts` signs in as `estate-admin@example.test` — it
registers nothing, it needs *that* account, because the two `adminOnly` consoles
open for nobody else — and it reads `CF_FOOTER_PASSWORD` then
`BEACON_SMOKE_PASSWORD`, then gives up. Whoever runs the footer audit against a
live estate exports the new value into one of those. Nothing in `micro-deploy`
sets either, so nothing here breaks silently; the person running it sees a
refusal naming the variables.

## Rotating it

Do testnet first when testnet is available — it is the same account shape
against the same identity build, so it is a real rehearsal. It is **not**
available today, so the mainnet rotation of 2026-08-10 was done first and alone.

### Generate it without seeing it

```sh
NEW=$(openssl rand -base64 48)
```

Never `echo "$NEW"`. Confirm it exists and is long enough by shape only:

```sh
printf '%s' "$NEW" | wc -c                       # 64
printf '%s' "$NEW" | sha256sum | cut -c1-12      # the fingerprint to compare later
```

`estate-bootstrap.sh` prints `openssl rand -base64 32 | tr -d '=+/' | cut -c1-40`
in its own refusal message, and that form is worth preferring if the value will
be re-typed or pass through anything that treats `+` `/` `=` specially. Both
clear identity's policy: it is checked with `checkPassword` against the
account's own handle and address, so the only generated value that could be
refused is one that happens to contain `estateadmin` or `estate-admin`.

### The ordered operation

Run it on the host, from `deploy/`, against the loopback port rather than the
public hostname — the same base URL `estate-verify.sh` derives, so the leading
digit is the port base and not a literal:

```sh
IDENTITY=http://127.0.0.1:${CF_PORT_BASE:-4}100   # mainnet 4100, testnet 5100
```

Going through `https://api.cloudsforge.online/v1` instead works, but it puts the
password through Cloudflare and through the gateway's logs for no gain.

1. **Keep the old value.** You need it in step 3 — the route will not change a
   password without it — and there is no other way to prove the rotation
   succeeded. Read it from the tokens file into a variable, never onto a
   terminal:

       set -a; . compose/estate/tokens.env; set +a
       OLD=$ESTATE_ADMIN_PASSWORD

2. **Sign in and keep the access token.** `identifier`, **not** `email`.
   Posting `email` returns `400 bad_request` — *"an identifier and a password
   are required"* — which reads exactly like a rejected credential and is not
   one. That mistake has cost a diagnosis on this thread already.

       TOK=$(curl -s -X POST "$IDENTITY/auth/login" \
               -H 'content-type: application/json' \
               -d "{\"identifier\":\"estate-admin@example.test\",\"password\":\"$OLD\"}" \
             | python3 -c 'import sys,json; print(json.load(sys.stdin).get("accessToken",""))')
       [ -n "$TOK" ] || { echo "the OLD password no longer works — stop and read Verifying"; }

3. **Change it through the route.** Both fields are required and the new value
   must differ from the current one, or it answers `400`.

       curl -s -X POST "$IDENTITY/auth/password" \
         -H "authorization: Bearer $TOK" -H 'content-type: application/json' \
         -d "$(python3 -c 'import json,os; print(json.dumps({"currentPassword":os.environ["OLD"],"newPassword":os.environ["NEW"]}))')"

   The body is built by `json.dumps` rather than by string interpolation
   because a generated password contains `/` and `+` and may contain `"` — a
   hand-built JSON body is how a rotation silently sets a *truncated* password.

   A success answers `200` with `{"sessionsRevoked": <n>}`. **On mainnet on
   2026-08-10 that number was 149**, and it is the desired behaviour rather
   than a surprise: every session the old password could still reach dies with
   it, along with any unused password-reset link. The caller's own session
   survives, because the person who just proved they know the password is the
   one who should stay signed in.

   **A `401 bad_password` here is not an expired token.** The route answers 401
   for two unrelated reasons and says which: `bad_password` means the *current*
   password was wrong. Do not refresh and retry — retrying counts as another
   failed attempt, and repeated failures engage the account lock-out, which is
   how a rotation turns into being locked out of the estate's only operator.
   `/auth/password` is rate-limited at 10 per window on top of that.

4. **Write the new value to the tokens file, on the host.** It is the only home;
   nothing else in the estate can recover it.

       umask 077
       printf 'ESTATE_ADMIN_PASSWORD=%s\n' "$NEW" >> compose/estate/tokens.env

   If a line is already there, replace it rather than appending — a later
   duplicate wins in `.env` parsing but not in every reader, and two different
   values in one file is a state nothing detects.

5. **Do not deploy anything.** Step 4 is the last change. Go to Verifying.

6. **Then unset the variables** — `unset OLD NEW TOK` — and, if the shell keeps
   one, clear the history for that session.

### Rollback

**There is no rollback, and that is worth knowing before step 3 rather than
after it.** The old password is gone from the row the moment the route answers
200, and the only way back is a second rotation using the *new* value as the
current one. That is why step 1 is "keep the old value" and step 4 is "write
the new one down immediately": the window in which neither is recorded anywhere
is the window in which the estate loses its administrator.

If that happens — the new value is lost and the old one no longer works — the
recovery is not in this runbook and is not cheap. `estate-bootstrap.sh` cannot
mint a replacement: the bootstrap grant is capped at **one per database for
ever** by a partial unique index, that one has been spent, and
`estate-verify.sh` asserts every pass that a second one is refused (`23505`) and
that a bare `update users set roles` is refused at COMMIT (`23514`). The
promotion lever is deliberately gone. The route left is identity's ordinary
password-reset flow to `estate-admin@example.test`, which needs that mailbox —
and the address is a `.test` sink domain, so it needs the mail to be
intercepted at notify rather than delivered.

## Verifying

**A green estate is not evidence.** Nothing was restarted, so every container
looks exactly as it did before the rotation whether it worked or not. The only
witness is a sign-in.

**The witness, and it is the one to use.** `estate-verify.sh` authenticates as
this account to mint the admin token that most of its assertions need, so it
fails loudly and early on a wrong password rather than reporting a red estate:

```sh
bash -c "set -a; . compose/estate/tokens.env; set +a; ./scripts/estate-verify.sh"
```

Run it from the host, in `deploy/`. It sources the file rather than taking the
password as an argument for the reason an argument is always wrong here: it
would be visible in `ps` and in the history.

**The narrow check, if a full verification is not wanted.** Both halves matter —
the second is what distinguishes "rotated" from "broke the account":

```sh
# the OLD value must now be refused
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$IDENTITY/auth/login" \
  -H 'content-type: application/json' \
  -d "{\"identifier\":\"estate-admin@example.test\",\"password\":\"$OLD\"}"   # expect 401

# the NEW value must be accepted
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$IDENTITY/auth/login" \
  -H 'content-type: application/json' \
  -d "{\"identifier\":\"estate-admin@example.test\",\"password\":\"$NEW\"}"   # expect 200
```

Mind the rate limit: `/auth/login` is 10 per window, and a burst of these while
debugging will start answering 429, which is not a rejected password.

Run against mainnet on 2026-08-10, codes only, nothing else printed: **the value
in `tokens.env` answered 200, a wrong value 401, and the same correct value in
an `email` field instead of `identifier` answered 400.** So the file and the row
agree today, and the `identifier` trap above is live rather than historical — it
is a 400 that arrives at the exact moment you are questioning a password.

**The tokens file and the row agree.** Sign in with the value the file actually
holds — sourcing it rather than using the `$NEW` still in the shell, because a
step-4 typo is invisible to `$NEW`:

```sh
bash -c 'set -a; . compose/estate/tokens.env; set +a
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$IDENTITY/auth/login" \
    -H "content-type: application/json" \
    -d "{\"identifier\":\"estate-admin@example.test\",\"password\":\"$ESTATE_ADMIN_PASSWORD\"}"'
```

**The two networks must not share a value.** Compare fingerprints, never values:

```sh
for f in compose/estate/tokens.env compose/estate/tokens.testnet.env; do
  printf '%s ' "$f"
  grep '^ESTATE_ADMIN_PASSWORD=' "$f" | cut -d= -f2- | tr -d '\n' \
    | sha256sum | cut -c1-12
done
```

## Both networks — and testnet is still on its pre-rotation password

**Mainnet: rotated.** `compose/estate/tokens.env` carries
`ESTATE_ADMIN_PASSWORD`, confirmed present on the host 2026-08-10 by counting
the line, not by reading it.

**Testnet: NOT rotated. Its operator account still holds the password that was
published in a public repository.** This is item 3 of micro-org#276 and it is
the only thing holding that issue open.

Two facts that are easy to misread, so both are written out:

- **`compose/estate/tokens.testnet.env` has no `ESTATE_ADMIN_PASSWORD` line at
  all** — measured on the host 2026-08-10, a `grep -c` returns `0`. That is not
  "testnet has a different value". It means every script in the table above
  refuses to run against testnet until somebody populates it, which is the
  fail-closed behaviour working, and it also means the *only* place testnet's
  current operator password exists is git history.
- **The account row already exists in testnet's `identity` database and is
  unaffected by testnet being down.** Bringing testnet up does not re-run
  `estate-bootstrap.sh`, so its refusals never fire and nothing is created — the
  row is simply there, as it has been the whole time. The refusals added in
  micro-deploy#13 prevent a *new* weak operator; they do nothing about the one
  that exists.

**It is blocked, not forgotten.** Testnet is stopped so `bitcoind` can finish
initial block download without competing for the same disk and bandwidth — 0
running containers and 79 exited, measured on the host 2026-08-10 — so the
account is reachable by nobody while it stays down. The exposure begins the
moment testnet comes back up, because the public `*-testnet` hostnames are
served through Cloudflare and are gated by nothing in the compose set.

**So the rotation belongs to the restart, before the hostnames answer.** The
procedure is the one above with `compose/estate/tokens.testnet.env` in place of
`compose/estate/tokens.env`, `$IDENTITY` pointing at testnet, and one
difference: the current password is not in any tokens file, so step 1 reads it
from micro-org#276's history rather than from the host.

Do it as part of bringing testnet up — between `up -d` and announcing the
environment — rather than afterwards. The restart will be driven by micro-org#257
and micro-org#210, which are about compose project names and disk contention;
this step is in neither of those threads, which is exactly why it is written
here instead of only there.

## Related

- `runbooks/runbook-postgres-password.md` — the other credential in the same
  tokens file, and the opposite shape in every respect: 57 copies, a mandatory
  recreate, and an atomic change at the server.
- `runbooks/runbook-secret-leaked-to-transcript.md` — the trigger this rotation
  most often has, and the general staged shape neither of these can use.
- `docs/releasing.md` — testnet's bring-up, which is when the rotation above
  must happen.
- `scripts/estate-verify.sh` — the witness, and the thing that goes red first if
  the tokens file and the row disagree.
