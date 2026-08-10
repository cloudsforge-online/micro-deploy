#!/usr/bin/env bash
# Is there a gateway on the port the TUNNEL sends this environment's traffic to?
#
#   ./scripts/check-tunnel-origin.sh mainnet
#   ./scripts/check-tunnel-origin.sh testnet
#
# ── WHY, WHEN THE MAKEFILE ALREADY DOCUMENTS THIS FAILURE ─────────────────────
#
# Because it documents it, and it happened again. `Makefile:117` carries a
# thirty-line header written on 2026-08-05 explaining that nothing was listening
# on 127.0.0.1:9181 and that every `*-testnet` hostname therefore answered 502.
# It ends by saying the fix is a target "because a gateway that lives only in an
# operator's shell history is the same defect".
#
# On 2026-08-08 `cftestnet-gateway-1` was gone again and every testnet hostname
# was 502 for the second time. The target existed. The header existed. Neither is
# a check, and a comment describing a failure prevents nothing.
#
# ── AND WHY IT LOOKED LIKE AN ORPHAN, WHICH IS THE REAL DEFECT ────────────────
#
# The gateway that serves testnet is in compose project `cftestnet`. The 46
# services it serves are in project `cf-testnet`. ONE HYPHEN. So:
#
#   docker compose -p cf-testnet ps            <- does not list the gateway
#   docker compose -p cf-testnet ... --remove-orphans
#                                              <- cannot see it either, luckily
#
# which means the container that every public testnet hostname depends on
# presents itself, to anybody auditing the environment, as an unclaimed container
# belonging to no stack. Removing it is the reasonable conclusion from what
# `docker ps` shows.
#
# MAINNET HAD THE SAME DEFECT AND WORSE ODDS — `cfmicro` is not one hyphen from
# `cloudsforge-estate`, it is a different word — and it was the gateway carrying
# live traffic. Fixed on 2026-08-10: that gateway is `cloudsforge-estate-gateway-1`
# in project `cloudsforge-estate` now, and the `owner` line this script prints at
# the end is what proves it on any given day. Testnet's rename is still open
# (micro-org#257); until it lands, this check is what notices there.
#
# ── WHAT IT ASSERTS ───────────────────────────────────────────────────────────
#
# One thing, the thing that was false both times: that a request arriving the way
# cloudflared sends one — plaintext, to the loopback tunnel entrypoint, carrying
# this environment's Hub in the Host header — is answered by a gateway that has
# a route for it. Not "a container is healthy". The 46 services were healthy
# throughout both outages; health is what made the outage invisible.
#
# It reads no compose file and interpolates nothing. Like check-handoff-live.sh,
# it observes the running system, so it holds however the gateway got there and
# stays true when the next deploy path is invented.
#
# Prints hostnames, ports and HTTP status codes. No secret of any kind.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

env_name="${1:-mainnet}"
case "$env_name" in
  mainnet)  env_file=compose/mainnet.env; traefik_env=compose/env/traefik.env ;;
  testnet)  env_file=compose/testnet.env; traefik_env=compose/env/traefik.testnet.env ;;
  *) echo "usage: check-tunnel-origin.sh [mainnet|testnet]" >&2; exit 2 ;;
esac

read_var() { grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' '; }

# `CF_GW_PORT_BASE` is unset for mainnet on purpose — see the run of ports in
# docker-compose.gateway.yml, where 9090-9099 is fully allocated on the mainnet
# base and only testnet has room. The default here must match the default there.
base=$(read_var "$env_file" CF_GW_PORT_BASE); base=${base:-90}
port="${base}81"
suffix=$(read_var "$traefik_env" CF_WEB_SUFFIX)
if [ -z "$suffix" ]; then
  echo "FATAL: $traefik_env defines no CF_WEB_SUFFIX, so this check cannot name a" >&2
  echo "       hostname to ask for and would pass against any gateway at all." >&2
  exit 1
fi
host="hub${suffix}"

probe() { curl -s -o /dev/null -m 10 -w '%{http_code}' -H "Host: $2" "http://127.0.0.1:$1/" 2>/dev/null; }

# ── THE CANARY, FIRST, BECAUSE A PROBE THAT CANNOT FAIL PROVES NOTHING ────────
#
# If `curl` were missing, or `-m` unsupported, or the status format wrong, every
# call below would return an empty string and the comparison further down would
# be a comparison of two empty strings. So probe a port chosen to be closed and
# require the probe to say so. 1 is privileged, unbindable by anything in this
# estate, and reserved — if something IS listening there, this check refuses to
# run rather than reporting on machinery it cannot trust.
canary=$(probe 1 "$host")
if [ "$canary" != "000" ]; then
  echo "FATAL: the canary probe of a closed port returned '$canary', not 000." >&2
  echo "       This check cannot distinguish 'answered' from 'did not answer', so its" >&2
  echo "       verdict on the real port would be meaningless. Refusing to give one." >&2
  exit 1
fi

# ── A GATEWAY THAT HAS JUST STARTED HAS NOT LOADED ITS ROUTES YET ────────────
#
# Both `make` targets run this immediately after `docker compose up -d gateway`,
# and `up -d` returns when the container is STARTED, not when Traefik has read
# its providers. Measured on the app host on 2026-08-10, bringing the testnet
# gateway up cold: this check printed the 404 verdict below — "something is
# bound to this environment's tunnel entrypoint and it is not this
# environment's gateway" — against the gateway it had itself just started, and
# the same hostname answered 200 a second later. A false alarm at the exact
# moment an operator is looking at a real one is worse than no check.
#
# So retry, briefly, and only while the answer is still a failing one. A genuine
# outage is delayed by twenty seconds and reported with the same words; a
# gateway still waking up gets those seconds and reports ok. The `000` case
# retries too — the container may be started and not yet listening — but nothing
# retries the canary, which is about this script's own machinery rather than the
# estate's.
for _ in $(seq 1 10); do
  code=$(probe "$port" "$host")
  case "$code" in 2*|3*) break ;; esac
  sleep 2
done

if [ "$code" = "000" ]; then
  echo "FATAL: NOTHING IS LISTENING ON 127.0.0.1:$port." >&2
  echo "       That is where cloudflared sends every ${env_name} hostname, and it reports an" >&2
  echo "       unreachable origin as 502. Every public ${env_name} surface is down RIGHT NOW —" >&2
  echo "       hub, worlds, market, explorer, status, api and account alike — while every" >&2
  echo "       service container behind it reports healthy, which is why nothing else notices." >&2
  echo >&2
  if [ "$env_name" = "testnet" ]; then
    echo "       start it:  make estate-gateway-testnet" >&2
  else
    echo "       start it:  make estate-gateway" >&2
  fi
  exit 1
fi

# A gateway is answering. Is it THIS environment's? A gateway with no router for
# the host answers 404 from its own default backend, which is the failure mode
# when two environments' ports are crossed — reachable, wrong, and 200 nowhere.
case "$code" in
  2*|3*) ;;
  404)
    echo "FATAL: 127.0.0.1:$port answers, but has NO ROUTE for $host (404)." >&2
    echo "       Something is bound to this environment's tunnel entrypoint and it is not" >&2
    echo "       this environment's gateway. Public $env_name traffic reaches it and is" >&2
    echo "       refused by a stranger — a 404 the tunnel will not report as an outage." >&2
    exit 1 ;;
  *)
    echo "FATAL: 127.0.0.1:$port answered $code for $host." >&2
    echo "       The origin is reachable but not serving this estate's Hub." >&2
    exit 1 ;;
esac

owner=$(docker ps --filter "publish=$port" --format '{{.Names}} (project {{.Label "com.docker.compose.project"}})' 2>/dev/null | head -1)
echo "ok: $env_name tunnel origin 127.0.0.1:$port answers $code for $host${owner:+ — $owner}"
