#!/usr/bin/env bash
# Replay the conformance corpus against the running estate and publish the result to beacon.
#
# ── THIS SCRIPT IS THE THING THAT DID NOT EXIST (micro-org#439) ──────────────────────────────
#
# Both ends of the conformance gate were built and were never joined. The corpus, the comparator,
# the publisher (`conformance/src/publish.ts`), beacon's `POST /v1/conformance` and the per-suite
# gate input were all complete and correct on 2026-08-04, and `conformance_runs` was empty because
# NOTHING CALLED ANY OF IT — not in that repository, not in a CI workflow, not in a deploy script.
# `HearthConformanceVectorsFailing` was green for its entire life by never having been asked, and
# `ConformanceCorpusNeverReplayed` exists to say so out loud. This is the caller.
#
# ── WHY A HOST SCRIPT AND NOT A CI JOB ───────────────────────────────────────────────────────
#
# The harness needs three things a GitHub-hosted runner does not have and should not be given:
# the estate's `tokens.env` (it resolves recorded secret literals so a corpus cannot contain one),
# the internal CA (`NODE_EXTRA_CA_CERTS`), and a route onto `cloudsforge-estate_default` to reach
# beacon. Handing a public runner the estate's secret file to replay a corpus would be a far worse
# trade than running the replay where the estate already is. `micro-conformance/.github/workflows/
# ci.yml` says the same thing in its header and runs only the pure half — typecheck and tests.
#
# ── WHY THE `micro` BASE AND MAINNET ONLY ────────────────────────────────────────────────────
#
# There is one corpus, `corpus-micro/`, and it was recorded against mainnet. Chain id is contract
# rather than gauge in that corpus — `0x1cf3` on mainnet, `0x1cf4` on testnet — so replaying it at
# testnet would report a breaking difference that means nothing except that this script pointed at
# the wrong estate. Testnet needs its own recorded corpus before it can be replayed; until then
# pointing this at it is not a configuration change, it is a false alarm.
#
#   ./scripts/conformance-replay.sh              # compare and publish
#   ./scripts/conformance-replay.sh --no-publish # compare only; nothing reaches beacon
#
# Run by `conformance-replay.timer` on the app host — see systemd/README.md.
set -euo pipefail

PUBLISH=1
[ "${1:-}" = "--no-publish" ] && PUBLISH=0

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_ROOT=$(cd -- "$HERE/.." && pwd)

# DERIVED FROM THIS CHECKOUT'S OWN LOCATION, not defaulted to a path. The two repositories are
# siblings on the app host (`~/dev/cloudsforge/{deploy,conformance}`), so the layout answers the
# question rather than a constant guessing at it — which is the shape micro-org#434 cost 43 hours
# of backups to learn. Override when they are not siblings; there is no fallback if the override
# is wrong, because a conformance checkout that is not there must fail loudly.
CONFORMANCE_DIR=${CF_CONFORMANCE_DIR:-$(cd -- "$DEPLOY_ROOT/.." 2>/dev/null && pwd)/conformance}
TOKENS_FILE=${CF_TOKENS_FILE:-$DEPLOY_ROOT/compose/estate/tokens.env}
CA_FILE=${CF_CA_FILE:-$DEPLOY_ROOT/gateway/certs/ca.crt}
NETWORK=${CF_ESTATE_NETWORK:-cloudsforge-estate_default}
APEX=${CF_CONFORMANCE_APEX:-cloudsforge.online}

# The compose service alias and the port the container listens on — NOT the published host port.
# This runs on the estate network as a peer of beacon, so it never crosses 127.0.0.1:4142.
BEACON_URL=${CF_BEACON_URL:-http://beacon:4000}

# The corpus and the base are a matched pair and are not independently configurable. A corpus
# recorded against one base and compared against another reports every difference as breaking.
CORPUS=corpus-micro/
BASE=micro

for f in "$TOKENS_FILE" "$CA_FILE"; do
  [ -r "$f" ] || { echo "conformance-replay: cannot read $f" >&2; exit 1; }
done
[ -d "$CONFORMANCE_DIR/$CORPUS" ] || {
  echo "conformance-replay: no $CORPUS under $CONFORMANCE_DIR — set CF_CONFORMANCE_DIR" >&2
  exit 1
}

# ── THE CHECKOUT IS PINNED TO `main`, EVERY RUN ──────────────────────────────────────────────
#
# A scheduled replay against whatever branch somebody last checked out by hand is a gate whose
# input nobody can name afterwards. `git -C … fetch` then a hard reset to `origin/main` means the
# answer to "which corpus was that" is a commit on the default branch and nothing else. The reset
# is safe here BECAUSE this directory is a replay checkout and not somewhere work is done; if that
# ever stops being true, the fix is a second checkout, not a softer reset.
git -C "$CONFORMANCE_DIR" fetch --quiet origin main
git -C "$CONFORMANCE_DIR" reset --quiet --hard origin/main
CORPUS_REF=$(git -C "$CONFORMANCE_DIR" rev-parse --short HEAD)
echo "conformance-replay: $BASE against $CORPUS at $CORPUS_REF (apex $APEX)"

# ── THE ACCOUNT ──────────────────────────────────────────────────────────────────────────────
#
# Five of the eight suites sign in. Without an account they SKIP, and a skip is recorded as a skip
# rather than a pass — beacon refuses to derive `pass` from zero comparisons — so a replay with no
# account is honest but nearly empty.
#
# `tokens.env` first, so that giving the harness its own dedicated account (micro-org#439) is a
# one-line change to a secret file and not a change to this script. Until that exists it borrows
# the LAST of beacon's provisioned journey accounts, which is a real verified account on this
# estate and the same one the first successful replay used on 2026-08-12.
#
# **THE VALUE NEVER REACHES argv.** It is exported into the environment and `docker run -e NAME`
# passes it by name. A password on a command line is visible in `ps` to every user on the host and
# lands in this unit's journal.
ACCOUNTS_FILE=${CF_BEACON_ACCOUNTS_FILE:-/home/savvaniss/secrets/beacon-journey-accounts.mainnet.json}
set -a
# shellcheck disable=SC1090
. "$TOKENS_FILE"
set +a

if [ -z "${CONFORMANCE_ACCOUNT:-}" ] && [ -r "$ACCOUNTS_FILE" ]; then
  CONFORMANCE_ACCOUNT=$(python3 -c "
import json,sys
a = json.load(open(sys.argv[1]))[-1]
print(a['email'] + ':' + a['password'], end='')
" "$ACCOUNTS_FILE")
fi
export CONFORMANCE_ACCOUNT
[ -n "${CONFORMANCE_ACCOUNT:-}" ] || echo "conformance-replay: no account configured — the authenticated suites will skip" >&2
[ -n "${BEACON_TOKEN:-}" ] || { echo "conformance-replay: BEACON_TOKEN is not in $TOKENS_FILE" >&2; exit 1; }
export BEACON_TOKEN

# Docker on this host is configured with a `credsStore` that is not present in a non-interactive
# session, and every `docker pull` fails with a helper-not-found error that says nothing about
# credentials. An empty config in a scratch directory is the whole fix.
DOCKER_CFG=$(mktemp -d)
printf '{}' > "$DOCKER_CFG/config.json"
export DOCKER_CONFIG=$DOCKER_CFG
cleanup() { rm -rf "$DOCKER_CFG"; }
trap cleanup EXIT

PUBLISH_ARGS=""
[ "$PUBLISH" = 1 ] && PUBLISH_ARGS="--beacon $BEACON_URL"

# `--network` and not a published port: the harness dials `https://<sub>.$APEX`, which resolves
# publicly, AND beacon by its compose alias, which does not.
#
# The harness writes nothing here — `compare` reads the corpus and reports — but the mount is
# read-write because pnpm needs to resolve a store inside it. Anything it does create belongs to
# root in the container and to nobody useful on the host, so the chown afterwards is not optional
# if a human is ever going to `git pull` this checkout again.
set +e
docker run --rm --network "$NETWORK" \
  -v "$CONFORMANCE_DIR:/w" \
  -v "$TOKENS_FILE:/estate/tokens.env:ro" \
  -v "$CA_FILE:/estate/ca.crt:ro" \
  -w /w \
  -e NODE_EXTRA_CA_CERTS=/estate/ca.crt \
  -e CONFORMANCE_SECRETS_FILE=/estate/tokens.env \
  -e CONFORMANCE_MICRO_APEX="$APEX" \
  -e CONFORMANCE_ACCOUNT -e BEACON_TOKEN \
  node:22-bookworm-slim \
  sh -c "corepack enable >/dev/null 2>&1; corepack pnpm install --frozen-lockfile >/dev/null 2>&1; \
         exec node --import tsx src/cli.ts compare --corpus $CORPUS --base $BASE $PUBLISH_ARGS"
STATUS=$?
set -e

docker run --rm -v "$CONFORMANCE_DIR:/w" alpine:3 chown -R 1000:1000 /w >/dev/null 2>&1 || true

# `compare` exits non-zero ONLY on a breaking difference — a benign one is a difference the
# normaliser expected. So this status is the gate's answer and is passed through unaltered: the
# timer's `OnFailure=` and `systemctl --failed` are what a breaking difference reaches an operator
# through, and swallowing it here would put this script back where it started.
exit $STATUS
