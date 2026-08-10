#!/usr/bin/env bash
# THE ONE RULE A CUSTODY BACKUP SET MUST OBEY (micro-org#25, docs/custody-backup-restore.md §4.1)
#
#   The vault and the keyring must never share a medium, a backup set, a cloud
#   bucket or a filesystem. Either one alone is safe to lose to a thief.
#   Together they are the coins.
#
# This file exists so that rule has exactly ONE implementation. `pull-custody-backup.sh`
# has to apply it in two places — on the estate host before anything is transferred,
# and on the workstation against what actually arrived — and those are two different
# machines. The obvious way to write that is to type the test twice, which is how
# micro-org#238 happened: a duplicated predicate drifted, CI verified the copy, and
# the copy was not the one that ran. So the remote check does not re-type the rule,
# it SHIPS this function over ssh with `declare -f`.
#
# `scripts/check-custody-backup-guard.sh` runs it against fixtures in CI, including
# a fixture that plants keyring material, because a guard nobody has watched refuse
# is a guard that has only ever been watched to pass.

# Returns 0 (true) when the directory holds keyring material, 1 when it is clean.
# Prints nothing. It must never print what it found — the finding IS the secret.
#
# Two probes, because artefact C can arrive in two shapes and only one of them is
# a file you can see:
#   1. the variable name in any file in the set — a stray `.env`, a copied
#      `tokens.env`, a note somebody left, a diff pasted into a README;
#   2. a keyring-shaped member INSIDE the vault tarball, which no `grep` over the
#      directory will ever see because the tarball is compressed. That is the one
#      that would actually get through.
set_contains_keyring() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1

  grep -rlq 'CUSTODY_MASTER_SECRET' "$dir" 2>/dev/null && return 0

  local t
  for t in "$dir"/*.tgz "$dir"/*.tar.gz; do
    [[ -f "$t" ]] || continue
    # `custody.mainnet.env`, `custody.testnet.env`, and anything else matching the
    # keyring's own filename convention. Matched case-insensitively and on the
    # basename, so a path prefix cannot hide it.
    tar -tzf "$t" 2>/dev/null | sed 's#.*/##' | grep -qiE '^custody\..*\.env$' && return 0
  done

  return 1
}
