#!/usr/bin/env bash
# Prove the chain-backing loop, end to end, on this machine.
#
#   cd deploy
#   ./scripts/verify-chain-backing.sh
#
# ── WHAT THIS PROVES, AND WHY IT IS A DEPLOY SCRIPT ───────────────────────────
#
# The estate's solvency invariant (04-domain-model §2.4) is: for each asset, the
# ledger's custody total must equal what the indexer observes on chain, and drift
# beyond tolerance FREEZES WITHDRAWALS. `ledger/src/reconcile.ts` has taken an
# optional `indexerObservedTotal` for the life of the service, and until
# `GET /v1/custody/:chain/:network/total` existed nothing in 58 repositories
# could produce one — `grep -rn indexerObservedTotal` found it supplied in
# exactly one place, a test. So every scheduled run took the `liability_sum`
# branch and compared the ledger against the ledger.
#
# That defect was invisible from inside either repository. micro-ledger's suite
# passed while no caller supplied the total; micro-indexer's suite passed while
# nothing asked it for one. IT LIVED IN THE SEAM, which is why proving it closed
# belongs here, in the repository that owns how the two are wired together,
# rather than in either service's unit suite.
#
# The work itself is `indexer/src/chainbacking.test.ts`: a real JSON-RPC node on
# a real port, the indexer's real pool, observer and HTTP server, the reference
# client, and micro-ledger's real `reconcileAsset` against a real ledger database
# with migration 11's constraints live. This script provisions the two databases
# that test needs and runs it. It asserts nothing itself — the assertions are
# there, where the code is.
#
# ── WHAT IT DOES NOT PROVE ────────────────────────────────────────────────────
#
# The chain is synthetic. Hearth's mainnet has not launched and there is no node
# on this machine to point at, so the JSON-RPC server is a deterministic fixture.
# Every other boundary is real. Said here rather than left to be assumed.
#
# `estate-verify.sh` covers the other half: it drives the LIVE custody route on
# the running estate and asserts the refusal shape, and asserts that EMBER's last
# reconciliation run is `unavailable/failed` rather than the vacuous
# `liability_sum`.
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
MICRO=$(cd "$HERE/.." && pwd)
INDEXER_REPO=${INDEXER_REPO:-$MICRO/indexer}
LEDGER_REPO=${LEDGER_REPO:-$MICRO/ledger}

# A container of its own, on a port of its own. It is NOT the estate's postgres:
# the test truncates every table in both schemas, and the ledger is the one
# service where running a suite against the wrong database destroys the record of
# every movement of money the platform has ever made. Both URLs contain "test"
# because both suites refuse to run against a database whose name does not.
PG_NAME=${PG_NAME:-chainbacking-test-pg}
PG_PORT=${PG_PORT:-55450}
PG_USER=test
PG_PASS=test
INDEXER_DB=indexer_chainbackingtest
LEDGER_DB=ledger_chainbackingtest

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

for repo in "$INDEXER_REPO" "$LEDGER_REPO"; do
  if [ ! -d "$repo/src" ]; then
    bad "no checkout at $repo — this drives both sides of the seam and needs both"
    exit 1
  fi
done

echo "── a database for each side ─────────────────────────────────────────────"
if [ "$(docker ps -q -f "name=^${PG_NAME}$" | wc -l | tr -d ' ')" = 0 ]; then
  # `docker rm` first so a stopped container from a previous run does not make
  # `docker run` fail on a name clash — which reads as "docker is broken" and is
  # not. A NAMED VOLUME IS NEVER TOUCHED HERE; the container is disposable and
  # its data is not worth keeping.
  docker rm -f "$PG_NAME" >/dev/null 2>&1
  docker run -d --name "$PG_NAME" \
    -e "POSTGRES_PASSWORD=$PG_PASS" -e "POSTGRES_USER=$PG_USER" -e "POSTGRES_DB=$INDEXER_DB" \
    -p "127.0.0.1:$PG_PORT:5432" postgres:16-alpine >/dev/null || {
      bad "could not start $PG_NAME on 127.0.0.1:$PG_PORT"
      exit 1
    }
  ok "started $PG_NAME on 127.0.0.1:$PG_PORT"
else
  ok "reusing the running $PG_NAME"
fi

# Poll rather than sleep a fixed amount: a fixed sleep is either slower than it
# needs to be or shorter than it needs to be, and which one is a property of the
# machine rather than of the change under test.
ready=0
attempt=0
while [ "$attempt" -lt 60 ]; do
  if docker exec "$PG_NAME" pg_isready -U "$PG_USER" >/dev/null 2>&1; then ready=1; break; fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$ready" != 1 ]; then
  bad "$PG_NAME never accepted connections"
  exit 1
fi
ok "postgres is accepting connections"

for db in "$INDEXER_DB" "$LEDGER_DB"; do
  docker exec "$PG_NAME" psql -U "$PG_USER" -d postgres -tAc \
    "select 1 from pg_database where datname = '$db'" 2>/dev/null | grep -q 1 \
    || docker exec "$PG_NAME" psql -U "$PG_USER" -d postgres -q -c "create database $db" >/dev/null 2>&1
done
ok "databases present: $INDEXER_DB, $LEDGER_DB"

echo
echo "── the loop, over real sockets ──────────────────────────────────────────"
# Run from the indexer checkout so `tsx` and the @cloudsforge/* file: deps
# resolve. The test imports micro-ledger's own sources across the checkout —
# `reconcileAsset` is not a published package, and copying it here to avoid the
# import would be testing a copy, which is the precise mistake that let a handler
# and a schema disagree in the first place.
cd "$INDEXER_REPO" || exit 1
INDEXER_TEST_DATABASE_URL="postgres://$PG_USER:$PG_PASS@127.0.0.1:$PG_PORT/$INDEXER_DB" \
LEDGER_TEST_DATABASE_URL="postgres://$PG_USER:$PG_PASS@127.0.0.1:$PG_PORT/$LEDGER_DB" \
  node --import tsx --test --test-concurrency=1 src/chainbacking.test.ts
result=$?

echo
if [ "$result" -eq 0 ]; then
  ok "THE CHAIN-BACKING LOOP CLOSES: a real aggregate, a real reconciliation, and every guard refused"
  echo
  echo "  What remains, and it is not in this repository: ledger/src/jobs.ts:213"
  echo "  does not make the call yet. The client it must adopt is observedTotalFor"
  echo "  in indexer/src/chainbacking.test.ts, and its one rule is that unreachable"
  echo "  arrives as undefined and never as 0n."
else
  bad "the chain-backing loop did not close — see the failures above"
fi
exit "$result"
