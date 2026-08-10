#!/usr/bin/env bash
# ── ONE CREDENTIAL MUST HAVE ONE HOME (micro-org#156) ─────────────────────────
#
# Sourced by `up.sh`. It is a file of its own, and not fifteen lines inside that
# script, for one reason: `up.sh` ends by talking to Docker, so it cannot be run
# in a test, and a rule about credentials that no test exercises is a rule that
# is true on the day it is written. `scripts/check-token-resolution.sh` runs the
# functions below directly, against fixtures, in CI.
#
# ── THE DEFECT ────────────────────────────────────────────────────────────────
#
# Three tokens exist twice: as `CF_<X>_TOKEN` in the telemetry project's `.env`,
# and as `<X>_TOKEN` in the estate's `compose/estate/tokens.env`. The estate copy
# is the one that is TRUE — `docker-compose.estate.yml` requires it there with
# `:?` and no default, so it is what beacon, analytics and lantern authenticate
# against. The `.env` copy is only what `up.sh` writes into the files Prometheus
# and Alertmanager present when they scrape.
#
# Nothing kept the two in step. Measured on the mainnet host 2026-08-10, `.env`
# held a 64-character `CF_BEACON_TOKEN` while beacon ran on a different
# 44-character `BEACON_TOKEN`, and the next run of that idempotent,
# safe-to-repeat script would have written the stale one over the working one:
# Prometheus 401s against beacon `/metrics`, `BeaconScrapeFailing` fires, and the
# cause is a deploy rather than the rotation everyone would go looking at. (Both
# were the same 44-character value by the time this was written. The mechanism is
# what is fixed here, not that morning's values.)
#
# So: prefer the estate's file, fall back to `.env` on a host that has no estate,
# and REFUSE when both exist and disagree. The refusal is the point — a script
# that silently picks one of two credentials is a script that decides, halfway
# through a rotation, which half of the estate stops working.

# Overridable so the check script can point at a fixture. `up.sh` runs from the
# repository root, which is what makes the default relative path correct there.
estate_tokens_file="${estate_tokens_file:-compose/estate/tokens.env}"

# Reads ONE variable out of the estate's tokens file without sourcing it.
# Sourcing would pull ~40 estate variables into the environment that interpolates
# the telemetry and gateway compose files, where a shared name would change a
# rendering nobody edited.
#
# `head -1` rather than the last match: a duplicated name in an env file is a
# broken file, and taking the first is at least the same one `docker compose`
# would report as the conflict. A value spanning lines is not supported and never
# occurs here — these are all base64 tokens on one line.
estate_token() {
  [[ -r "$estate_tokens_file" ]] || return 0
  sed -n "s/^$1=//p" "$estate_tokens_file" | head -1
}

# 12-character SHA-256 prefix. Exists so a disagreement between two credentials
# can be reported precisely without either value reaching a terminal, a log or a
# transcript — which is the failure micro-org#156 is about in the first place.
fp() { printf '%s' "$1" | sha256sum | cut -c1-12; }

# RETURNS 1, IT DOES NOT `exit`. Callers assign the result and carry `|| exit 1`.
# An `exit` inside the `$( )` of an argument leaves only the SUBSHELL: the
# refusal would print, the substitution would yield the empty string,
# `write_secret` would report "keeping the existing …" and the deploy would carry
# on. A guard that announces itself and then does not stop is worse than no
# guard, because afterwards the log says it fired.
resolve_token() {
  local estate_name="$1" dotenv_name="$2"
  local from_estate dotenv_value
  from_estate=$(estate_token "$estate_name")
  dotenv_value="${!dotenv_name:-}"

  if [[ -n "$from_estate" && -n "$dotenv_value" && "$from_estate" != "$dotenv_value" ]]; then
    cat >&2 <<MSG
up.sh: REFUSING — $estate_name and $dotenv_name are two different credentials.

  $estate_tokens_file
      $estate_name=$(fp "$from_estate")  (${#from_estate} chars)  <- the estate authenticates on THIS
  .env
      $dotenv_name=$(fp "$dotenv_value")  (${#dotenv_value} chars)

  Those are 12-character SHA-256 fingerprints, not the values. Make .env agree
  with the estate file, or delete $dotenv_name from .env and let this take the
  estate's copy. Do not guess which is current — ask the service. See
  micro-org#156.
MSG
    return 1
  fi

  printf '%s' "${from_estate:-$dotenv_value}"
}
