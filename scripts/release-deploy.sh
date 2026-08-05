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

# ── THE ENV-FILE SET, WHICH USED TO BE A SINGLE IMPLICIT FILE ─────────────────
#
# This script called `docker compose -f … up -d` with no `--env-file` at all and
# relied on the default `.env` — a symlink to `estate/tokens.env`. That worked
# for mainnet by accident and could never have worked for testnet, because
# `--env-file` REPLACES the default rather than adding to it, so the moment a
# second environment needed its own env file it lost every credential (#158).
#
# Both files, always, in this order. The flag is repeatable and repeated flags
# merge, so tokens last means tokens win on any shared key.
ESTATE_ENV=${ESTATE_ENV:-compose/mainnet.env}
TOKENS_FILE=${TOKENS_FILE:-compose/estate/tokens.env}
for f in "$ESTATE_ENV" "$TOKENS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: $f does not exist." >&2
    echo "       Deploying without it would interpolate its variables to empty — the estate's" >&2
    echo "       hostnames, or every service credential in it. Both fail silently." >&2
    exit 1
  fi
done
ENVSET=(--env-file "$ESTATE_ENV" --env-file "$TOKENS_FILE")


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

# ── THREE VARIABLES, BECAUSE THE APEX ALONE STOPPED IDENTIFYING AN ENVIRONMENT ─
#
# This read `CF_WEB_APEX` and nothing else, and on 2026-08-05 that became a check
# that cannot fail. Both environments now serve on the zone `cloudsforge.online`
# — the environment lives inside the FIRST LABEL, as a suffix on the subdomain
# (`hub-testnet.cloudsforge.online`) — so comparing apexes agrees with itself
# whichever env file is in play, including the wrong one.
#
# `CF_WEB_SUFFIX` and `CF_SITE_HOST` are what actually differ, and both are
# interpolated by COMPOSE into identity's hand-off allowlist. A release deployed
# with the wrong one of them is the failure this block's header describes,
# undiminished: every surface 200, SSO dead.
for var in CF_WEB_APEX CF_WEB_SUFFIX CF_SITE_HOST; do
  file_val=$(grep -E "^$var=" "$TRAEFIK_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)
  if [ -z "$file_val" ]; then
    echo "FATAL: $TRAEFIK_ENV defines no $var." >&2
    echo "       The gateway would render its routers with an empty Host() and serve nothing," >&2
    echo "       silently, while every container reported healthy." >&2
    exit 1
  fi
  eval "shell_val=\${$var:-}"
  if [ -n "$shell_val" ] && [ "$shell_val" != "$file_val" ]; then
    echo "FATAL: $var disagrees between the shell and the gateway." >&2
    echo "         shell          : $shell_val" >&2
    echo "         $TRAEFIK_ENV : $file_val" >&2
    echo "       Deploying this would serve the surfaces on one set of hostnames while" >&2
    echo "       identity's hand-off allowlist named another — every surface 200, SSO dead." >&2
    exit 1
  fi
  eval "export $var=\"\$file_val\""
done
echo "hostnames: <surface>$CF_WEB_SUFFIX, site $CF_SITE_HOST  (from $TRAEFIK_ENV)"

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
# ── `--env-file`, WITHOUT WHICH A TESTNET RELEASE CANNOT DEPLOY AT ALL ────────
#
# The renderer asks `docker compose config --services` what this environment
# defines, and compose OMITS a profile-gated service unless the profile is
# active. `faucet` carries `profiles: [ember-testnet]` and `COMPOSE_PROFILES`
# lives in `compose/testnet.env` — so a render that did not pass that file was
# told faucet does not exist here, recorded it under "in the manifest but NOT in
# this environment", and emitted no `image:`/`build: !reset` pair for it.
#
# The failure is not the missing pin. It is what compose does with an unpinned
# service: `faucet` keeps its `build:` from the base file, so `up -d` tried to
# BUILD it — `unable to prepare context: path "…/faucet" not found`, because a
# deploy host has images and no source. The deploy died with the estate
# untouched, which is the right direction to fail in, but it dies on every
# attempt until this flag is passed.
#
# `release-render.py:51-61` added the flag FOR THIS CASE and names faucet in its
# own comment. Nothing ever passed it. That is the whole defect: a fix that
# reached the tool and not the caller, which is the same shape as the four
# frontend fixes this release is carrying.
#
# Mainnet is unaffected and that was checked rather than assumed: `mainnet.env`
# sets no `COMPOSE_PROFILES`, so the rendered service list is byte-identical
# with the flag and without it.
if ! python3 scripts/release-render.py "$manifest" --base "$BASE" --env-file "$ESTATE_ENV" --out "$OVERLAY"; then
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

# ── THE HAND-OFF ALLOWLIST, MEASURED RATHER THAN INFERRED ─────────────────────
#
# THE CHECK ABOVE COULD NOT FAIL, AND IT GUARDED THIS EXACTLY. Its header — 60
# lines up — says it exists because "the surfaces would be served on one apex and
# identity's hand-off allowlist would name another… every surface 200, SSO dead".
# It then compares CF_WEB_APEX, CF_WEB_SUFFIX and CF_SITE_HOST between a file and
# the shell. Every one of those comparisons is satisfied by an allowlist that is
# EMPTY, and satisfied again by one built for `.cloudsforge.localtest.me`,
# because the allowlist is not one of the things it looks at. It checks the
# INPUTS and asserts nothing about the OUTPUT.
#
# On 2026-08-05 the output was wrong for eleven hours. `IDENTITY_HANDOFF_ORIGINS`
# on the live mainnet container named `hub.cloudsforge.localtest.me` while the
# gateway served `hub.cloudsforge.online`; `POST /auth/handoff` answered 403 to
# every real origin and cross-surface SSO was dead. The three variables agreed
# with each other perfectly throughout.
#
# So this reads the RENDERED value — what compose will actually put in the
# container, after interpolation, from the same files and the same env-file set
# the deploy below uses — and asserts three things about it:
#
#   1. it is not empty. An empty allowlist refuses every origin by design
#      (identity/src/handoff.ts:32 is `allowlist.includes(origin)` over a frozen
#      empty array), and that design is correct — "empty means allow everything"
#      is how an allowlist becomes an open redirector. It is the DEPLOYMENT's
#      value that must not be empty, and nothing checked that until now.
#   2. it names this estate's Hub. That is the origin every surface hands off
#      FROM, so a list that omits it is a list under which nothing works.
#   3. it names this estate's apex surface, `CF_SITE_HOST`.
#
# Checked here rather than after `up -d` because a deploy that has already
# replaced the containers has already broken sign-in. --dry-run runs it too:
# a guard only exercised on the real path is a guard nobody rehearses.
echo "── checking the rendered hand-off allowlist ─────────────────────────────"
# `--format json` rather than the default YAML on purpose: parsing it needs only
# the standard library, so this guard has no third-party dependency it could be
# silently skipped for. PyYAML is absent from plenty of machines that can deploy.
rendered=$(docker compose "${ENVSET[@]}" -f "$BASE" -f "$OVERLAY" config --format json 2>/dev/null \
  | python3 -c '
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
env = ((doc.get("services") or {}).get("identity") or {}).get("environment") or {}
if isinstance(env, list):
    env = dict(e.split("=", 1) for e in env if "=" in e)
print((env.get("IDENTITY_HANDOFF_ORIGINS") or "").strip())
' 2>/dev/null)

if [ -z "$rendered" ]; then
  echo "FATAL: the rendered IDENTITY_HANDOFF_ORIGINS is EMPTY." >&2
  echo "       identity refuses every origin when this list is empty, by design, so" >&2
  echo "       POST /auth/handoff would answer 403 to every surface — while every surface" >&2
  echo "       returned 200 and nothing anywhere reported an error. Cross-surface SSO" >&2
  echo "       would be dead on arrival and this deploy would look completely successful." >&2
  echo "       (A config render that fails for any reason also lands here, on purpose:" >&2
  echo "        a check that silently skips is the defect this block exists to end.)" >&2
  exit 1
fi

for required in "https://hub$CF_WEB_SUFFIX" "https://$CF_SITE_HOST"; do
  case ",${rendered// /}," in
    *",$required,"*) ;;
    *)
      echo "FATAL: the rendered hand-off allowlist does not name $required." >&2
      echo "       The gateway will serve that hostname and identity will refuse to mint a" >&2
      echo "       hand-off code for it, so a user signs in at one surface and is signed out" >&2
      echo "       at every other. This is the failure the apex check above was written for" >&2
      echo "       and could not see, because it compares its inputs and never its output." >&2
      echo "       rendered: $rendered" >&2
      exit 1 ;;
  esac
done
echo "  allowlist names hub$CF_WEB_SUFFIX and $CF_SITE_HOST ($(printf '%s' "$rendered" | tr ',' '\n' | grep -c .) origins)"

if [ "$dry_run" -eq 1 ]; then
  echo
  echo "--dry-run: rendered $OVERLAY and verified $checked image(s). Nothing was changed."
  exit 0
fi

echo "── deploying ────────────────────────────────────────────────────────────"
# The overlay is second so it wins. The base keeps owning environment, ordering,
# health checks and ports; the release owns only which image runs.
if docker compose "${ENVSET[@]}" -f "$BASE" -f "$OVERLAY" up -d; then
  echo
  echo "release $version is up."
  echo "verify it:   ./scripts/estate-verify.sh"
  echo "roll it back: ./scripts/release-deploy.sh --rollback"
  exit 0
fi
echo "deploy failed" >&2
exit 1
