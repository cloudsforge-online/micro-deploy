#!/usr/bin/env bash
# Install the three chain-daemon units on the chain host. Idempotent, and it
# NEVER starts, stops or restarts a daemon - `enable` only.
#
# That restraint is the point. The three nodes hold ~1.25 TB between them and
# back every UTXO surface on the estate; installing supervision is not a reason
# to bounce them. Run this, then let the next reboot - or a deliberate,
# announced restart of ONE node - be the first time a unit actually starts
# anything.
#
#   scp -r systemd malf@<chain-host>:/home/malf/cf-systemd
#   ssh malf@<chain-host> 'sudo bash /home/malf/cf-systemd/install-chain-units.sh'
#
# Copy to /home/malf, not /tmp: this host's /tmp is not somewhere an operator
# should be leaving anything, and a private-tmp'd service cannot read it anyway.
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UNIT_DIR=/etc/systemd/system
HELPER_DIR=/usr/local/lib/cloudsforge
DOC_DIR=/etc/cloudsforge
UNITS=(bitcoind.service litecoind.service dogecoind.service)

[ "$(id -u)" -eq 0 ] || { echo "install-chain-units.sh: run me as root" >&2; exit 1; }

install -d -m 0755 "$HELPER_DIR" "$DOC_DIR"

# install(1) rather than a redirect into `tee`, deliberately. `echo "$PW" | sudo -S tee f`
# writes the SUDO PASSWORD into f and exits 0, which is a silent way to install
# a credential where a config belongs. A path argument cannot do that, and the
# cmp below proves the file arrived rather than assuming it.
install -m 0755 "$SRC/wait-for-rpcbind" "$HELPER_DIR/wait-for-rpcbind"
cmp -s "$SRC/wait-for-rpcbind" "$HELPER_DIR/wait-for-rpcbind" \
  || { echo "install-chain-units.sh: wait-for-rpcbind did not copy intact" >&2; exit 1; }

install -m 0644 "$SRC/README.md" "$DOC_DIR/README.systemd.md"

for u in "${UNITS[@]}"; do
  install -m 0644 "$SRC/$u" "$UNIT_DIR/$u"
  cmp -s "$SRC/$u" "$UNIT_DIR/$u" \
    || { echo "install-chain-units.sh: $u did not copy intact" >&2; exit 1; }
done

# Refuses to go further on a unit systemd will not parse, so a typo is caught
# here and not at 04:00 by an operator who has just rebooted.
systemd-analyze verify "${UNITS[@]/#/$UNIT_DIR/}"

systemctl daemon-reload
systemctl enable "${UNITS[@]}"

echo
echo "installed and enabled; NOT started. Current state:"
systemctl --no-pager --no-legend list-unit-files "${UNITS[@]}"
for u in "${UNITS[@]}"; do
  printf '%-20s enabled=%-10s active=%s\n' "$u" \
    "$(systemctl is-enabled "$u" 2>&1)" "$(systemctl is-active "$u" 2>&1)"
done
echo
echo "'active=inactive' beside a running hand-started daemon is EXPECTED and is"
echo "the state this script leaves behind. Prove it with: ps -eo pid,args | grep coind"
