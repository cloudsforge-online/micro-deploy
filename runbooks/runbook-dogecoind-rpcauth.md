# dogecoind's RPC credential, the placeholder that authenticated nobody, and the one step that needs a human

**Triggered by** `Merge-mining produces no Dogecoin; a 401 from the DOGE node; rotation; the value appearing in a transcript`
**Severity** SEV3 · **Owner** platform

## Read this first

This node is shaped like the other two on the chain host and rotates by
`runbook-bitcoind-rpcauth-rotation.md` — read that one for the format of an
`rpcauth` line, for the five ways a credential change fails silently, and for
the discipline about `sudo -S`, argv and backups. All of it applies here
unchanged. **This file is only about the four things that are different**, and
three of them cost hours on 2026-08-18:

1. **`rpcauth=none` starts a node that refuses everybody.** It is not a syntax
   error and it is not a log line. It is a placeholder that was written when the
   host was stood up, and it survived because nothing had ever authenticated
   against this daemon.
2. **The node's only working credential was its `.cookie`**, which is rewritten
   on every start — so it cannot go in a variable that has to survive a restart.
   That is the whole reason the merge-mining feature sat shipped and off for a
   week.
3. **This daemon runs under systemd, and `systemctl restart` needs interactive
   authentication.** There is no passwordless `sudo` on the chain host. The
   restart is therefore an operator step, and it is the *only* operator step —
   see the last section, which exists so nobody reaches for `kill` instead.
4. **Probing it from the app host's shell answers nothing.** The valid vantage
   point is inside a container. See "Where to ask from".

## What was found, on 2026-08-18

    rpcauth: present, value length 4, colons 0, dollars 0

Four characters. Dogecoin 1.14's `multiUserAuthorized` splits the field on `:`
and returns false when the count is wrong, so the daemon accepted the line at
boot, started cleanly, logged nothing, and answered **401 to every caller for
every password** — including the correct one, because there was no correct one.

That is the same class of failure as trap (a) in the bitcoind runbook, and it
reads identically from the outside: a credential you just wrote, refused. The
distinguishing evidence is that the *old* credential is refused too, and so is a
credential you invent on the spot. **If every password gets 401, the problem is
the conf, not the password.**

The symptom the owner actually reported was none of this. It was *"I thought we
enabled dogecoin merge mine with litecoin but I don't see any dogecoin reference
in the wallet"* (micro-org#481). An absence, three layers downstream.

## Where the value lives

Two files, two hosts, one value, **one consumer**.

| Host | Path | Holds |
| --- | --- | --- |
| chain `malf@192.168.1.42` | `/data/chains/dogecoin/dogecoin.conf` | one `rpcauth=` line, user `cfpool` |
| app `savva@192.168.1.129` | `compose/estate/tokens.env` | `DOGE_RPC_URL` |

`DOGE_RPC_URL` is an interpolation variable and compose substitutes it into
exactly one place — `POOL_DOGE_NODE_URL` on the pool, in both the service and
the migrator block. So unlike BTC, which feeds three services, **the blast
radius of getting this wrong is the pool and nothing else**, and the pool's
response to a wrong value is to go on mining Litecoin without an aux commitment.
Quietly. Forever.

The node is a **host process under systemd**, not a container:

    /data/docs/dogecoin-1.14.9/bin/dogecoind -datadir=/data/chains/dogecoin
    unit: /etc/systemd/system/dogecoind.service   (enabled; Restart=on-failure)

The RPC port is **9332**, not 22555. Every node on that host is moved off its
default; the map is in `runbook-chain-node-unreachable.md`.

`dogecoin.conf` is `malf:malf`, mode `600`, 89 lines. **No `sudo` is needed to
edit it.** `sudo` is needed for exactly one thing, and that thing is the
restart.

## Where to ask from

`dogecoin.conf` carries `rpcallowip=127.0.0.1`, `rpcallowip=10.10.0.2/32` — the
app host over wireguard — and the two docker bridges, `172.20.0.0/16` and
`172.31.0.0/16`.

**A shell on the app host is not `10.10.0.2` for this purpose.** From inside
WSL, TCP to `10.10.0.1:9332` times out; so does `:50001`, so does `:50002`, and
so does the Ember RPC on `:8545`. That is not four dead ports — the pool
container talks to the Litecoin one successfully every few seconds. It is one
wrong network namespace, and it produces the most convincing possible imitation
of a node that is down.

Ask from **inside a container on the estate network**:

    docker exec cloudsforge-estate-pool-1 node /tmp/probe.js </dev/null

The pass conditions, and both halves matter:

- **litecoind on `10.10.0.1:9332`'s sibling port answers 200** — the control.
  Without it, a failure tells you nothing about Dogecoin.
- **dogecoind answers 401 rather than timing out** — which is what proved, on
  2026-08-18, that the route and the port were fine and the *credential* was the
  problem.

And the standing rule from `runbook-secret-leaked-to-transcript.md`, which this
diagnosis is exactly the shape that violates: **never print a caught error from
code that builds an RPC URL.** Node's `fetch` — and `http.request` — put the
whole URL, userinfo included, in the error object. The prober used for this
prints `${host}:${port} connection failed` and never the error. That is not
fastidiousness; it is how bitcoind's `rpcauth` leaked once already.

## Setting or rotating it

Follow `runbook-bitcoind-rpcauth-rotation.md` §"Rotating it" with three
substitutions — user `cfpool`, conf `/data/chains/dogecoin/dogecoin.conf`, port
`9332` — and these differences.

### The password file, and idempotency

    /home/malf/.cf-doge-rpc-password    0600, secrets.token_urlsafe(32)
    /home/malf/.cf-doge-rpcauth         0600, the resulting line

The generator reuses the password file if it is already there and **refuses if a
`cfpool` line already exists in the conf**, so a re-run cannot half-rotate a
working credential. It prints the password nowhere: not the password, not the
salt, not the digest — only `conf : written; lines before 89 after 89, changed 1`.

`token_urlsafe` is deliberate: the value is substituted into a URL on the other
host and its alphabet needs no percent-encoding. (Hex would do as well; what
must not happen is a generator that emits `:` `/` `?` `#` `@` or `%`.)

### Moving it to the app host without it existing anywhere in between

The password went chain-host → app-host by piping one `cat` of the 0600 file
straight into the receiving script's stdin:

    ssh malf@192.168.1.42 'cat ~/.cf-doge-rpc-password' \
      | ssh savva@192.168.1.129 wsl -d Ubuntu-24.04 -- bash -lc '… read -r PW …'

It was never an argument, never an `export`, never echoed, and never in either
host's `~/.bash_history`. A paste would have landed in scrollback on both
machines and in this agent's transcript.

### The rewrite asserts on the placeholder, not on a count

bitcoind's script asserts `exactly one rpcauth= line`. This one additionally
refuses unless the literal `rpcauth=none\n` is the thing it is replacing:

    if 'rpcauth=none\n' not in original:
        print('conf : REFUSING — the placeholder `rpcauth=none` is not there any more')
        sys.exit(1)

Because the interesting case here is not "there are two credentials". It is
"somebody already fixed this", and overwriting a working `cfpool` line with a
second one is how you break a node while reporting success.

## The restart, which is the operator's step and nobody else's

`rpcauth` is read **once, at daemon start**. `SIGHUP` does not reload it. Until
the daemon restarts, the new line is a fix that is present and inactive.

    sudo systemctl restart dogecoind      # on 192.168.1.42, as malf

Expect it to take around **80 seconds** to return. That is correct and it is
measured: on 2026-08-12 the same restart took 77 s, because systemd waits for
Core's shutdown flush instead of racing it — which is why the unit does not use
the default `TimeoutStopSec`. A restart that returns instantly is the one to be
suspicious of.

**Why nothing else is an acceptable substitute**, all three considered and
rejected on 2026-08-18:

- **`dogecoin-cli stop`** exits **0**, and the unit is `Restart=on-failure`.
  systemd reads a clean exit as a job well done and leaves the node **down**,
  with no auto-restart, until a human notices.
- **`kill -9` / `SIGQUIT`** would exit non-zero and *would* trigger
  `Restart=on-failure` — and a `txindex=1` Core fork killed mid-write comes back
  wanting a reindex. On this chain that is hours, to save one password prompt.
- **Starting it by hand outside systemd** discards the reboot-survivability the
  unit exists for (micro-org#338 §5.4), and the next reboot starts a second
  daemon that loses to the datadir lock.

And the lock trap from the bitcoind runbook is live here too: litecoind on this
same host releases `.lock` *after* its pid leaves `ps`, and a restart issued in
that window loses the race and leaves the node down. `systemctl restart` already
waits properly; this is a warning about hand-rolling it, not about the command
above.

### Arming the pool before the restart is safe, and is what was done

The compose change shipped **before** the node was restarted into, on purpose.
`AuxTemplateSource.refresh()` never throws: every failure is classified by
`unavailabilityOf` into `unreachable` / `syncing` / `no-peers` / `refused` and
becomes a reason to mine Litecoin *without* an aux commitment for that round.
Nothing gates pool boot on aux reachability. So the pool tolerates an
unanswering dogecoind indefinitely and picks it up **on its next poll, with no
deploy and no restart of its own**, the moment the node starts answering.

**The load-bearing detail is which side of that line a 401 falls on.** Core
answers 401 with a body that is not JSON-RPC, so `jsonRpcErrorIn` returns null,
`rpc.ts` raises `NodeUnavailableError` with cause `http 401`, and
`unavailabilityOf` calls it `unreachable` — the retry-forever branch, not the
`refused` one that latches `auxUsable` off. The breaker in front of it opens
after five consecutive failures and half-opens 10 s later, so even a pool that
spends days against a refusing node re-probes continuously and needs nothing
done to it.

Had 401 classified as a *refusal* instead, arming early would have been a
mistake: the pool would have latched merging off at boot and the operator's
restart would have fixed nothing visible until a redeploy. Check that
classification before reusing this shape for another aux chain.

That is the property that let this ship as one release instead of two, and it is
the reason the operator's single `systemctl restart` is the whole remaining
sequence.

## Verifying, after the restart

**A health endpoint proves nothing** — the pool is green while mining Litecoin
with no Dogecoin commitment at all, which is precisely the state being fixed.

From the chain host, over loopback, using a curl config rather than `-u`
(bitcoind runbook trap (d)):

    curl -s -o /dev/null -w '%{http_code}\n' --config "$HOME/.cf-doge-curlrc" \
      -X POST -H 'content-type: application/json' \
      --data '{"jsonrpc":"1.0","id":"v","method":"getblockchaininfo","params":[]}' \
      http://127.0.0.1:9332/

**200 for the new credential.** Then from the pool's own logs, which is the only
evidence that the whole path works rather than the node alone. There are four
lines and they say four different things:

    docker logs cloudsforge-estate-pool-1 --since 20m 2>&1 \
      | grep -c 'new job for a changed aux tip'                       # ← the one that matters
    docker logs cloudsforge-estate-pool-1 --since 20m 2>&1 \
      | grep -c 'aux payout address validated by the aux node'
    docker logs cloudsforge-estate-pool-1 --since 20m 2>&1 \
      | grep -c 'the aux node did not answer at boot'
    docker logs cloudsforge-estate-pool-1 --since 20m 2>&1 \
      | grep -c 'this aux chain is misconfigured and will NOT be merged'

- **`new job for a changed aux tip`** carries `aux=doge` and `auxHeight=`, and it
  is the only one of the four that proves merging is happening *continuously*
  rather than having once been possible. It is what to count.
- **`aux payout address validated by the aux node`** is the boot check, and it
  appears only if the node was already answering when the pool started. Its
  absence is not a failure.
- **`the aux node did not answer at boot — merging will start when it does`** is
  the expected line for a pool armed ahead of the restart, and it is a `warn`,
  not an error. It means exactly what it says.
- **`this aux chain is misconfigured and will NOT be merged`** is the one to act
  on, and it is the reason to read the logs at all rather than assume. It fires
  on a *refusal* — a payout address the node rejects, or the wrong network — and
  **it sets `auxUsable` false for the lifetime of the process.** Unlike an
  unreachable node, this state does not self-heal: fix the value and recreate the
  pool container, or it will mine Litecoin alone until the next deploy.

Count them; do not eyeball them. And **grep for the message, never for the
URL** — a `grep -i doge_rpc` over a log is one line away from printing the
credential into your transcript.

The node-side proof that the payout address is usable, which does not need the
estate at all:

    dogecoin-cli -datadir=/data/chains/dogecoin createauxblock <POOL_DOGE_PAYOUT_ADDRESS>

On 2026-08-18 that returned a real aux block at height 6,336,473, `chainid` 98,
`coinbasevalue` 1000221185664 — against `DMin1y72p8etiyyrzwSMPgRoaEfXPabP3m`,
minted through custody's `POST /v1/admin/pool-payouts/dogecoin/mainnet/mint`
under purpose `pool`. `validateaddress` says `isvalid: true`, `ismine: false`:
the node can pay it and cannot spend it, which is the correct pair.

## Residue

The same rule as everywhere: a rotation is finished when the retired value is
not on either disk, not when the containers are green.

    shred -u /data/chains/dogecoin/dogecoin.conf.bak-before-cfpool-rpcauth
    shred -u /home/malf/.cf-doge-rpcauth /home/malf/.cf-doge-curlrc
    make check-secret-backups && make check-residue      # on BOTH hosts

Keep `/home/malf/.cf-doge-rpc-password` until the restart has been verified —
it is the only copy of the value on that host, and without it the rollback in
the bitcoind runbook has nothing to put back. Shred it once the pool is
committing to aux blocks.

The `.bak-before-cfpool-rpcauth` file contains the *placeholder*, not a
credential, so it is not a secret — but it is exactly the shape
`scripts/check-no-secret-backups.sh` scans `/data/chains` for since
micro-org#429, and a permanent red is a check nobody reads.

## Related

- `runbooks/runbook-bitcoind-rpcauth-rotation.md` — the parent procedure. The
  format, the five silent failures, and the rollback all live there.
- `runbooks/runbook-chain-node-unreachable.md` — ports, datadirs, restart
  discipline, and the wedge that is not an auth failure.
- `runbooks/runbook-secret-leaked-to-transcript.md` — what to do when a value has
  been printed, and why the prober above prints no error object.
- `systemd/README.md` — why these daemons run under units at all, and the two
  decisions `dogecoind.service` makes.
