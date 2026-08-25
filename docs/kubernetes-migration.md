# Migrating the estate to Kubernetes

The estate moved off `docker compose` on a WSL host and onto k3s on a Hyper-V
Linux VM. This document is the *history*: what exists, where it lives, what has
to be done by hand if the VM is ever rebuilt, and the exact sequence that
flipped public traffic — with what each step actually did.

> **Looking for how to run it day to day?** Start, stop, deploy a release,
> survive a reboot, move it to another machine, roll back:
> **[`kubernetes-operations.md`](kubernetes-operations.md)**. This file explains
> *why*; that one is what you do.

---

## Status, before anything else

**CUT OVER 2026-08-19 07:44 UTC. Public traffic is served by Kubernetes.**

| | Serving the public | Stopped |
| --- | --- | --- |
| **Where** | `cf-k8s` VM, k3s | app host, WSL, `docker compose` |
| **Mainnet** | `cloudsforge-estate` namespace | project `cloudsforge-estate` |
| **Testnet** | `cf-testnet` namespace | project `cf-testnet` |
| **Deployed by** | `scripts/k8s-deploy.sh` | `scripts/release-deploy.sh` |
| **Cloudflare tunnel** | `cf-edge`, `replicas: 1`, 4 connectors | Windows service, **Stopped and Disabled** |

Steps 1–7 below were executed in order and are recorded with what they actually
did, including the two places the runbook was wrong and had to be fixed mid-
cutover (step 3's `down`, step 4's live target). What the estate measures now:

| | real failures | of which pre-existing, documented below |
| --- | --- | --- |
| mainnet | **3** | 2 — `app` not in `initdb.sql`, `market.listings is EMPTY`; the third is a race in the verifier, not the estate |
| testnet | **59** | 59 — the documented baseline exactly |

Mainnet's items 3–6 — the parallel-run drift — closed on the cutover, which is
what step 1's stopped-source dump was for. Testnet's 59 is unchanged from the
pre-cutover measurement: no new failure shape appeared on either network.

Measured a second time with **every** estate container on the app host stopped
and no estate port bound there, so that the cluster was demonstrably the only
thing that could answer: same numbers, and all 21 mainnet public hostnames 200.
That is step 8.

The interlock this section used to describe is now spent, and the direction it
guards has reversed. It was: a second connector splits live traffic across two
estates with two databases. **That is still true**, so the Windows service is
`Disabled` rather than merely stopped — `Automatic` plus a Windows reboot would
re-attach a connector to the compose estate, which is stopped but still on disk
with its volumes, and Cloudflare would load-balance onto it. Do not re-enable it.
The other half of that interlock lived in `scripts/k8s-cloudflared.sh`, and it
**was turned around rather than left**. Before the cutover it applied a manifest
carrying `replicas: 0` and refused to proceed unless it still said so — going
live had to be a decision, not the side effect of an apply. Immediately after
the cutover that same line was an outage button: the manifest is what `kubectl
apply` writes over the live spec, so a routine apply of an unchanged checkout
would have scaled the estate's only connector to zero and 502'd every public
hostname at once. The protection and the outage were the same line.

The manifest now carries `replicas: 1`, the assertion demands 1, and the
post-apply check fails if the result is anything else — plus a `rollout status`
wait, because "a pod exists" and "the connector registered with Cloudflare's
edge" are different claims and only the second one means the estate is
reachable. Same guard, aimed at the direction that is now dangerous.

`docs/releasing.md` still describes the compose release path. **This document
governs deploys now**, until that one is rewritten.

---

## Which machine

| Host | Reach it by | What is there |
| --- | --- | --- |
| **k8s** `savva@192.168.1.171` | `ssh savva@192.168.1.171` — key-only, passwordless sudo | The `cf-k8s` VM. k3s, both estates, CloudNativePG, the telemetry plane, the backup runner, BuildKit. Checkouts at `~/dev/cloudsforge/{deploy,org,runtime,miner-keys}`. **This document.** |
| **app** `savva@192.168.1.129` | `ssh` lands on **Windows cmd.exe**; the estate is `wsl -d Ubuntu-24.04`, checkouts at `/home/savvaniss/dev/cloudsforge` | The live compose estate. Also the Hyper-V host: the VM runs *on this machine*. Also the `Cloudflared` Windows service that carries all public traffic today. |
| **chain** `malf@192.168.1.42` | `ssh malf@192.168.1.42` | `bitcoind`, `litecoind`, `dogecoind` and the Hearth seed — host processes, not containers. Reached over WireGuard from both estates. |
| **Mac** | — | Git authority. Branch `migration/kubernetes`. |

### Never run kubectl from the Mac

The Mac's default kubectl context is `aks-editorai-sbx`, **a live Azure work
cluster**. A `kubectl delete` typed against the wrong context is not recoverable
by apologising. Every `kubectl` in this document runs **on the VM, over ssh**:

```sh
ssh savva@192.168.1.171 'kubectl get pods -A'
```

No kubeconfig was ever copied to the Mac, and none should be.

---

## Why a Linux VM, and not Docker Desktop or WSL

The original plan was single-node Kubernetes through Docker Desktop, because
Docker Desktop is a Windows application and that sounded like "no WSL". It is
not: Docker Desktop's Kubernetes runs inside a WSL2 VM, so choosing it would
have kept every gram of the overhead the move was meant to remove. There is no
native-Windows path either — Linux containers need a Linux kernel, and on
Windows that is always a VM. The only real choice is *which* VM and *who
manages it*.

So: a Hyper-V VM we own, running a real Linux server, reached over ssh. k3s
rather than full kubeadm — one binary, one systemd unit, a bundled containerd,
and Traefik and local-path already present. The trade is explicit and worth
writing down: k3s is a single point of failure on a single node, which is
exactly what compose on one host already was. Nothing got less available; the
control plane got standard.

---

## The Windows host

The VM must survive a reboot with no human present, so the pieces are services
rather than sessions:

| Piece | State | Why |
| --- | --- | --- |
| `vmms` (Hyper-V VMM) | Running, **Automatic** | Starts the hypervisor at boot. |
| `vmcompute` | Running, Manual | Started on demand by `vmms`. Correct as-is. |
| `cf-lan` virtual switch | **External**, on the Realtek 2.5GbE adapter | An *external* switch, not the Default Switch, so the VM gets a real LAN address (`192.168.1.171`) that survives reboots and is reachable from the chain host and the Mac. The Default Switch NATs and renumbers. |
| `cf-k8s` VM | `AutomaticStartAction: Start`, delay 30s | Comes back by itself. The 30s delay lets networking settle first. |
| `Cloudflared` | Running, Automatic | **Still carrying all public traffic.** Stopped at cutover, not before. |

`Get-VM cf-k8s` is the one-line health check from the Windows side.

**Do not use `Start-Process` to launch anything long-lived over ssh on this
host** — SSH kills the process tree when the session ends, and the result reads
as a service "flapping". Use a service, or `Win32_Process.Create`.

---

## The VM

```
cf-k8s        Ubuntu 26.04 LTS, kernel 7.0.0-30-generic
              16 vCPU, 12 GB static memory, autostart
              / = 194G on /dev/mapper/ubuntu--vg-ubuntu--lv
              k3s v1.36.3+k3s1, containerd 2.3.2-k3s2
              savva = uid/gid 1000, key-only ssh, passwordless sudo
```

**Memory is static, not dynamic, and 12 GB is a ceiling set by the host.** The
Windows box is also running WSL and Docker Desktop today; that budget is what
was free. The VM currently sits around 8 GB used with both estates up, which is
enough but not roomy. **Raising it is a post-cutover step**, once WSL is gone.

**The LVM volume group has zero free extents.** There is no `lvextend` waiting
to be run — growing storage means attaching a *new* virtual disk. That matters
for the backup destination below, and Windows `C:` has only ~136 GB free today,
so the new disk is also blocked behind deleting WSL.

---

## Host state the manifests do not carry

This is the rebuild list. If the VM is ever recreated, these are the things no
`kubectl apply` will restore, in the order they are needed.

### 1. k3s, with a raised pod ceiling

`/etc/rancher/k3s/config.yaml`:

```yaml
kubelet-arg:
  - max-pods=250
```

The kubelet's default is 110. The steady state is ~104 pods before cloudflared,
telemetry or the backup runner land — measured on 2026-08-19 at 111
non-terminated pods against an allocatable 110, at which point the second
hearth-devkit pod simply could not be scheduled. Everything already running
stayed healthy, which is what makes it worth writing down: **the ceiling does
not degrade the estate, it silently refuses the next thing.**

250 and not higher because the node's podCIDR is a `/24` — 254 usable
addresses. A limit above that trades a scheduling error for an IP-exhaustion
error, which is the same outage with a worse message.

### 2. WireGuard to the chain host

`wg-quick@wg0`, enabled and active. The VM is **`10.10.0.3`**; the peer is the
chain host at `192.168.1.42:51820`, `allowed-ips 10.10.0.0/24`, keepalive 25s.

The chain host had to be told to accept it. `bitcoin.conf`, `litecoin.conf` and
`dogecoin.conf` each gained an `rpcallowip=10.10.0.3/32` line beside the
existing `10.10.0.2/32` (the WSL app host), and **all three daemons were
restarted** to pick it up — `rpcallowip` is read at startup only. The
pre-change files are kept as `*.conf.bak.20260819`.

`litecoind` does not stop instantly: the process disappears **before** it
releases the datadir lock, so a fast restart loses the race and leaves the node
down. Wait for the lock, then start.

Both estates are allowed at once on purpose. The app host's `10.10.0.2/32` line
and its peer are retired *after* the cutover, not during it.

### 3. BuildKit, driving k3s's own containerd

`/etc/buildkit/buildkitd.toml` + `/etc/systemd/system/buildkit.service`
(`After=k3s.service`, enabled). The OCI worker is off; the containerd worker
points at `/run/k3s/containerd/containerd.sock`, namespace `k8s.io`.

`deploy/backup` is the one estate deployable with **no published image** — every
other service is a digest-pinned GHCR reference out of the release manifest,
while the backup runner has only ever existed as a local `docker build` on the
app host. After cutover that host loses Docker, and an unbuildable backup image
is micro-org#434 in a new form (the estate went 43 hours with no backup because
nothing on the deploy path rendered it).

So the VM builds it itself, and **no Docker daemon is reinstated**. buildkitd
writes into the namespace kubelet resolves from, so a built image is already in
the store — no registry, no push, no pull to miss. Building into any other
containerd namespace produces an image that exists and that no pod can use.

`./scripts/k8s-backup-runner.sh --build` is the whole interface.

> **Follow-up:** add a GHCR publish job to `deploy/.github/workflows/ci.yml` so
> `deploy/backup` gets a digest-pinned reference like every other service. Then
> BuildKit becomes a convenience rather than a dependency.

### 4. The backup destination

```
/srv/cloudsforge-backups   owner 1000:1000, mode 700
```

Owner and mode are load-bearing. Kubernetes will happily mount a root-owned
hostPath; the pod then starts, reports Ready, and fails its canary write — which
reads as a *backup* fault rather than a *permissions* one.
`scripts/k8s-backup-runner.sh` checks ownership, mode, and the 100 GiB
filesystem floor `src/disk.ts` enforces, because all three surface as a pod
event several seconds after an apply that already printed `configured`.

**Mainnet's 11.8 GB of backup history is already here** (`mainnet/`, `testnet/`
under that root). It was rsynced from WSL on 2026-08-19, direct host-to-host
over a restricted ephemeral key that was destroyed on both ends afterwards. It
had to move *before* cutover rather than after: the imported database carries
`succeeded` rows pointing at `/backups/mainnet/<ts>` directories, and `verify`
runs daily against the newest succeeded set — leaving the files behind would
have produced daily verify failures that were migration artefacts, not faults.

Both networks share one root. `run.ts` already writes
`<root>/<environment>/<timestamp>`, `prune.ts` selects from database rows in
per-network clusters and independently refuses any path outside the root, and
separate roots buy nothing on one filesystem because `min_free_bytes` is
enforced through `statfs`. The payoff is one manifest, byte-identical for both
namespaces.

> **Post-cutover:** give this its own virtual disk. 143 GB free today against a
> 100 GB `min_free_bytes` floor is comfortable and is not a plan — and the
> backups sharing a filesystem with the container store means a runaway image
> pull can starve the estate's only recovery point.

### 5. The miner keys

```
~/dev/cloudsforge/miner-keys/mainnet/coinbase-keystore.json
~/dev/cloudsforge/miner-keys/testnet/coinbase-keystore.json
~/dev/cloudsforge/miner-keys/secrets/coinbase-passphrase
```

Mounted read-only into the backup runner, which encrypts them into every set
under `CF_BACKUP_AGE_RECIPIENT`. Their absence is not an error the runner
raises — it publishes `backup_secrets_included 0` and `MinerCoinbaseKeyUnbacked`
fires. Both networks currently read **1**.

Note the standing limitation, unchanged by this migration: this backs up the
*app host's* key. The chain host holds roughly six times as much EMBER and has
no runner of its own.

### 6. `gateway/certs/` — untracked, and correctly so

```
deploy/gateway/certs/estate.crt    the estate's TLS certificate
deploy/gateway/certs/estate.key    mode 600
deploy/gateway/certs/trust.crt     tracked; the internal trust bundle
```

`estate.key` is a private key and is not in git. `scripts/k8s-gateway.sh` loads
the pair into the `gateway-certs` Secret in each namespace. A rebuilt VM needs
these copied across before the gateway will serve TLS; the gateway starts
without them and answers on `:80` only, which looks like a routing bug.

### 7. The untracked env files, and one deliberate divergence

`compose/estate/tokens.env` and `tokens.testnet.env` are untracked host state and
are the input to `scripts/k8s-secrets.py`. They were copied from the app host.

**`compose/estate/tokens.testnet.env` on the VM carries
`CF_BACKUP_AGE_RECIPIENT`; the app host's copy does not.** That is on purpose,
and it is the one place the two hosts' files differ. Testnet had never had a
backup at all — every row in its `backup_runs` was `queued` with a NULL
`started_at`, enqueued by something and claimed by nothing, because the compose
estate had no testnet runner. One Kubernetes manifest serves both namespaces, so
testnet has a runner now, and a runner with no recipient leaves the coinbase key
out of every set.

The value is **mainnet's recipient, copied rather than regenerated**. An age
recipient is a *public* key, so copying creates no new secret; a second keypair
would create a new *private* one, and private-key custody is already the
estate's thinnest thread. Blast radius is unchanged either way — whoever holds
the identity that decrypts testnet already decrypts mainnet.

`k8s/estate/render-vars.testnet.yaml` declares the name, so
`scripts/k8s-secrets.py --verify` checks it in both directions.

---

## The layers, and the order they go on

Each script's own header carries the full argument for why it is a script and
not a bare `kubectl apply`. This is the sequence.

| # | Layer | Command | Notes |
| --- | --- | --- | --- |
| 0 | Namespaces, StorageClass | `kubectl apply -f k8s/base/` | `cf-retain` is `reclaimPolicy: Retain`. Every stateful claim uses it, so deleting a PVC cannot delete the data. |
| 1 | CloudNativePG | operator install, then `kubectl apply -f k8s/database/` | One `Cluster` named `postgres` per namespace, single instance `postgres-1`, 60Gi data + 16Gi WAL, plus 30 `Database` objects generated from `initdb.sql`. |
| 2 | Secrets | `./scripts/k8s-secrets.py --network <net> --apply` | Reads the untracked env files. **Prints names only, never values.** `--verify` checks both directions against `render-vars.<net>.yaml`. |
| 3 | Database import | `./scripts/k8s-db-import.sh --network <net> --rehearse` | Same command rehearses and cuts over; `--cutover` is the flag that means "the source is stopped". |
| 4 | Volumes | `./scripts/k8s-estate-seed.sh --network <net>` | Fills the PVCs. A manifest can declare a PVC but not fill it, and an empty one is invisible: custody starts, reports ready, holds no keys. |
| 5 | The estate | `./scripts/k8s-deploy.sh --network <net> --hold beacon,settlement` | 51 rendered Deployments, applied in waves, wave 50 in batches. |
| 6 | Gateway | `./scripts/k8s-gateway.sh --network <net>` | ConfigMap of `gateway/dynamic/*.yml` (208 KB), the trust bundle, the cert Secret, the pod. `strategy: Recreate` — never two Traefiks, per micro-org#428. |
| 7 | Hearth devkit | `./scripts/k8s-hearth-devkit.sh --network testnet` | Testnet only; refuses mainnet, which runs no devkit. |
| 8 | Telemetry | `./scripts/k8s-telemetry.sh` | One plane in `cf-telemetry` for both networks, as compose has. |
| 9 | Backup runner | `./scripts/k8s-backup-runner.sh --network <net>` | Both networks. Add `--build` first on a fresh VM. |
| 10 | Tunnel | `./scripts/k8s-cloudflared.sh --token-file <path>` | The public front door. Refuses a manifest that is not `replicas: 1`, and waits for the connector to reach Ready rather than merely Scheduled. |

Rendering is separate from applying, and both generated trees are committed:

```sh
./scripts/k8s-render.py --network mainnet --release ../org/releases/2026.8.81.yaml \
    --outdir k8s/estate/mainnet
./scripts/k8s-render-databases.py --network mainnet --out k8s/database/21-databases-mainnet.yaml
```

`k8s/estate/{mainnet,testnet}/` are pinned to release **2026.8.81**; all 51
images are digest-pinned `ghcr.io` references and no pull secret is needed.
Re-render on every release, exactly as `release-deploy.sh` re-resolves digests.
`scripts/check-k8s-databases-match-initdb.py` fails the build if the SQL and the
generated `Database` manifests drift — that particular rot is silent in the
worst way, because a missing database is a service that starts and 500s.

### Namespace names are load-bearing

`cloudsforge-estate` and `cf-testnet` are the **compose project names**. They
were chosen so that `<project> == <namespace>`, which is what lets
`scripts/k8s-telemetry.sh` rewrite every compose target
(`cloudsforge-estate-indexer-1:9464`) into a Kubernetes FQDN
(`indexer.cloudsforge-estate.svc.cluster.local:9464`) mechanically, and what lets
the backup runner take `BACKUP_COMPOSE_PROJECT` straight from the downward API
(`fieldRef: metadata.namespace`). Renaming a namespace breaks both, quietly.

---

## What is running now, and what was deliberately not

Measured 2026-08-19, **after** the cutover:

| Namespace | Pods | Notes |
| --- | --- | --- |
| `cloudsforge-estate` | 54/54 Running | 51 estate + gateway + postgres + backup-runner |
| `cf-testnet` | 56/56 Running | the same, plus 2 hearth-devkit |
| `cf-telemetry` | 6/6 Running | prometheus, alertmanager, grafana, loki, tempo, otel-collector |
| `cnpg-system` | 1/1 Running | the operator |
| `cf-edge` | 1/1 Running | cloudflared — **the estate's public front door** |

Both estate namespaces also hold 32 `Completed` migrate Jobs each, which
`kubectl get pods` lists and which are not failures.

### The two that were held, and are not any more

Through the whole parallel run `beacon` and `settlement` were held on both
networks — `--hold beacon,settlement` — and held rather than
applied-and-scaled-to-zero, so nothing about them existed to be accidentally
started:

- **`beacon`** synthesises registrations against live surfaces. Two beacons on
  two estates would double the load *and* double the mail: Mailtrap's free tier
  is 150 messages a day, and beacon already spends all of it.
- **`settlement`** moves real money. Two settlement processes against two
  databases and one set of chain nodes is a double-spend engine.

Both reasons said "two estates", and after the cutover there is one. Both are
now `1/1 Ready` on both networks, which is why the counts above are two higher
per namespace than the parallel-run measurement they replace.

Prometheus reports **40 targets, 40 up**. During the parallel run it was 40/38,
and the two down were exactly these — the held services were visible as down
rather than absent, so "everything green" could not be reached by forgetting
them. It is now green because they are actually running.

---

## Reaching things without a public hostname

Nothing in the cluster is exposed on a node port; the gateway is `ClusterIP`,
and that did not change at the cutover — public traffic arrives through the
`cf-edge` pod's own loopback, never through the node's network. So the operator
routes are still these, from the VM:

```sh
# Grafana — replaces the old ssh tunnel to the app host
ssh -L 9091:127.0.0.1:9091 savva@192.168.1.171
#   then, on the VM:
kubectl -n cf-telemetry port-forward svc/grafana 9091:3000

# Prometheus, without a port-forward at all — through the API server proxy
kubectl get --raw "/api/v1/namespaces/cf-telemetry/services/prometheus:9090/proxy/api/v1/targets?state=active"

# Postgres
kubectl exec -n cloudsforge-estate postgres-1 -c postgres -- psql -U postgres -d <db> -c '<sql>' </dev/null
```

`kubectl exec -i` eats your stdin exactly as `docker exec -i` does. Drop the
`-i` and append `</dev/null` unless a pipe into the pod is the deliberate point.

For building a Prometheus query string, use `urllib.parse.urlencode` in a small
python helper rather than hand-escaping through ssh → kubectl → shell.

---

## The cutover

Do this in one sitting. Steps 3–6 are the window in which the estate is down.

1. **Re-render at the release that is live**, and commit. The k8s tree must
   name the same release `release-deploy.sh` last applied, or the cutover is
   also an unreviewed rollback — the failure mode of 2026.08.12, where 45
   services silently went backwards and nothing was unhealthy.

2. **Verify the k8s estate answers**, with hostnames mapped to the gateway
   rather than to Cloudflare:
   ```sh
   ./scripts/k8s-cluster-dns.sh --check     # the zone still matches gateway/dynamic/
   ./scripts/k8s-estate-verify.sh mainnet
   ./scripts/k8s-estate-verify.sh testnet
   ```
   Compare against the counts in "Where verification stands" below. What matters
   is not the number but the DELTA: a failure that is not on that list is new,
   and a cutover is the wrong moment to meet it. Expect **9 on mainnet** —
   6 documented, plus 3 that are the hold itself (`settlement /livez`,
   `settlement /readyz`, `beacon /v1/gate` 504), which step 5 clears.

   On mainnet the four drift failures are expected HERE and must be gone after
   step 4 — they are the only check in the suite that proves the re-import
   actually closed the gap.

3. **Quiet the compose estate** on the app host, inside WSL — everything except
   its postgres. There is no `release-deploy.sh --down` (that script only ever
   brings things *up*), and `deploy/down.sh` stops the telemetry plane, not the
   estate. Per project, by name:
   ```sh
   export DOCKER_CONFIG=/tmp/dockercfg-nocreds     # else every compose call re-authenticates
   docker compose -p cf-stratum down                # see below — the one that must go

   docker compose -p cloudsforge-estate stop
   docker compose -p cloudsforge-estate start postgres
   docker compose -p cf-testnet stop
   docker compose -p cf-testnet start postgres
   ```

   **`stop` and not `down`, and postgres back up, and this ordering is not
   stylistic.** Step 4 dumps FROM the compose postgres over ssh, and
   `k8s-db-import.sh` refuses to start unless the source container is running:

   > `fail "source container $SOURCE_CONTAINER is not running"`

   …while `--cutover` separately refuses unless it has **zero** client backends.
   Those two together are the definition of "quiet": the server is up, and
   nothing is talking to it. `down` satisfies the second and breaks the first,
   so a runbook that says `down` here stops the cutover dead at step 4 with the
   estate already off. It said `down` until 2026-08-19.

   `stop` is also the better half of the rollback. It leaves the containers in
   place, so recovering is `docker compose -p <project> start` — the same images,
   the same env, the same networks — instead of a full `release-deploy.sh` from a
   host whose registry login may have expired.

   Both projects resolve by name alone: compose reads the project from container
   labels, so `stop`/`start`/`ps` need neither `-f` nor `--env-file` (verified —
   `ps --services` lists all 55 for each, `postgres` among them). **Never add
   `-v`** — that deletes the named volumes, which on this host is the estate's
   data. **Never add `--remove-orphans`**, a standing rule for the devkit and
   miner projects that costs nothing to keep here.

   The equivalent with files, if you want compose to re-read them, is
   `-f compose/docker-compose.estate.yml -f compose/docker-compose.release.yml
   --env-file compose/mainnet.env --env-file compose/estate/tokens.env` — the
   two `--env-file`s must name the same estate, which is what
   `scripts/check-env-files-agree.sh` exists to enforce.

   Nothing may write to the source databases after this point. `backup-runner`
   is inside the estate project and stops with it, which is what makes the
   backend count reach zero; if it does not, the gate in step 4 will say so
   rather than dumping a moving target.

   **`cf-stratum` is stopped first, and it is the only one of the five
   outside-the-estate projects that has to be.** Five docker-compose projects on
   the app host are not `cloudsforge-estate` or `cf-testnet`, so `down` by
   project name leaves every one of them running:

   | Project | What it is | At step 3 |
   |---|---|---|
   | `cf-miners` | `cf-miner-mainnet-apphost`, the estate's *second* EMBER coinbase | leave up — it mines to the chain host, not to the estate |
   | `cf-stratum` | `stratum-endpoint` | **stop it** |
   | `cfmicro` | the compose telemetry plane (6 containers) | leave up during the window; it goes red on a down estate, which is true. **Stopped at step 8** — the cluster has its own `cf-telemetry`, and leaving it up meant an estate container was still running on the app host |
   | `cfwg` | WireGuard to the chain host | leave up — the miner needs it |
   | `ft_userdata` | freqtrade, unrelated to the estate | leave up |

   `stratum-endpoint` holds `/var/run/docker.sock` and its whole job is to run
   `docker compose -p cloudsforge-estate up -d --no-deps pool` when the WAN
   address changes. Against a torn-down project that is a single `pool` container
   with no dependencies, pointed at the compose database this cutover exists to
   stop writing to. It is inert *today* — `CF_STRATUM_PUBLISH` is unset on both
   networks, so it defaults to `false`, writes nothing, and never applies;
   `compose/generated/stratum.env` does not exist, which is the observable proof.
   But "inert because a flag nobody is thinking about is still off" is not a
   property to run a cutover on, and the container costs nothing to stop.

   **The cluster has no `stratum-endpoint`, and that is not a regression.**
   `scripts/k8s-render.py` never saw it — it is deliberately not in
   `docker-compose.estate.yml` (a `build:` the release manifest cannot pin), so
   there was nothing to render. With publishing off, compose and cluster agree
   exactly: no generated file, `pool` reads no public host, `GET /v1/pool`
   answers `stratumEndpoint: null`. It becomes real work the day an operator
   wants hardware miners to dial in; see "What is not finished".

   **The EMBER chain itself is on the chain host and no step here touches it** —
   `cf-hearth-seed` and `cf-hearth-seed-testnet`, beside `cf-miner-mainnet` and
   `cf-miner-testnet` and the three UTXO daemons. Verified rather than assumed,
   because "the estate is down" and "the chain stopped" are the same symptom from
   a frontend.

4. **Quiet the TARGET too, then re-import** — from the VM, not the app host; the
   script reaches back over ssh:
   ```sh
   for ns in cloudsforge-estate cf-testnet; do
     kubectl -n $ns scale $(kubectl -n $ns get deploy -o name | grep -vE '/gateway(-testnet)?$') --replicas=0
   done
   # wait until only gateway and postgres-1 remain in each namespace
   ./scripts/k8s-db-import.sh --network mainnet --cutover
   ./scripts/k8s-db-import.sh --network testnet --cutover
   ```

   **The scale-down is not tidiness, and this step failed without it on
   2026-08-19.** `--cutover` gates on the SOURCE being quiet and then compares an
   exact row count on both sides, where any difference means data that did not
   arrive. But the cluster estate has been running this whole time — that is the
   point of the parallel run — so all 51 Deployments are connected to the target
   while `pg_restore --clean --if-exists` drops and recreates their tables under
   them. They reconnect and carry on writing. The first attempt came back:

   ```
   foresight   ok / ROWS 366 vs 362              (target 4 short)
   indexer     ok / ROWS 12717506 vs 12718891    (target 1,385 over)
   FAIL: these databases did not import cleanly: foresight indexer
   ```

   Both restores were clean — `RESULT` is `ok`, there was no `pg_restore: error:`
   in either log. The only thing wrong was the count, and the count was right:
   the cluster's own `indexer` watches the same live chain compose used to, so it
   had inserted 1,385 rows into the copy in the seconds between the restore
   finishing and the count being taken. A verification that catches that is doing
   its job; a runbook that walks into it is not.

   **`gateway` is the one Deployment left up**, because it holds no database
   connection and `k8s-deploy.sh` does not apply it — `k8s-gateway.sh` does.
   Scaling it with the rest would leave it at 0 after step 5 with nothing to
   notice.

   Step 5 is what brings the other 50 back: `50-deployments.yaml` carries an
   explicit `replicas: 1`, so `kubectl apply` restores it.

   **…but only the 51 it renders.** Three more Deployments live in these
   namespaces, hold database connections (so they DO have to be scaled down),
   and are applied by a different script each — so step 5 leaves them at zero and
   says nothing. After step 5, run their own scripts:
   ```sh
   ./scripts/k8s-backup-runner.sh --network mainnet
   ./scripts/k8s-backup-runner.sh --network testnet
   ./scripts/k8s-hearth-devkit.sh --network testnet
   ```

   | Deployment | Namespace | Applied by |
   |---|---|---|
   | `backup-runner` | both | `scripts/k8s-backup-runner.sh` |
   | `hearth-explorer-api` | `cf-testnet` | `scripts/k8s-hearth-devkit.sh` |
   | `hearth-verify` | `cf-testnet` | `scripts/k8s-hearth-devkit.sh` |

   Missing `backup-runner` is the expensive one and it is silent by
   construction: the estate keeps serving, and the only thing that changed is
   that nothing is writing a recovery point. `estate-verify.sh` does say so —
   `NO backup-runner container in project cloudsforge-estate` — which is how it
   was caught here. The check to run afterwards is:
   ```sh
   kubectl get deploy -A -o json | jq -r '.items[]|select(.spec.replicas==0)|"\(.metadata.namespace) \(.metadata.name)"'
   ```
   Only `cf-edge/cloudflared` should be listed, and only until step 6.
   Then, and only then, stop the two postgres containers as well:
   ```sh
   docker compose -p cloudsforge-estate stop postgres      # on the app host
   docker compose -p cf-testnet stop postgres
   ```
   Leaving them up would not corrupt anything — nothing is pointed at them — but
   a running postgres holding the pre-cutover copy of every table is exactly what
   somebody debugging at 2am connects to by habit and then believes.

5. **Deploy without the hold**, which is what starts `beacon` and `settlement`:
   ```sh
   ./scripts/k8s-deploy.sh --network mainnet --no-hold
   ./scripts/k8s-deploy.sh --network testnet --no-hold
   ```
   **`--no-hold` is not optional at this step, and it was missing here until
   2026-08-19.** The default hold is derived from `cf-edge/cloudflared`'s replica
   count — 0 means "this estate is not live, hold `settlement,beacon`" — and the
   tunnel does not move until step 6. So a bare `k8s-deploy.sh` run here reads
   the pre-cutover world correctly and holds exactly the two services the cutover
   exists to start. It would say so on stdout (`hold: settlement,beacon`) and
   deploy everything else green.

6. **Move the tunnel.** Off first, then on — never both:
   ```sh
   # on the Windows app host
   Stop-Service Cloudflared
   Set-Service Cloudflared -StartupType Disabled
   # on the VM
   kubectl -n cf-edge scale deploy/cloudflared --replicas=1
   ```
   Disabling the Windows service matters as much as stopping it: a reboot with
   it still on `Automatic` re-attaches a connector to a dead estate and
   Cloudflare will happily send it half the traffic.

   **`ssh savva@192.168.1.129` lands on `cmd.exe`, which eats the quoting of any
   PowerShell one-liner with a `|`, a `{}` or a `$_` in it.** Drive it with
   `-EncodedCommand` instead — UTF-16LE, base64 — and the nesting problem does
   not exist:
   ```sh
   c=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
   ssh savva@192.168.1.129 "powershell -NoProfile -EncodedCommand $c"
   ```
   Measured: `Cloudflared  Stopped  Disabled`, then four connectors registered in
   ~6s (`fra08`, `ath01`, `fra10`, `ath01`, all QUIC). The whole window between
   the last compose-served request and the first cluster-served one was under a
   minute.

7. **Verify from outside** — `scripts/estate-verify.sh` against the real public
   hostnames, both networks, plus one authenticated journey.

   Measured immediately after step 6. Fourteen public hostnames from a machine
   outside the estate entirely, all 200 except two that are correct: `nimbus/`
   404 (identity publishes no `/` route — its `/.well-known/jwks.json` answers
   200 with keys) and `testnet.cloudsforge.online` 302 (the retirement). Then
   the full suite on both networks:

   | | real failures | what they are |
   | --- | --- | --- |
   | mainnet | **2** | `app` not in `initdb.sql`; `market.listings is EMPTY` |
   | testnet | **59** | the documented baseline, unchanged |

   **The nine failures that were the tunnel cleared on both networks**, which is
   what makes step 6 provable rather than merely done — see "After steps 3–5"
   for why those nine existed and what they were really measuring. Mainnet's
   drift items 3–6 closed too. One alert firing estate-wide,
   `HearthConformanceVectorsFailing` (severity `ticket`, pre-existing content),
   and `backup_last_success_unixtime` 889s old inside the cluster.

8. **Stop everything on the app host, and re-measure.** *Not in the original
   plan.* Steps 1–7 prove the cluster answers; they do not prove the app host
   has stopped answering, because a surface that works has no way to say which
   machine served it.

   Step 3 had already stopped both estate projects. What was still running was
   nine containers in four projects the runbook designates "leave up": the
   `cfmicro` compose telemetry plane (6), `cf-miner-mainnet-apphost` (1), its
   `cf-wg` (1), and freqtrade (1, unrelated and crash-looping). The telemetry
   plane is the only one of those that is *estate* infrastructure, and the
   cluster has its own — so it was stopped too, and that is a state change this
   document is the record of. What remains on the app host is the second EMBER
   miner, the WireGuard tunnel it mines through, and freqtrade. None of them
   can serve a request.

   The proof is a negative and has to be read as one: `ss -lntp` on the app host
   binds **no estate port at all** — not 80, 443, 9081, 9181, 4000 or 5432.
   Then, from a machine outside the estate, all **21** mainnet public hostnames
   answered 200 with their real titles. With nothing estate-shaped listening on
   the app host, the cluster is the only thing that could have answered.

   | | real failures | what they are |
   | --- | --- | --- |
   | mainnet | **3** | the 2 pre-existing, plus one race in the verifier itself |
   | testnet | **59** | the documented baseline, unchanged |

   The third mainnet failure is **not a defect in the estate**. `estate-verify`
   empties the custody address set, asserts the reconciliation fails closed,
   restores it, and re-asserts — with no settle time for the indexer to re-scan
   the twenty restored addresses. `reconciliation_runs` shows the whole drill in
   fourteen seconds: `clean` drift 0 at 08:09:46, the deliberate
   `failed/indexer_error` at 08:09:51, `drift_exceeded` at 08:09:57 — which is
   what the verifier reads — and `clean` drift 0 again at 08:10:00. The drift at
   08:09:57 is **negative**, the signature of an indexer that has not caught up
   rather than of custody holding less than the ledger says. `asset_freezes` is
   empty: EMBER was never frozen and the estate was not left worse. Filed as
   follow-up 8.

Rollback, at any point before step 6, is: scale `cf-edge` back to 0 (it already
is), then `docker compose -p cloudsforge-estate start` and
`docker compose -p cf-testnet start` — and nothing else. Step 3 used `stop`, so
the containers are still there and `start` is the exact inverse. The compose
databases are only ever READ (step 4 dumps from them; the restore writes into the
cluster), and the tunnel never moved.

After step 8 the rollback is the same three projects plus `cfmicro`, and the
order matters in the other direction: bring compose **up first**, then
`Start-Service Cloudflared` on Windows, then scale `cf-edge` to 0 — reversing
those last two leaves the tunnel registered and pointing at nothing. That
sequence is written out at the top of `k8s/cloudflared/60-cloudflared.yaml`,
which is where anyone scaling that deployment will actually be looking.

**Public hostnames are Cloudflare configuration and cannot be checked from this
repository.** If a surface looks broken, prove the origin with a `Host` header
before believing the routing.

---

## After the cutover

In order, none of them urgent enough to do during the window:

1. **Retire the app host's chain access.** Remove the `10.10.0.2/32` peer from
   the chain host's WireGuard and the `rpcallowip=10.10.0.2/32` line from all
   three `*.conf`, then restart the daemons — waiting for `litecoind`'s lock.
   Remove the `*.conf.bak.20260819` files at the same time.
2. **Delete WSL and Docker Desktop.** ~118 GB reclaimed. The 15 GB WSL
   "leak" was never a leak — it is an unset `.wslconfig` memory cap — but the
   distro image is real and the estate no longer needs it.
3. **Raise the VM's memory** now that the host has it to give.
4. **Attach a dedicated backup disk** and move `/srv/cloudsforge-backups` onto
   it. Requires the space freed in step 2 (there are no free extents in the
   existing volume group).
5. **Rotate the Postgres password.** One role, `cloudsforge`, across 32
   databases and every connection string, driven by one interpolation variable
   — the rotation is atomic and has a runbook.
6. **Publish `deploy/backup` to GHCR** so the last unpinned image becomes a
   digest like the other 51.
7. **Task #168:** rotate the four exposed tokens and de-duplicate the three
   repeated names in `tokens.testnet.env`.
8. **Give the custody drill a settle window.** `estate-verify`'s custody drill
   restores the address set and asserts reconciliation about three seconds
   later, before the indexer has re-scanned it, so it intermittently reads the
   catching-up run and reports `drift_exceeded` — under a headline claiming the
   estate has been left worse than it was found. The drift is negative every
   time, which is the tell: custody has not shrunk, the indexer has not caught
   up yet. Either poll until a run starts *after* the restore, or require two
   consecutive runs to agree. Pre-existing; it belongs to the verifier and not
   to this migration, and it is only visible here because this is the first
   time the drill has been run repeatedly in one morning.

---

## Divergences from compose, recorded

Things the Kubernetes estate does differently, each on purpose.

| Compose | Kubernetes | Why |
| --- | --- | --- |
| Per-network backup roots | one `/srv/cloudsforge-backups` | `run.ts` already namespaces by environment; `prune.ts` refuses paths outside the root; one filesystem makes separate roots meaningless. Buys one manifest for both networks. |
| No testnet backup runner | testnet has one | It never had a backup at all. One manifest, both namespaces. |
| `CF_BACKUP_AGE_RECIPIENT` mainnet-only | on both | See §7 above; shared public key, no new private key. |
| `BackupNeverRun: absent(backup_last_success_unixtime)` | one `absent()` per instance, `or`-ed | The bare form answers about the whole series set and goes empty the moment *any* runner succeeds anywhere. Harmless with one runner; with two, a healthy mainnet covers for a testnet that never succeeds. |
| `estate:` network `aliases:` | a CoreDNS zone per namespace | `scripts/k8s-cluster-dns.sh` renders every `Host()` in `gateway/dynamic/` — 29 names per network — to that network's gateway ClusterIP, so a pod resolving `hub.cloudsforge.online` reaches ITS OWN estate rather than the live one. `hostAliases` would have needed the same list on all 51 pod specs. Names not in the zone fall through to the internet. |
| `NODE_EXTRA_CA_CERTS` on beacon only | on every container | Consequence of the row above. Once those names resolve in-cluster, every caller meets the gateway's own leaf — the estate CA's on testnet, a Cloudflare Origin CA's on mainnet — and neither is in a public root store. `trust.crt` is the estate CA plus every public root, so carrying it costs nothing. Without it the whole testnet suite turned `401` into `503 verifier_unavailable`. |
| host-published ports | ClusterIP only | Nothing but the tunnel should ever reach the gateway. |
| kubelet default 110 pods | `max-pods=250` | ~104 pods steady state across two estates. |

---

## Where verification stands

`./scripts/k8s-estate-verify.sh <network>` runs the estate's own
`estate-verify.sh` against the cluster. Measured 2026-08-19, both estates at
release 2026.8.81:

| | mainnet | testnet |
| --- | --- | --- |
| **k8s, held** (`settlement,beacon` unapplied) | **9 failed** | **62 failed** |
| **k8s, of which are the hold itself** | 3 | 3 |
| **k8s, the rest** | **6 failed** | **59 failed** |
| compose, same day, same suite | — | 54 failed |

Both held totals are measured, not derived: mainnet 9 and testnet 62, each
run with `cf-edge/cloudflared` at 0 replicas and therefore each carrying the same
three hold failures. The testnet gap over compose is 5 checks and every one is
accounted for below. Mainnet has no compose control because running the suite
against the live estate writes test data into it; its 6 are read directly instead.

Testnet's three are the same shape as mainnet's but on testnet hostnames —
`settlement /livez`, `settlement /readyz`, and `beacon-testnet.cloudsforge.online/v1/gate
answered 504`. Do not confuse the last one with the two *other* beacon-testnet
failures in the same run (`answered 302`, `the bundle is NOT in front of the
service`): those are the retirement, they are inside the 59, and step 5 will not
clear them.

### Three of those failures ARE the hold, and only appear before step 5

**Read this before comparing your run against the numbers above.** The first
measurement was taken during the window when `settlement` and `beacon` had been
deployed unheld — the incident that made the hold default-on. With the hold
correctly applied, three more checks fail, because the two services they ask
about are not there:

```
FAIL settlement /livez
FAIL settlement /readyz
FAIL https://beacon.cloudsforge.online/v1/gate answered 504
```

That is the hold working, not a defect: `kubectl get deploy -n cloudsforge-estate`
shows no `settlement` and no `beacon` (only `beacon-web`, which is the frontend
and a different service). **Cutover step 5's `--no-hold` is what clears them**, at
the same moment it clears the four drift failures below. So the honest
expectation at step 2 is **9 on mainnet**, and **0 of those 9 after step 5**
except items 1 and 2 below, which are not migration failures at all.

### Mainnet's six, in full

1. `app` database present on the server and not declared in `initdb.sql` — a
   pre-existing divergence, not a migration one. See the row in the table above.
2. `market.listings is EMPTY` — the four seeded listings are `draft` and cannot
   be activated until a `cf:brand:` URN resolves to something a buyer could be
   given (micro-org#407). The check prints this itself.
3–6. Four faces of ONE fact: `the observed run is drift_exceeded`, `EMBER is
   still frozen after a clean run`, `after restoring the custody set the run is
   indexer/drift_exceeded`, `the post-600s run recorded indexer/drift_exceeded`.
   **This is the parallel-run drift and the cutover closes it.** The cluster's
   ledger came from a dump taken while compose kept trading; its indexer watches
   the same live chain compose does. The books are therefore behind the chain by
   exactly the traffic that has happened since the dump. Cutover step 1 takes the
   dump with compose STOPPED, which is what makes the two agree.

### Testnet's five, over compose

Everything else in testnet's 59 reproduces verbatim under compose — including
the whole `401 unauthenticated` cluster, which is micro-org#472: all 28 testnet
services carry `IDENTITY_JWKS_URL`/`IDENTITY_URL` pointing at the SHARED MAINNET
identity while the suite mints its token at testnet's own. That predates the
migration by months. The five that do not reproduce:

- **22 web surfaces answer `302` where compose answers `200`.** Not a defect on
  either side — both fail the check. `CF_WEB_RETIRED=true` in
  `compose/env/traefik.testnet.env` makes the TESTNET gateway render
  `cf-retired-web-sub` and `cf-retired-web-apex`, which redirect every testnet
  frontend to its mainnet equivalent (micro-org#459 step 5). It has been true
  since that shipped. `estate-verify.sh` **has no reader of `CF_WEB_RETIRED`**
  and has never known the frontends are retired, so it asserts a shell that is
  deliberately not served. The 302 is the retirement working.
- **`no gateway on https://…:443`.** Same cause: the liveness probe is
  `gw "hub$WEB_SUFFIX" /healthz`, and on testnet `hub-testnet…` is one of the
  names the retirement redirects. The gateway is up; the probe asks a retired
  name.
- **`testnet.cloudsforge.online answered 302`** appeared only once cluster DNS
  started answering it. Same retirement, apex router.
- **`no backup_last_verified_unixtime`.** Here Kubernetes is AHEAD: compose fails
  this as `NO backup-runner container in project cf-testnet` because testnet has
  never had one at all.
- **`app` not declared in `initdb.sql`** — the same pre-existing divergence as
  mainnet's, surfacing on both.

**Two fixes for `estate-verify.sh` fall out of this and are not migration work:**
teach it to read `CF_WEB_RETIRED` and skip the 25 web-surface assertions and the
`/healthz` probe when a network's frontends are retired; and stop asserting a
testnet shell that the estate deliberately redirects away.

### After steps 3–5, and the ten failures that are the tunnel

Measured on mainnet 2026-08-19, on a cluster left alone for several minutes
after the cutover — `cloudsforge-estate` 53/53 and `cf-testnet` 55/55 ready,
nothing applied since: **11 failures in a 276-line run, and ten of them have one
cause.** Every check that addresses the cluster passed. The eleven are item 1
above (`app` not in `initdb.sql`) plus these ten:

```
FAIL foresight: https://foresight.cloudsforge.online/markets?…  answered 502 (gateway)
FAIL market.listings:   https://api.cloudsforge.online/v1/listings     answered 502 (gateway)
FAIL market.collections: https://api.cloudsforge.online/v1/collections answered 502 (gateway)
FAIL worlds.titles:     https://api.cloudsforge.online/v1/titles       answered 502 (gateway)
FAIL status page:       https://status.cloudsforge.online/api/status/public answered 502
FAIL mint.tokens / community / nda.worlds / billing.products:
       needs the operator to be signed in and this run has no token
```

All ten come from ONE section — `THE PAGES HAVE SOMETHING ON THEM`, which does
not curl anything itself but shells out to `scripts/estate-seed.mjs --check`.
**That subprocess is the only part of the suite that still resolves the estate's
hostnames through PUBLIC DNS.** Between step 3 and step 6 those names point at
Cloudflare, and Cloudflare's origin is the compose estate step 3 stopped, so
every one of them is answered `502` by Cloudflare — confirmed from the VM:

```
https://api.cloudsforge.online/v1/listings   HTTP 502  server: cloudflare
```

The four "no token" lines are the same fault one hop earlier: `login()` in
`scripts/seed/lib.mjs` posts to `IDENTITY_BASE`, which is
`https://nimbus.cloudsforge.online`. No token, so the four authenticated reads
are refused rather than attempted. They are not four faults; they are the fifth
502 with its status code swallowed.

**Step 6 is the fix, and clearing them is step 6's proof.** Nothing here needs
changing.

#### But the same gap made those ten checks PASS for the wrong reason

Worth writing down, because it cuts the other way and is the more dangerous
half. `k8s-estate-verify.sh`'s own header says of the seeder's addresses:

> Eleven of its entries are https hostnames and survive the runtime change
> untouched.

That is false in both directions. Before step 3, those eleven names also
resolved through public DNS — to the **compose** estate, which was up and
answering. So every pre-cutover cluster run reported those ten surfaces green
**having never addressed the cluster at all**. The rest of the suite is pinned:
`gw()` uses `--resolve` onto the gateway's ClusterIP, and the 26 service URLs
are exported as ClusterIPs. This one subprocess is not, and it is the section
whose entire reason for existing is catching surfaces that are up and empty.

It cannot be fixed the way `gw()` was. `estate-seed.mjs` uses Node's global
`fetch`, which has no `--resolve`: pinning it needs either an undici dispatcher
with a custom `lookup` (undici is not importable from a bare Node, and the
seeder's Node is a pinned tarball `scripts/node-tool.sh` fetches into `.tools/`),
or `/etc/hosts` entries on the VM — which is host state outside the repo, the
thing `k8s-cluster-dns.sh` exists to keep in one place. Deliberately NOT done
during the cutover; recorded in "What is not finished".

---

## What is not finished

Honest list, as of 2026-08-19:

- **The cutover itself**, below. Nothing public points at the cluster.
- **Nothing is on `main`.** All of this is branch `migration/kubernetes`, and it
  merges when the migration is complete and verified — not before.
- **`scripts/gateway-reload.sh --validate|reload` is compose-only.** It runs
  `docker exec` against a gateway container and `docker compose up -d gateway`,
  neither of which exists here. The cluster's equivalent of `reload` is already
  covered — `k8s-gateway.sh` stamps the dynamic files' content hash onto the pod
  template, so a changed file is a new pod deterministically, which is stronger
  than a reload. What has no equivalent is `--validate`: checking a Traefik config
  is loadable *before* replacing the live one. That wants a throwaway Pod running
  the same image over the candidate ConfigMap, and it does not exist yet. Until it
  does, a broken dynamic file is caught by the new pod failing its readiness
  probe — the old pod is already gone by then, because the strategy is `Recreate`.
- **No `stratum-endpoint` in the cluster.** Equivalent to today while
  `CF_STRATUM_PUBLISH` is off, and a real gap the day hardware miners are meant to
  dial in. See cutover step 3 for why it was never rendered and what it would take.
- **`estate-seed.mjs --check` is not pinned to the cluster.** The one part of the
  suite that still resolves the estate's hostnames through public DNS, so its ten
  assertions answer about whatever the tunnel currently points at rather than
  about this cluster. Measured in both directions — green pre-cutover off the
  compose estate, ten 502s between steps 3 and 6. Argued in full under "After
  steps 3–5" above, including why `--resolve` is not available to it. This is the
  section that exists to catch surfaces that are up and empty, so it is the worst
  one to have unpinned.

Closed since the first draft of this list: host aliases (superseded by
`scripts/k8s-cluster-dns.sh`, which gives CoreDNS a zone per namespace instead of
per-pod `hostAliases`); the full `estate-verify.sh` run, which is the section
above; and the drift guards, which are the section below.

### Smaller items noticed on the way

- `compose/docker-compose.backup.yml` still comments a `coinbase-key.json` that
  no longer exists under that name.
- `compose/env/chain.mainnet.env`'s header claims "Compose v5.1.1"; the host
  reports `2.40.3-desktop.1`.
- Eight `.bak` token files on the app host, plus three duplicated keys in
  `tokens.testnet.env`.
- `loki` runs `runAsUser: 0`; it probably does not need to.
- `cloudflared-metrics.cf-edge` exports metrics that nothing scrapes.
- `prometheus/rules/alerts.test.yaml` has no `BackupNeverRun` case at all.
- Mainnet's `traefik.env` sets `CF_EXPLORER_INDEX_UPSTREAM` and
  `CF_VERIFY_UPSTREAM` even though mainnet runs no devkit, so those routers
  exist and 502. **Operator's call** whether to remove them.

---

## The drift guards

The migration's one structural cost is that **the compose file stops being the
deploy**. Under compose, editing `compose/docker-compose.estate.yml` IS the
deploy: the next `release-deploy.sh` reads the edited file, and there is no
second artefact that can disagree with it. Under Kubernetes the compose file
becomes a *source*, and what gets applied is a generated tree.

So an edit that is not re-rendered is an edit that is written, reviewed, merged —
and never deployed. Worse, `k8s-deploy.sh` reports a completely green deploy of
the previous shape, because from its side nothing is wrong: the manifests it
applied are the manifests it was given.

Three scripts close that. Each **regenerates and compares bytes** rather than
comparing structure, so anything a generator would emit differently, for any
reason, fails — not only the cases somebody thought to check for.

| Script | Regenerates | Catches |
|---|---|---|
| `check-k8s-databases-match-initdb.py` | `k8s/database/21-databases-*.yaml` from `compose/estate/initdb.sql` | a database in one and not the other — a migration Job connecting to a database that was never created |
| `check-k8s-render-matches-compose.py` | `k8s/estate/{mainnet,testnet}/` from the compose file + `render-vars.<network>.yaml` | a new env var read as absent by every `env.ts`; a changed healthcheck port leaving the ClusterIP behind so the gateway 502s while healthy; a new service with no Deployment while `kubectl get deploy` says 51 of 51 |
| `check-k8s-gateway-matches-compose.py` | nothing — it compares the two gateway definitions directly | a version bump on one side; an argument added to one gateway only; a middleware missing from the `tunnel` chain, which nothing local drives; an entrypoint with no Service port; a certificate filename that `tls.yml` and `k8s-gateway.sh` disagree about |

Run them together:

```sh
make check-k8s          # also part of `make check`
```

They are in CI as the **`k8s` job**, which checks out `micro-org` at `path: org`
beside `deploy` because the renderer resolves images from a release manifest.
A separate job from `drift`: a different checkout set, a different question, and
running in parallel means the k8s answer arrives whether or not `drift`'s pnpm
install succeeded.

**Two deliberate holes, both stated in the scripts:**

- **Cutting a release does not turn the render guard red.** It re-renders against
  the release each tree *names in its own header* — the same line `k8s-deploy.sh`
  reads — not against the newest one. A check that is red by default is a check
  nobody reads. What catches a forgotten re-render is the deploy naming a release
  the operator did not expect.
- **The gateway guard does not read `gateway/dynamic/*.yml` as routing.** That is
  `surface-routes.py`'s much larger job. Those files are *mounted* by both
  platforms — `k8s-gateway.sh` rebuilds the ConfigMap from the directory on every
  apply — so they cannot drift between the two. What can drift is everything
  around them.

Every difference between the two gateways' argument lists must be declared in
`ARG_TRANSLATIONS`, with the reason. There is exactly one today: the OTLP
endpoint, which needs an FQDN now that the collector lives in `cf-telemetry`
rather than on the shared `app` network.
