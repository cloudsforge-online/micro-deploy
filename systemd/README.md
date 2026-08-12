# The chain host's daemons, and what happens when it reboots

`bitcoind`, `litecoind` and `dogecoind` on **192.168.1.42** are not containers
and never were. Until 2026-08-12 they were also not supervised by anything: three
processes started by hand in an SSH session, holding about 1.25 TB of state
between them, with nothing on the machine that would bring them back.

micro-org#338 §5.4 flagged that before the chain/app split, and the split did not
fix it — it made it worse. The app stack now lives on a different machine and
reaches these three over WireGuard, so a reboot of this host is a full outage of
every UTXO surface the estate has: pool templates, deposit crediting, withdrawal
building, settlement fee quotes. And nothing in the app stack would be able to
say why, because from over there the symptom is a node that stopped answering.

These four files are the fix. They are installed by

```sh
scp -r systemd malf@192.168.1.42:/home/malf/cf-systemd
ssh malf@192.168.1.42 'sudo bash /home/malf/cf-systemd/install-chain-units.sh'
```

which copies the units to `/etc/systemd/system`, the wait helper to
`/usr/local/lib/cloudsforge`, this file to `/etc/cloudsforge/README.systemd.md`,
verifies each copy with `cmp`, runs `systemd-analyze verify`, and **enables
without starting**.

## Decision 1: `Type=simple`, so no `-daemon`

Every one of these daemons has been started with `-daemon` since the day it was
installed, and the units drop it. Three things follow, and each is a reason:

- **systemd supervises the process that can crash.** With `-daemon` the launcher
  forks and exits 0 immediately, so `Restart=on-failure` would be watching
  something that already succeeded. Without a `PIDFile=` — and none of these
  daemons' versions offer `-daemonwait`, which is what would make `Type=forking`
  honest — systemd would guess at the main pid and mostly guess wrong.
- **`systemctl stop` returns when the process is gone.** This is not theoretical
  here: litecoind's datadir lock is released *after* the pid leaves `ps`, so a
  stop-then-start typed by hand loses the race and the node stays down, refusing
  to start with a message about already running. `Type=simple` makes stop block
  until the process is reaped, which is exactly the wait a human forgets.
- **No stale pid file.** The `<chain>d.pid` files in each datadir still exist from the hand-started
  era and are now nothing but litter.

The cost is that a non-daemonised Core logs to the console by default, so every
`debug.log` line would be copied into the journal. `-printtoconsole=0` turns that
off. Startup failures still reach the journal: Core writes `InitError` to stderr
regardless of the flag, which is the only output anybody wants from these units.

`TimeoutStopSec=1200` is the other half. A chainstate flush is slow and a node
SIGKILLed part-way through comes back wanting a reindex — hours on a `txindex=1`
chain, during which every alert this file exists to prevent is firing.

## Decision 2: enabled, not started

The installer never starts, stops or restarts a daemon, and `systemctl is-active`
saying `inactive` beside a running node is the expected state after it runs.

Installing supervision is not a reason to bounce 1.25 TB of live chain state.
BTC and LTC are both in the estate's `POOL_CHAINS` and back live surfaces; a
restart of either is a customer-visible event that should be announced, not a
side effect of a config change. The units take over at the next reboot.

The exception, and the reason this is a measurement rather than a hope, is
**dogecoind**. Nothing in the estate reads DOGE — it is in no `POOL_CHAINS`, no
surface queries it, and the node is still deep in initial block download — so its
blast radius is nil. It was stopped and restarted under `systemctl` on
2026-08-12 to prove the unit shape actually works on a Core fork this old, before
BTC and LTC inherit it unexamined at some future reboot. What that produced:

| Claim | What was measured |
| --- | --- |
| systemd tracks the real process, not a launcher | `MainPID=2047390` = the pid in `pgrep -x dogecoind` |
| `ExecStartPre` runs and says so | `wait-for-rpcbind: all rpcbind addresses … present after 0s` in the journal |
| the node actually serves | `getblockchaininfo` answered; height moved 5,333,510 → 5,333,524 |
| the RPC bind is live and still refuses strangers | `POST http://10.10.0.1:9332/` from the host itself → **403**, which is `rpcallowip=10.10.0.2/32` working |
| `systemctl restart` cannot lose the lock race | restart returned after **77s** — systemd waited for the shutdown — and the journal has no `Cannot obtain a lock` / `already running` |

That last row is also why `TimeoutStopSec` is not left at its default. systemd's
default is 90 seconds; this shutdown took 77 of them on a node that is still in
IBD and holds a 1.2 GB dbcache. A synced `txindex=1` node with more to flush
would cross 90s, be SIGKILLed, and come back wanting a reindex — the default is
close enough to the real number to be dangerous, which is worse than being
obviously wrong.

### Do not `systemctl start` bitcoind or litecoind today

Until one of them has been taken over, `systemctl start litecoind` does not
adopt the running node — it starts a **second** one, which finds the datadir
lock held and exits:

```
Error: Cannot obtain a lock on data directory /data/chains/litecoin.
Litecoin Core is probably already running.
```

That is not a prediction. It was run against `bitcoind` on 2026-08-12 and the
journal above is the real one, word for word, from `/data/chains/bitcoin`. The
hand-started node came through it with the same pid it went in with and answered
`getblockcount` → 962,082 straight afterwards, which is the point: this mistake
is loud and harmless, and it will still look like an outage to whoever makes it.

Here that message is true. `Restart=on-failure` then retries every 30s, and
after ten failures inside an hour `StartLimitBurst` gives up and leaves the unit
`failed` — visible in `systemctl --failed` rather than looping forever. The real
node is untouched throughout, which is the confusing part: the unit is red and
the chain is fine. Stop the hand-started process first.

### Taking a live daemon over without a reboot

When you do want to, one at a time, announced:

```sh
/data/docs/<chain>-<ver>/bin/<chain>-cli -datadir=/data/chains/<chain> stop
# wait for it to leave ps AND for the lock to go - do not race it:
while pgrep -x <chain>d >/dev/null; do sleep 2; done
sudo systemctl start <chain>d
systemctl status <chain>d --no-pager
```

`pgrep -x`, matching the process NAME, and not `pgrep -f "…/data/chains/<chain>…"`.
`-f` matches against the whole command line, and the shell you are running that
loop in has the pattern in its own command line, so it matches itself and the
loop never ends. That mistake cost ten minutes here on 2026-08-12 and read
exactly like a daemon refusing to shut down, which is the one thing you must not
respond to with `kill -9`.

Then confirm the node is answering before you move to the next one — the CLI
first, then a caller. `runbook-chain-node-unreachable.md` has the HTTP probe and
the reason the CLI answering is not sufficient.

## The reboot hazard these units expose rather than create

All three confs bind RPC on addresses this machine does not own at boot:

| Address | Owner | Exists at boot because |
| --- | --- | --- |
| `127.0.0.1` | loopback | always |
| `10.10.0.1` | `wg0` | `wg-quick@wg0.service`, enabled |
| `172.31.0.1` | `cf-testnet_default` docker bridge | snap dockerd recreates it |
| `172.20.0.1` | `cloudsforge-estate_default` docker bridge | snap dockerd recreates it |

Core treats an unavailable `rpcbind` address as a **fatal** init error and blames
the wrong thing while doing it:

```
Error: Unable to bind to 172.20.0.1:50001 on this computer. Bitcoin Core is
probably already running.
```

Nothing is already running. So the units order themselves `After=` wg-quick and
dockerd, and — because dockerd reports itself started before it has finished
recreating every persisted network — `ExecStartPre` runs `wait-for-rpcbind`,
which reads the conf, waits up to 180s for each address to appear, and on timeout
says which one is missing instead of letting Core say something untrue.

**`cloudsforge-estate_default` is a landmine.** It has had no containers on it
since the app stack left on 2026-08-10 and survives only because nobody has run
`docker network prune`. The day somebody does, bitcoind and litecoind can no
longer start. The real fix is to delete the `172.20.0.1` and `172.31.0.1`
`rpcbind=`/`rpcallowip=` lines from all three confs — nothing reaches these nodes
over a docker bridge any more, only over `wg0` from `10.10.0.2` — and it is not
done here because it needs a restart of each live daemon to take effect. Do it
during the next announced restart, in the same window as the takeover above.

## What these units do not do

- **They do not monitor.** A node that starts and then wedges is
  `ChainNodeTemplateStale`, and `Restart=on-failure` will not fire for it because
  a wedged Core has not exited. See `runbook-chain-node-unreachable.md`.
- **They do not make the reboot safe to perform casually.** They make it
  survivable. Bringing 1.25 TB of chain state back is still minutes of catch-up
  during which the estate's UTXO surfaces are degraded, and it should still be
  announced.
- **They have not been proven by an actual reboot of this host.** That is a
  deliberate production outage of every UTXO surface and it needs a window and an
  owner, not an unattended agent. Until one happens, what is proven is: all three
  units parse (`systemd-analyze verify`), all three are enabled, and one of them
  has genuinely started and stopped its daemon.
