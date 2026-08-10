#!/usr/bin/env bash
# Exercises `scripts/custody-backup-guard.sh` against fixtures (micro-org#25).
#
# `pull-custody-backup.sh` cannot run in CI — it needs the estate host, a live
# postgres and a docker volume. The rule it enforces is the one thing in it that
# must never be wrong, so the rule lives in its own sourceable file and this runs
# it here instead. Same shape as `check-token-resolution.sh`, for the same reason.
#
# The case that matters is the tarball one. A `grep` over the backup directory
# passes a set whose *tarball* contains the keyring, because the tarball is
# compressed and grep sees noise — which is precisely the shape of hole that reads
# as "the guard works" until the day it does not.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/custody-backup-guard.sh
. scripts/custody-backup-guard.sh

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0

# NOT a real keyring value, and deliberately not keyring-shaped beyond the name:
# a fixture that carried real key material would put the coins in the repository
# in order to test that they never reach a backup.
FIXTURE_LINE='CUSTODY_MASTER_SECRET_V9=fixture-not-a-real-secret'

check() { # check <name> <expected: leak|clean> <dir>
  local name="$1" expect="$2" dir="$3" got
  if set_contains_keyring "$dir"; then got=leak; else got=clean; fi
  if [[ "$got" == "$expect" ]]; then
    printf '  ok    %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s — expected %s, got %s\n' "$name" "$expect" "$got"; fail=$((fail + 1))
  fi
}

mkset() { # mkset <name> -> a directory shaped like a real backup set
  local d="$W/$1"
  mkdir -p "$d/vault/keys/addr1"
  printf 'v3:ciphertext' > "$d/vault/keys/addr1/key.enc"
  tar -czf "$d/custody-vault.tgz" -C "$d/vault/keys" .
  rm -rf "$d/vault"
  printf 'fake pgdump' > "$d/custody-db.dump"
  printf '1\nkeys=1\nseeds=0\n' > "$d/BLOB-COUNT"
  printf '%s\n' "$d"
}

# 1. The set this script's subject actually produces.
clean=$(mkset clean)
check "a normal A+B set is clean" clean "$clean"

# 2. Artefact C copied in beside the artefacts — someone "helpfully" completing
#    the backup, which is the mistake §4.1 is written against.
loose=$(mkset loose)
printf '%s\n' "$FIXTURE_LINE" > "$loose/custody.mainnet.env"
check "keyring file dropped in the set" leak "$loose"

# 3. The variable name inside some other file: a note, a pasted diff, a stray
#    tokens.env. The name is enough — this must not require a valid value.
buried=$(mkset buried)
mkdir -p "$buried/notes"
printf 'reminder, the keyring line is\n%s\n' "$FIXTURE_LINE" > "$buried/notes/README.txt"
check "keyring name buried in another file" leak "$buried"

# 4. THE ONE A GREP MISSES. Inside the compressed tarball, where nothing that
#    reads the directory can see it.
intar=$(mkset intar)
mkdir -p "$W/stage/keys/addr1"
printf 'v3:ciphertext' > "$W/stage/keys/addr1/key.enc"
printf '%s\n' "$FIXTURE_LINE" > "$W/stage/keys/custody.mainnet.env"
tar -czf "$intar/custody-vault.tgz" -C "$W/stage/keys" .
check "keyring INSIDE the vault tarball" leak "$intar"

# 5. Nested one directory deeper in the tarball, so a match on the basename is
#    doing the work rather than a match anchored at the start of the path.
nested=$(mkset nested)
mkdir -p "$W/stage2/keys/sub/deeper"
printf 'v3:ciphertext' > "$W/stage2/keys/addr1-key.enc"
printf '%s\n' "$FIXTURE_LINE" > "$W/stage2/keys/sub/deeper/custody.testnet.env"
tar -czf "$nested/custody-vault.tgz" -C "$W/stage2/keys" .
check "keyring nested deep inside the tarball" leak "$nested"

# 6. A directory that does not exist is not a clean set, but it is also not a
#    leak. The caller treats a missing set as a failed transfer; this predicate
#    answers only the question it is asked.
check "a missing directory is not a leak" clean "$W/does-not-exist"

# 7. A file whose name merely resembles the convention but is not a keyring —
#    the guard must not be so broad that operators start working around it.
benign=$(mkset benign)
printf 'notes about custody\n' > "$benign/custody-restore-notes.md"
check "an ordinary custody note is not a leak" clean "$benign"

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
