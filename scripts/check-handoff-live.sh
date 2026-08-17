#!/usr/bin/env bash
# Does the RUNNING identity actually allowlist the origins this estate serves?
#
# ── WHY THIS EXISTS, WHEN release-deploy.sh ALREADY CHECKS THE RENDER ─────────
#
# It checks the render, correctly and thoroughly, and #152 recurred anyway on
# 2026-08-05 — mainnet identity came back up with eighteen `cloudsforge.localtest.me`
# origins and cross-surface SSO was dead for every surface, the owner hitting it on
# Worlds.
#
# The guard did not pass. IT WAS NEVER RUN. It lives inside `release-deploy.sh`,
# and the container was recreated with a plain `docker compose up -d identity` —
# which is what operators and agents actually type, and what the Makefile's own
# `ESTATE` variable set up, because that variable named the compose file and NOT
# `--env-file compose/mainnet.env`. Compose then resolved
# `${CF_WEB_SUFFIX:-.cloudsforge.localtest.me}` to the dev default and shipped it.
#
# The failure is silent by construction on mainnet and impossible on testnet, and
# the asymmetry is the whole trap: `compose/.env` is a symlink to the mainnet
# tokens file and is auto-loaded, so a mainnet deploy with no `--env-file` still
# resolves `CF_POSTGRES_PASSWORD` and comes up healthy. Only the apex-dependent
# variables quietly fall back. Testnet has no such fallback, so the same mistake
# there fails loudly on the first interpolation and nobody ever ships it.
#
# So a guard bolted to ONE deploy path is not a guard. This one observes the
# RUNNING CONTAINER and therefore holds however the container got there — a
# release deploy, a bare `up -d`, a hand-rolled `docker run`, or a restart weeks
# later. It reads no compose file and interpolates nothing, because the thing it
# must not trust is precisely the rendering.
#
# ── AND IT ASKED FOR ONE ORIGIN, WHICH IS NOT THE SAME AS ASKING ──────────────
#
# Until micro-org#480 the required list was `hub` and nothing else, on the
# argument that hub is the origin every surface hands off FROM. True, and not
# enough: `pool.cloudsforge.online` shipped without an allowlist entry, served
# 200 throughout, and this check stayed green the whole time because the one
# origin it asked about was present. A required list of one passes on nineteen
# surfaces out of twenty.
#
# It derives the whole list from micro-ui's registry now — the same module
# `surface-routes.py` runs — so the question is "does the running container
# allowlist every surface the estate serves" rather than "does it allowlist the
# one I thought to name".
#
#   ./scripts/check-handoff-live.sh cloudsforge-estate-identity-1 .cloudsforge.online
#   ./scripts/check-handoff-live.sh cf-testnet-identity-1        -testnet.cloudsforge.online
#
# Prints hostnames, which are public, and no secret of any kind.
set -euo pipefail

container="${1:?usage: check-handoff-live.sh <identity-container> <web-suffix>}"
suffix="${2:?usage: check-handoff-live.sh <identity-container> <web-suffix>}"

if ! docker inspect "$container" >/dev/null 2>&1; then
  echo "FATAL: no such container: $container" >&2
  exit 1
fi

origins=$(docker inspect "$container" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep '^IDENTITY_HANDOFF_ORIGINS=' | cut -d= -f2- | tr -d ' ')

if [ -z "$origins" ]; then
  echo "FATAL: $container has an EMPTY IDENTITY_HANDOFF_ORIGINS." >&2
  echo "       identity refuses every origin when this list is empty, BY DESIGN, so every" >&2
  echo "       POST /auth/handoff answers 403 while every surface still returns 200 and" >&2
  echo "       nothing reports an error. Cross-surface SSO is dead and the deploy looks fine." >&2
  exit 1
fi

fail=0

# ── 1. EVERY browsable surface, derived from the registry, not just hub ───────
#
# This asked for `hub` alone until micro-org#480, and one required origin is a
# check that passes on nineteen of twenty. `pool.cloudsforge.online` was live,
# 200, `servesUi` in the registry, and absent from this list — and it made no
# noise here, because hub was present and hub is all that was asked.
#
# The registry is the same one `surface-routes.py` reads, RUN rather than parsed,
# so a row that arrives in micro-ui arrives here on the next deploy with nothing
# to remember. `servesUi && !basePath` is the estate's predicate for "a hostname
# a browser loads a page from": a basePath surface rides another surface's
# origin and would be a duplicate, and a surface with no page has no `Origin`
# header to send.
#
# The apex is spelled from the suffix rather than passed in, because the two are
# one fact in every environment this estate has ever had — `.cloudsforge.online`
# / `cloudsforge.online` and `-testnet.cloudsforge.online` /
# `testnet.cloudsforge.online`. Stripping the leading separator yields
# CF_SITE_HOST in both.
site_host="${suffix#[.-]}"

ui_registry="$(cd "$(dirname "$0")/.." && pwd)/../ui/packages/ui"
required_subs=""
if [ -d "$ui_registry" ] && command -v node >/dev/null 2>&1; then
  required_subs=$(cd "$ui_registry" && node --import tsx -e \
    "import {SURFACES} from './src/surfaces.ts';\
     console.log(SURFACES.filter(s=>s.servesUi && !s.basePath).map(s=>s.subdomain).join(' '))" \
    2>/dev/null | tail -1) || required_subs=""
fi

if [ -z "$required_subs" ]; then
  # A DEPLOY HOST CLONES NO FRONTEND (`scripts/provision-siblings.sh`), so the
  # registry is genuinely unreadable there. That is reported rather than passed
  # over — the weaker check still runs and says out loud that it is the weaker
  # one, which is this repository's rule for a check that cannot fully run.
  echo "note: micro-ui is not checked out beside this repo, so the full surface list" >&2
  echo "      could not be derived. Falling back to hub + the apex; run this from a" >&2
  echo "      full checkout (or CI) to check every surface." >&2
  required_subs="hub"
  required_origins="https://hub${suffix} https://${site_host}"
else
  required_origins=""
  for sub in $required_subs; do
    if [ -z "$sub" ]; then
      required_origins="$required_origins https://${site_host}"
    else
      required_origins="$required_origins https://${sub}${suffix}"
    fi
  done
fi

for required in $required_origins; do
  case ",${origins}," in
    *",${required},"*) ;;
    *)
      echo "FATAL: $container does not allowlist ${required}." >&2
      echo "       identity answers 403 to every POST /auth/handoff for that origin, so a" >&2
      echo "       reader signed in anywhere else is bounced back to that surface signed" >&2
      echo "       out — which reads as a broken account rather than a missing config line." >&2
      fail=1 ;;
  esac
done

# 2. THE CHECK THAT WOULD HAVE CAUGHT THIS ONE. A production estate carrying dev
#    origins is the exact recurrence of #152, and it is invisible to any check
#    that only compares its own inputs with each other — they agreed perfectly
#    while production was broken.
case "$suffix" in
  *localtest.me) ;;
  *)
    if printf '%s' "$origins" | grep -q 'localtest\.me'; then
      echo "FATAL: $container allowlists localtest.me origins on a NON-DEV estate." >&2
      echo "       This is #152 recurring: the container was created without" >&2
      echo "       --env-file compose/mainnet.env, so CF_WEB_SUFFIX fell back to its dev" >&2
      echo "       default. Redeploy with BOTH env files (see the Makefile's ESTATE)." >&2
      fail=1
    fi ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "       live list: $origins" >&2
  exit 1
fi

echo "ok: $container allowlists $(printf '%s' "$required_origins" | wc -w | tr -d ' ') required origin(s)\
 and no dev origins ($(printf '%s' "$origins" | tr ',' '\n' | grep -c .) entries)"
