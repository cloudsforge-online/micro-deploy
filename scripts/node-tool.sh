#!/usr/bin/env bash
# Print the path of a Node >= 22 this repository may run, or fail saying why.
#
#   NODE=$(./scripts/node-tool.sh) && "$NODE" ./scripts/estate-seed.mjs
#
# Diagnostics go to stderr, the interpreter path to stdout, and nothing else ever
# goes to stdout — the caller substitutes it.
#
# ══════════════════════════════════════════════════════════════════════════════
# ── WHY THIS FILE EXISTS: A GREEN LINE FOR A STEP THAT NEVER HAPPENED ─────────
#
# `estate-bootstrap.sh` §7 seeds the product surfaces, and its Node branch read:
#
#     elif ! command -v node >/dev/null 2>&1; then
#       ok "seeding skipped: no node on this machine (the seeder needs Node >= 22)"
#
# The deployment host has no Node and never has. So on every bootstrap this
# estate has ever run, seeding was skipped and REPORTED AS `ok` — and on
# 2026-08-05 both live estates were measured with `foresight.markets` 0,
# `market.listings` 0, `market.collections` 0, `mint.tokens` 0,
# `community.communities` 0, `nda.worlds` 0 and `beacon.probes` 0. Five empty
# products, green for months, because a missing interpreter was reported as a
# successful skip.
#
# A skip is a decision. `CF_SEED_SKIP=1` is a decision. "The tool is not
# installed" is not a decision, it is a failure, and the whole difference between
# this file and that line is that it is now reported as one — after this has had
# a real go at removing the cause.
#
# ── WHY IT FETCHES RATHER THAN TELLING SOMEBODY TO ────────────────────────────
#
# The alternative is a README line, and a README line is what the previous
# arrangement effectively was: the information existed and the estate stayed
# empty. `sudo apt install nodejs` is not available here — the deploy account is
# in the `sudo` group with no password, deliberately — and a bootstrap that
# requires an interactive privilege escalation is a bootstrap that does not run
# unattended.
#
# So this fetches ONE PINNED BUILD from nodejs.org into `.tools/`, which is
# git-ignored, user-owned, and touches nothing outside this checkout. No package
# manager, no PATH change, no version manager, nothing installed system-wide.
#
# ── AND WHY THE CHECKSUM IS IN THIS FILE ──────────────────────────────────────
#
# It downloads and then EXECUTES a binary, so the only thing standing between
# this estate and whatever nodejs.org serves tomorrow is a digest committed to
# git. The four below are from the official `SHASUMS256.txt` for v22.23.2 and a
# mismatch DELETES the download and fails — it never falls back to running it
# anyway, for the same reason `estate-seed.mjs` will not fall back to an
# unverified TLS request.
#
# The version is pinned rather than floating for the same reason: "the latest
# 22.x" is a different binary every few weeks and a digest that has to be
# updated is a digest somebody looks at.
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

NODE_VERSION=${CF_NODE_VERSION:-22.23.2}
TOOLS=${CF_TOOLS_DIR:-.tools}

# From https://nodejs.org/dist/v22.23.2/SHASUMS256.txt. Update BOTH the version
# above and every line here together; a stale digest fails closed.
sha_for() {
  case "$1" in
    linux-x64)     echo d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307 ;;
    linux-arm64)   echo fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8 ;;
    darwin-arm64)  echo 5eff7a9011895aae3f29d06f167b84a62b028a591370c7cafb59103559fd26e1 ;;
    darwin-x64)    echo 96dff79f4e19a78715da559ec7cac2028f4985a175ea0c3454625a269c21deb7 ;;
    *)             echo "" ;;
  esac
}

say() { printf 'node-tool: %s\n' "$1" >&2; }

# Is this interpreter one the seeder can run? The seeder uses `import`, top-level
# await, `AbortSignal.timeout` and native TypeScript stripping for the surface
# registry, so the floor is a real one and not a formality.
usable() {
  [ -x "$1" ] || return 1
  v=$("$1" --version 2>/dev/null) || return 1
  case "$v" in v*) ;; *) return 1 ;; esac
  major=${v#v}; major=${major%%.*}
  [ "$major" -ge 22 ] 2>/dev/null
}

# 1. Whatever the operator already has. A machine with Node 24 on PATH must not
#    grow a second copy of Node 22 in this checkout.
if [ -n "${CF_NODE:-}" ] && usable "$CF_NODE"; then
  echo "$CF_NODE"; exit 0
fi
if command -v node >/dev/null 2>&1 && usable "$(command -v node)"; then
  command -v node; exit 0
fi

case "$(uname -s)" in
  Linux)  os=linux ;;
  Darwin) os=darwin ;;
  *) say "unsupported OS $(uname -s) — install Node >= $NODE_VERSION yourself and set CF_NODE"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  arch=x64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) say "unsupported CPU $(uname -m) — install Node >= $NODE_VERSION yourself and set CF_NODE"; exit 1 ;;
esac
platform="$os-$arch"
want=$(sha_for "$platform")
if [ -z "$want" ]; then
  say "no pinned checksum for $platform — install Node >= $NODE_VERSION yourself and set CF_NODE"
  exit 1
fi

dir="$TOOLS/node-v$NODE_VERSION-$platform"
bin="$dir/bin/node"

# 2. The copy a previous run fetched. Verified by RUNNING it, not by the
#    directory existing: a half-extracted tarball leaves the path in place.
if usable "$bin"; then
  echo "$PWD/$bin"; exit 0
fi

if [ "${CF_NODE_NO_FETCH:-0}" = "1" ]; then
  say "no usable Node and CF_NODE_NO_FETCH=1 — refusing to download"
  exit 1
fi

tarball="node-v$NODE_VERSION-$platform.tar.xz"
url="https://nodejs.org/dist/v$NODE_VERSION/$tarball"
say "no Node >= 22 on this machine; fetching the pinned build $NODE_VERSION for $platform"

mkdir -p "$TOOLS" || exit 1
tmp="$TOOLS/$tarball.part"
rm -f "$tmp"
# `--fail` so an HTML error page is not extracted as if it were a tarball, and no
# `-k`: the one thing this must not do is take a binary off an unverified
# connection and then run it.
if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" "$url"; then
  rm -f "$tmp"
  say "could not download $url"
  say "the estate cannot seed its product surfaces without Node >= $NODE_VERSION."
  say "install one and re-run, or set CF_NODE to an existing interpreter."
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then
  got=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
else
  rm -f "$tmp"
  say "neither sha256sum nor shasum is available, so the download cannot be verified — refusing to run it"
  exit 1
fi
if [ "$got" != "$want" ]; then
  rm -f "$tmp"
  say "CHECKSUM MISMATCH for $tarball"
  say "  expected $want"
  say "  got      $got"
  say "the download has been deleted and nothing was executed."
  exit 1
fi

rm -rf "$dir"
if ! tar -xJf "$tmp" -C "$TOOLS"; then
  rm -f "$tmp"; rm -rf "$dir"
  say "could not extract $tmp (is xz available?)"
  exit 1
fi
rm -f "$tmp"

if ! usable "$bin"; then
  say "extracted $tarball but $bin does not run — nothing usable was produced"
  exit 1
fi
say "using $PWD/$bin ($("$bin" --version))"
echo "$PWD/$bin"
