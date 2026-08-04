#!/usr/bin/env bash
# Deploy the estate from a release manifest — and roll it back the same way.
#
#   ./scripts/release-deploy.sh 2026.08.1            # deploy that release
#   ./scripts/release-deploy.sh --list               # what releases exist
#   ./scripts/release-deploy.sh --rollback           # go back to the previous one
#   ./scripts/release-deploy.sh 2026.08.1 --dry-run  # render and check, change nothing
#
# ── THE POINT ──────────────────────────────────────────────────────────────────
#
# 17 §89 requires every service to be "deployable and rollbackable BY MANIFEST
# ALONE", and 17 §277 says that a service deployed but not in the release
# manifest means "if a rollback cannot name its previous version, there is no
# rollback". Both were unmeetable, not because the manifest format was missing —
# micro-org designed it and `cfctl release` generates it — but because nothing in
# the estate had ever READ one. A format with a generator and no consumer proves
# a release can be described, not that one can be performed.
#
# Deploy and rollback below are LITERALLY the same code path with a different
# manifest. That is deliberate: a rollback that is a different procedure from a
# deploy is a procedure nobody has ever practised, and 3am is not when to find
# out which step was missing.
#
# ── WHERE A MANIFEST COMES FROM ────────────────────────────────────────────────
#
# Not from here. `cfctl release <version>` in micro-org generates it from each
# repository's package.json version and its git HEAD, refuses a dirty checkout
# ("an image tag cannot name a working tree"), and lists deployables it could not
# see under `absent:` rather than omitting them. This script only consumes that
# file. It never writes one, because a manifest a deploy can edit is a manifest
# that records what it wished had happened.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BASE=${BASE:-compose/docker-compose.estate.yml}
RELEASES=${RELEASES:-../org/releases}
OVERLAY=${OVERLAY:-compose/docker-compose.release.yml}


version=""
dry_run=0
rollback=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)  dry_run=1 ;;
    --rollback) rollback=1 ;;
    --list)
      echo "releases in $RELEASES:"
      ls -1 "$RELEASES"/*.yaml 2>/dev/null | sed 's|.*/||; s|\.yaml$||' | grep -v -- '-example$' || echo "  (none)"
      exit 0 ;;
    --*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)   version="$arg" ;;
  esac
done

# ── THE APEX, WHICH THIS SCRIPT USED TO WALK STRAIGHT PAST ─────────────────────
#
# `estate-up.sh:86-105` refuses to start when the shell's `CF_WEB_APEX` disagrees
# with the gateway's, because "the surfaces would be served on one apex and
# identity's hand-off allowlist would name another". This script never mentioned
# the apex at all, so the release path bypassed that guard entirely — and it cost
# exactly what the guard predicts.
#
# Measured on the first real deployment: the gateway served `cloudsforge.online`
# while `IDENTITY_HANDOFF_ORIGINS` and `LANTERN_RUM_ORIGINS` on the live
# containers were built for the default `cloudsforge.localtest.me`. Every surface
# answered 200 and looked healthy; cross-surface SSO and the RUM sink were dead,
# because they are allowlists and an allowlist that names the wrong origin fails
# silently rather than loudly.
#
# DERIVED, not merely checked. Requiring the operator to remember `CF_WEB_APEX=…`
# on every deploy is the same class of trap one rung higher: it would be right
# until somebody forgot, and forgetting produces a healthy-looking estate. The
# gateway's own env file is the single source, so read it and adopt it. An
# explicit shell value still wins if it AGREES, and is fatal if it does not —
# that disagreement is a real mistake worth stopping for.
TRAEFIK_ENV="compose/env/${CF_TRAEFIK_ENV:-traefik}.env"
gateway_apex=$(grep -E '^CF_WEB_APEX=' "$TRAEFIK_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)
if [ -z "$gateway_apex" ]; then
  echo "FATAL: $TRAEFIK_ENV defines no CF_WEB_APEX." >&2
  echo "       The gateway would render its routers with an empty Host() and serve nothing," >&2
  echo "       silently, while every container reported healthy." >&2
  exit 1
fi
if [ -n "${CF_WEB_APEX:-}" ] && [ "$CF_WEB_APEX" != "$gateway_apex" ]; then
  echo "FATAL: CF_WEB_APEX disagrees between the shell and the gateway." >&2
  echo "         shell          : $CF_WEB_APEX" >&2
  echo "         $TRAEFIK_ENV : $gateway_apex" >&2
  echo "       Deploying this would serve the surfaces on one apex while identity's" >&2
  echo "       hand-off allowlist named another — every surface 200, SSO dead." >&2
  exit 1
fi
export CF_WEB_APEX="$gateway_apex"
echo "apex: $CF_WEB_APEX  (from $TRAEFIK_ENV)"

# ── which manifest ─────────────────────────────────────────────────────────────
if [ "$rollback" -eq 1 ]; then
  # The deployment history IS `git log releases/`, so the previous release is the
  # previous manifest — not a tag, not a note in a channel, not somebody's shell
  # history. Sorted by version rather than by mtime: a file's timestamp changes
  # when it is checked out, and a rollback that picks by mtime picks whatever was
  # touched last.
  current=$(ls -1 "$RELEASES"/*.yaml 2>/dev/null | sed 's|.*/||; s|\.yaml$||' | grep -v -- '-example$' | sort -V | tail -1)
  version=$(ls -1 "$RELEASES"/*.yaml 2>/dev/null | sed 's|.*/||; s|\.yaml$||' | grep -v -- '-example$' | sort -V | tail -2 | head -1)
  if [ -z "$version" ] || [ "$version" = "$current" ]; then
    echo "cannot roll back: there is no release before ${current:-none} in $RELEASES." >&2
    echo "A rollback that cannot name its previous version is not a rollback." >&2
    exit 1
  fi
  echo "rolling back: $current -> $version"
fi

if [ -z "$version" ]; then
  echo "usage: $0 <version> | --rollback | --list [--dry-run]" >&2
  exit 2
fi

manifest="$RELEASES/$version.yaml"
if [ ! -f "$manifest" ]; then
  echo "no manifest at $manifest" >&2
  echo "Nothing is deployed from a manifest that does not exist. Generate one with:" >&2
  echo "  (in micro-org)  pnpm cfctl release $version" >&2
  exit 1
fi

echo "── rendering $manifest ──────────────────────────────────────────────────"
if ! python3 scripts/release-render.py "$manifest" --base "$BASE" --out "$OVERLAY"; then
  echo "render failed; nothing was deployed" >&2
  exit 1
fi

# ── every image must exist BEFORE anything is changed ──────────────────────────
# `cfctl release --verify` does this from the org side. It is done again here, on
# purpose, because refusing to deploy an unpullable manifest is a property of the
# DEPLOY and has to hold on a host where micro-org is not checked out at all.
#
# A 'denied' here is usually the GHCR visibility trap — a package that inherited
# a private repository's visibility — rather than a missing image. Say both.
echo "── verifying every image can be pulled ──────────────────────────────────"
missing=0
checked=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  checked=$((checked+1))
  if err=$(docker manifest inspect "$ref" 2>&1 >/dev/null); then
    printf '  \033[32mok\033[0m   %s\n' "$ref"
  else
    missing=$((missing+1))
    printf '  \033[31mFAIL\033[0m %s — %s\n' "$ref" "$(printf '%s' "$err" | head -1)"
  fi
done <<EOF
$(grep -oE 'image: [^ ]+' "$OVERLAY" | sed 's/image: //' | sort -u)
EOF

if [ "$checked" -eq 0 ]; then
  echo "the overlay pins no images — refusing to report an empty release as deployed." >&2
  exit 1
fi
if [ "$missing" -gt 0 ]; then
  echo >&2
  echo "$missing of $checked image(s) cannot be pulled. NOT DEPLOYING." >&2
  echo "This is the check that exists so the failure happens here rather than on the host." >&2
  exit 1
fi
echo "  all $checked image(s) exist"

if [ "$dry_run" -eq 1 ]; then
  echo
  echo "--dry-run: rendered $OVERLAY and verified $checked image(s). Nothing was changed."
  exit 0
fi

echo "── deploying ────────────────────────────────────────────────────────────"
# The overlay is second so it wins. The base keeps owning environment, ordering,
# health checks and ports; the release owns only which image runs.
if docker compose -f "$BASE" -f "$OVERLAY" up -d; then
  echo
  echo "release $version is up."
  echo "verify it:   ./scripts/estate-verify.sh"
  echo "roll it back: ./scripts/release-deploy.sh --rollback"
  exit 0
fi
echo "deploy failed" >&2
exit 1
