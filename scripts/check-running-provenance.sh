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
#   NO TAG    the container is pinned by digest and carries no release-tag label, so there is no
#             version to compare at all. A failure, never a skip — see the block below.
#
# ── A DIGEST-PINNED RELEASE HAS NO TAG IN `docker ps`, AND 2.5.8 IS THE FIRST ONE ────────────────
#
# micro-deploy#18 made `release-render.py` emit `image@sha256:…` for every manifest entry that
# carries a digest, and `cfctl release` has recorded digests since micro-org#288. So 2.5.8 is the
# first release this estate deploys by digest, and a digest names bytes rather than a version —
# which is precisely the input this check could not read.
#
# HOW BADLY IT COULD NOT READ IT DEPENDS ON THE HOST'S IMAGE STORE, AND BOTH ANSWERS ARE WRONG.
# `docker ps` TRUNCATES `{{.Image}}` unless told not to, and the truncation for a digest reference
# is not a shortening — it is a different string. Measured 2026-08-09 against the docker CLI, with
# `/containers/json` served by a stub so the two stores could be compared side by side:
#
#   ImageID != the index digest (overlay2 — what the estate host runs, docker 29.3.1):
#       {{.Image}}            -> ghcr.io/cloudsforge-online/micro-identity
#   ImageID == the index digest (containerd image store):
#       {{.Image}}            -> d8d8d8d8d8d8
#   Either store, with --no-trunc:
#       {{.Image}}            -> ghcr.io/cloudsforge-online/micro-identity@sha256:d8d8…
#
# On the estate's store the digest is DELETED and what is left parses cleanly as a repository with
# no tag, so the old `IFS=:` split produced an empty tag and every one of the 46 services reported
# MISMATCH "running (nothing) but main declares 2.5.6". That is the worst available failure: not a
# check that admits it measured nothing, but a full-estate provenance alarm, raised by the release
# mechanism working correctly, at the moment somebody is deploying.
#
# So the reference is read with `--no-trunc`, which is `Config.Image` verbatim on every store and
# every CLI version, and this script never has to know which truncation rule the host would apply.
#
# ── AND THE VERSION COMES FROM THE LABEL, BECAUSE COMPOSE DROPS COMMENTS ─────────────────────────
#
# The overlay carries the tagged reference each digest was resolved from twice: in a comment for
# whoever opens the file, and in the label `online.cloudsforge.release.tag` because
# `docker compose config` re-emits from a parsed model and drops every comment in it. The label is
# the half that reaches a container, so it is the half this reads.
#
# A container pinned by digest with no such label is a FAILURE and not a skip. Skipping it would
# make this check go quiet on exactly the releases the digest mechanism exists for, and "no alarm"
# would be read as "provenance verified" — the vacuous pass this file's own last block refuses one
# level up.
#
# ── Usage ────────────────────────────────────────────────────────────────────────────────────────
#
#   scripts/check-running-provenance.sh                            # testnet against design-system/*
#   scripts/check-running-provenance.sh cloudsforge-estate main    # mainnet against main
#
# The mainnet project used to be written `cf-mainnet` here and that project has never existed:
# `docker-compose.estate.yml` names it `${CF_PROJECT:-cloudsforge-estate}` and testnet overrides
# `CF_PROJECT=cf-testnet` in `compose/testnet.env`. Read off the host 2026-08-09 — the running
# projects are `cloudsforge-estate`, `cfmicro`, `cf-miners` and `hearth`. The documented mainnet
# invocation therefore matched no container and exited 2, which is at least loud.
#
# Exits non-zero on any MISMATCH, so it can gate a deploy rather than merely inform one.

set -uo pipefail

PROJECT="${1:-cf-testnet}"
REF_PREFIX="${2:-design-system/}"
ESTATE="${CLOUDSFORGE_ESTATE:-$HOME/dev/personal/cloudsforge-micro}"

# ── THE DEFAULT HOST MOVED, AND POINTING AT THE OLD ONE FAILS SILENTLY-ISH ───────────────────────
#
# Until 2026-08-10 this defaulted to `malf@192.168.1.42`, which then held everything. The app stack
# moved to `savva@192.168.1.129` and 192.168.1.42 kept only the UTXO daemons, which run as host
# processes rather than containers. So the old default now reaches a host with no estate containers
# on it at all, and this script's answer for that is `exit 2` with "no containers running" — a
# message that reads as "the estate is down" when what happened is that the question went to the
# wrong machine. Checked on 2026-08-11: asking for `2026.08.16` against the old default said no
# containers were running, while 47 of the 48 manifest digests were in fact live on the app host.
#
# `docker` is not on the Windows host's PATH in the shell ssh lands in — the estate runs inside
# WSL — so the command has to be routed through `wsl -d Ubuntu-24.04`. `CLOUDSFORGE_DOCKER_PREFIX`
# exists so the chain host, which is plain Linux, can still be targeted by clearing it:
#
#   CLOUDSFORGE_HOST=malf@192.168.1.42 CLOUDSFORGE_DOCKER_PREFIX= scripts/check-running-provenance.sh
HOST="${CLOUDSFORGE_HOST:-savva@192.168.1.129}"
DOCKER_PREFIX="${CLOUDSFORGE_DOCKER_PREFIX-wsl -d Ubuntu-24.04 -- }"

# The label `scripts/release-render.py` writes beside every digest-pinned image, holding the
# `image:tag` reference the digest was resolved from. One spelling, in both files.
TAG_LABEL="online.cloudsforge.release.tag"

# Read the running set off the host. `docker ps` is the only source of truth here: a compose file
# says what SHOULD run and this question is about what does.
#
# Two columns, tab-separated, because a digest-pinned container's version lives in the second one.
# The `sed` is global so the registry prefix is stripped from the label as well as from the image —
# the two are then directly comparable, which is what lets a label naming a DIFFERENT service than
# the image it sits on be caught below rather than silently believed.
running=$(ssh -o BatchMode=yes "$HOST" \
  "${DOCKER_PREFIX}docker ps --no-trunc --filter name=$PROJECT --format '{{.Image}}\t{{.Label \"$TAG_LABEL\"}}'" 2>/dev/null |
  tr -d '\r' | sed 's|ghcr.io/cloudsforge-online/micro-||g' | sort -u)

if [ -z "$running" ]; then
  # Name the host in the failure, because the most likely cause of an empty set is asking the wrong
  # machine rather than an estate that is down — see the note on the default above.
  echo "error: no containers running under $PROJECT on $HOST" >&2
  echo "       if that host is not where the estate runs, set CLOUDSFORGE_HOST" >&2
  exit 2
fi

fail=0
checked=0
digests=0

version_at() { # <repo> <ref> -> version, or empty
  git -C "$ESTATE/$1" show "$2:package.json" 2>/dev/null |
    node -p "try{JSON.parse(require('fs').readFileSync(0,'utf8')).version}catch(e){''}" 2>/dev/null
}

while IFS=$'\t' read -r image label; do
  [ -n "${image:-}" ] || continue

  # The repository name is derivable from EITHER form, so it is derived from the image and never
  # from the label: everything before the first `@` (a digest) or `:` (a tag). Deriving it from the
  # label instead would make a mislabelled container attribute itself to whatever it claimed.
  name="${image%%@*}"
  name="${name%%:*}"
  [ -d "$ESTATE/$name" ] || continue # a container with no repo checked out is not this check's business

  ref="${REF_PREFIX}${name}"
  case "$REF_PREFIX" in */) ;; *) ref="$REF_PREFIX" ;; esac # a bare ref like `main` is used as-is

  git -C "$ESTATE/$name" rev-parse --verify -q "$ref" >/dev/null 2>&1 || continue
  # Counted BEFORE the tag is resolved, deliberately. A digest-pinned container whose label is
  # missing is a container this check looked at and could not answer for, and leaving it out of the
  # count would let a whole digest-pinned estate reach the "nothing was verified" branch below and
  # be reported as an addressing mistake rather than as an unprovable release.
  checked=$((checked + 1))

  case "$image" in
  *@sha256:*)
    digests=$((digests + 1))
    if [ -z "${label:-}" ]; then
      printf '  NO TAG    %-18s pinned by digest and carries no %s\n' "$name" "$TAG_LABEL"
      fail=1
      continue
    fi
    # The label names an `image:tag`. Its repository half must be the same service the image is,
    # or the overlay has pinned one service to another's release line and every verdict below
    # would be about the wrong repository.
    labelled="${label%%@*}"
    labelled="${labelled%%:*}"
    if [ "$labelled" != "$name" ]; then
      printf '  MISMATCH  %-18s digest-pinned, but its %s names %s\n' "$name" "$TAG_LABEL" "$labelled"
      fail=1
      continue
    fi
    case "$label" in
    *:*) tag="${label##*:}" ;;
    *) tag="" ;;
    esac
    ;;
  *:*) tag="${image##*:}" ;;
  # An image reference with neither a tag nor a digest means `latest`, which no package.json
  # declares. Left empty so it falls through to MISMATCH, exactly as it did before.
  *) tag="" ;;
  esac

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

how=""
if [ "$digests" -gt 0 ]; then
  how=" ($digests pinned by digest, read through the $TAG_LABEL label)"
fi

if [ "$fail" -eq 1 ]; then
  echo "$checked checked$how; at least one container is running a build no watched ref would reproduce." >&2
  exit 1
fi

echo "$checked containers checked$how; every one is running the build its ref declares."
