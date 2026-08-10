#!/usr/bin/env bash
# Exercises `scripts/resolve-token.sh` (micro-org#156) against fixtures.
#
# `up.sh` ends by talking to Docker and cannot be run in CI, which is why the
# resolver lives in its own sourceable file and why this exists: the rule that a
# credential has one home is only true for as long as something checks it.
#
# The case that matters is the last one. A guard that refuses is easy to write
# and easy to write WRONGLY — the first draft of this used `exit 1` inside the
# `$( )` of an argument, which leaves the subshell, prints the refusal, yields
# an empty string and lets the deploy continue. So this asserts both halves:
# non-zero status AND no value on stdout.
set -uo pipefail
cd "$(dirname "$0")/.."

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0

check() { # check <name> <expected-status> <expected-stdout> <actual-status> <actual-stdout>
  if [[ "$4" == "$2" && "$5" == "$3" ]]; then
    printf '  ok    %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n        expected status=%s stdout=%q\n        got      status=%s stdout=%q\n' \
      "$1" "$2" "$3" "$4" "$5"; fail=$((fail + 1))
  fi
}

# The `2>` belongs INSIDE the `$( )`, not after the assignment. A simple command
# expands its words before it applies its redirections, so `OUT=$(…) 2>err`
# redirects the assignment — which writes no stderr — while the substitution's
# stderr goes to the terminal. That looked exactly like a refusal that printed
# nothing, which is the failure this file is here to detect.
run() { # run <tokens-file-or-empty> <dotenv-value-or-unset> -> sets STATUS/OUT
  local tokens="$1" dotenv="$2"
  OUT=$(
    {
      estate_tokens_file="$tokens"
      # shellcheck source=scripts/resolve-token.sh
      . scripts/resolve-token.sh
      if [[ "$dotenv" == "unset" ]]; then unset CF_BEACON_TOKEN; else CF_BEACON_TOKEN="$dotenv"; fi
      resolve_token BEACON_TOKEN CF_BEACON_TOKEN
    } 2>"$W/err"
  )
  STATUS=$?
}

printf 'estate tokens file + .env:\n'

printf 'BEACON_TOKEN=from-the-estate\nOTHER=x\n' > "$W/tokens.env"

run "$W/tokens.env" "from-the-estate"
check "they agree -> the value" 0 "from-the-estate" "$STATUS" "$OUT"

run "$W/tokens.env" "unset"
check "estate only -> the estate value" 0 "from-the-estate" "$STATUS" "$OUT"

run "$W/tokens.env" ""
check "empty in .env -> the estate value" 0 "from-the-estate" "$STATUS" "$OUT"

run "$W/absent.env" "only-in-dotenv"
check "no estate on this host -> .env value" 0 "only-in-dotenv" "$STATUS" "$OUT"

run "$W/absent.env" "unset"
check "neither -> empty, and no error" 0 "" "$STATUS" "$OUT"

# The estate file exists but does not declare this token: a host running the
# estate that has not configured lantern. Falling back to .env is right; refusing
# would make an unconfigured scrape into a failed deploy.
printf 'SOMETHING_ELSE=y\n' > "$W/partial.env"
run "$W/partial.env" "only-in-dotenv"
check "estate file lacks the name -> .env value" 0 "only-in-dotenv" "$STATUS" "$OUT"

run "$W/tokens.env" "a-different-credential"
check "THEY DISAGREE -> refuses" 1 "" "$STATUS" "$OUT"

if grep -q "REFUSING" "$W/err"; then
  printf '  ok    the refusal explains itself on stderr\n'; pass=$((pass + 1))
else
  printf '  FAIL  the refusal printed nothing to stderr\n'; fail=$((fail + 1))
fi

# THE ONE RULE: the message identifies the two credentials without being one.
if grep -qE 'from-the-estate|a-different-credential' "$W/err"; then
  printf '  FAIL  the refusal PRINTED A CREDENTIAL — it must print fingerprints only\n'
  fail=$((fail + 1))
else
  printf '  ok    neither value appears in the refusal, only fingerprints\n'; pass=$((pass + 1))
fi

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
