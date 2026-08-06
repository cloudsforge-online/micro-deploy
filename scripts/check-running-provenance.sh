#!/usr/bin/env bash
#
# What is RUNNING, and which git ref did it come from?
#
# ── Why this exists ──────────────────────────────────────────────────────────────────────────────
#
# Merged, published and running are three different states, and nothing in this estate compared
# them. GHCR tags are immutable, so a fix can be merged, green in CI, correct, and reach nobody —
# the release file still pins the tag it always pinned, and that tag still resolves to the build
# from before the fix. The failure is silent in the direction that matters: everything looks done.
#
# It has already cost real time twice.
#
#   * Two services were reported as "missing the secrets guard" and needed no code change at all.
#     They had it in source; the published image predated it. The version bump WAS the fix, and it
#     took a day of searching for a bug that did not exist to find that out.
#   * Two frontends ran images built from `main` during a merge that was later reverted. Their
#     design branches carried no version that could rebuild, so a build from the branch would have
#     published nothing and a deploy would have reported success while changing nothing.
#
# ── What it checks ───────────────────────────────────────────────────────────────────────────────
#
# For every running container, the tag it is running is compared against the `version` in the
# package.json of the git ref it is supposed to have come from. Three answers:
#
#   OK        the running tag equals the ref's version, and the ref is not main — so what is
#             running is what that branch says, and it is not accidentally main's build
#   SAME      the running tag matches, but the branch and main agree on the version, so this check
#             cannot tell which one built it. Not a failure; an admission of what is unknowable.
#   MISMATCH  the running tag is not the version any watched ref declares. Something is running
#             that no branch would rebuild, which is the state that wastes a day.
#
# ── Usage ────────────────────────────────────────────────────────────────────────────────────────
#
#   scripts/check-running-provenance.sh                      # testnet against design-system/*
#   scripts/check-running-provenance.sh cf-mainnet main       # mainnet against main
#
# Exits non-zero on any MISMATCH, so it can gate a deploy rather than merely inform one.

set -uo pipefail

PROJECT="${1:-cf-testnet}"
REF_PREFIX="${2:-design-system/}"
ESTATE="${CLOUDSFORGE_ESTATE:-$HOME/dev/personal/cloudsforge-micro}"
HOST="${CLOUDSFORGE_HOST:-malf@192.168.1.42}"

# Read the running set off the host. `docker ps` is the only source of truth here: a compose file
# says what SHOULD run and this question is about what does.
running=$(ssh -o BatchMode=yes "$HOST" \
  "docker ps --filter name=$PROJECT --format '{{.Image}}'" 2>/dev/null |
  sed 's|ghcr.io/cloudsforge-online/micro-||' | sort -u)

if [ -z "$running" ]; then
  echo "error: no containers running under $PROJECT on $HOST" >&2
  exit 2
fi

fail=0
checked=0

version_at() { # <repo> <ref> -> version, or empty
  git -C "$ESTATE/$1" show "$2:package.json" 2>/dev/null |
    node -p "try{JSON.parse(require('fs').readFileSync(0,'utf8')).version}catch(e){''}" 2>/dev/null
}

while IFS=: read -r name tag; do
  [ -n "${name:-}" ] || continue
  [ -d "$ESTATE/$name" ] || continue # a container with no repo checked out is not this check's business

  ref="${REF_PREFIX}${name}"
  case "$REF_PREFIX" in */) ;; *) ref="$REF_PREFIX" ;; esac # a bare ref like `main` is used as-is

  git -C "$ESTATE/$name" rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
  checked=$((checked + 1))

  want=$(version_at "$name" "$ref")
  mainv=$(version_at "$name" main)

  if [ "$tag" = "$want" ] && [ "$tag" != "$mainv" ]; then
    printf '  OK        %-18s %-9s from %s\n' "$name" "$tag" "$ref"
  elif [ "$tag" = "$want" ]; then
    printf '  SAME      %-18s %-9s %s and main agree; provenance unprovable\n' "$name" "$tag" "$ref"
  else
    printf '  MISMATCH  %-18s running %-9s but %s declares %s\n' "$name" "$tag" "$ref" "${want:-nothing}"
    fail=1
  fi
done <<<"$running"

echo
if [ "$checked" -eq 0 ]; then
  # A sweep that measured nothing must never read as a pass. This is the same defect the whole
  # check exists to catch, one level up.
  echo "error: no container matched a checked-out repo with a $REF_PREFIX ref — nothing was verified" >&2
  exit 2
fi

if [ "$fail" -eq 1 ]; then
  echo "$checked checked; at least one container is running a build no watched ref would reproduce." >&2
  exit 1
fi

echo "$checked containers checked; every one is running the build its ref declares."
