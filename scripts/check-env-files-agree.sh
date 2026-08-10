#!/usr/bin/env bash
# Do these two --env-file paths name the SAME environment?
#
#   scripts/check-env-files-agree.sh compose/testnet.env compose/estate/tokens.env
#
# ── THE DEFECT (micro-org#238) ────────────────────────────────────────────────
#
# Every entry point in this repository takes the estate's env file and the tokens
# file as two INDEPENDENT variables — `ESTATE_ENV` and `TOKENS_FILE` in
# `release-deploy.sh`, `ENV_FILE` and `TOKENS_FILE` in `estate-bootstrap.sh` — and
# passes both to `docker compose --env-file`. Nothing has ever checked that they
# refer to the same estate.
#
# So a testnet bring-up accepts the MAINNET tokens file without complaint. It
# comes up under `CF_PROJECT=cf-testnet`, every banner says testnet, and the
# containers hold mainnet's service credentials, mainnet's operator password and
# mainnet's custody keyring selection. Nothing fails: the credentials are real,
# they are simply the other estate's, and the only symptom is 401s from testnet
# identity — or, far worse, a component that accepts them.
#
# `release-deploy.sh` then reports the environment from the ESTATE FILE ALONE
# (`case "$ESTATE_ENV" in *testnet*)`), which is why the whole thing "reports it
# as testnet": every label in the output comes from the one file that was right.
#
# ── WHY THE PATHS AND NOT A MARKER INSIDE THE FILE ────────────────────────────
#
# The obvious answer is to stamp the tokens file at bootstrap and compare
# stamps. It cannot be the primary check, for two reasons that both matter here.
# The tokens file is UNTRACKED and mode 0600, so no CI can ever verify what is in
# it; and no existing file has a stamp, so a check that required one would be
# absent on precisely the two hosts that have been running for months — which is
# the pattern this estate keeps paying for, a guard that is only armed where it
# was never needed.
#
# The pairing is fully determined by the paths, and the paths are tracked. There
# are exactly two environments and their file names are the convention every
# caller already follows.
#
# ── AND IT IS DELIBERATELY SILENT ON ANYTHING IT DOES NOT RECOGNISE ───────────
#
# A path naming neither environment is a fixture, a dev estate or a third
# environment nobody has built yet. Refusing those would make this check a thing
# people work around, and a guard that is routinely bypassed guards nothing. It
# refuses one thing only: two paths that each name an environment, and name
# DIFFERENT ones. That case has no legitimate reading.
set -uo pipefail

ESTATE_ENV="${1:-}"
TOKENS_FILE="${2:-}"

if [ -z "$ESTATE_ENV" ] || [ -z "$TOKENS_FILE" ]; then
  echo "usage: $0 <estate-env-file> <tokens-file>" >&2
  exit 2
fi

# `testnet` is checked FIRST because `compose/estate/tokens.testnet.env` contains
# neither `mainnet` nor anything else distinguishing, and mainnet's tokens file is
# the unadorned name — the same "the environment is a suffix, and its absence is
# the default" rule the hostnames follow.
#
# ── `tokens.env` WITH NO DIRECTORY IS THE SAME FILE AND MUST MATCH TOO ────────
#
# `*/tokens.env` requires a slash, so the bare filename fell through to `*)` and
# this guard exited 0 in silence — the one spelling that reaches it from the one
# place a person is most likely to be standing. Measured on 2026-08-10, before
# this clause:
#
#   compose/testnet.env + tokens.env                     -> exit 0   (accepted)
#   compose/testnet.env + ./compose/estate/tokens.env    -> exit 1
#   compose/testnet.env + estate/tokens.env              -> exit 1
#   testnet.env         + estate/tokens.env              -> exit 1
#
# `TOKENS_FILE=tokens.env` run from inside `compose/estate/` is a real
# invocation: it is what you type when you have just been reading the file, and
# both entry points take `TOKENS_FILE` from the environment. Every other
# spelling of the same path was refused, which is the shape of hole that reads
# as "the guard works" right up to the one time it does not.
environment_of() {
  case "$1" in
  *testnet*) echo testnet ;;
  *mainnet* | */tokens.env | tokens.env) echo mainnet ;;
  *) echo "" ;;
  esac
}

estate_env=$(environment_of "$ESTATE_ENV")
tokens_env=$(environment_of "$TOKENS_FILE")

if [ -z "$estate_env" ] || [ -z "$tokens_env" ]; then
  exit 0
fi
if [ "$estate_env" = "$tokens_env" ]; then
  exit 0
fi

echo "FATAL: these two --env-file paths name different estates." >&2
echo "         $ESTATE_ENV -> $estate_env" >&2
echo "         $TOKENS_FILE -> $tokens_env" >&2
echo "       Compose would accept this without a word. The stack would come up under" >&2
echo "       $estate_env's project name, every banner would say $estate_env, and the" >&2
echo "       containers would hold $tokens_env's service credentials, operator password and" >&2
echo "       custody keyring — real credentials, for the other estate. Nothing fails" >&2
echo "       loudly; identity answers 401 to callers that look correct, and anything" >&2
echo "       that does NOT reject them is worse than the ones that do." >&2
echo "       The pair for $estate_env is:" >&2
if [ "$estate_env" = testnet ]; then
  echo "         --env-file compose/testnet.env --env-file compose/estate/tokens.testnet.env" >&2
else
  echo "         --env-file compose/mainnet.env --env-file compose/estate/tokens.env" >&2
fi
exit 1
