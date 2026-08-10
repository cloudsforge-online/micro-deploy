#!/usr/bin/env bash
# Put the sibling repositories the deploy tooling reads next to this checkout.
#
#   ./scripts/provision-siblings.sh           # clone whatever is missing
#   ./scripts/provision-siblings.sh --check   # report only; non-zero if a REQUIRED one is missing
#   ./scripts/provision-siblings.sh --all     # include the optional asset repositories
#
# ── WHY THIS EXISTS (micro-org#350) ────────────────────────────────────────────
#
# `deploy` is not self-contained and never claimed to be. Several scripts read
# files out of SIBLING REPOSITORIES — and they read them under directory names
# that are NOT the repository names. `micro-contracts` has to be checked out as
# `contracts`, `micro-ui` as `ui`. Cloning either with git's default name leaves
# the tooling failing exactly as if it were not cloned at all.
#
# Nothing said so. Standing up the Windows/WSL app host for micro-org#338, the
# only signal that a whole repository was missing was this, from the middle of a
# bootstrap:
#
#   FileNotFoundError: '../contracts/packages/events/src/audit.ts'
#
# A Python traceback naming a path inside a repository the operator has never
# heard of, which is the least actionable form the message could have taken for
# the one person guaranteed to hit it: whoever is standing up a new machine.
#
# ── THE TABLE IS THE SOURCE, AND IT IS CHECKED ────────────────────────────────
#
# `estate-bootstrap.sh` runs this with `--check` in its pre-flight rather than
# keeping a second list, and `check-sibling-prerequisites.py` fails CI if a
# script grows a `../<something>/` read that this table does not name. A
# prerequisite list maintained by hand is a list that is accurate on the day it
# is written, and the failure it prevents only ever shows up on a fresh host —
# the one place nobody is testing.
#
# ── WITNESS FILES, NOT DIRECTORIES ────────────────────────────────────────────
#
# Each row names the FILE the tooling actually opens. A directory that exists is
# not the question — `git clone` interrupted halfway, a clone made under the
# wrong name and then renamed onto a stale one, or a repository whose layout has
# moved all produce a present directory that fails at the same traceback. Every
# witness below was confirmed present in a real checkout on 2026-08-11.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SIBLINGS=${SIBLINGS:-..}
ORG_URL=${ORG_URL:-https://github.com/cloudsforge-online}
# Empty means a full clone. The asset repositories are hundreds of PNGs and a
# deploy host reads only their current contents, so `CLONE_DEPTH=1` is a
# reasonable thing to want and a bad thing to impose: `cfctl release` in micro-org
# reads git history, and a shallow `org` would break the release path it feeds.
CLONE_DEPTH=${CLONE_DEPTH:-}

# dir|repo|witness path within the repo|tier|what breaks without it
#
# REQUIRED  a documented command cannot run at all.
# DEGRADED  the command runs and silently does less than it says.
# OPTIONAL  a cosmetic or genuinely absent-by-default feature.
SIBLING_TABLE="\
org|micro-org|releases|REQUIRED|release-deploy.sh reads ../org/releases/<version>.yaml — without it there is no deploy and no rollback
contracts|micro-contracts|packages/events/src/audit.ts|REQUIRED|estate-bootstrap.sh reads the audited topic list from the contract; absent, it dies with a FileNotFoundError traceback
ui|micro-ui|packages/ui/src/surfaces.ts|REQUIRED|estate-up.sh runs surface-routes.py over the surface registry, and seed/beacon.mjs imports it
analytics|micro-analytics|src/catalogue.ts|DEGRADED|estate-bootstrap.sh cannot read EVENT_TOPICS, so analytics is never subscribed to anything and the estate looks healthy
runtime|micro-runtime|packages/telemetry|DEGRADED|make check-backup cannot run, and the runtimepkgs build context is unresolvable so no service can be built from source
brand|micro-brand|review/sheet-og.png|OPTIONAL|seeded market listings for the CloudsForge identity suite get no cover image
emberkin-assets|micro-emberkin-assets|review/sheet-species.png|OPTIONAL|the seeded Emberkin listing gets no cover image
aetherholm-assets|micro-aetherholm-assets|review/sheet-keyart.png|OPTIONAL|the seeded Aetherholm listing gets no cover image
tessera-assets|micro-tessera-assets|materialise.py|OPTIONAL|no source for the world art in CF_WORLD_ASSETS; /world-assets/ 404s, which the compose gate calls the supported default"

check_only=0
include_optional=0
for arg in "$@"; do
  case "$arg" in
    --check) check_only=1 ;;
    --all)   include_optional=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

missing_required=0
missing_degraded=0
missing_optional=0
# Collected and printed together. The ticket asks for this by name: a preflight
# that surfaces one prerequisite per run makes standing up a host a sequence of
# clone-rerun-clone-rerun, and each of those runs is a bootstrap against a
# half-provisioned estate.
report=""

while IFS='|' read -r dir repo witness tier why; do
  [ -z "$dir" ] && continue
  if [ "$tier" = "OPTIONAL" ] && [ "$include_optional" -eq 0 ] && [ "$check_only" -eq 0 ]; then
    continue
  fi

  path="$SIBLINGS/$dir"
  if [ -e "$path/$witness" ]; then
    [ "$check_only" -eq 1 ] && printf '  \033[32mok\033[0m       %-18s %s\n' "$dir" "$repo"
    continue
  fi

  present=""
  [ -d "$path" ] && present=" (the directory exists; $witness does not — an interrupted or wrongly-named clone looks exactly like this)"

  case "$tier" in
    REQUIRED) missing_required=$((missing_required + 1)) ;;
    DEGRADED) missing_degraded=$((missing_degraded + 1)) ;;
    *)        missing_optional=$((missing_optional + 1)) ;;
  esac
  report="$report
missing prerequisite: $SIBLINGS/$dir   ($tier)
  clone $repo AS '$dir' — the directory name is not the repository name:
      git clone $ORG_URL/$repo.git $SIBLINGS/$dir
  without it: $why"

  if [ "$check_only" -eq 0 ]; then
    if [ -d "$path" ] && [ ! -e "$path/$witness" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
      echo "  skip     $dir — the directory exists and is not empty, but $witness is absent." >&2
      echo "           Refusing to clone over it; inspect it and remove it by hand." >&2
      continue
    fi
    echo "  clone    $repo -> $SIBLINGS/$dir"
    depth_arg=()
    [ -n "$CLONE_DEPTH" ] && depth_arg=(--depth "$CLONE_DEPTH")
    if git clone ${depth_arg[@]+"${depth_arg[@]}"} "$ORG_URL/$repo.git" "$path"; then
      if [ -e "$path/$witness" ]; then
        printf '  \033[32mok\033[0m       %s\n' "$dir"
        case "$tier" in
          REQUIRED) missing_required=$((missing_required - 1)) ;;
          DEGRADED) missing_degraded=$((missing_degraded - 1)) ;;
          *)        missing_optional=$((missing_optional - 1)) ;;
        esac
      else
        echo "  FAIL     $dir cloned and still has no $witness — the layout has moved." >&2
        echo "           This table names the file the tooling opens, so a clone that does not" >&2
        echo "           contain it does not satisfy the prerequisite." >&2
      fi
    else
      echo "  FAIL     could not clone $repo" >&2
    fi
  fi
done <<EOF
$SIBLING_TABLE
EOF

if [ -n "$report" ]; then
  echo "$report" >&2
fi

if [ "$missing_required" -gt 0 ]; then
  echo >&2
  echo "$missing_required REQUIRED sibling checkout(s) are missing." >&2
  echo "Provision them all with:  ./scripts/provision-siblings.sh" >&2
  exit 1
fi

if [ "$missing_degraded" -gt 0 ]; then
  echo >&2
  echo "$missing_degraded sibling checkout(s) are missing that DO NOT stop a deploy and DO" >&2
  echo "reduce what one does — see each line above for what silently stops happening." >&2
fi

if [ "$check_only" -eq 1 ]; then
  if [ "$missing_required" -eq 0 ] && [ "$missing_degraded" -eq 0 ] && [ "$missing_optional" -eq 0 ]; then
    echo "  every sibling this repository reads is checked out under the name it is read by"
  fi
else
  echo "siblings provisioned. Optional asset repositories: re-run with --all."
fi
exit 0
