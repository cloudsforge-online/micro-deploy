# The whole public estate is 502, or nothing answers at all

**Triggered by** the `Uptime` scheduled workflow failing (`.github/workflows/uptime.yml`)
**Severity** SEV1 - page · **Owner** platform

## What it means

Every public hostname is probed from a GitHub runner every fifteen minutes by
`scripts/probe-public-estate.py`. The workflow fails when a hostname stops
answering — a 5xx, a refused connection, a TLS failure or a timeout. A 401, 403,
404 or 405 is an answer and does not fail.

If the failure list is **every hostname in both environments**, this is not a
service. It is the app host, the Docker engine on it, or the tunnel out of it.
That has happened once, on 2026-08-11, and it lasted thirty-five minutes because
nothing was watching from outside — which is why this workflow exists.

## The first thing to check, because it is the thing that happened

The app host is `savva@192.168.1.129`, Windows, with the estate inside
`wsl -d Ubuntu-24.04`. **Docker Desktop is a desktop application.** It requires
an interactive Windows session. After an unattended reboot there is none, so the
engine does not start, every container stays down, and Cloudflare answers 502 on
behalf of a tunnel with nothing behind it.

Is there an engine at all:

```powershell
docker version --format "{{.Server.Version}}"
```

An error naming the pipe or the socket means the engine is not running.

## Restoring the engine over SSH, which is not obvious

```powershell
Start-Service com.docker.service
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
  CommandLine = '"C:\Program Files\Docker\Docker\Docker Desktop.exe" -Autostart'
}
# wait ~60s, then:
docker version --format "{{.Server.Version}}"
```

**`Start-Process` and `docker desktop start` both appear to crash it.** They do
not. Windows OpenSSH kills the whole process tree when the session ends, so the
engine dies the instant the SSH command returns and the next connection finds
nothing. `Invoke-CimMethod … Win32_Process Create` parents the process to WMI
instead, and it survives.

Then give WSL a minute: the Docker integration injects `/usr/bin/docker` and the
socket into the distro AFTER the engine is up. A container inventory run too
early reports the engine down when it is not. It appeared about thirty seconds
behind the engine on 2026-08-11.

Containers should come back on their own — every long-running service in the
estate carries a restart policy, and `scripts/check-restart-policy.py` fails CI
if one does not. If they do not, deploy the current release rather than running
`docker compose up`: see `runbook-rollback-release.md` for why a bare `up` is
never the right command here.

## If the engine is up and hostnames are still dead

Work outward:

1. **The gateway** — `docker ps` for the Traefik container in both projects
   (`cloudsforge-estate` and `cf-testnet`). One project down and the other up
   shows as one environment's twenty-five hostnames failing and not the other's.
2. **The tunnel** — `cloudflared`. If the gateway is healthy and Cloudflare
   still answers 502, the tunnel is not registered. `check-tunnel-origin.sh`.
3. **A single surface** — one hostname failing while the other forty-nine answer
   is a service, not the host. Go to that service's own runbook.

## Why the monitors did not tell you

Prometheus, Alertmanager, blackbox and beacon all run **as containers on the
host they monitor**. In a host-level outage they are down too, and a monitor
that is gone reports nothing — which is indistinguishable from a monitor with
nothing to report. Do not wait for a page from inside the estate during an
estate-wide outage; there will not be one. That is micro-org#431.

## After it is back

Confirm from outside, not from the host:

```bash
python3 scripts/probe-public-estate.py
```

Fifty hostnames, about eight seconds. Then run `scripts/estate-verify.sh` from
beside the estate for what the surfaces actually say, which this deliberately
does not check.
