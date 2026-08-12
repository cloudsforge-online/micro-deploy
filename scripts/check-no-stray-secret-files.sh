#!/usr/bin/env bash
# Is a live secrets file sitting somewhere other than the one tree that owns it?
#
#   ./scripts/check-no-stray-secret-files.sh
#   ROOTS="/home/malf /srv" ./scripts/check-no-stray-secret-files.sh
#
# ── THE THIRD QUESTION ────────────────────────────────────────────────────────
#
# This estate already asks two:
#
#   check-no-secret-backups.sh   is there a backup-SHAPED NAME beside a live
#                                secrets file?
#   check-residue (hygiene.py)   does any file under this root contain a
#                                CURRENTLY LIVE value?
#
# Neither can see a complete second copy of the credential set under its
# ORDINARY name in an unexpected directory, once the values in it have gone
# stale. The first misses it because `tokens.env` is not backup-shaped — it is
# the correct name, in the wrong place. The second misses it because a
# superseded value is not a live value, and that is deliberate.
#
# Measured on the chain host, 2026-08-12. `/home/malf/gwvalidate/` was a
# complete copy of the deploy tree taken on 2026-08-05 — no `.git`, so nothing
# would ever reconcile it, and nothing referenced it: no process, no cron entry.
# It carried `compose/estate/tokens.env`, ten `compose/env/*.env`, both
# Alertmanager webhook files and a `beacon_token`.
#
# It held nothing live, and that is the whole point. `make check-residue` over it
# returned `ok` because every value had been superseded by a rotation since
# 2026-08-05 — postgres, the custody keyring, the administrator password,
# bitcoind's rpcauth. For the week before the first of those, it was a second
# live copy of every service token and the operator password, on a
# network-reachable host, and NO CHECK HERE WOULD HAVE SAID A WORD. It was saved
# by rotations that happened for unrelated reasons. micro-org#430.
#
# ── IT PRINTS FILENAMES. IT NEVER READS A FILE ────────────────────────────────
#
# There is no `cat`, no `grep`, no `head`, no `read` and no redirection FROM any
# scanned path below. It looks at names, it prints paths, and it prints nothing
# else — not a size, not a mode, not a first line. Same rule as
# `check-no-secret-backups.sh`, for the same reason: a check that quotes the
# secret it is warning about has reproduced the leak it is reporting, into a log
# that may be public. `scripts/check-secret-hygiene.py` is the tool that may look
# INSIDE these files. This one does not look.
set -uo pipefail
cd "$(dirname "$0")/.."

# THE TREE THAT IS ALLOWED TO HOLD THESE. Everything under it is where these
# files are SUPPOSED to be, so it is pruned rather than reported — otherwise the
# check's loudest finding would be the live estate itself, which is how a check
# stops being read.
CANONICAL=$(pwd -P)

# Where to look. `$HOME` by default because that is where every checkout on both
# of this estate's hosts lives, and because a scratch copy is made by a person,
# in their own home directory, on the way to solving something else.
ROOTS_LIST=${ROOTS:-$HOME}

# The names, taken from the live credential set rather than imagined. Each of
# these is a file that exists right now under `compose/secrets/`,
# `compose/estate/`, `alertmanager/secrets/` or `prometheus/secrets/`, and each
# is distinctive enough that a match outside the canonical tree is a finding
# rather than a coincidence.
#
# `.env` is deliberately NOT here. Every Node project in this organisation has
# one, most of them hold `PORT=3000`, and a rule that fires on all of them is a
# rule that gets `|| true`'d into silence within a week.
PATTERNS=(
  'tokens.env' 'tokens.*.env'
  'analytics-pepper.*.env' 'chainrpc.*.env' 'custody.*.env'
  'identity-key.*.env' 'outbox.*.env' 'studio.*.env'
  'beacon_token' 'analytics_token' 'lantern_token'
  'page_webhook_url' 'ticket_webhook_url'
)

expr_args=()
for p in "${PATTERNS[@]}"; do
  [ ${#expr_args[@]} -gt 0 ] && expr_args+=(-o)
  expr_args+=(-name "$p")
done

declare -a FOUND=()
declare -a PRESENT=()
declare -a ABSENT=()
declare -a UNREADABLE=()

for root in $ROOTS_LIST; do
  if [ ! -d "$root" ]; then
    ABSENT+=("$root")
    continue
  fi
  # A root that exists and cannot be traversed gives an empty `find` and an error
  # this script does not show, which is indistinguishable from a clean scan. Same
  # hole, same handling, as in check-no-secret-backups.sh.
  if [ ! -x "$root" ] || [ ! -r "$root" ]; then
    UNREADABLE+=("$root")
    continue
  fi
  PRESENT+=("$root")

  # `-prune` on the canonical tree, on `.git` (which holds no working file worth
  # reporting and a great many objects) and on `node_modules` (which on this
  # estate is tens of gigabytes across sixty repositories and has never held a
  # credential). Symlinks are matched but not followed: a symlink named
  # `tokens.env` in a second tree is a second PATH to the live file, which is the
  # `gwvalidate/deploy/compose/.env` case exactly.
  while IFS= read -r hit; do
    [ -n "$hit" ] && FOUND+=("$hit")
  done < <(find "$root" \
                \( -path "$CANONICAL" -o -name .git -o -name node_modules \) -prune -o \
                \( -type f -o -type l \) \( "${expr_args[@]}" \) -print 2>/dev/null | sort)
done

if [ ${#FOUND[@]} -gt 0 ]; then
  echo "FATAL: a live secrets file is sitting outside the tree that owns it." >&2
  printf '         %s\n' "${FOUND[@]}" >&2
  echo "" >&2
  echo "       These are not backups and no backup check will ever see them: the" >&2
  echo "       name is CORRECT, the directory is not. On 2026-08-12 a copy of the" >&2
  echo "       deploy tree from a week earlier held tokens.env — every service" >&2
  echo "       token and the operator password — with no .git, no owner and" >&2
  echo "       nothing referencing it. It was harmless only because four unrelated" >&2
  echo "       rotations had superseded every value in it." >&2
  echo "" >&2
  echo "       Before destroying anything, find out whether it is still live:" >&2
  echo "         make check-residue ROOTS=<the directory above>" >&2
  echo "" >&2
  echo "       If that reports a hit, the value must be ROTATED, not merely" >&2
  echo "       deleted — deleting a copy of a live credential retires nothing." >&2
  echo "       If it reports ok, destroy them:" >&2
  printf '         shred -u %s\n' "${FOUND[@]}" >&2
  echo "" >&2
  echo "       A scratch copy of the deploy tree is a reasonable thing to want." >&2
  echo "       Carrying a live tokens.env into it is not: a scratch tree is a" >&2
  echo "       CLONE, not a cp -r, and a clone cannot carry a credential because" >&2
  echo "       none of them is tracked. README.md, 'A second copy of this tree'," >&2
  echo "       has the rule and what to do when you genuinely need a filled one." >&2
  echo "       micro-org#430." >&2
  exit 1
fi

join() {
  local out="" x
  for x in "$@"; do out="${out:+$out, }$x"; done
  echo "$out"
}

scanned=$(join ${PRESENT[@]+"${PRESENT[@]}"})
[ -z "$scanned" ] && scanned="(nothing — see below)"
printf 'ok: no live secrets file outside %s — %d name pattern(s) over: %s\n' \
  "$CANONICAL" "${#PATTERNS[@]}" "$scanned"
if [ ${#ABSENT[@]} -gt 0 ]; then
  printf '    not present on this host, so not scanned: %s\n' "$(join "${ABSENT[@]}")"
fi
if [ ${#UNREADABLE[@]} -gt 0 ]; then
  printf '    PRESENT AND NOT TRAVERSABLE, so NOT scanned: %s\n' "$(join "${UNREADABLE[@]}")" >&2
  echo   '    The ok line above does not cover these. Re-run where you can read them.' >&2
fi
