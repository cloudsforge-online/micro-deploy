#!/usr/bin/env bash
# Install the app host's scheduled units. Idempotent.
#
#   sudo bash ~/dev/cloudsforge/deploy/systemd/install-app-units.sh
#
# ── THIS ONE STARTS WHAT IT ENABLES, AND install-chain-units.sh DELIBERATELY DOES NOT ─────────
#
# The difference is what is on the other end. That script supervises three daemons holding 1.25 TB
# of chain state behind every UTXO surface the estate has, so starting a unit there is a decision
# with a blast radius and belongs to an announced window. This one starts a TIMER. Nothing runs
# until the timer fires, the thing it eventually runs is a read-only comparison, and leaving it
# installed-but-not-started would reproduce micro-org#439 exactly: a mechanism that exists, is
# correct, and is never invoked.
#
# No scp step either — unlike the chain host, the app host has this checkout on it already,
# because it is the machine the estate is deployed from.
set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UNIT_DIR=/etc/systemd/system
DOC_DIR=/etc/cloudsforge
UNITS=(conformance-replay.service conformance-replay.timer)

[ "$(id -u)" -eq 0 ] || { echo "install-app-units.sh: run me as root" >&2; exit 1; }

install -d -m 0755 "$DOC_DIR"
install -m 0644 "$SRC/README.md" "$DOC_DIR/README.systemd.md"

# install(1) with a path argument rather than a redirect into `tee`. `echo "$PW" | sudo -S tee f`
# writes the SUDO PASSWORD into f and exits 0 — a silent way to put a credential where a config
# belongs — and `cmp` proves the file arrived rather than assuming it did.
for u in "${UNITS[@]}"; do
  install -m 0644 "$SRC/$u" "$UNIT_DIR/$u"
  cmp -s "$SRC/$u" "$UNIT_DIR/$u" \
    || { echo "install-app-units.sh: $u did not copy intact" >&2; exit 1; }
done

# A typo is caught here rather than at 04:30 by nobody, which is how a schedule goes missing.
systemd-analyze verify "${UNITS[@]/#/$UNIT_DIR/}"

systemctl daemon-reload
systemctl enable --now conformance-replay.timer

echo
echo "installed. The TIMER is enabled and started; the service itself runs when it fires:"
systemctl --no-pager --no-legend list-timers conformance-replay.timer || true
echo
echo "Run one now, without waiting for the schedule:"
echo "  sudo systemctl start conformance-replay.service && journalctl -u conformance-replay -n 40"
