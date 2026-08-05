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

# 1. Hub, the origin every surface hands off FROM. A list without it works for nobody.
for required in "https://hub${suffix}"; do
  case ",${origins}," in
    *",${required},"*) ;;
    *)
      echo "FATAL: $container does not allowlist ${required}." >&2
      echo "       A user signs in at one surface and is signed out at every other." >&2
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

echo "ok: $container allowlists hub${suffix} and no dev origins ($(printf '%s' "$origins" | tr ',' '\n' | grep -c .) entries)"
