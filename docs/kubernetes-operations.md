# Operating the estate on Kubernetes

The estate runs as **k3s on one Linux VM**. This file is how you start it, stop
it, deploy to it, survive a reboot, and move it to another machine.

It is deliberately separate from [`kubernetes-migration.md`](kubernetes-migration.md),
which is the *history*: why this shape was chosen, what the cutover did, what is
not finished. Read that when you want to know **why**. Read this when something
needs doing.

- **Deploys:** `./scripts/k8s-deploy.sh --network <net>`, run **on the VM**.
- **Not** `release-deploy.sh`. That is the compose estate, and it is stopped.

---

## The shape of it

```
                    ┌──────────────────────────────────────────┐
   public traffic   │  Cloudflare                              │
   ───────────────► │  21 hostnames → one tunnel               │
                    └───────────────────┬──────────────────────┘
                                        │ outbound only; no port is
                                        │ forwarded, nothing listens
                                        ▼
  ╔═════════════════════════════════════════════════════════════════════════╗
  ║  NICELY — Windows host, 192.168.1.129                                   ║
  ║                                                                         ║
  ║   Hyper-V ──► cf-lan (external switch, on the 2.5GbE NIC)               ║
  ║        │                                                                ║
  ║   ╔════▼════════════════════════════════════════════════════════════╗   ║
  ║   ║  cf-k8s — Ubuntu 26.04 VM, 192.168.1.171, k3s v1.36.3           ║   ║
  ║   ║                                                                 ║   ║
  ║   ║   cf-edge          cloudflared ×1   ◄── the public front door   ║   ║
  ║   ║        │                                                        ║   ║
  ║   ║        ├─► cloudsforge-estate   gateway + 52 svc + postgres     ║   ║
  ║   ║        │      (mainnet)         + backup runner                 ║   ║
  ║   ║        │                                                        ║   ║
  ║   ║        └─► cf-testnet           the same, + 2 hearth-devkit     ║   ║
  ║   ║                                                                 ║   ║
  ║   ║   cf-telemetry     prometheus alertmanager grafana loki tempo   ║   ║
  ║   ║   cnpg-system      the CloudNativePG operator                   ║   ║
  ║   ║                                                                 ║   ║
  ║   ║   wg0 = 10.10.0.3 ──────────────────────┐                       ║   ║
  ║   ╚═════════════════════════════════════════╪═══════════════════════╝   ║
  ║                                             │                           ║
  ║   still on Windows, NOT part of the estate: │                           ║
  ║     cf-miner-mainnet-apphost  (2nd EMBER coinbase)                      ║
  ║     cf-wg, freqtrade                        │                           ║
  ╚═════════════════════════════════════════════╪═══════════════════════════╝
                                                │ WireGuard
                                                ▼
                    ┌──────────────────────────────────────────┐
                    │  chain host — 192.168.1.42, 10.10.0.1    │
                    │  bitcoind · litecoind · dogecoind        │
                    │  (host processes, not containers)        │
                    └──────────────────────────────────────────┘
```

**Two namespaces are two whole estates**, not one estate with a testnet flag.
Same manifests, different `render-vars`, separate Postgres, separate secrets.
`cf-telemetry` and `cf-edge` are shared by both, once.

### Where state actually lives

Everything else is disposable; these are not.

| What | Where | Reclaim |
| --- | --- | --- |
| Postgres, both networks | PVC `postgres-1` (60Gi / 20Gi) + `postgres-1-wal` | **Retain** |
| Custody keys | PVC `custody-keys` | **Retain** |
| Studio / world assets | PVC `studio-assets`, `world-assets` | **Retain** |
| Telemetry history | 5 PVCs in `cf-telemetry` | **Retain** |
| Backups, both networks | `/srv/cloudsforge-backups` on the VM (hostPath) | n/a |
| Miner coinbase keys | `~/dev/cloudsforge/miner-keys/` on the VM | n/a |

Every estate PVC uses the **`cf-retain`** StorageClass, whose `reclaimPolicy` is
`Retain`. `local-path` is the cluster default and deletes on release — nothing
that matters is on it. This is the difference between `kubectl delete pvc` being
a recoverable mistake and being the end of the estate.

---

## First, the one rule

**Run `kubectl` on the VM, over ssh. Never from the Mac.**

```sh
ssh savva@192.168.1.171
```

The Mac's default kubectl context is `aks-editorai-sbx`, a live Azure work
cluster. A `kubectl delete` typed against the wrong context is not recoverable
by apologising. Three scripts enforce this rather than trusting it —
`k8s-deploy.sh` requires the node list to be exactly `cf-k8s`, and
`k8s-cluster-dns.sh` and `k8s-estate-verify.sh` require the API server to be
loopback.

There is no kubeconfig on the Mac for this cluster on purpose. Don't add one.

---

## Looking at it

```sh
# the whole estate, one line per namespace
for ns in cloudsforge-estate cf-testnet cf-telemetry cf-edge cnpg-system; do
  echo "$ns $(kubectl get pods -n $ns --no-headers | grep -c Running)/$(kubectl get pods -n $ns --no-headers | wc -l)"
done

# anything unhealthy, anywhere
kubectl get pods -A --no-headers | grep -v 'Running\|Completed'

# the full suite — mainnet takes ~4 min, testnet ~6
./scripts/k8s-estate-verify.sh            # mainnet
./scripts/k8s-estate-verify.sh testnet    # the network is POSITIONAL, not a flag
```

Healthy right now is **54/54**, **56/56**, **6/6**, **1/1**, **1/1**.

`k8s-estate-verify.sh` counts failures in colour, so count them like this or you
will get a false positive off the line that says `it FAILED CLOSED`:

```sh
./scripts/k8s-estate-verify.sh | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^ *//' | grep -c '^FAIL'
```

Baselines: mainnet **2–3**, testnet **59**. Both are explained in
[`kubernetes-migration.md`](kubernetes-migration.md) — they are pre-existing
content and verifier issues, not cluster faults. A number *above* the baseline
is the signal; the baseline itself is noise you have already paid for.

### Reaching a service with no public hostname

```sh
# Grafana
kubectl -n cf-telemetry port-forward svc/grafana 3000:3000
# Prometheus, through the API server proxy — no port-forward at all
kubectl -n cf-telemetry get --raw \
  '/api/v1/namespaces/cf-telemetry/services/prometheus:9090/proxy/api/v1/targets?state=active'
# Postgres
kubectl -n cloudsforge-estate exec -it postgres-1 -- psql -U cloudsforge
```

The gateway Service is **ClusterIP**. It is reachable from inside the cluster
and through the tunnel, and from nowhere else — including the VM's own LAN
address. That is intentional: the only front door is Cloudflare.

> `kubectl exec -i` eats your stdin. Drop `-i` and append `</dev/null` unless
> you actually mean to pipe something in.

---

## Starting and stopping

### The VM

```powershell
# on the Windows host
Get-VM cf-k8s                 # the one-line health check
Start-VM cf-k8s
Stop-VM cf-k8s                # graceful; Hyper-V asks the guest to power off
```

The VM is `AutomaticStartAction: Start` with a 30s delay, so **it comes back by
itself** and you should almost never need `Start-VM` by hand.

Do **not** use `Start-Process` to launch anything long-lived over ssh on the
Windows host — ssh kills the process tree when the session ends and the result
reads as a service flapping. Use a service, or `Win32_Process.Create`.

### One service

```sh
kubectl -n cloudsforge-estate rollout restart deploy/<name>
kubectl -n cloudsforge-estate rollout status  deploy/<name>
kubectl -n cloudsforge-estate logs deploy/<name> --tail=100
```

### A whole network, without destroying anything

Scaling to zero stops the pods and leaves every PVC, Secret and Service intact.
This is the stop you want; `kubectl delete` is not.

```sh
NS=cf-testnet
kubectl -n $NS scale deploy --all --replicas=0     # 53 Deployments
kubectl -n $NS patch cluster postgres --type merge -p '{"spec":{"instances":0}}'
```

Bringing it back:

```sh
kubectl -n $NS patch cluster postgres --type merge -p '{"spec":{"instances":1}}'
./scripts/k8s-deploy.sh --network testnet          # re-applies the declared replicas
```

Use `k8s-deploy.sh` rather than `scale --replicas=1` to come back up: the deploy
script applies in **waves**, and the wave order exists because 33 services run a
schema migration Job that 31 others depend on. Scaling everything up at once
starts every service against a schema that is not there yet — they crash-loop,
recover eventually, and in between the estate serves 500s while every dashboard
says the deploy succeeded.

### Stopping mainnet is a public outage

There is no second estate to fall back to. If you scale `cloudsforge-estate` to
zero, every public hostname 502s — cloudflared is still up and still registered,
pointing at services with no endpoints. Scale `cf-edge` to zero **first** if you
want an honest failure instead of a confusing one, and read the next section
before you touch it.

### The tunnel — the one thing to be careful with

`k8s/cloudflared/60-cloudflared.yaml` is the estate's **only** Cloudflare
connector. The app host's `Cloudflared` service is `Stopped` **and `Disabled`**,
and no other connector holds the token.

```sh
./scripts/k8s-cloudflared.sh --status     # read this before doing anything
./scripts/k8s-cloudflared.sh              # apply; refuses any manifest not at replicas: 1
```

`kubectl scale deploy/cloudflared --replicas=0` is not a safety measure. It is
the estate going dark, all 21 hostnames at once. The script refuses to apply a
manifest that does not say `replicas: 1` and waits for the connector to
*register with Cloudflare's edge* rather than merely be scheduled — a pod that
exists and a tunnel that is serving are different claims.

That assertion used to demand `replicas: 0`, back when the compose estate was
live and going public by accident was the hazard. The cutover inverted which
direction is dangerous and the guard was turned around to match.

---

## Deploying a release

Cutting a release is unchanged and still lives in [`releasing.md`](releasing.md):
`cfctl bump` in the org repo, immutable version tags, and the rule that **one
dirty checkout anywhere blocks the whole cut**. What changed is where it lands.

```sh
ssh savva@192.168.1.171
cd ~/dev/cloudsforge/org    && git pull          # release manifests live here
cd ~/dev/cloudsforge/deploy && git pull

# regenerate k8s/estate/** — BOTH flags are required, and without --outdir it
# writes to stdout rather than to the tree
./scripts/k8s-render.py --network mainnet \
    --release ../org/releases/<version>.yaml --outdir k8s/estate/mainnet
./scripts/k8s-render.py --network testnet \
    --release ../org/releases/<version>.yaml --outdir k8s/estate/testnet

git diff --stat k8s/                                # read what moved

./scripts/k8s-deploy.sh --network mainnet --dry-run
./scripts/k8s-deploy.sh --network mainnet
./scripts/k8s-deploy.sh --network testnet
```

**Pull `org` as well as `deploy`.** The renderer resolves images from
`../org/releases/<version>.yaml`; a stale `org` renders a stale estate and
reports success.

### The rendered tree is generated, and drift is silent

`k8s/estate/**` is **output**. Under compose, editing the compose file *was* the
deploy. Here it is a source: an edit that is not re-rendered gets written,
reviewed, merged, and never deployed — while `k8s-deploy.sh` reports a
completely green deploy of the previous shape. Three guards exist because that
failure is invisible:

```sh
python3 scripts/check-k8s-databases-match-initdb.py     # every DB initdb.sql creates
python3 scripts/check-k8s-render-matches-compose.py     # the rendered workloads, byte for byte
python3 scripts/check-k8s-gateway-matches-compose.py    # the gateway is the compose gateway
```

All three run in CI. Run them locally after touching `compose/`, `k8s/` or the
renderer. They compare against the release each tree **names in its own header**,
not the newest one, so cutting a release does not turn them red.

### Useful flags

| Flag | When |
| --- | --- |
| `--dry-run` | Always, first, on anything you have not done before. |
| `--rerun-migrations` | A migration Job failed and you fixed the cause. |
| `--wave 50` | Only the services; skip PVCs and migrators. |
| `--batch 0` | Apply wave 50 all at once instead of in batches. |
| `--hold a,b` | Do not start these — used at cutover for `settlement,beacon`. |
| `--no-hold` | Start everything including the held pair. |

---

## Rebooting

**This has been done, unattended, and it works.** On 2026-08-19 someone
restarted the Windows host from the Start menu with no preparation. Measured:

| UTC | |
| --- | --- |
| 08:28:00 | restart initiated on Windows |
| 08:28:16 | `hv_utils: Shutdown request received` — Hyper-V asks the guest to stop |
| 08:28:22 | VM powered off cleanly (`systemd-poweroff`, no crash, no forced kill) |
| 08:28:47 | Windows back up |
| 08:29:35 | `cf-k8s` autostarted — 48s later, the configured 30s delay plus boot |
| 08:30:06 | cloudflared Ready; public traffic restored |

**Total public outage: about 1 minute 50 seconds, with no human action.** All
five namespaces came back to full count, the WireGuard tunnel re-handshook, and
the Windows `Cloudflared` service stayed `Stopped`/`Disabled` — the interlock
holding exactly where it was supposed to.

Nothing here is a hand-crank because every piece is a service or an autostart
flag:

| Piece | Setting |
| --- | --- |
| `vmms` (Hyper-V) | Running, **Automatic** |
| `cf-k8s` | `AutomaticStartAction: Start`, 30s delay |
| `k3s.service` | enabled |
| `wg-quick@wg0` | enabled |
| `buildkit.service` | enabled, `After=k3s.service` |
| Windows `Cloudflared` | **Stopped, Disabled** — and must stay that way |

After any reboot, the check is the census plus one hostname:

```sh
kubectl get pods -A --no-headers | grep -v 'Running\|Completed'
sudo wg show wg0 latest-handshakes
curl -s -o /dev/null -w '%{http_code}\n' https://cloudsforge.online/
```

The 30s VM start delay is not decoration: it lets the external switch bind to
the physical NIC before the guest asks for a LAN address. Removing it trades 30
seconds for a VM that occasionally boots without networking.

---

## Moving it to another machine

The manifests are portable. **Seven things on the host are not**, and no
`kubectl apply` restores any of them. This is the rebuild list, in the order a
new machine needs them.

1. **k3s, with a raised pod ceiling.** `/etc/rancher/k3s/config.yaml`:
   ```yaml
   kubelet-arg:
     - max-pods=250
   ```
   The default is 110 and the steady state is ~104 before cloudflared,
   telemetry and the backup runner land. Over the ceiling nothing degrades —
   the *next* pod simply never schedules, which is much harder to notice. 250
   and not more because the podCIDR is a `/24`; a higher limit trades a
   scheduling error for IP exhaustion, the same outage with a worse message.

2. **WireGuard to the chain host.** `wg-quick@wg0`, enabled. The VM is
   `10.10.0.3`; the peer is `192.168.1.42:51820`, `allowed-ips 10.10.0.0/24`,
   keepalive 25. The chain host must also be told: an `rpcallowip=<new>/32` line
   in `bitcoin.conf`, `litecoin.conf` and `dogecoin.conf`, then **restart all
   three daemons** — `rpcallowip` is read at startup only. `litecoind` releases
   its datadir lock *after* the process disappears, so wait for the lock or the
   restart loses the race and leaves the node down.

3. **BuildKit against k3s's own containerd.** `/etc/buildkit/buildkitd.toml` and
   `/etc/systemd/system/buildkit.service` (`After=k3s.service`). The OCI worker
   is off; the containerd worker points at `/run/k3s/containerd/containerd.sock`,
   namespace `k8s.io`. `deploy/backup` is the one deployable with no published
   image, so the VM builds it — into the namespace the kubelet resolves from, so
   there is no registry, no push, and no pull to miss. Build into any other
   namespace and you get an image that exists and that no pod can use.
   `./scripts/k8s-backup-runner.sh --build` is the whole interface.

4. **The backup destination.** `/srv/cloudsforge-backups`, owner `1000:1000`,
   mode `700`. Owner and mode are load-bearing: Kubernetes will happily mount a
   root-owned hostPath, the pod starts, reports Ready, and fails its canary
   write — which reads as a backup fault rather than a permissions one. Both
   networks share this root. There is also a 100 GiB free-space floor enforced
   through `statfs`.

5. **The miner keys**, under `~/dev/cloudsforge/miner-keys/`: two
   `coinbase-keystore.json` and one `coinbase-passphrase`. Mounted read-only
   into the backup runner. Their absence is not raised as an error — the runner
   publishes `backup_secrets_included 0` and `MinerCoinbaseKeyUnbacked` fires.

6. **`gateway/certs/`** — `estate.crt` and `estate.key` (mode 600, untracked and
   correctly so). Without them the gateway still starts and answers on `:80`
   only, which looks exactly like a routing bug.

7. **`compose/estate/tokens.env` and `tokens.testnet.env`** — untracked host
   state, and the input to `scripts/k8s-secrets.py`. Note the one deliberate
   divergence: the VM's testnet file carries `CF_BACKUP_AGE_RECIPIENT` and the
   app host's never did, because testnet had no backup runner at all under
   compose.

Then, in order:

```sh
./scripts/provision-siblings.sh          # org, contracts, ui — under their required names

# secrets: --verify compares render-vars against the real file both ways and
# creates nothing; a bare run is a NAME-ONLY dry run, --apply is what writes
./scripts/k8s-secrets.py --network mainnet --verify
./scripts/k8s-secrets.py --network mainnet
./scripts/k8s-secrets.py --network mainnet --apply

./scripts/k8s-cluster-dns.sh
./scripts/k8s-deploy.sh --network mainnet --dry-run
./scripts/k8s-deploy.sh --network mainnet
./scripts/k8s-gateway.sh --network mainnet
./scripts/k8s-telemetry.sh --grafana-password-file <file>
./scripts/k8s-backup-runner.sh --build
./scripts/k8s-backup-runner.sh --network mainnet
# repeat the estate + gateway + backup-runner set for testnet, then last of all:
./scripts/k8s-cloudflared.sh
```

**`k8s-cloudflared.sh` goes last, always.** It is what makes the estate public,
and pointing the tunnel at a half-built estate serves 502s to real traffic.

Data comes across separately: restore Postgres from a backup set — see
[`estate-backup-restore.md`](estate-backup-restore.md) — and rsync
`/srv/cloudsforge-backups` **before** cutting over, not after, because the
database carries `succeeded` rows pointing at those directories and `verify`
runs daily against the newest one.

`scripts/k8s-db-import.sh` (`--rehearse` / `--cutover`) is **not** the general
tool for this. It copies from the *compose* host specifically, over ssh, and was
written for the one-way move that has already happened. For VM-to-VM, restore
from a backup set.

### Growing to more than one node

Nothing here assumes a single node, but two things would need attention before a
second one is useful: the backup destination is a **hostPath**, so it pins the
runner to whichever node holds the disk, and `cf-retain` is
`rancher.io/local-path`, which is node-local storage. Both are correct choices
for one node and both are the first things to change for two — real shared
storage, or a nodeSelector that is honest about the pinning.

Postgres is already on CloudNativePG rather than a hand-rolled Deployment
precisely so that `instances: 1 → 3` is a supported operation and not a rebuild.

---

## Rolling back to compose

The compose estate is stopped, not deleted, and can be brought back. **Order
matters, and it is the reverse of the cutover:**

```sh
# 1. on the WSL app host — bring the estate up FIRST
docker compose -p cloudsforge-estate start
docker compose -p cf-testnet start
#    (never add -v to a `down` here, and never `--remove-orphans` on devkit/miners)

# 2. on Windows
Start-Service Cloudflared

# 3. on the VM — only now
kubectl -n cf-edge scale deploy/cloudflared --replicas=0
```

Doing 3 before 1 leaves the tunnel registered and pointing at nothing. Two
connectors briefly overlapping is survivable; zero is not.

This gets worse to execute the longer it is left, because the cluster's Postgres
has been taking writes since 07:44 UTC on 2026-08-19 and the compose databases
have not. **A rollback after any real user activity is a restore, not a
`start`.** The honest window for this closed on the cutover day.

---

## When something is wrong

| Symptom | Look at |
| --- | --- |
| Every hostname 502 | `kubectl -n cf-edge get pods` — the connector. Then the gateway. |
| One surface 502, rest fine | That service's pod, then `gateway/dynamic/*.yml` for its router. |
| A surface serves the *wrong* app | Traefik router priority. Whole-host rules beat path rules — `vault` maps to custody for the entire host, so `vault/` 404ing from custody with a `requestId` is correct behaviour, not a routing fault. |
| Pod `Pending`, no events | The pod ceiling (`max-pods=250`) or a PVC that never bound. |
| Deploy green, estate serving 500s | A migration Job failed. `--rerun-migrations`. |
| Chain calls failing | `sudo wg show wg0 latest-handshakes`, then the chain host. Probe chain RPCs **from inside a container** — from the VM shell every `10.10.0.1` port times out, working ones included, so a dead port and a wrong namespace look identical. |
| `litecoind` "work queue depth exceeded" with idle workers | The node has wedged. Restart it; it is not load. |
| A surface looks broken but nothing is | Public hostnames are Cloudflare config and cannot be checked from this repo. Prove the origin with a `Host` header first. |

Two habits worth keeping:

- **Never print env values.** Print variable **names** only, and get them by
  cutting whole lines (`grep -n` then `cut -d= -f1`). Never `grep -o` — it
  re-anchors mid-line and emits value fragments that look like names. That is
  how four tokens leaked.
- **Never print a caught error from credential code.** Node's `fetch` puts the
  whole URL, credentials included, in the exception message.

---

## See also

- [`kubernetes-migration.md`](kubernetes-migration.md) — why this shape, what the
  cutover did, the verification baselines in full, and what is not finished.
- [`releasing.md`](releasing.md) — cutting a release. Its deploy half is compose
  and no longer describes the live estate.
- [`estate-backup-restore.md`](estate-backup-restore.md) — restoring a set.
- [`custody-backup-restore.md`](custody-backup-restore.md) — the custody keyring.
