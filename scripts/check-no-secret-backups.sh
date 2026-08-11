#!/usr/bin/env bash
# Is a backup copy of a secrets file lingering beside the live one?
#
#   ./scripts/check-no-secret-backups.sh
#
# ── THE DEFECT ────────────────────────────────────────────────────────────────
#
# Every rotation this estate has performed made a copy of the file it was about
# to edit, and every one of them left it there. Four `.bak-*` files have been
# found beside live secrets files across four rotations — the most recent during
# the bitcoind `rpcauth` rotation of 2026-08-11, which is what produced this
# check.
#
# They are not stale files. On 2026-08-05, `compose/estate/tokens.env.bak-1785933479`
# held 39 values of which **37 were byte-identical to the live `tokens.env`** —
# only `SMTP_PASS` had actually moved. So it was not a fragment of an old
# credential set, it was a SECOND COMPLETE COPY of the estate's entire credential
# set: every service token, the operator password, the beacon token, the SMTP
# password before the change and every other value unchanged by it.
#
# ── AND THE RISK IS LONGEVITY, NOT GIT ────────────────────────────────────────
#
# `compose/secrets/` is gitignored as a DIRECTORY and `compose/estate/tokens*`
# globs the whole tail, so none of these was ever committable. That is worth
# stating plainly, because it is the reason nothing has caught them: every guard
# this repository owns is aimed at the commit, and this failure never reaches
# one. It is on-disk longevity instead — a retired credential in a file nobody
# remembers making, with an older mode, no owner and no expiry, sitting on a host
# that is reachable from the network.
#
# It fails SILENTLY in the most literal sense: nothing reads these files, nothing
# writes them, nothing alerts on them, and the estate is completely healthy with
# them present. They surface months later as a permanent finding in
# `make check-residue`, which is the point at which a check stops being read.
#
# ── IT PRINTS FILENAMES. IT NEVER READS A FILE ────────────────────────────────
#
# There is no `cat`, no `grep`, no `head`, no `read` and no redirection FROM any
# scanned path anywhere below. It looks at names and nothing else, and it prints
# paths and nothing else — not a size, not a mode, not a first line, not a
# diff against the live file.
#
# That is not caution, it is the rule whose violation caused the 2026-08-11
# rotation in the first place, and a check that quotes the secret it is warning
# about has reproduced the leak it is reporting into a CI log that is public.
# `scripts/check-secret-hygiene.py` is the tool that may look INSIDE these files;
# it is written so that it cannot print a value even by accident. This one does
# not look.
#
# The remedy is always the same and is the last step of every rotation:
#
#   shred -u <path>
#
# `runbooks/runbook-bitcoind-rpcauth-rotation.md` step 8, and the same sentence
# in `runbooks/runbook-postgres-password.md`.
set -uo pipefail
cd "$(dirname "$0")/.."

# The directories a live credential set is kept in. `compose/secrets/` holds the
# custody keyrings and the chain RPC credentials; `compose/estate/` holds
# `tokens.env`, which is every service token in the estate; and `*/secrets/` picks
# up the telemetry plane's credential files (`prometheus/secrets`,
# `alertmanager/secrets`) and anything a later component adds under the same
# convention — a rule that only covers the places it was born in is a rule with a
# hole in it.
ROOTS=(compose/secrets compose/estate)
while IFS= read -r d; do
  ROOTS+=("${d#./}")
done < <(find . -type d -name secrets \
              -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null | sort)

# Deduplicate, preserving order: `compose/secrets` is named above AND found by
# the sweep, and a path reported twice reads as two findings.
declare -a SCAN=()
for r in "${ROOTS[@]}"; do
  for seen in ${SCAN[@]+"${SCAN[@]}"}; do
    [ "$seen" = "$r" ] && continue 2
  done
  SCAN+=("$r")
done

# What a backup looks like. Every one of these is a name a person or a script has
# actually produced on this estate or is one keystroke from producing:
# `cp x x.bak`, `cp x x.bak-$(date +%s)`, `cp x x.20260805`, an editor's `~` and
# `.swp`, `sed -i.orig`, and the `.pre-<something>` an operator writes before a
# deploy. The epoch pattern is last because `tokens.env.bak-1785933479` — the one
# that was found — matches `*.bak*` first, and a second reader should not have to
# work out which rule caught it.
PATTERNS=(
  '*.bak' '*.bak*' '*.backup' '*.backup*'
  '*.orig' '*.old' '*.prev' '*.previous'
  '*.save' '*.saved' '*.copy' '*.rej'
  '*.pre-*' '*-backup' '*-copy'
  '*~' '*.swp' '*.swo'
  '*.20[0-9][0-9]*'
  '*.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
)

# Assemble the find expression once: `-name p1 -o -name p2 -o …`.
expr_args=()
for p in "${PATTERNS[@]}"; do
  [ ${#expr_args[@]} -gt 0 ] && expr_args+=(-o)
  expr_args+=(-name "$p")
done

declare -a FOUND=()
declare -a PRESENT=()
declare -a ABSENT=()

for root in "${SCAN[@]}"; do
  if [ ! -d "$root" ]; then
    ABSENT+=("$root")
    continue
  fi
  PRESENT+=("$root")

  # Inside the directory, at any depth. Symlinks count: a symlink named like a
  # backup is a second path to the live file and behaves exactly like a copy for
  # everything except `shred`.
  while IFS= read -r hit; do
    [ -n "$hit" ] && FOUND+=("${hit#./}")
  done < <(find "$root" \( -type f -o -type l \) \( "${expr_args[@]}" \) 2>/dev/null | sort)

  # And BESIDE it, because `cp -r compose/secrets compose/secrets.bak` puts the
  # whole set one directory over, where a scan of the directory itself cannot see
  # it. Restricted to names beginning with the directory's own basename so this
  # stays a check about secrets and does not start reporting every stray `.orig`
  # in `compose/`.
  parent=$(dirname "$root")
  base=$(basename "$root")
  while IFS= read -r hit; do
    [ -n "$hit" ] && FOUND+=("${hit#./}")
  done < <(find "$parent" -maxdepth 1 -name "$base.*" \( "${expr_args[@]}" \) 2>/dev/null | sort)
done

if [ ${#FOUND[@]} -gt 0 ]; then
  echo "FATAL: backup-shaped files are sitting beside a live secrets file." >&2
  printf '         %s\n' "${FOUND[@]}" >&2
  echo "" >&2
  echo "       These are not stale fragments. A copy taken before an edit is a full" >&2
  echo "       SECOND COPY of the credential set: on 2026-08-05 one of them held 39" >&2
  echo "       values of which 37 were byte-identical to the live file — only SMTP_PASS" >&2
  echo "       had actually moved. Everything else was, and still is, live." >&2
  echo "" >&2
  echo "       Nothing reads them, nothing alerts on them and the estate is healthy" >&2
  echo "       with them present, which is why they survive rotation after rotation." >&2
  echo "       They are gitignored, so this is not a commit risk — it is a retired" >&2
  echo "       credential with no expiry on a network-reachable host." >&2
  echo "" >&2
  echo "       Destroy them, do not merely delete them:" >&2
  printf '         shred -u %s\n' "${FOUND[@]}" >&2
  for hit in "${FOUND[@]}"; do
    if [ -d "$hit" ]; then
      echo "       (a directory hit is a whole copied SET: shred each file inside it," >&2
      echo "        then remove the directory. 'shred -u' on a directory does nothing.)" >&2
      break
    fi
  done
  echo "" >&2
  echo "       Then re-run this, and 'make check-residue' for the values themselves." >&2
  echo "       runbooks/runbook-bitcoind-rpcauth-rotation.md, step 8." >&2
  exit 1
fi

# The ok line names what was scanned, and names what was NOT there. On a CI
# runner none of the secrets directories exists — the whole point of them being
# gitignored — so a bare "ok" would be indistinguishable from this check having
# looked at nothing, which is the state every guard in this repository has been
# found in at least once.
# Written as a loop rather than `local IFS=", "; echo "$*"`, which joins on the
# FIRST character of IFS and silently produces a comma-jammed list.
join() {
  local out="" x
  for x in "$@"; do out="${out:+$out, }$x"; done
  echo "$out"
}

scanned=$(join ${PRESENT[@]+"${PRESENT[@]}"})
[ -z "$scanned" ] && scanned="(nothing — see below)"
printf 'ok: no backup-shaped file beside a live secrets file — %d name pattern(s) over: %s\n' \
  "${#PATTERNS[@]}" "$scanned"
if [ ${#ABSENT[@]} -gt 0 ]; then
  printf '    not present on this host, so not scanned: %s\n' "$(join "${ABSENT[@]}")"
fi
