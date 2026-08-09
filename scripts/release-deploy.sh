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

# ── AND THE TWO OF THEM MUST NAME THE SAME ESTATE (micro-org#238) ─────────────
#
# They are independent variables, and until now nothing compared them. A deploy
# given `ESTATE_ENV=compose/testnet.env` and the default mainnet tokens file was
# accepted without a word: it renders under testnet's project name, every line
# this script prints says testnet — including the tunnel check at the foot, which
# derives the environment from `$ESTATE_ENV` ALONE — and the containers hold
# MAINNET's service credentials, operator password and custody keyring selection.
#
# Nothing fails loudly, because the credentials are real. They are the other
# estate's. The best case is 401s from testnet identity against callers that look
# entirely correct; the worse case is a component that accepts them.
#
# Before the render rather than after, and before the apex checks below, because
# this is the one mistake that makes every subsequent line of output a confident
# statement about the wrong estate.
if ! ./scripts/check-env-files-agree.sh "$ESTATE_ENV" "$TOKENS_FILE"; then
  exit 1
fi

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
# `estate-up.sh` refuses to start when the shell's `CF_WEB_APEX` disagrees
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
# `release-render.py` added the flag FOR THIS CASE and names faucet in its
# own comment. Nothing ever passed it. That is the whole defect: a fix that
# reached the tool and not the caller, which is the same shape as the four
# frontend fixes this release is carrying.
#
# Mainnet is unaffected and that was checked rather than assumed: `mainnet.env`
# sets no `COMPOSE_PROFILES`, so the rendered service list is byte-identical
# with the flag and without it.
# BOTH env files, via the same `ENVSET` the deploy below uses. The render used to
# be passed `$ESTATE_ENV` alone, and because `--env-file` REPLACES the default
# rather than adding to it, that one file WAS the renderer's whole environment.
#
# It broke the moment the Postgres password became `${CF_POSTGRES_PASSWORD:?}`
# (16cdbf2, micro-org#190): that variable lives in the tokens file, the render
# could not see it, and `docker compose config --services` failed outright. No
# release could be rendered on either network — the render is the FIRST step, so
# this failed every deploy and every rollback, with the variable set correctly in
# both tokens files throughout.
#
# The header 130 lines up already argues that this script must pass both files
# "always, in this order… so tokens last means tokens win on any shared key". It
# was reasoning about the deploy. It is just as true of the render, and the render
# is what decides which services get pinned at all.
if ! python3 scripts/release-render.py "$manifest" --base "$BASE" "${ENVSET[@]}" --out "$OVERLAY"; then
  echo "render failed; nothing was deployed" >&2
  exit 1
fi

# ── A REGISTRY FAILS IN TWO WAYS AND THIS SCRIPT TREATED THEM AS ONE ──────────
#
# Every registry call below used to be one attempt, and any non-zero exit refused
# the deploy. That is right for one of the two failures and wrong for the other.
#
#   AN ANSWER.  `manifest unknown` means the registry looked and the tag is not
#               there. Trying again gets the same answer more slowly. The
#               manifest names an image that was never published and the deploy
#               must stop — retrying that is how a wrong release gets shipped on
#               the fifth attempt because somebody was watching the wrong line.
#   A BLIP.     `denied`, `unauthorized`, `TOO MANY REQUESTS`, a TLS handshake
#               that timed out, a connection reset. GHCR returns these under load
#               and to a token that is a second away from being refreshed, and
#               the next attempt succeeds. Refusing a whole release for one of
#               them is refusing it for the network's mood.
#
# The classification is deliberately WHITELIST-BY-ANSWER: only the phrases that
# mean "the registry looked and it is not there" abort immediately, and
# everything else is retried. The failure modes are asymmetric. Retrying a
# genuinely missing tag costs the backoff and then aborts anyway with the same
# message; treating a blip as final costs a refused deploy at the moment somebody
# is trying to ship, or — before the phase split below — half a deploy.
#
# `denied` deliberately sits on the retry side even though it is often the GHCR
# visibility trap, which no amount of retrying will fix. It is indistinguishable
# on the wire from the transient one, the trap is permanent and so survives the
# attempts, and the abort message names both causes.
REGISTRY_ATTEMPTS=${REGISTRY_ATTEMPTS:-5}
REGISTRY_BACKOFF=${REGISTRY_BACKOFF:-3}

registry_said_no() { # <message> -> 0 when the registry gave a definitive answer
  case "$1" in
  *"manifest unknown"* | *"no such manifest"* | *"not found"* | \
    *"name unknown"* | *"repository name not known"* | \
    *"reference does not exist"* | *"unsupported manifest media type"*)
    return 0
    ;;
  esac
  return 1
}

# Runs a registry command until it succeeds, until the registry answers no, or
# until the attempts run out. Exponential backoff because the two things that
# actually produce a blip — a rate limit and a saturated link — are both made
# worse by retrying at a fixed short interval, which is the shape of a client
# that turns one slow moment into an outage of its own making.
#
# Leaves the last error in `registry_err` and why it gave up in `registry_gaveup`.
registry_try() { # <label> <command…>
  local label="$1"
  shift
  local attempt=1
  local delay="$REGISTRY_BACKOFF"
  registry_err=""
  registry_gaveup=""
  while :; do
    # stderr captured, stdout discarded: `docker pull` writes layer progress to
    # stdout and the reason it failed to stderr, and only the reason is wanted.
    if registry_err=$("$@" 2>&1 >/dev/null); then return 0; fi
    registry_err=$(printf '%s' "$registry_err" | grep -v '^[[:space:]]*$' | tail -1)
    registry_err=${registry_err:-no error message}
    if registry_said_no "$registry_err"; then
      registry_gaveup="the registry answered; retrying cannot change it"
      return 1
    fi
    if [ "$attempt" -ge "$REGISTRY_ATTEMPTS" ]; then
      registry_gaveup="still failing after $REGISTRY_ATTEMPTS attempts"
      return 1
    fi
    printf '  \033[33mretry\033[0m %s — %s (attempt %d of %d, waiting %ss)\n' \
      "$label" "$registry_err" "$attempt" "$REGISTRY_ATTEMPTS" "$delay"
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# ── every image must exist BEFORE anything is changed ──────────────────────────
# `cfctl release --verify` does this from the org side. It is done again here, on
# purpose, because refusing to deploy an unpullable manifest is a property of the
# DEPLOY and has to hold on a host where micro-org is not checked out at all.
#
# A 'denied' here is usually the GHCR visibility trap — a package that inherited
# a private repository's visibility — rather than a missing image. Say both.
#
# `docker manifest inspect` takes a digest reference as happily as a tagged one,
# so this reads the same whichever form the manifest produced (micro-org#295).
#
# ANCHORED, because `grep -o` matches anywhere in a line. The overlay now emits
# `online.cloudsforge.release.tag: "ghcr.io/…:2.5.7"` beside each digest-pinned
# image so the tag survives `docker compose config`, and an unanchored
# `image: [^ ]+` matched every YAML KEY ending in `image` as well as the key
# itself. Measured 2026-08-09, rendering 2.5.7 re-cut with digests against the
# mainnet base while the label was briefly called `…release.image`: 96 references
# where the manifest names 48, half of them quoted strings, and this loop would
# have failed every one and refused to deploy any release at all. The overlay
# writes `image:` at exactly four spaces and nothing else in it does.
echo "── verifying every image can be pulled ──────────────────────────────────"
# Extracted once and reused by the pull phase further down, so the set of images
# this deploy is ABOUT cannot drift between the thing that checks them and the
# thing that fetches them.
release_refs=$(grep -oE '^    image: [^ ]+' "$OVERLAY" | sed 's/^    image: //' | sort -u)
missing=0
checked=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  checked=$((checked+1))
  if registry_try "$ref" docker manifest inspect "$ref"; then
    printf '  \033[32mok\033[0m   %s\n' "$ref"
  else
    missing=$((missing+1))
    printf '  \033[31mFAIL\033[0m %s — %s (%s)\n' "$ref" "$registry_err" "$registry_gaveup"
  fi
done <<EOF
$release_refs
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
#      (identity/src/handoff.ts is `allowlist.includes(origin)` over a frozen
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
#
# Held in a variable rather than piped straight through, because the pull phase
# below reads the same document for a different question — which images this
# project will need that are NOT in the release. Rendering it twice would let the
# allowlist and the pull set be computed from two different resolutions of the
# same files.
config_json=$(docker compose "${ENVSET[@]}" -f "$BASE" -f "$OVERLAY" config --format json 2>/dev/null)
rendered=$(printf '%s' "$config_json" | python3 -c '
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
  echo "--dry-run: rendered $OVERLAY and confirmed $checked image(s) exist in the registry."
  echo "Nothing was pulled, and no container was created, started or stopped."
  exit 0
fi

# ── PULL EVERYTHING, THEN SWITCH. THEY USED TO BE ONE STEP ────────────────────
#
# `docker compose up -d` interleaves the two: for each service in turn it pulls
# the image and then recreates the container. One `denied` on the 30th of 48
# images therefore aborted the deploy PARTWAY — 29 services on the new release
# and 19 on the old one, mid-flight, with no single version anywhere.
#
# That is the one outcome the release mechanism exists to prevent. The whole
# point of shipping one version across every deployable is that the estate is
# only ever tested as a set; a half-applied release is a combination nobody has
# ever run and that no manifest describes, so `--rollback` cannot even name what
# to go back to for the half that moved.
#
# A deploy that fails before it has touched anything is recoverable. One that
# fails halfway is an outage. So: fetch every image first, prove every one of
# them is on this host, and only then let compose replace containers. Everything
# above this line is a pre-flight; everything below it changes the estate.
#
# WHY NOT `docker compose pull`. 77 of the 81 services in the base file carry a
# `build:` and no `image:` at all — they only get one from the release overlay —
# so a project-wide pull asks the registry for `<project>-<service>` names that
# were never published. The refs are taken from the overlay instead, which is
# the same list the verify phase above just checked.
#
# The second list is everything compose will still need that the release does not
# name: `postgres:17-alpine` and friends, present on a running host and absent on
# a fresh one. A service that keeps its `build:` after the overlay is applied is
# excluded, because compose builds those rather than pulling them.
echo "── pulling every image before any container is replaced ─────────────────"
pull_refs=$(
  {
    printf '%s\n' "$release_refs"
    printf '%s' "$config_json" | python3 -c '
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for spec in (doc.get("services") or {}).values():
    if spec.get("build"):
        continue
    image = spec.get("image")
    if image:
        print(image)
' 2>/dev/null
  } | grep -v '^[[:space:]]*$' | sort -u
)

pulled=0
unpullable=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if registry_try "$ref" docker pull --quiet "$ref"; then
    pulled=$((pulled + 1))
    printf '  \033[32mpulled\033[0m %s\n' "$ref"
  else
    unpullable=$((unpullable + 1))
    printf '  \033[31mFAIL\033[0m   %s — %s (%s)\n' "$ref" "$registry_err" "$registry_gaveup"
  fi
done <<EOF
$pull_refs
EOF

if [ "$unpullable" -gt 0 ]; then
  echo >&2
  echo "$unpullable of $((pulled + unpullable)) image(s) could not be pulled. NOT DEPLOYING." >&2
  echo "       A 'denied' that survived $REGISTRY_ATTEMPTS attempts is usually the GHCR" >&2
  echo "       visibility trap — a package that inherited a private repository's" >&2
  echo "       visibility — rather than a busy registry." >&2
  echo "       NO CONTAINER WAS CREATED, STARTED OR STOPPED. The estate is still running" >&2
  echo "       the release it was running before this command, in one piece, and re-running" >&2
  echo "       this command once the images are pullable is the whole remedy." >&2
  exit 1
fi

# Pulled and present are different claims, and only the second one is what the
# switch below depends on. A pull can report success for a reference this host
# then cannot resolve — a manifest list with no entry for its platform is the
# usual way — so the thing that is actually required is asserted directly rather
# than inferred from the exit status of the thing that was supposed to cause it.
absent=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  docker image inspect "$ref" >/dev/null 2>&1 && continue
  absent=$((absent + 1))
  printf '  \033[31mABSENT\033[0m %s\n' "$ref"
done <<EOF
$pull_refs
EOF

if [ "$absent" -gt 0 ]; then
  echo >&2
  echo "$absent image(s) pulled without error and are not on this host. NOT DEPLOYING." >&2
  echo "       Nothing has been changed. Most often this is an image published for another" >&2
  echo "       platform only — check \`docker manifest inspect\` for a matching architecture." >&2
  exit 1
fi
echo "  all $pulled image(s) are on this host; the switch below needs no registry"

echo "── deploying ────────────────────────────────────────────────────────────"
# The overlay is second so it wins. The base keeps owning environment, ordering,
# health checks and ports; the release owns only which image runs.
#
# `--pull never` is what makes the phase split above load-bearing rather than
# merely earlier. Without it the split is a convention — compose would still be
# free to reach for the registry mid-switch and fail on the 30th service — and
# with it a partway abort caused by a registry cannot happen, because the switch
# phase is no longer allowed to talk to one. Every image it needs was just
# asserted present by name.
#
# Probed rather than assumed: the flag arrived in compose v2.15 and this refuses
# to hand an older CLI an option it would reject, which would abort the deploy
# for the guard rather than for anything wrong with the release.
PULL_POLICY=()
if docker compose up --help 2>&1 | grep -q -- '--pull'; then
  PULL_POLICY=(--pull never)
fi
if docker compose "${ENVSET[@]}" -f "$BASE" -f "$OVERLAY" up -d ${PULL_POLICY[@]+"${PULL_POLICY[@]}"}; then
  echo
  echo "release $version is up."

  # ── AND IS ANY OF IT REACHABLE? ─────────────────────────────────────────────
  #
  # `up -d` returning 0 means every container was created and, given the health
  # checks in the base file, will report healthy. It says NOTHING about whether a
  # browser can reach one, because the gateway is not in this compose project —
  # it is a separate stack on a separate network, brought up by a separate
  # command, and this script has never once looked at it.
  #
  # That gap is not hypothetical. Testnet's gateway has now been absent twice
  # (2026-08-05 and 2026-08-08) with all 46 services healthy and every public
  # hostname answering 502 both times. On the second occasion this script had
  # just reported "release 2.5.4 is up" and it was true and the estate was dark.
  #
  # AFTER the deploy rather than before, unlike every other guard here: an
  # unreachable origin is not a reason to refuse to ship new images, and the
  # gateway is a running-system fact that a pre-flight cannot establish. So it
  # runs, it prints, and it does not fail the deploy — but the last line of a
  # deploy now states whether anything can actually be served, which is the
  # sentence whose absence made "up" and "up and serving" look like one claim.
  case "$ESTATE_ENV" in
    *testnet*) tunnel_env=testnet ;;
    *)         tunnel_env=mainnet ;;
  esac
  echo
  if ! ./scripts/check-tunnel-origin.sh "$tunnel_env"; then
    echo
    echo "THE IMAGES ARE DEPLOYED AND THE ESTATE IS NOT PUBLICLY REACHABLE." >&2
    echo "Fix the origin above; nothing needs redeploying." >&2
  fi

  echo
  echo "verify it:   ./scripts/estate-verify.sh"
  echo "roll it back: ./scripts/release-deploy.sh --rollback"
  exit 0
fi
echo "deploy failed" >&2
exit 1
