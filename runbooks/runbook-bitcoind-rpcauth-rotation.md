# bitcoind's RPC credential, and why rotating it is one ordered operation

**Triggered by** `Rotation; a suspected compromise; the value appearing in a transcript or a public file; a 401 from the BTC node`
**Severity** SEV2 if exposed · **Owner** platform

## Read this first

One credential authenticates every call this estate makes to Bitcoin Core. It is
held in **one line of `bitcoin.conf` on the chain host** and in **two files on
the app host**, and it feeds **three services**. Nothing stages it: Core's
`rpcauth` is a single salted digest for a single password, so — exactly as with
Postgres — the usual estate rotation shape (publish the new value, accept both
for a window, drop the old one) **is not available here**. The change is atomic
at the node and everything else must be made to agree with it in one controlled
operation.

Three facts make this different from the Postgres rotation it is otherwise
shaped like, and all three bite in the same direction — *quietly*:

1. **`rpcauth` is read once, at daemon startup, and nowhere else.** There is no
   reload, and `SIGHUP` does not do it. A rewritten `bitcoin.conf` that has not
   been restarted into is a fix that is present and inactive — which is one of
   this repository's recurring shapes (see `runbook-chain-node-unreachable.md`
   on `rpcthreads`).
2. **A wrong BTC credential does not take anything down.** It answers 401 on
   every poll, the indexer retries at `warn`, and an address with no observed
   rows reads exactly like an address with no coins. That is not hypothetical:
   the indexer's credential had never matched `bitcoin.conf` since the chain host
   was stood up, and nothing surfaced it until somebody read the node's own logs
   (micro-org#383, and the note at `x-settlement-rpc-urls` in
   `compose/docker-compose.estate.yml`).
3. **The node only admits one source address.** `rpcallowip` is not a
   convenience here; it is the reason a correct credential can look wrong. See
   trap (a) — it is the trap that costs the most time, so it is first.

This was performed by hand on **2026-08-11** and it worked. What is below is
that run, written down so the next one is not improvised.

## Where the value lives

Three files, two hosts, one value.

| Host | Path | Holds |
| --- | --- | --- |
| chain `malf@192.168.1.42` | `/data/chains/bitcoin/bitcoin.conf` | one `rpcauth=` line, user `cfindexer` |
| app `savva@192.168.1.129` | `compose/secrets/chainrpc.mainnet.env` | `INDEXER_RPC_BTC_MAINNET` |
| app `savva@192.168.1.129` | `compose/estate/tokens.env` | `BTC_RPC_URL` |

**The node is a HOST PROCESS, not a container.** `docker ps` does not list it and
no compose command can touch it:

    /data/docs/bitcoin-27.0/bin/bitcoind -datadir=/data/chains/bitcoin -daemon

`bitcoin.conf` is owned `malf:malf`, mode `600`. **No `sudo` is required for any
step of this rotation** — see trap (c), which is about the instinct to reach for
it anyway.

**The RPC port is 50001, not 8332.** Every node on that host is moved off its
default port; the map is in `runbook-chain-node-unreachable.md`. A rotation
verified against 8332 verifies nothing — there is nothing listening there.

There is **exactly one `rpcauth=` line** and there is no `rpcuser`/`rpcpassword`
pair. That matters twice: Core accepts *several* `rpcauth` lines and would go on
honouring an older one you did not rewrite, and a surviving `rpcuser` would keep
a second credential alive that no file in this repository knows about.

### The app host is inside WSL

    ssh savva@192.168.1.129
    wsl -d Ubuntu-24.04
    cd /home/savvaniss/dev/cloudsforge/deploy

### One variable, three consumers, and that is what makes it atomic

`BTC_RPC_URL` is an **interpolation** variable, not an `env_file:` entry, and
compose substitutes it into two other places:

- `POOL_BTC_NODE_URL: ${BTC_RPC_URL:-}` — the pool, twice (mainnet and its
  second block source).
- the `btc` key of the `SETTLEMENT_RPC_URLS` anchor,
  `${BTC_RPC_URL:+,"btc":"$BTC_RPC_URL"}` — settlement.

So the three consumers are `indexer`, `settlement` and `pool`
(`cloudsforge-estate-indexer-1`, `-settlement-1`, `-pool-1`), and they are fed by
**two** files rather than three. Editing `BTC_RPC_URL` once moves both of the
services that read it, in the same recreate — which is the property that makes
this survivable at all, and the reason a partial rotation is not a state you can
end up in by accident.

## What `rpcauth` is, and why the bundled tool is the wrong one

The format is Core's own:

    rpcauth=<user>:<salt_hex>$<hmac_sha256(key=salt_hex, msg=password)>

The salt is hex, the key of the HMAC is **the hex string itself, not the bytes it
decodes to**, and the message is the password. Getting that backwards produces a
line that is syntactically perfect and authenticates nothing.

`rpcauth.py` **is** bundled, at
`/data/docs/bitcoin-27.0/share/rpcauth/rpcauth.py`, and it is the wrong tool for
this job: it **generates its own password and prints it to stdout**. That is two
defects at once for a rotation — you do not get to choose the value, so it cannot
be the value you have already written into a 0600 file for the other host, and
the value it does choose lands in your scrollback and in any agent transcript
(`runbook-secret-leaked-to-transcript.md`). Compute the HMAC directly instead;
it is six lines and they are below.

## Five ways this fails silently

Every one of these was met on 2026-08-11. They are listed before the procedure
because four of them are indistinguishable from "the new credential is wrong",
and the wasted move is to go back and regenerate it.

### (a) Testing from the wrong source address looks exactly like a bad credential

`bitcoin.conf` carries `rpcallowip=10.10.0.2/32` — the **app host, and nothing
else** — beside `rpcallowip=127.0.0.1`.

Core rejects a disallowed source **before it looks at the credential**. So
probing `http://10.10.0.1:50001` *from the chain host* returns **403 for every
credential, correct or not**. There is no way to tell a right password from a
wrong one through that hole, and the 403 body says nothing that distinguishes
them.

**Verify over `127.0.0.1:50001`, from the chain host.** The pass condition is:

- **200** for the new credential, and
- **401** — not 403 — for the old one.

**A 403 anywhere in that pair means you tested wrong, not that the rotation
failed.** Read the code before you read the outcome.

### (b) The process disappears before it releases the datadir lock

`bitcoin-cli … stop` returns, and the pid leaves `ps`, while the daemon is still
flushing and still holding `/data/chains/bitcoin/.lock`. A restart issued in that
window loses the race, exits, and leaves the node **DOWN** — with the new config
in place and nothing serving it.

Wait on **the lock, not the pid**. litecoind taught this estate the same lesson
and the failure mode is identical (`runbook-chain-node-unreachable.md`).

And stop it with `stop`, never `kill -9`: a node killed mid-write comes back
wanting a reindex, and on a `txindex=1` chain of 866G that is hours.

### (c) `echo "$PW" | sudo -S <cmd>` destroys anything else piped into `<cmd>`

`sudo -S` reads the password **from stdin**, which is the same stdin the command
you are running was supposed to read. Piping a heredoc into a `sudo tee` writes
**the sudo password** into the target file and exits **0**. It has happened on
this estate, silently, and the file looked plausible enough to be deployed.

**No step in this rotation needs `sudo`.** `bitcoin.conf` is owned by `malf` and
so is the datadir. Said here explicitly because the instinct to `sudo` a path
under `/data` is strong, and because the two-second version of that instinct is
the one that corrupts a config file without a single error message. If you ever
do need it: pass a **file path** to the privileged command and `cmp` the result,
never a pipe.

### (d) A credential in a shell word is a credential in the host's process list

`ps` on either host is readable by every account on it, and `~/.bash_history` is
readable by one. So the password must never be an argument, an `export`, or an
interpolation in a command line:

- **Generate it into a mode-0600 file** and never echo it.
- **Do the config rewrite in python**, reading that file — not with `sed -i
  "s/…/$PW/"`.
- **Give curl the credential with `--config <file>`, never `-u user:pass`.**
  `-u` is an argv.

Two more, from this estate's own history: never `echo` the resulting
`BTC_RPC_URL`, and **never print a caught exception from code that builds it** —
Node's `fetch` puts the whole URL, credential included, into the error it throws,
and no redaction rule catches that.

### (e) Old backups of a secrets file are the same secret with a longer half-life

Four `.bak-*` files were found beside live secrets files across four rotations.
One of them, `tokens.env.bak-1785933479`, had **37 of its 39 values
byte-identical to the live file** — only `SMTP_PASS` had actually moved. It was
not a stale file. It was a second, complete copy of the estate's entire
credential set, with an older mode and no owner.

`compose/secrets/` is gitignored **as a directory**, so none of these was ever
committable: **the risk here is on-disk longevity, not git exposure.** A retired
credential in a file nobody remembers making outlives the rotation that retired
it, and `make check-residue` finds it months later as a permanent red.

`shred -u` them as the **last step of every rotation**, and let
`scripts/check-no-secret-backups.sh` be the half a person cannot forget to run.

## Rotating it — the ordered operation

Nothing below is destructive until step 4. Steps 1–3 can be abandoned at any
point by deleting the files they made.

### 1. Generate the new password, on the chain host, into a 0600 file

It is substituted into a URL on the app host, so a value containing `:` `/` `?`
`#` `@` or `%` would have to be percent-encoded — the same trap as
`CF_POSTGRES_PASSWORD`. `openssl rand -hex 32` is 64 hex characters and needs no
encoding at all.

    umask 077
    openssl rand -hex 32 > "$HOME/.btc-rpc-new"

Never `cat` it. Confirm it by fingerprint only, which is also how you will
confirm the copy on the other host is the same value:

    sha256sum "$HOME/.btc-rpc-new" | cut -c1-12

### 2. Keep what a rollback needs

Write the **current** `rpcauth=` line and the **current** `BTC_RPC_URL`
credential to a mode-0600 file outside both trees. Without them there is no way
back after step 4, because at that point nothing on either host knows the old
value.

The old `rpcauth=` line is a salted digest rather than a password, so it is not
the same class of hazard as the app-host files — but it is still offline
crackable, it is still deleted at the end, and it is the reason step 8 shreds a
list rather than one file.

### 3. Rewrite `bitcoin.conf`, in python, reading the file from step 1

    python3 - <<'PY'
    import hashlib, hmac, pathlib, secrets
    pw   = pathlib.Path.home().joinpath(".btc-rpc-new").read_text().strip().encode()
    conf = pathlib.Path("/data/chains/bitcoin/bitcoin.conf")
    salt = secrets.token_hex(16)
    line = "rpcauth=cfindexer:%s$%s" % (
        salt, hmac.new(salt.encode(), pw, hashlib.sha256).hexdigest())
    lines = conf.read_text().splitlines()
    hits  = [i for i, l in enumerate(lines) if l.startswith("rpcauth=")]
    assert len(hits) == 1, "expected exactly one rpcauth= line, found %d" % len(hits)
    lines[hits[0]] = line
    conf.write_text("\n".join(lines) + "\n")
    print("rewrote one rpcauth= line for cfindexer")
    PY

Three things that assertion and that shape are doing:

- **`len(hits) == 1` is load-bearing.** Core honours *every* `rpcauth` line. If a
  second one has appeared, rewriting the first leaves a live credential behind
  and the rotation is a no-op wearing a success message.
- **It prints neither the password nor the digest.** It reports what it did.
- **It rewrites in place**, so the file keeps its 0600 mode and its owner.
  Writing a temp file and `mv`-ing it over the top does not, and that is how a
  world-readable secrets file gets made by a careful person.

No `sudo`. See trap (c).

### 4. Restart the node, waiting on the LOCK

    /data/docs/bitcoin-27.0/bin/bitcoin-cli -datadir=/data/chains/bitcoin stop

    # wait for the datadir lock to be released — NOT for the pid to vanish
    while fuser /data/chains/bitcoin/.lock >/dev/null 2>&1; do sleep 2; done

    /data/docs/bitcoin-27.0/bin/bitcoind -datadir=/data/chains/bitcoin -daemon

Start it **exactly as it was started** — the flags above are the ones in
`/etc/rc.local`, and a node started with a different datadir comes up empty and
resyncs.

From this moment the estate is authenticating with a credential it does not have
yet. That window is the whole risk of the operation, and it is why steps 5 and 6
are already written before step 4 is run.

### 5. Prove the credential at the node, before touching the app host

Build a curl config rather than passing `-u` (trap (d)):

    python3 - <<'PY'
    import pathlib
    pw = pathlib.Path.home().joinpath(".btc-rpc-new").read_text().strip()
    p  = pathlib.Path.home().joinpath(".btc-curlrc")
    p.write_text('user = "cfindexer:%s"\n' % pw)
    p.chmod(0o600)
    PY

    curl -s -o /dev/null -w '%{http_code}\n' --config "$HOME/.btc-curlrc" \
      -X POST -H 'content-type: application/json' \
      --data '{"jsonrpc":"1.0","id":"rot","method":"getblockchaininfo","params":[]}' \
      http://127.0.0.1:50001/

**Expect 200.** Then repeat with a curlrc built from the OLD password and
**expect 401.**

- **401 for the old credential** is the proof that the restart actually took the
  new config. A node still running the old `rpcauth` answers the old password
  200, and everything downstream will keep working right up until the next
  restart — which is the worst possible way for this to end.
- **403 for either** means you asked from the wrong source address. Trap (a).
  Ask again over loopback.

`getblockchaininfo` is deliberate: it is not a wallet RPC. Every node here runs
`disablewallet=1`, so a wallet method answers `-32601 Method not found` **after**
authenticating, and a 200 with an error body would still be a pass — but it is
not a signal anyone reads correctly under pressure.

### 6. Move the FILE to the app host, not the value

`scp` the mode-0600 file, or carry it via the operator's workstation with the
same discipline. **Do not paste the value into a terminal.** A paste lands in
scrollback, in `~/.bash_history`, and in any agent transcript on either machine
— which is the leak `runbook-secret-leaked-to-transcript.md` exists for, and the
one that costs another rotation.

Compare the fingerprint on both hosts before going further:

    sha256sum "$HOME/.btc-rpc-new" | cut -c1-12    # must match step 1

### 7. Rewrite the two app-host files, in python, and recreate the three services

    cd /home/savvaniss/dev/cloudsforge/deploy

    python3 - <<'PY'
    import pathlib, urllib.parse
    pw   = pathlib.Path.home().joinpath(".btc-rpc-new").read_text().strip()
    enc  = urllib.parse.quote(pw, safe="")
    root = pathlib.Path("/home/savvaniss/dev/cloudsforge/deploy")
    targets = {
        root / "compose/secrets/chainrpc.mainnet.env": "INDEXER_RPC_BTC_MAINNET",
        root / "compose/estate/tokens.env":            "BTC_RPC_URL",
    }
    for path, var in targets.items():
        out, n = [], 0
        for line in path.read_text().splitlines():
            if line.startswith(var + "="):
                u = urllib.parse.urlsplit(line.split("=", 1)[1])
                host = u.hostname + (":%d" % u.port if u.port else "")
                out.append("%s=%s" % (var, urllib.parse.urlunsplit(
                    (u.scheme, "cfindexer:%s@%s" % (enc, host), u.path, u.query, u.fragment))))
                n += 1
            else:
                out.append(line)
        assert n == 1, "%s: expected exactly one %s= line, found %d" % (path, var, n)
        path.write_text("\n".join(out) + "\n")
        print("rewrote %s in %s" % (var, path.name))
    PY

It takes the host and port from the line already there rather than reconstructing
them, it asserts exactly one occurrence per file, it rewrites in place so the
mode survives, and **it prints a variable name and never a URL.**

Then recreate — and the invocation matters more than it looks:

    export DOCKER_CONFIG=/tmp/dockercfg-clean
    mkdir -p "$DOCKER_CONFIG" && echo '{}' > "$DOCKER_CONFIG/config.json"

    docker compose -p cloudsforge-estate \
      --env-file compose/mainnet.env \
      --env-file compose/estate/tokens.env \
      -f compose/docker-compose.estate.yml \
      -f compose/docker-compose.release.yml \
      up -d --no-deps --force-recreate indexer settlement pool

- **That is not a command anybody composed from memory.** It is read off the
  containers' own compose labels, so it reproduces what they were actually
  created from. A recreate assembled from the repository instead can differ from
  the running estate in a way nothing reports.
- **`--env-file` REPLACES the default, it does not add to it.** Passing only
  `compose/mainnet.env` silently drops every credential in the tokens file —
  including the one being rotated. Both, always. (`--env-file`'s other trap, a
  pair naming two different estates, is `scripts/check-env-files-agree.sh` and
  `runbook-postgres-password.md`.)
- **`--no-deps`** keeps a project-wide `up -d` from re-evaluating the whole
  dependency graph, which on this host reliably fails partway with `No such
  container` and has cost an outage.
- **The empty `DOCKER_CONFIG`** is not superstition. With the operator's normal
  config, every pull tries a `credsStore` helper that is not present in WSL,
  fails, and is retried forever by `release-deploy.sh` without an error anyone
  sees.

Only three services are named because only three read the value. Recreating more
is not safer; it is a larger blast radius for a credential change.

### 8. Verify (below), then destroy the residue

Only after verification passes:

    shred -u "$HOME/.btc-rpc-new" "$HOME/.btc-curlrc" <the old-value file> …

on **both** hosts, and then, in the checkout:

    ./scripts/check-no-secret-backups.sh
    make check-residue

Trap (e). A rotation is not finished when the containers are green; it is
finished when the retired value is not on either disk.

## Verifying — from the consumers' own logs, never a health endpoint

**A health endpoint can be green while BTC auth is broken.** `/readyz` on these
services does not make an authenticated BTC call on every probe, and the indexer
degrades by *retrying at `warn`* rather than by failing — which is exactly how a
credential that had never worked survived from the day the chain host was stood
up. Green is not evidence here.

The passing evidence on 2026-08-11 was three lines, each of which is an
authenticated RPC call that succeeded:

    docker logs cloudsforge-estate-indexer-1    --since 10m 2>&1 | grep -c 'bitcoin network verified'
    docker logs cloudsforge-estate-pool-1       --since 10m 2>&1 | grep -c 'payout address validated by the node'
    docker logs cloudsforge-estate-pool-1       --since 10m 2>&1 | grep -c 'new job'

- `indexer: "bitcoin network verified" scope=btc:mainnet` — the indexer asked the
  node what chain it is on and was answered.
- `pool: "payout address validated by the node" chain=btc` — `validateaddress`,
  authenticated.
- `pool: "new job" chain=btc height=962008` — a block template, which is the one
  that proves the credential is working *continuously* rather than once at boot.

Count them; do not eyeball them. And **grep for the message, never for the URL**:
a `grep -i btc_rpc` over a log is one line away from printing the credential into
your transcript.

Then confirm the negative, at the node rather than at the services:

    grep -c 'ThreadRPCServer incorrect password attempt' /data/chains/bitcoin/debug.log

It must stop increasing. A rising count after the recreate means one consumer
still carries the old value — almost always because it was not in the service
list on step 7, or because only one `--env-file` was passed.

Settlement has no equivalent line of its own and is not verified from logs: its
proof is that its boot line no longer classifies `btc` as `no_endpoint`, and its
real exercise is the next withdrawal.

## Rollback

Valid at any point, and it is the same operation with the old value: put the old
`rpcauth=` line back in `bitcoin.conf` (step 3's shape, pasting the saved line
rather than computing one), restart the node by step 4 — **waiting on the lock**
— and restore the two app-host files, then recreate by step 7.

The old credential is not compromised *by the rollback*; whatever made it worth
rotating is still true, so a rollback is an availability measure and must be
followed by another attempt, not left in place.

## Related

- `runbooks/runbook-postgres-password.md` — the estate's other atomic, no-window
  rotation. This one is deliberately the same shape (micro-org#401).
- `runbooks/runbook-chain-node-unreachable.md` — the node's ports, datadirs and
  restart discipline, and the wedge that is not an auth failure.
- `runbooks/runbook-secret-leaked-to-transcript.md` — the general staged shape
  that this credential cannot use, and what to do when a value has been printed.
- `runbooks/runbook-indexer-lag.md` — if deposits are behind after a rotation
  rather than refused.
