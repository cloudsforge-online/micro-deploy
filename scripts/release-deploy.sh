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
#
# ── AND WHICH GATEWAY FILE, WHICH `ESTATE_ENV` ALONE DID NOT REACH ────────────
#
# `compose/env/${CF_TRAEFIK_ENV:-traefik}.env` reads `CF_TRAEFIK_ENV` FROM THE
# SHELL. This script selects the estate with `--env-file`, which COMPOSE reads
# and the shell does not, so `ESTATE_ENV=compose/testnet.env` left the variable
# unset and this line silently chose MAINNET's gateway file.
#
# It does not stop at reading it. The loop below EXPORTS the three variables it
# finds, and an exported shell variable outranks every `--env-file` in compose
# interpolation — so a testnet deploy rendered MAINNET hostnames into every
# container variable built from them, and the rendered-allowlist guard 300 lines
# down then checked that allowlist against the same mainnet values and passed.
#
# Measured on the app host on 2026-08-10, immediately after deploying testnet
# 2.5.14 with ESTATE_ENV=compose/testnet.env and the matching tokens file — the
# variable NAMES, read off the live containers, whose values named mainnet:
#
#   cf-testnet-identity-1   IDENTITY_HANDOFF_ORIGINS, IDENTITY_ACCOUNT_URL
#   cf-testnet-lantern-1    LANTERN_RUM_ORIGINS
#   cf-testnet-beacon-1     BEACON_HANDOFF_ORIGIN
#   cf-testnet-faucet-1     FAUCET_CORS_ORIGINS
#   cf-testnet-foresight-1  STUDIO_PUBLIC_URL
#   cf-testnet-market-1     STUDIO_PUBLIC_URL
#
# Every testnet surface answered 200 throughout. Cross-surface SSO answered 403,
# the RUM sink 400, and a testnet verification mail would have carried a link to
# mainnet's Hub. Re-running the deploy did not repair it: the second run made the
# same substitution and therefore rendered an IDENTICAL config, so compose saw no
# change and recreated nothing.
#
# The estate's own env file already declares the answer — `compose/testnet.env`
# sets `CF_TRAEFIK_ENV=traefik.testnet` — so read it from there, the same way the
# three variables below are read from the file that owns THEM. Same rule as the
# apex: an explicit shell value wins if it agrees and is fatal if it does not.
estate_traefik_env=$(grep -E '^CF_TRAEFIK_ENV=' "$ESTATE_ENV" 2>/dev/null | tail -1 | cut -d= -f2-)
if [ -n "${CF_TRAEFIK_ENV:-}" ] && [ -n "$estate_traefik_env" ] &&
   [ "${CF_TRAEFIK_ENV}" != "$estate_traefik_env" ]; then
  echo "FATAL: CF_TRAEFIK_ENV disagrees between the shell and $ESTATE_ENV." >&2
  echo "         shell        : $CF_TRAEFIK_ENV" >&2
  echo "         $ESTATE_ENV : $estate_traefik_env" >&2
  echo "       One of them names the wrong environment's gateway file, and whichever" >&2
  echo "       wins is exported into compose's interpolation — so this deploy would" >&2
  echo "       build one estate's hand-off allowlist out of the other's hostnames." >&2
  exit 1
fi
export CF_TRAEFIK_ENV="${CF_TRAEFIK_ENV:-${estate_traefik_env:-traefik}}"
TRAEFIK_ENV="compose/env/${CF_TRAEFIK_ENV}.env"

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
# Mainnet was unaffected when this was written, and is now affected the same way
# testnet was: as of 2026-08-09 `mainnet.env` sets `COMPOSE_PROFILES=pool`, so
# the render sees `pool` and `pool-migrate` and pins them, and without the flag it
# would not — the same missing pin that made a deploy host try to BUILD faucet
# from a source tree it does not have. Neither environment renders its full
# service list without both env files any more.
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

# ── DOCKER'S CREDENTIAL HELPER, WHICH THIS HOST CANNOT RUN (micro-org#359) ────
#
# The app host is Windows running WSL2, and `docker` inside the distro is Docker
# Desktop's integration — so `~/.docker/config.json` is the WINDOWS config and its
# `credsStore` names a Windows binary. That helper needs an interactive Windows
# logon session. Over `ssh → wsl -d Ubuntu-24.04` there is not one, and docker
# consults the helper on EVERY pull, including anonymous ones. The estate's GHCR
# packages are public and no credential was ever needed; a helper that could not
# answer a question nobody had to ask blocked an entire release.
#
# Measured on 192.168.1.129 (WSL Ubuntu-24.04) on 2026-08-10, over ssh:
#
#   docker-credential-desktop.exe list  -> exit 1,
#     "A specified logon session does not exist. It may already have been terminated."
#   docker pull hello-world             -> exit 1,
#     "error getting credentials - err: exit status 1, out: `A specified logon
#      session does not exist. It may already have been terminated.`"
#   DOCKER_CONFIG=$HOME/.docker-cf docker pull hello-world  -> exit 0
#
# ── WHY THE HELPER IS EXERCISED RATHER THAN LOOKED FOR ────────────────────────
#
# The obvious check — is the helper binary on PATH — CANNOT FAIL HERE. Measured
# on the same host and the same day: `docker-credential-desktop.exe`,
# `docker-credential-wincred.exe` and `docker-credential-ecr-login.exe` are all
# on PATH through WSL's Windows interop. They exist and they do not work. So this
# runs the helper and reads its ANSWER.
#
# `list` is the probe because it is the one credential-helper verb that needs no
# argument and no stored credential, and a healthy helper answers it with a JSON
# object — `{}` when it holds nothing. Judging it by its exit status alone would
# call a helper broken for having an empty keychain; judging it by whether it
# SPOKE THE PROTOCOL is the question actually being asked.
DOCKER_CONFIG_DIR=${DOCKER_CONFIG:-$HOME/.docker}
DOCKER_CONFIG_FALLBACK=${DOCKER_CONFIG_FALLBACK:-$HOME/.docker-cf}

# Both keys, because they configure the same thing at different scopes:
# `credsStore` is the default helper and `credHelpers` overrides it per registry.
# A `credHelpers` entry for ghcr.io alone breaks this deploy exactly as totally.
docker_credential_helpers() { # <config dir> -> one helper NAME per line
  [ -f "$1/config.json" ] || return 0
  python3 - "$1/config.json" <<'PY' 2>/dev/null
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(doc, dict):
    sys.exit(0)
names = set()
store = doc.get("credsStore")
if isinstance(store, str) and store:
    names.add(store)
helpers = doc.get("credHelpers")
if isinstance(helpers, dict):
    names.update(h for h in helpers.values() if isinstance(h, str) and h)
print("\n".join(sorted(names)))
PY
}

broken_helper=""
broken_helper_said=""
while IFS= read -r helper; do
  [ -z "$helper" ] && continue
  if ! command -v "docker-credential-$helper" >/dev/null 2>&1; then
    broken_helper="$helper"
    broken_helper_said="docker-credential-$helper is named in the config and is not on PATH"
    break
  fi
  if probe=$("docker-credential-$helper" list </dev/null 2>&1) &&
     printf '%s' "$probe" | python3 -c 'import json,sys; json.loads(sys.stdin.read() or "{}")' 2>/dev/null
  then
    continue
  fi
  broken_helper="$helper"
  broken_helper_said=$(printf '%s' "$probe" | grep -v '^[[:space:]]*$' | tail -1)
  broken_helper_said=${broken_helper_said:-it produced no output and did not speak the credential protocol}
  break
done <<EOF
$(docker_credential_helpers "$DOCKER_CONFIG_DIR")
EOF

if [ -n "$broken_helper" ]; then
  echo "── docker's credential helper does not work here; routing around it ─────"
  echo "  config     : $DOCKER_CONFIG_DIR/config.json names the helper '$broken_helper'"
  echo "  it said    : $broken_helper_said"
  if [ "$DOCKER_CONFIG_FALLBACK" = "$DOCKER_CONFIG_DIR" ]; then
    echo "FATAL: DOCKER_CONFIG_FALLBACK is the same directory as the broken config." >&2
    echo "       There is nowhere to put a helper-free config, so every pull below would" >&2
    echo "       fail on the credential lookup this block exists to avoid." >&2
    exit 1
  fi
  # An EXISTING fallback is validated rather than overwritten: an operator may
  # have put real `auths` in it, and clobbering those would turn a working private
  # pull into a `denied` that this script had caused itself.
  if [ -f "$DOCKER_CONFIG_FALLBACK/config.json" ]; then
    if [ -n "$(docker_credential_helpers "$DOCKER_CONFIG_FALLBACK")" ]; then
      echo "FATAL: $DOCKER_CONFIG_FALLBACK/config.json names a credential helper too." >&2
      echo "       It is the fallback precisely because it must name none — pointing docker" >&2
      echo "       at it would reproduce the failure it exists to route around." >&2
      exit 1
    fi
  else
    # `{"auths":{}}` and nothing else. The estate's GHCR packages are public, so
    # an empty auth set is not a downgrade — it is what an anonymous pull needs,
    # and it is what docker refused to attempt while a helper was in the way.
    if ! mkdir -p "$DOCKER_CONFIG_FALLBACK" ||
       ! printf '{"auths":{}}\n' > "$DOCKER_CONFIG_FALLBACK/config.json"; then
      echo "FATAL: could not write $DOCKER_CONFIG_FALLBACK/config.json." >&2
      echo "       Every pull below would fail on the credential helper named above." >&2
      exit 1
    fi
    echo "  wrote      : $DOCKER_CONFIG_FALLBACK/config.json  (no credential helper)"
  fi
  # ── AND `DOCKER_CONFIG` IS NOT ONLY ABOUT CREDENTIALS ───────────────────────
  #
  # It also selects where the docker CLI looks for its plugins, so moving it can
  # take `docker compose` away with it — and this script is nothing but compose
  # calls after this point. Measured 2026-08-11, the same command on two machines:
  #
  #   app host (WSL)  plugins in /usr/local/lib/docker/cli-plugins, system-wide
  #                   DOCKER_CONFIG=$HOME/.docker-cf docker compose version -> v2.40.3
  #   a dev Mac       plugins in $HOME/.docker/cli-plugins, user-scoped
  #                   DOCKER_CONFIG=<other dir> docker compose version
  #                     -> "docker: unknown command: docker compose"
  #
  # So the fallback inherits the original's plugin directory when there is one.
  # A symlink rather than a copy: the plugins are large, and a copy would go stale
  # the first time docker is upgraded.
  if [ -d "$DOCKER_CONFIG_DIR/cli-plugins" ] && [ ! -e "$DOCKER_CONFIG_FALLBACK/cli-plugins" ]; then
    ln -s "$DOCKER_CONFIG_DIR/cli-plugins" "$DOCKER_CONFIG_FALLBACK/cli-plugins" 2>/dev/null &&
      echo "  linked     : $DOCKER_CONFIG_FALLBACK/cli-plugins -> $DOCKER_CONFIG_DIR/cli-plugins"
  fi

  export DOCKER_CONFIG="$DOCKER_CONFIG_FALLBACK"
  echo "  using      : DOCKER_CONFIG=$DOCKER_CONFIG for every registry call below"
  echo "  NOTE       : this deploy will pull ANONYMOUSLY. The estate's packages are public;"
  echo "               a private one would answer 'denied' rather than hang."

  # Asserted rather than reasoned about. The plugin directory is the known way this
  # redirection breaks a deploy, and every step from here to `up -d` is a compose
  # call — so the cost of being wrong is a deploy that dies later with a message
  # about a missing subcommand, which reads as a broken docker install rather than
  # as something this block did.
  if ! docker compose version >/dev/null 2>&1; then
    echo "FATAL: \`docker compose\` stopped working once DOCKER_CONFIG moved to" >&2
    echo "       $DOCKER_CONFIG." >&2
    echo "       DOCKER_CONFIG also selects the CLI's plugin directory, so a user-scoped" >&2
    echo "       compose plugin under $DOCKER_CONFIG_DIR/cli-plugins is no longer found." >&2
    echo "       Link it and re-run:" >&2
    echo "         ln -s $DOCKER_CONFIG_DIR/cli-plugins $DOCKER_CONFIG_FALLBACK/cli-plugins" >&2
    exit 1
  fi
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

# ── AND A THIRD WAY, WHICH IS NOT THE REGISTRY'S AT ALL (micro-org#359) ───────
#
# The two cases above are both ANSWERS FROM A REGISTRY. This one never reached a
# registry: docker asked its credential helper for a token, the helper failed, and
# docker gave up before opening a connection. The message is a local one.
#
# It matters because the retry rule that is right for a blip is catastrophic here.
# A blip is per-request, so the next attempt genuinely can differ. A credential
# helper that cannot run is a property of THE MACHINE — it will fail for this
# image, for the next image, and for every image, identically, forever.
#
# On 2026-08-10 that cost eighteen minutes of a deploy that could never succeed.
# With the defaults below the arithmetic is worse than it looks: five attempts
# from a three-second backoff is 3+6+12+24 = 45s of sleeping PER REFERENCE, and a
# release resolves to about fifty of them, so the loop would have spent roughly
# thirty-seven minutes re-asking a question whose answer cannot change before
# reporting the failure it already had in hand at second zero.
#
# So this returns "stop", and it stops the WHOLE RUN rather than this reference:
# once one image has proved this host cannot authenticate, the other forty-nine
# are not evidence and are not worth gathering.
registry_local_failure() { # <message> -> 0 when the failure is THIS HOST's
  case "$1" in
  *"error getting credentials"* | *"error storing credentials"* | \
    *"error listing credentials"* | *"credential helper"* | \
    *"docker-credential-"* | *"logon session"* | *"resolve authconfig"*)
    return 0
    ;;
  esac
  return 1
}

# Set once `registry_local_failure` has matched, and never cleared: it records a
# fact about the host, which no later reference can disprove.
registry_fatal=0

# The remedy, printed at the point of abort rather than left to be rediscovered.
# It names the cause first, because "error getting credentials" reads as a missing
# login and the fix is the opposite — REMOVING the credential path entirely.
registry_local_failure_note() {
  echo "       docker never reached a registry. It asked its credential helper for a token," >&2
  echo "       the helper failed, and docker refused to open the connection — so NO image" >&2
  echo "       will pull on this host, for any release, until that is fixed." >&2
  echo "       This is why the run stopped at the first reference instead of asking the" >&2
  echo "       same unanswerable question of every image in the release." >&2
  echo >&2
  echo "       On the Windows/WSL app host this is Docker Desktop's Windows credsStore," >&2
  echo "       which needs an interactive Windows logon session that ssh does not have." >&2
  echo "       The pre-flight above routes around it automatically; if you are seeing this," >&2
  echo "       it did not run or did not catch this helper. By hand, for this shell:" >&2
  echo >&2
  echo "         export DOCKER_CONFIG=\$HOME/.docker-cf" >&2
  echo "         mkdir -p \"\$DOCKER_CONFIG\"" >&2
  echo "         printf '{\"auths\":{}}' > \"\$DOCKER_CONFIG/config.json\"" >&2
  echo >&2
  echo "       The estate's GHCR packages are public, so a config with no credential" >&2
  echo "       helper at all is what an anonymous pull needs." >&2
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
    if registry_local_failure "$registry_err"; then
      registry_gaveup="this host cannot authenticate to any registry; retrying cannot change it"
      registry_fatal=1
      return 1
    fi
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
    # One reference is the whole proof when the failure belongs to the host.
    if [ "$registry_fatal" -eq 1 ]; then break; fi
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
  if [ "$registry_fatal" -eq 1 ]; then
    echo "THIS HOST CANNOT TALK TO A REGISTRY AT ALL. NOT DEPLOYING." >&2
    registry_local_failure_note
    exit 1
  fi
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

# ── AND WHETHER ANY OF IT WILL BE WATCHED (micro-org#308) ─────────────────────
#
# The scrape list is the same question the overlay answers — "what is running" —
# so it is rendered here, from the same manifest, by the same command. It was not
# rendered at all until now, and the cost of that was total: `prometheus/targets/
# services.yaml` held the literal `[]` from the telemetry plane's first deploy
# until 2026-08-09, so Prometheus scraped 8 targets on mainnet, 7 of which were
# the monitoring stack watching itself, while 48 services ran.
#
# Every money alert the estate has — LedgerTrialBalanceNonZero,
# LedgerReconciliationDrift, WithdrawalStuck, CustodyUnreachable,
# IndexerLagPastConfirmationDepth — was deployed, had a runbook, and evaluated
# against no data. #247/#248 (three days of frozen withdrawals) and #307 (every
# LTC function down for twenty minutes) were both found by a person, with a rule
# for exactly that condition sitting in alerts.yaml.
#
# TWO PHASES, AND THE SPLIT IS THE POINT.
#
#   Here, `--check`: validate and write nothing. The one thing that can fail is
#   a service the tier map does not name, and failing THERE means failing before
#   any container has been touched. A deploy stopped by this is fixed by one line
#   in prometheus/tiers.yaml and re-run; a deploy that had already switched and
#   then could not describe itself is an estate running a release nothing is
#   watching.
#
#   After `up -d`, the write. The file then describes what IS running rather than
#   what is about to. Written before the switch, it would name containers that do
#   not exist yet for the length of the deploy and Prometheus would report them
#   down — which is a page for the deploy rather than for a fault.
#
# --dry-run runs the check and not the write, like every other guard here: a
# guard only exercised on the real path is a guard nobody rehearses.
echo "── checking the scrape list this release implies ────────────────────────"
if ! printf '%s' "$config_json" | python3 scripts/render-prometheus-targets.py \
  "$manifest" --compose-json - --check; then
  echo >&2
  echo "The release cannot be described to Prometheus, so nothing was deployed." >&2
  echo "Fix the above and re-run. No container was created, started or stopped." >&2
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  echo
  echo "--dry-run: rendered $OVERLAY and confirmed $checked image(s) exist in the registry."
  echo "Nothing was pulled, and no container was created, started or stopped."
  # ── WHAT A CLEAN --dry-run DOES NOT PROVE (micro-org#359) ────────────────────
  #
  # It was read as "the deploy will work", and on 2026-08-10 it said "all 48
  # image(s) exist" minutes before a deploy that pulled nothing for eighteen
  # minutes. The phase above asks with `docker manifest inspect`, which resolves
  # a public image ANONYMOUSLY — measured on the WSL app host that day, it
  # answered normally while `docker pull` on the same host, in the same shell,
  # failed on the credential helper. Existence and pullability are two questions
  # and only one of them had been asked.
  #
  # The credential pre-flight at the head of this script now closes that
  # particular gap for both paths, which is why this says what it covered rather
  # than only what it did not.
  echo
  echo "It proved the manifest RESOLVES — \`docker manifest inspect\`, which reads a public"
  echo "image anonymously — and that this host's docker credential path works, which is a"
  echo "separate question and the one that stalled a deploy for eighteen minutes on"
  echo "2026-08-10. It did not prove there is disk for the layers, and it says nothing"
  echo "about whether the new images will start."
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
    # As in the verify phase: a host-side failure is proved by one reference, and
    # the remaining forty-nine would each cost the full backoff to prove it again.
    if [ "$registry_fatal" -eq 1 ]; then break; fi
  fi
done <<EOF
$pull_refs
EOF

if [ "$registry_fatal" -eq 1 ]; then
  echo >&2
  echo "THIS HOST CANNOT TALK TO A REGISTRY AT ALL. NOT DEPLOYING." >&2
  registry_local_failure_note
  echo >&2
  echo "       NO CONTAINER WAS CREATED, STARTED OR STOPPED." >&2
  exit 1
fi

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

  # ── AND NOW SOMETHING IS WATCHING IT ────────────────────────────────────────
  #
  # The write half of the pre-flight check above. `prometheus/targets/` is a
  # read-only bind mount into the Prometheus container and the `cf-services` job
  # re-reads it every 30s, so this is live within half a minute with no restart,
  # no reload signal and no gap — which is why it is safe to do it here, after
  # the switch, rather than before it.
  #
  # It does NOT fail the deploy. The images are already running and refusing to
  # exit 0 would not un-run them; the check that CAN fail already ran, before
  # anything moved. But it says so loudly, because an estate nothing is scraping
  # is the state micro-org#308 exists about and it lasted as long as it did by
  # being quiet.
  if ! printf '%s' "$config_json" | python3 scripts/render-prometheus-targets.py \
    "$manifest" --compose-json - --out prometheus/targets/services.yaml; then
    echo >&2
    echo "THE RELEASE IS DEPLOYED AND PROMETHEUS'S TARGET LIST WAS NOT UPDATED." >&2
    echo "It is still describing the previous release. Re-run the renderer by hand:" >&2
    echo "  make prometheus-targets RELEASE=$version" >&2
  fi

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
