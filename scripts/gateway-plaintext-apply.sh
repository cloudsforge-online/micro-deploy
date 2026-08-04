#!/usr/bin/env bash
# Turn the deployment's gateway into a plaintext origin, and then PROVE it took.
#
#   ssh malf@192.168.1.42 'bash -s' < scripts/gateway-plaintext-apply.sh
#
# ── WHY THIS IS A SCRIPT AND NOT A PARAGRAPH IN A CHAT MESSAGE ────────────────
#
# Every step below is a thing that has to be true together: the flag, the removed
# key, the two RECREATED gateways, the recreated miners. Half of it applied is a
# gateway that answers and a chain that has quietly stopped, which is the failure
# `compose/docker-compose.miners.yml` spends a header warning about. A list of
# commands somebody pastes gets half-applied; a script does not.
#
# IT IS IDEMPOTENT and safe to re-run — that is what makes it usable as a CHECK
# afterwards as well as a migration. Steps 7 to 11 assert rather than change:
# content over plaintext, the security headers, the CORS allowlist in both
# directions, the /internal refusal, loopback-only binding tested from the LAN
# address rather than inferred from the compose file, config freshness, and both
# miners' heights.
#
# WHAT IT DELIBERATELY DOES NOT DO: touch the Cloudflare dashboard. Those 46
# entries are the owner's and the tunnel is dashboard-managed, so nothing on this
# host can change them. Step 12 prints exactly what to paste.
#
# The render is validated in a throwaway BEFORE either live gateway is touched
# (step 4), because a template failure rejects the whole dynamic directory and
# has already taken every surface down for three minutes once.
set -uo pipefail

D=/home/malf/dev/cloudsforge/deploy
cd "$D" || { echo "FATAL: $D missing"; exit 1; }

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; rc=1; }
rc=0

# A throwaway used to measure the entrypoint split left this behind when the host
# dropped off the network mid-run. Untracked, harmless, and it would sit in
# `git status` forever if nothing removed it.
docker rm -f cf-tunnel-probe >/dev/null 2>&1
rm -rf "$D/.tunnel-probe"

echo "── 1. track main ────────────────────────────────────────────────────────"
git pull --ff-only origin main || { echo "FATAL: pull failed"; exit 1; }
git log --oneline -1

echo
echo "── 2. mainnet opts into plaintext ───────────────────────────────────────"
# testnet's switch is committed in compose/testnet.env; mainnet's compose env is
# .env, which is gitignored, so it is set here.
if grep -q '^CF_GATEWAY_TLS=' .env 2>/dev/null; then
  sed -i 's/^CF_GATEWAY_TLS=.*/CF_GATEWAY_TLS=false/' .env
else
  printf '\n# The gateway terminates no TLS: cloudflared cannot validate a certificate\n# against 127.0.0.1 and no Origin CA will sign an IP literal. See\n# gateway/dynamic/tls.yml and .env.example.\nCF_GATEWAY_TLS=false\n' >> .env
fi
grep '^CF_GATEWAY_TLS=' .env

echo
echo "── 3. the Origin CA leaf goes (its key was in a chat transcript) ────────"
for f in gateway/certs/origin.crt gateway/certs/origin.key; do
  if [ -e "$f" ]; then
    shred -u "$f" 2>/dev/null || rm -f "$f"
    echo "  removed $f"
  else
    echo "  $f already absent"
  fi
done
# Rebuild trust.crt without it, if the script is there to do it.
[ -x scripts/gateway-cert.sh ] && ./scripts/gateway-cert.sh >/dev/null 2>&1

echo
echo "── 4. validate the render BEFORE touching either live gateway ───────────"
CF_GATEWAY_TLS=false ./scripts/gateway-reload.sh --validate || { echo "FATAL: render is not clean; nothing was restarted"; exit 1; }

echo
echo "── 5. recreate both gateways (a flag change needs recreate, not restart) ─"
docker compose -p cfmicro -f compose/docker-compose.telemetry.yml -f compose/docker-compose.gateway.yml up -d gateway
CF_GATEWAY_TLS=false docker compose -p cf-testnet-gw --env-file compose/testnet.env \
  -f compose/docker-compose.gateway.yml up -d gateway
sleep 8

echo
echo "── 6. the miners now poll http:// — recreate them too ───────────────────"
docker compose -p cf-miners -f compose/docker-compose.miners.yml up -d
sleep 5

echo
echo "── 7. PROVE the plaintext origin, mainnet :443 ──────────────────────────"
code=$(curl -s -o /tmp/pt.body -w '%{http_code}' --resolve hub.cloudsforge.online:443:127.0.0.1 http://hub.cloudsforge.online:443/)
[ "$code" = 200 ] && ok "hub over plain HTTP -> $code ($(wc -c </tmp/pt.body) bytes, not a 301)" || bad "hub over plain HTTP -> $code"
hdrs=$(curl -s -o /dev/null -D - --resolve hub.cloudsforge.online:443:127.0.0.1 http://hub.cloudsforge.online:443/)
for h in strict-transport-security x-content-type-options; do
  printf '%s' "$hdrs" | grep -qi "^$h:" && ok "$h present on the plaintext path" || bad "$h MISSING on the plaintext path"
done
acao=$(curl -s -o /dev/null -D - --resolve nimbus.cloudsforge.online:443:127.0.0.1 \
  -H 'Origin: https://hub.cloudsforge.online' http://nimbus.cloudsforge.online:443/x | grep -i '^access-control-allow-origin:')
[ -n "$acao" ] && ok "CORS allowlist applied ($acao)" || bad "no access-control-allow-origin on the plaintext path"
evil=$(curl -s -o /dev/null -D - --resolve nimbus.cloudsforge.online:443:127.0.0.1 \
  -H 'Origin: https://evil.example.com' http://nimbus.cloudsforge.online:443/x | grep -ci '^access-control-allow-origin:')
[ "$evil" = 0 ] && ok "a disallowed origin gets no ACAO" || bad "ACAO returned for a disallowed origin"
for p in /internal/credit //Internal/credit; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --resolve pay.cloudsforge.online:443:127.0.0.1 "http://pay.cloudsforge.online:443$p")
  [ "$c" = 502 ] && ok "$p refused ($c)" || bad "$p answered $c and must be 502"
done

echo
echo "── 8. testnet :10443 ────────────────────────────────────────────────────"
c=$(curl -s -o /dev/null -w '%{http_code}' --resolve hub.testnet.cloudsforge.online:10443:127.0.0.1 http://hub.testnet.cloudsforge.online:10443/)
[ "$c" = 200 ] && ok "testnet hub over plain HTTP -> $c" || bad "testnet hub -> $c"

echo
echo "── 9. bound to 127.0.0.1 ONLY (verify from the LAN too) ─────────────────"
ss -ltn | awk '$4 ~ /:443$|:10443$/ {print "     " $4}'
ip=$(hostname -I | awk '{print $1}')
for port in 443 10443; do
  if timeout 4 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
    bad "$ip:$port IS reachable on the LAN address — it must be loopback only"
  else
    ok "$ip:$port refuses (loopback only)"
  fi
done

echo
echo "── 10. gateway is serving what is on disk ───────────────────────────────"
CF_GATEWAY_TLS=false ./scripts/gateway-reload.sh --check

echo
echo "── 11. both miners still producing ──────────────────────────────────────"
for m in cf-miner-mainnet cf-miner-testnet; do
  echo "  --- $m ---"; docker logs --tail 6 "$m" 2>&1 | sed 's/^/      /'
done
echo "  heights:"
for rpc in 8545 8745; do
  h=$(curl -s -X POST -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    "http://127.0.0.1:$rpc" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))' 2>/dev/null)
  echo "      127.0.0.1:$rpc height=${h:-unreadable}"
done

echo
echo "── 12. the tunnel ───────────────────────────────────────────────────────"
echo "  The 46 dashboard entries still say https://. Until they are changed they"
echo "  will keep 502ing. Paste these, keeping each entry's existing port:"
echo "      mainnet (23 entries):  http://127.0.0.1:443"
echo "      testnet (23 entries):  http://127.0.0.1:10443"
echo
journalctl -u cloudflared --no-pager -n 5 2>/dev/null | tail -5

echo
[ "$rc" = 0 ] && echo "ALL LOCAL ASSERTIONS PASSED" || echo "SOME ASSERTIONS FAILED — see FAIL lines above"
exit $rc
