#!/usr/bin/env bash
#
# Prepare the backup destination on the estate host. Run ONCE, as malf, before the runner starts.
#
#   ssh malf@192.168.1.42 'bash -s' < deploy/backup/setup-destination.sh
#
# It is idempotent and it creates nothing outside the two paths it names.
#
# ══════════════════════════════════════════════════════════════════════════════════════════════
# WHY THE DESTINATION IS TWO PATHS FOR ONE DIRECTORY.
#
# The bytes belong on /dev/sdb1 — a SECOND physical disk from the one holding the databases, which
# is the entire point: backups beside the thing they back up die with it. /dev/sdb1 is mounted at
# /data and has 1.4 TB free.
#
# But Docker on this host is the CANONICAL SNAP (29.3.1, rev 3505). Snap confinement grants the
# `docker:home` interface and NOT `removable-media`, so the daemon cannot see /data. A bind of
# `/data/cloudsforge-backups:/backups` does not fail — the container is given an empty directory in
# its own ephemeral layer, every write appears to succeed, and the artefacts are destroyed when the
# container stops. Measured on this host 2026-08-05: a canary written through a /data bind was
# absent from the host afterwards; the same write through /home/malf was present.
#
# So /data/cloudsforge-backups is bind-mounted at /home/malf/cloudsforge-backups, which snap docker
# CAN see, and the compose overlay binds that. The bytes still land on /dev/sdb1.
#
# `nofail` on the fstab entry, so a missing second disk can never stop this host from booting — the
# miner and the chain matter more than the backup runner starting.
# ══════════════════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SPINDLE_PATH=${SPINDLE_PATH:-/data/cloudsforge-backups}
VISIBLE_PATH=${VISIBLE_PATH:-/home/malf/cloudsforge-backups}
OWNER=${OWNER:-malf:malf}

echo "==> destination on the second spindle: $SPINDLE_PATH"
sudo install -d -o "${OWNER%%:*}" -g "${OWNER##*:}" -m 0700 "$SPINDLE_PATH"

echo "==> path snap-packaged Docker can see: $VISIBLE_PATH"
sudo install -d -o "${OWNER%%:*}" -g "${OWNER##*:}" -m 0700 "$VISIBLE_PATH"

FSTAB_LINE="$SPINDLE_PATH $VISIBLE_PATH none bind,nofail,x-systemd.requires-mounts-for=/data 0 0"
if grep -qF "$VISIBLE_PATH" /etc/fstab; then
  echo "==> /etc/fstab already carries the bind; leaving it alone"
else
  echo "==> adding the bind to /etc/fstab"
  echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
fi

# `findmnt --verify` before `mount -a`: a malformed fstab that is only discovered at the next reboot
# is a host that does not come back, and this host mines.
echo "==> verifying /etc/fstab"
sudo findmnt --verify
sudo mount -a

echo "==> proving the bind is real"
findmnt "$VISIBLE_PATH"
df -h "$VISIBLE_PATH" | tail -1

# ── The canary. This is the check the runner also performs at boot (src/disk.ts), done here first
#    so a wrong destination is found before anything depends on it.
echo "==> canary: writing through Docker exactly as the runner will"
CANARY=".cf-setup-canary-$$"
docker run --rm -v "$VISIBLE_PATH:/backups" alpine:3 sh -c "echo canary > /backups/$CANARY"
if [ -f "$VISIBLE_PATH/$CANARY" ]; then
  rm -f "$VISIBLE_PATH/$CANARY"
  echo "==> OK: a container's write is visible on the host. The destination is real."
else
  echo "!!! FAILED: the container wrote into its own ephemeral layer and the host cannot see it." >&2
  echo "!!! Do NOT start the runner: it would report successful backups and write nothing." >&2
  exit 1
fi

echo
echo "Destination ready. It holds ONLY ciphertext and dumps:"
echo "  · the custody VAULT, which is ciphertext (docs/custody-backup-restore.md §1.5 artefact B)"
echo "  · the miner coinbase key, age-encrypted to an off-host recipient"
echo
echo "It must NEVER hold the custody keyring (artefact C). That goes on paper and an encrypted USB,"
echo "by hand, per §4 — and the runner refuses to boot if it is ever put in its environment."
