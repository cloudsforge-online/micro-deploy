#!/usr/bin/env bash
# The conformance replay, as run inside the runner container.
#
# ── THIS IS THE CALLER THAT DID NOT EXIST (micro-org#439) ────────────────────────────────────
#
# Both ends of the conformance gate were built and never joined. The corpus, the comparator,
# `conformance/src/publish.ts`, beacon's `POST /v1/conformance` and the per-suite gate input were
# all complete on 2026-08-04, and `conformance_runs` was empty because NOTHING CALLED ANY OF IT —
# not in micro-conformance, not in a CI workflow, not in a deploy script. So
# `HearthConformanceVectorsFailing` was green for its entire life by never having been asked a
# question, and the gate the release policy names had no input at all.
#
#   replay.sh once   compare, publish, exit with the comparison's status
#   replay.sh loop   the above, then again every CF_CONFORMANCE_INTERVAL seconds, for ever
#
# `once` is what a human runs. `loop` is the container's command.
set -uo pipefail

MODE=${1:-once}
INTERVAL=${CF_CONFORMANCE_INTERVAL:-86400}

# The corpus and the base are a matched pair and are deliberately not independently configurable:
# a corpus recorded against one base and compared against another reports every difference as
# breaking, which is a loud way of saying nothing.
#
# MAINNET ONLY, and that is not an oversight. There is one corpus and it was recorded against
# mainnet. Chain id is contract rather than gauge in it — `0x1cf3` mainnet, `0x1cf4` testnet — so
# pointing this at testnet reports a breaking difference that means "wrong estate" and nothing
# else. Testnet needs its own recorded corpus before it can be replayed.
CORPUS=corpus-micro/
BASE=micro

REPO=/workspace
BEACON_URL=${CF_BEACON_URL:-http://beacon:4000}

# ── THIS IS CI, AND pnpm HAS TO BE TOLD ─────────────────────────────────────────────────────
#
# The checkout is bind-mounted from a host where a human's pnpm installed `node_modules`. When the
# store layout underneath it does not match, pnpm wants to remove the directory and rebuild it, and
# it will not do that unattended:
#
#   [ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY] Aborted removal of modules directory due to no TTY
#
# There is no TTY here and there is never going to be one. `CI=true` is pnpm's own documented
# answer, and it is true: nothing about this container is interactive. Purging the tree is also the
# right outcome rather than a cost to avoid — a replay that reused a `node_modules` some other pnpm
# built is exactly the drift `--frozen-lockfile` exists to prevent.
export CI=true

log() { printf '%s conformance-replay: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

replay_once() {
  # ── PINNED TO `main`, EVERY RUN ───────────────────────────────────────────────────────────
  #
  # A scheduled replay against whatever branch somebody last checked out by hand is a gate whose
  # input nobody can name afterwards. Fetch-and-reset means the answer to "which corpus was that"
  # is a commit on the default branch and nothing else, and the commit is logged below.
  #
  # Safe here BECAUSE this is a replay checkout and not somewhere work is done. If that ever stops
  # being true the fix is a second checkout, not a softer reset. `CF_CONFORMANCE_PIN=0` turns it
  # off for the case where a human is testing an unmerged corpus against the live estate.
  if [ "${CF_CONFORMANCE_PIN:-1}" = 1 ]; then
    if ! git -C "$REPO" fetch --quiet origin main || ! git -C "$REPO" reset --quiet --hard origin/main; then
      log "could not pin the checkout to origin/main — replaying what is on disk instead"
    fi
  fi
  local ref
  ref=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
  log "$BASE against $CORPUS at $ref (apex ${CONFORMANCE_MICRO_APEX:-unset})"

  # ── THE PACKAGE MANAGER IS PINNED BY THE REPOSITORY, NOT BY THIS IMAGE ────────────────────
  #
  # `corepack pnpm` was the first thing tried and it fails outright here:
  #
  #   This project is configured to use 11.9.0 of pnpm. Your current pnpm is v11.21.0
  #   pnpm does not switch versions when running under corepack
  #
  # `node:22-bookworm` ships whatever corepack pin was current when the tag was rebuilt, and that
  # floats underneath us; the repository's `packageManager` field does not. Reading the version out
  # of the checkout and asking npm for exactly it means the tree is installed by the same pnpm the
  # lockfile was written by, and a base-image refresh cannot change what a replay resolves.
  #
  # Not `--pm-on-fail=ignore`, which would have been one flag: that installs with a package manager
  # nobody chose, and a replay whose dependency tree drifted is a comparison against a base that is
  # not quite the one the corpus was recorded under.
  local pm
  pm=$(node -p "require('$REPO/package.json').packageManager" 2>/dev/null || echo '')
  case "$pm" in
    pnpm@*) ;;
    *)
      log "cannot read a pnpm version from $REPO/package.json (got '${pm:-nothing}') — not guessing one"
      return 70
      ;;
  esac

  # `--frozen-lockfile`, so a replay can never quietly resolve a different dependency tree than
  # the one the corpus was recorded under.
  #
  # The output goes to a file and is TAILED ON FAILURE. It used to go to /dev/null under a message
  # that said "see the container log", which is the log it had just discarded — and that cost a
  # diagnostic round trip the first time this failed.
  local install_log=${HOME:-/tmp}/pnpm-install.log
  if ! npx --yes "$pm" install --frozen-lockfile --dir "$REPO" > "$install_log" 2>&1; then
    log "pnpm install failed ($pm); not comparing against a half-installed tree. Last lines:"
    tail -n 20 "$install_log" >&2
    return 70
  fi

  local args=(compare --corpus "$CORPUS" --base "$BASE")
  [ "${CF_CONFORMANCE_PUBLISH:-1}" = 1 ] && args+=(--beacon "$BEACON_URL")

  # The token and the account reach the harness through the ENVIRONMENT and never through argv.
  # `--beacon-token` reads `BEACON_TOKEN` for exactly this reason: a credential on a command line
  # is visible in `ps` to everything sharing the namespace and is kept by every log that captures
  # a command.
  ( cd "$REPO" && node --import tsx src/cli.ts "${args[@]}" )
}

case "$MODE" in
  once)
    replay_once
    exit $?
    ;;
  loop)
    # ── RUNS IMMEDIATELY, THEN EVERY INTERVAL ────────────────────────────────────────────────
    #
    # Immediately on start, deliberately: the question the release gate actually asks is "has the
    # corpus been replayed SINCE THE LAST RELEASE", and a deploy restarts this container. So the
    # first thing that happens after a release is the replay that certifies it.
    #
    # Then daily. This estate cuts a release most days, so daily is the cadence the question is
    # asked at; hourly would spend forty authenticated sign-ins a day re-measuring something that
    # only changes when a deploy lands.
    while true; do
      replay_once
      status=$?
      # ── A BREAKING DIFFERENCE MUST NOT KILL THE RUNNER ─────────────────────────────────────
      #
      # It is tempting to exit non-zero and let `restart: unless-stopped` express the failure. It
      # would be wrong: the difference would then be reported by a crash-loop, the next replay
      # would run in seconds rather than tomorrow, and the estate would hammer identity with
      # sign-ins for as long as the divergence lasted. The divergence is already published — it is
      # a `fail` row in `conformance_runs` and a non-zero
      # `beacon_conformance_vectors{result="failed"}`, which is what `HearthConformanceVectorsFailing`
      # reads. The runner's job is to keep asking, not to editorialise.
      if [ "$status" -eq 0 ]; then
        log "no breaking difference; next replay in ${INTERVAL}s"
      else
        log "comparison exited $status — see beacon for the per-suite verdict; next replay in ${INTERVAL}s"
      fi
      sleep "$INTERVAL"
    done
    ;;
  *)
    echo "replay.sh: unknown mode '$MODE' (want: once | loop)" >&2
    exit 64
    ;;
esac
