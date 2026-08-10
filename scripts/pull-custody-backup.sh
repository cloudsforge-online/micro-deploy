#!/usr/bin/env bash
# Take a custody backup on the estate host and pull it OFF that host.
#
#   scripts/pull-custody-backup.sh [--host malf@192.168.1.42] [--project cloudsforge-estate]
#                                  [--dest ~/cloudsforge-custody-backup] [--keep 14]
#
# ── WHY THIS EXISTS (micro-org#25, item 3) ────────────────────────────────────
#
# `docs/custody-backup-restore.md` §2 has always described how to take artefacts
# A (the database) and B (the vault). Nothing has ever moved them off the machine
# they protect. Measured on the estate host 2026-08-10, before this ran: the only
# custody backup anywhere was `~/custody-backup/20260805T091142Z` — one directory,
# one date, on the host whose loss it is supposed to survive. So item 3's sentence
# was literally true: lose the host and every custodied key is unrecoverable
# ciphertext.
#
# ── IT PULLS, IT IS NOT PUSHED, AND THAT IS THE SECURITY PROPERTY ─────────────
#
# The workstation reaches into the host. The host therefore holds NO credential
# for the backup destination, knows no path on it and cannot reach it. An attacker
# who owns the estate host can destroy `~/custody-backup` there and cannot touch
# the off-host copies — which is the failure a push-based backup does not survive,
# because a push needs a writable destination and a credential for it, and both
# are sitting on the machine being encrypted.
#
# ── WHAT IT DELIBERATELY DOES NOT COPY ────────────────────────────────────────
#
# Artefact C, the keyring. Never. `docs/custody-backup-restore.md` §4.1: the vault
# and the keyring must never share a medium, a backup set, a cloud bucket or a
# filesystem — either alone is safe to lose to a thief, together they are the
# coins. A + B on their own are ciphertext and §4.1 says they may live anywhere,
# which is exactly why this script can run unattended and the keyring copy cannot.
#
# There is a second reason, specific to how this estate has actually been burned.
# §4 requires the keyring to be handled at the machine's own console and NOT over
# SSH, because a value read over SSH is in the scrollback of a second computer and,
# if an agent is driving, in a transcript file on disk. micro-org#25, #144, #156
# and #254 are all that failure. A script that SSH'd out the keyring to automate
# this ticket would re-create the exposure the ticket is about.
#
# So the guard below is not paranoia about a mistake nobody would make: it is the
# one invariant that keeps this whole mechanism safe to run every night, and it
# runs before anything is written to the destination, not after.
set -euo pipefail

HOST="malf@192.168.1.42"
PROJECT="cloudsforge-estate"
DEST="$HOME/cloudsforge-custody-backup"
KEEP=14

while [[ $# -gt 0 ]]; do
  case "$1" in
  --host) HOST="$2"; shift 2 ;;
  --project) PROJECT="$2"; shift 2 ;;
  --dest) DEST="$2"; shift 2 ;;
  --keep) KEEP="$2"; shift 2 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'pull-custody-backup: %s\n' "$*" >&2; exit 1; }

# One definition of the artefact-C rule, applied on both machines. See the header
# of that file for why it is not typed out twice.
# shellcheck source=scripts/custody-backup-guard.sh
. "$(dirname "$0")/custody-backup-guard.sh"

# `umask 077` before the first mkdir, not a chmod afterwards. A chmod leaves a
# window in which the directory is world-readable, and on a shared workstation
# that window is when the file appears.
umask 077

# ---------------------------------------------------------------- artefacts ---
# §2 verbatim, run on the host. The counts are written by the host because they
# come from the live database, and they are what a restore is checked against:
# blob count must equal keys + seeds, or the vault and the database disagree about
# what exists and the backup is not a consistent picture of anything.
say "== taking the backup on $HOST =="
STAMP=$(ssh -o BatchMode=yes "$HOST" "bash -euo pipefail -s" <<EOF
P=$PROJECT
STAMP=\$(date -u +%Y%m%dT%H%M%SZ); OUT=\$HOME/custody-backup/\$STAMP
mkdir -p "\$OUT" && chmod 700 "\$OUT"
docker exec \${P}-postgres-1 pg_dump -U cloudsforge -d custody -Fc > "\$OUT/custody-db.dump"
docker run --rm -v \${P}_custody-keys:/vault:ro -v "\$OUT":/out busybox:1.37 \
  tar -czf /out/custody-vault.tgz -C /vault/keys . >/dev/null 2>&1
cd "\$OUT"
sha256sum custody-db.dump custody-vault.tgz > SHA256SUMS
tar -tzf custody-vault.tgz | grep -c 'key\.enc\$' > BLOB-COUNT
docker exec \${P}-postgres-1 psql -U cloudsforge -d custody -tAc \
  "select 'keys='||count(*) from custody_keys" >> BLOB-COUNT
docker exec \${P}-postgres-1 psql -U cloudsforge -d custody -tAc \
  "select 'seeds='||count(*) from custody_seeds" >> BLOB-COUNT
printf '%s' "\$STAMP"
EOF
) || die "the backup did not complete on $HOST — nothing was pulled"

[[ -n "$STAMP" ]] || die "the host returned no timestamp"
say "   $STAMP"

# ── ARTEFACT C GUARD, BEFORE THE TRANSFER ─────────────────────────────────────
# Asked of the host, about the host's own set, before a byte lands here. Checking
# after the copy would mean the keyring had already been written to this disk, and
# a `rm` does not unwrite it — the blocks are still on the medium and, on a laptop
# with a backup of its own, in that backup too.
say "== refusing to transfer a set that contains the keyring =="
{ declare -f set_contains_keyring
  printf 'if set_contains_keyring "$HOME/custody-backup/%s"; then echo LEAK; else echo CLEAN; fi\n' "$STAMP"
} | ssh -o BatchMode=yes "$HOST" "bash -s" | grep -qx CLEAN \
  || die "REFUSING: the backup set on the host contains keyring material.
  Artefact C must never share a medium with artefact B (docs/custody-backup-restore.md §4.1).
  Nothing was transferred. Find out what put it there before running this again."

# ------------------------------------------------------------------- pull ---
mkdir -p "$DEST"
say "== pulling to $DEST/$STAMP =="
# A path relative to the remote home, not an absolute one: the account this runs
# as is a parameter (`--host`), and hard-coding `/home/malf` makes the script
# silently wrong on any host whose operator is named something else.
scp -q -r "$HOST:custody-backup/$STAMP" "$DEST/" || die "the transfer failed"
chmod 700 "$DEST/$STAMP"

# ------------------------------------------------------------------ verify ---
# Verified HERE, against the manifest the host wrote, so this proves the transfer
# as well as the artefacts. A checksum computed on the host and never re-checked
# on the destination proves the host can hash its own files.
cd "$DEST/$STAMP"
say "== verifying the copy that is now off-host =="
if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi \
  || die "the off-host copy does not match the host's manifest — treat it as absent"

blobs=$(sed -n 1p BLOB-COUNT)
keys=$(sed -n 's/^keys=//p' BLOB-COUNT)
seeds=$(sed -n 's/^seeds=//p' BLOB-COUNT)
[[ "$blobs" -eq $((keys + seeds)) ]] \
  || die "inconsistent set: $blobs blobs but $keys keys + $seeds seeds.
  The vault and the database do not agree about what exists. This is not a transfer
  fault — investigate on the host before relying on this set."
say "   $blobs blobs = $keys keys + $seeds seeds"

# The keyring guard again, on what actually arrived. The first one asked the host
# about the host; this one asks this machine about this machine, and they are not
# the same question if the transfer is ever anything but a plain copy.
if set_contains_keyring "$DEST/$STAMP"; then
  die "REFUSING to keep this set: keyring material arrived. Delete $DEST/$STAMP and investigate."
fi
say "   no keyring on this medium (docs/custody-backup-restore.md §4.1)"

# ------------------------------------------------------------------- prune ---
# Both ends. The host's copy is not the backup — it is the staging area — but
# leaving every set there forever fills the disk that also holds the chain data,
# and a full disk on the estate host is an outage, not a backup problem.
say "== keeping the $KEEP most recent sets, both ends =="
# `head -n -N` is a GNU extension and this half runs on the operator's macOS
# workstation, where BSD head rejects a negative count outright. The remote half
# below is Ubuntu and may use it; this one counts and drops instead. Same
# ordering either way: the stamps are UTC `%Y%m%dT%H%M%SZ`, so lexical sort is
# chronological sort and stays so past the year 9999 problem nobody has.
# shellcheck disable=SC2012
local_sets=$(ls -1d "$DEST"/*/ 2>/dev/null | sort || true)
local_n=$(printf '%s' "$local_sets" | grep -c . || true)
if [[ "${local_n:-0}" -gt "$KEEP" ]]; then
  printf '%s\n' "$local_sets" | sed -n "1,$((local_n - KEEP))p" | while read -r old; do
    [[ -n "$old" ]] || continue
    say "   local  drop $(basename "$old")"; rm -rf "$old"
  done
fi
ssh -o BatchMode=yes "$HOST" "
  cd \"\$HOME/custody-backup\" 2>/dev/null || exit 0
  ls -1d */ 2>/dev/null | sort | head -n -$KEEP | while read -r old; do
    echo \"   host   drop \$(basename \"\$old\")\"; rm -rf \"\$old\"
  done
"

say
say "off-host copy: $DEST/$STAMP"
say
say "This is artefacts A and B only. It is ciphertext. It recovers NOTHING without"
say "the keyring, which is artefact C, which is on paper and an encrypted stick and"
say "is the owner's job — docs/custody-backup-restore.md §4. If that has not been"
say "done, this backup is a list of addresses you cannot spend."
