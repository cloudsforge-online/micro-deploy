#!/usr/bin/env bash
# A local certificate authority and one wildcard leaf, so a REAL BROWSER can use this estate.
#
#   cd deploy && ./scripts/gateway-cert.sh          # idempotent; regenerates only what is missing
#   cd deploy && ./scripts/gateway-cert.sh --force  # start again
#
# It also writes `gateway/certs/trust.crt` — the estate CA plus every public root
# in `gateway/trust/` — which is the file every internal client verifies with now
# that the mainnet gateway terminates on a Cloudflare Origin CA leaf. See the
# section near the end; the short version is that `ca.crt` stays exactly what it
# is, because it signs and because the owner installs it.
#
# ── WHY THIS EXISTS: THE ESTATE WAS ONLY EVER VERIFIED IN A MODE NO PERSON HAS ─
#
# The gateway terminated TLS on **Traefik's built-in self-signed default** —
# `CN=TRAEFIK DEFAULT CERT`, an authority nothing trusts. Every verification path
# in this repository turned certificate checking OFF to talk to it:
#
#   * `scripts/estate-verify.sh`  — `curl -k`, 183 times
#   * `scripts/estate-browser.sh` — `ignoreHTTPSErrors: true`
#   * `compose/docker-compose.estate-gateway.yml` — wrote the trade-off down and
#     called it "correct for loopback": "A browser will warn; `playwright-core`
#     takes `ignoreHTTPSErrors`, and `curl` takes `-k`".
#
# That is this estate's own named defect class — **a check that cannot fail** —
# in the one place it hurts most. `-k` does not merely tolerate a warning: it
# makes the entire transport layer untestable, so the estate reported 183 green
# assertions and 16 green browser journeys while being unusable in Chrome.
#
# ── WHAT ACTUALLY BREAKS, AND WHY IT LOOKS LIKE A NETWORK FAULT ───────────────
#
# A person opens `https://hub.<apex>`, gets the interstitial, clicks through. The
# PAGE loads, so the estate looks fine. Then the sign-in form posts to
# `https://nimbus.<apex>/auth/login` — a **different hostname**, cross-origin, and
# one the person has never been shown an interstitial for. **A browser never
# offers an interstitial for a subresource or an XHR.** Chrome fails the request
# outright with `net::ERR_CERT_AUTHORITY_INVALID`, `fetch` rejects with
# `TypeError: Failed to fetch`, and every frontend in this estate maps that to
# one string:
#
#     "Cannot reach the server. Check your connection and try again."
#
# Which is what the owner saw, on sign-in, on the Forge Worlds registry, and on
# every cross-origin call in the estate. It reads as a connection failure and it
# is a certificate failure. Reproduced with headless Chromium against the running
# gateway, twice — `ignoreHTTPSErrors: true` navigates fine, `false` fails with
# `net::ERR_CERT_AUTHORITY_INVALID` before a byte of HTML arrives.
#
# ── WHY A CA, AND NOT JUST A SELF-SIGNED WILDCARD ─────────────────────────────
#
# A browser exception is keyed PER HOST. This estate serves twenty-one hostnames
# under one apex and a single page talks to four of them, so a self-signed leaf
# would need twenty-one separate click-throughs — and the cross-origin ones can
# never be clicked at all, because the interstitial is never offered. One CA
# trusted once covers every host under the apex, today and for every host added
# later, with no further interaction.
#
# The CA is generated HERE, on this machine, and its private key never leaves
# `gateway/certs/` — which `.gitignore` refuses. It is a development CA for a
# development apex and it must never be installed anywhere that matters; the
# apex it signs, `*.localtest.me`, is a public wildcard that resolves to
# 127.0.0.1, so a leaf under it can only ever address loopback.
#
# ── mkcert IS NOT USED, DELIBERATELY ──────────────────────────────────────────
#
# `mkcert` does this well and is not installed here, and installing a tool at 3am
# to obtain four PEM files that `openssl` — already present on every machine that
# can run Docker — produces in one pass is a dependency bought for nothing. What
# mkcert adds over this script is `-install`, which writes to the system trust
# store and needs a password; that step is the owner's and is printed, not run.
#
# ── WHAT IS AUTOMATED AND WHAT IS NOT ─────────────────────────────────────────
#
# Generating and serving the certificate is automated, and it is most of the
# value: `curl --cacert` now works, so `estate-verify.sh` can make an assertion
# about TLS that is CAPABLE OF FAILING, and the browser tier can drop
# `ignoreHTTPSErrors`. Trusting the CA in the login keychain is NOT automated —
# it needs an interactive administrator password, and a script that asks for one
# unattended is a script that gets run with `sudo` out of habit. The one command
# is printed at the end.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

APEX=${CF_WEB_APEX:-cloudsforge.localtest.me}
CERTS=${CF_CERT_DIR:-gateway/certs}

# ── EVERY APEX THIS ONE LEAF ANSWERS FOR, AND WHY IT IS A LIST ────────────────
#
# THE DEFECT THIS REMOVES: this script used to write a leaf for exactly ONE apex
# into a FIXED directory, and `docker-compose.gateway.yml` mounted that directory
# by a hardcoded path. So running it for a second environment
# (`CF_WEB_APEX=testnet.cloudsforge.online`) overwrote `estate.crt` with a leaf
# that no longer named `cloudsforge.online` — and the LIVE MAINNET GATEWAY, which
# reads the same file, started serving a certificate for the wrong apex. A second
# environment could not be stood up without taking the first one down.
#
# A WILDCARD CAN ABSORB THIS NOW, AND COULD NOT BEFORE 2026-08-05. It used to
# read "a wildcard cannot absorb this": `*.cloudsforge.online` matches ONE label,
# so it did not match `hub.testnet.cloudsforge.online`, and the second apex had
# to be in the certificate however this was arranged.
#
# The same one-label rule is why testnet's hostnames MOVED. Cloudflare's
# Universal SSL is that same wildcard, so every two-label testnet name failed the
# handshake at Cloudflare's edge and the whole environment was configured and
# publicly unreachable. Testnet is `hub-testnet.cloudsforge.online` now — one
# label — so `*.cloudsforge.online` covers both environments and both apexes are
# the same apex.
#
# THE MACHINERY BELOW STAYS ANYWAY, and it is not dead weight. `CF_CERT_APEXES`
# and the union are what stop a run for one environment from clobbering the
# other's leaf, which is a property of "two environments, one committed
# certificate directory" rather than of how they are named. It is also what a
# genuinely separate apex — a vanity domain, a customer's zone — would need.
#
# ONE STALE PAIR WILL PERSIST, DELIBERATELY UNTOUCHED. The leaf on disk still
# carries `DNS:testnet.cloudsforge.online` and `DNS:*.testnet.cloudsforge.online`
# from before the rename, because the union only ever ADDS. They name hostnames
# this estate no longer serves, which costs nothing and breaks nothing;
# `--force` is the way to retire them, and it is deliberately a decision someone
# makes rather than something a re-run does behind them.
#
# ── WHY ONE LEAF FOR BOTH, RATHER THAN A DIRECTORY PER ENVIRONMENT ────────────
#
# `CF_CERT_DIR` above already allows the per-environment split, and it stays
# supported. It is not the DEFAULT because of what it costs the owner: the CA is
# minted INSIDE $CERTS (`ca.key`/`ca.crt` below), so a second directory is a
# SECOND AUTHORITY, and trusting an authority is the one step this script refuses
# to automate — it needs an administrator password (see the footer). The owner
# runs a browser on a Mac and a PC, so a second CA is four more trust operations
# and four more chances for one machine to be quietly wrong. One CA, one leaf,
# both apexes: the trust step stays a thing done once.
#
# `tls.yml` needs NO change for this — it names a single `defaultCertificate`
# pair, and one leaf naming both apexes is still a single pair. That preserves
# its own argument against an SNI list ("enumerating them here would be the
# sixteenth copy of the registry").
#
# ── THE LIST IS ADDITIVE, WHICH IS THE PART THAT ACTUALLY FIXES IT ────────────
#
# Defaulting `CF_CERT_APEXES` to `$APEX` and asking the operator to remember to
# widen it would leave the defect exactly where it was: testnet's own
# `estate-up.sh` would call this with only its own apex and clobber mainnet
# again. So the required set is UNIONED WITH WHAT THE EXISTING LEAF ALREADY
# COVERS, read back off the certificate itself. Running this for testnet now
# ADDS to the leaf instead of replacing it, with no variable set anywhere and
# nothing to coordinate between two environments.
#
# `--force` is the escape: it deletes the leaf first, so the union starts empty
# and the SAN collapses back to just the current apexes. That is the way to
# retire a name, and it is the only way, deliberately.
APEXES=${CF_CERT_APEXES:-$APEX}
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# The CA outlives leaves: a re-run for a new apex must not invalidate a CA the
# owner has already trusted, or the trust step would have to be repeated every
# time. 10 years on the CA, 825 days on the leaf — Apple refuses a leaf longer
# than 825 days outright, and a certificate the platform rejects for its LIFETIME
# fails with the same opaque error as one signed by an unknown authority.
CA_DAYS=3650
LEAF_DAYS=825

if ! command -v openssl >/dev/null 2>&1; then
  echo "FATAL: openssl is not on PATH. It is what generates the certificate." >&2
  exit 1
fi

mkdir -p "$CERTS" || exit 1
chmod 700 "$CERTS"

ca_key="$CERTS/ca.key"
ca_crt="$CERTS/ca.crt"
leaf_key="$CERTS/estate.key"
leaf_crt="$CERTS/estate.crt"

if [ "$FORCE" = 1 ]; then
  rm -f "$ca_key" "$ca_crt" "$leaf_key" "$leaf_crt"
fi

# ── the authority ─────────────────────────────────────────────────────────────
if [ ! -s "$ca_crt" ] || [ ! -s "$ca_key" ]; then
  echo "  generating a local development CA (${CA_DAYS}d)"
  # `-nodes` deliberately: an encrypted CA key would prompt for a passphrase
  # inside `estate-up.sh`, which runs unattended. The key's protection is the
  # 0600 mode and the .gitignore rule, both asserted by estate-verify.
  if ! openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days "$CA_DAYS" \
      -keyout "$ca_key" -out "$ca_crt" \
      -subj "/CN=CloudsForge Estate Local CA/O=CloudsForge (development only)" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/tmp/gateway-cert-ca.log; then
    echo "FATAL: could not generate the CA:" >&2
    tail -5 /tmp/gateway-cert-ca.log >&2
    exit 1
  fi
  chmod 600 "$ca_key"
  chmod 644 "$ca_crt"
else
  echo "  CA already present — kept, because the owner may have trusted it already"
fi

# ── the leaf ──────────────────────────────────────────────────────────────────
#
# A leaf is regenerated whenever it is missing OR does not cover the current
# apex. That second condition is the one that matters: `CF_WEB_APEX` is
# overridable, and a leaf for the old apex would serve a certificate whose SAN
# does not match the host — `ERR_CERT_COMMON_NAME_INVALID`, a DIFFERENT opaque
# browser error from the one this script exists to remove, and one that
# `--cacert` alone would not catch either.
#
# The check is now over EVERY apex in the list, not just one: a leaf covering
# mainnet but not testnet must be regenerated, and so must the reverse. Checking
# only `$APEX` is what let a narrower certificate look satisfactory.
existing_san=""
if [ -s "$leaf_crt" ]; then
  existing_san=$(openssl x509 -in "$leaf_crt" -noout -ext subjectAltName 2>/dev/null | tr -d " " | tr "," "\n" | grep "^DNS:" || true)
fi

covers_all=1
for a in $APEXES; do
  printf "%s\n" "$existing_san" | grep -qx "DNS:$a"   || covers_all=0
  printf "%s\n" "$existing_san" | grep -qx "DNS:\*.$a" || covers_all=0
done

needs_leaf=1
if [ -s "$leaf_crt" ] && [ -s "$leaf_key" ] && [ "$FORCE" = 0 ]; then
  if [ "$covers_all" = 1 ]; then
    # Also require it to still be valid for a week, so a stack that has been up
    # for two years does not hand a browser an expired certificate.
    if openssl x509 -in "$leaf_crt" -noout -checkend 604800 >/dev/null 2>&1; then
      needs_leaf=0
      echo "  leaf certificate already covers $APEXES (and *.each) and is not expiring"
    else
      echo "  leaf certificate expires within a week — regenerating"
    fi
  else
    echo "  leaf certificate does not cover every apex in: $APEXES — regenerating"
  fi
fi

if [ "$needs_leaf" = 1 ]; then
  # THE UNION: every apex asked for now, plus every DNS name the outgoing leaf
  # already carried. `--force` removed the leaf above, so that case starts clean.
  san_names=""
  add_name() {
    case " $san_names " in *" $1 "*) return 0 ;; esac
    san_names="$san_names $1"
  }
  for a in $APEXES; do add_name "DNS:$a"; add_name "DNS:*.$a"; done
  for d in $existing_san; do add_name "$d"; done
  add_name "DNS:localhost"
  san=$(printf "%s" "$san_names" | sed "s/^ //; s/ /,/g")

  echo "  generating a leaf for:$san_names (${LEAF_DAYS}d)"
  ext=$(mktemp)
  # ── THE SAN LIST, AND THE ONE ENTRY THAT IS NOT OBVIOUS ─────────────────────
  #
  # `*.$APEX` matches ONE label only — `hub.<apex>` yes, `a.b.<apex>` no — which
  # is exactly the shape `cloudsforgeHosts()` composes, so one wildcard covers
  # every surface in the registry including ones not written yet. The bare apex
  # is listed SEPARATELY because a wildcard does not match its own parent: `site`
  # is served at `<apex>` with an empty subdomain (ui/packages/ui/src/surfaces.ts,
  # the `site` row), and a certificate for `*.<apex>` alone would fail on the
  # front door and nowhere else — the hardest kind of partial failure to read.
  #
  # `localhost` and `127.0.0.1` are there because the loopback ports
  # (9095/9096/9097) are addressed that way by `make config` and by anything
  # driving the gateway without DNS.
  cat > "$ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san,IP:127.0.0.1,IP:::1
EXT
  csr=$(mktemp)
  if ! openssl req -nodes -newkey rsa:2048 -sha256 \
        -keyout "$leaf_key" -out "$csr" -subj "/CN=$APEX" 2>/tmp/gateway-cert-leaf.log \
     || ! openssl x509 -req -in "$csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
        -out "$leaf_crt" -days "$LEAF_DAYS" -sha256 -extfile "$ext" 2>>/tmp/gateway-cert-leaf.log; then
    echo "FATAL: could not generate the leaf certificate:" >&2
    tail -5 /tmp/gateway-cert-leaf.log >&2
    rm -f "$ext" "$csr"
    exit 1
  fi
  rm -f "$ext" "$csr"
  chmod 600 "$leaf_key"
  chmod 644 "$leaf_crt"
fi

# ── THE ASSERTION, BECAUSE A CERTIFICATE THAT DOES NOT VERIFY IS THE WHOLE BUG ─
#
# `openssl verify` against the CA that signed it. This is cheap and it is the
# only step here that can catch a leaf built from a stale CA — the state a
# `--force` on one file and not the other leaves behind, which produces a
# certificate that looks perfect in every field and chains to nothing.
if ! openssl verify -CAfile "$ca_crt" "$leaf_crt" >/tmp/gateway-cert-verify.log 2>&1; then
  echo "FATAL: the leaf does not verify against the CA in the same directory:" >&2
  cat /tmp/gateway-cert-verify.log >&2
  echo "       run: ./scripts/gateway-cert.sh --force" >&2
  exit 1
fi

echo "  ok   $leaf_crt verifies against $ca_crt"
echo "       SAN: $(openssl x509 -in "$leaf_crt" -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')"

# ── THE TRUST BUNDLE: ONE FILE EVERY INTERNAL CLIENT CAN POINT AT ─────────────
#
# `trust.crt` is `ca.crt` plus every `gateway/trust/*.pem`, rebuilt on every run.
# Six consumers point at it and none of them should have to know how many issuers
# this estate has: `estate-verify.sh` (`--cacert`), the three seeders and
# `foresight-market-journey.mjs` (`NODE_EXTRA_CA_CERTS`), beacon in its container
# (docker-compose.estate.yml), and both miners (docker-compose.miners.yml).
#
# ── IT IS BACK TO ONE ISSUER, AND `gateway/trust/` IS NOW EMPTY ───────────────
#
# It briefly held Cloudflare's Origin CA root, because the mainnet gateway
# terminated on a Cloudflare Origin leaf to stop the tunnel answering 502. That
# leaf is gone — the tunnel reaches the gateway over plain HTTP now
# (compose/docker-compose.gateway.yml, the `tunnel` entrypoint), so nothing in
# this estate serves a Cloudflare-issued certificate and nothing needs to verify
# one. A root left in this bundle would be an AUTHORITY THE ESTATE DOES NOT USE,
# trusted by all six consumers above, able to vouch for origin certificates
# Cloudflare issued to other customers. It came out with the leaf.
#
# THE DIRECTORY AND THE LOOP STAY. `roots` is 0 today and the bundle is `ca.crt`
# alone, which is what it was before the Origin leaf and what every consumer
# already handles. Keeping the mechanism means the next deployment that genuinely
# terminates on a public issuer drops a root in and changes nothing else — and
# the loop already refuses a file that is not a PEM certificate, which is the
# failure a concatenation cannot otherwise report.
#
# ── AND IT IS A SEPARATE FILE RATHER THAN AN APPEND TO ca.crt ─────────────────
#
# Unchanged, and still the right shape even at zero extra roots:
#
#   1. `ca.crt` IS AN INPUT TO SIGNING, twenty lines above — `openssl x509 -req
#      -CA "$ca_crt" -CAkey "$ca_key"`. Appending would make the signing input
#      depend on file order.
#   2. IT IS NOT IDEMPOTENT. `--force` rewrites `ca.crt` wholesale and would
#      silently drop anything appended; a re-run of an append duplicates it.
#   3. `ca.crt` IS THE FILE THE OWNER INSTALLS IN A KEYCHAIN. Appending a public
#      root would quietly widen what "trust the estate CA" means on their machine.
#
trust_crt="$CERTS/trust.crt"
trust_dir="gateway/trust"

# `cat` into a temporary file and move, so a consumer reading the bundle while
# this runs never sees half of one. `estate-up.sh` runs this with the estate up.
trust_tmp=$(mktemp)
cat "$ca_crt" > "$trust_tmp"
roots=0
if [ -d "$trust_dir" ]; then
  for pem in "$trust_dir"/*.pem; do
    [ -s "$pem" ] || continue
    # A file that is not a certificate would land in the bundle as text and be
    # skipped in silence by every consumer, so it is rejected here instead.
    if ! openssl x509 -in "$pem" -noout -subject >/dev/null 2>&1; then
      echo "FATAL: $pem is in $trust_dir but is not a PEM certificate." >&2
      rm -f "$trust_tmp"
      exit 1
    fi
    cat "$pem" >> "$trust_tmp"
    roots=$((roots + 1))
  done
fi
mv "$trust_tmp" "$trust_crt"
chmod 644 "$trust_crt"

# ── THE ASSERTIONS, BECAUSE A BUNDLE THAT VERIFIES NOTHING LOOKS IDENTICAL ────
#
# A bundle is a concatenation and a concatenation always succeeds. What can fail
# is the thing it is FOR, so that is what is checked: the estate leaf must still
# verify against it, and the origin certificate must too when one is installed.
if ! openssl verify -CAfile "$trust_crt" "$leaf_crt" >/tmp/gateway-cert-trust.log 2>&1; then
  echo "FATAL: $leaf_crt does not verify against the bundle $trust_crt:" >&2
  cat /tmp/gateway-cert-trust.log >&2
  exit 1
fi

# THE `origin.crt` BRANCH THAT WAS HERE IS GONE. It verified an installed
# Cloudflare Origin leaf against this bundle and FATAL'd when it did not verify.
# With the Origin root deliberately out of `gateway/trust/` that check could only
# ever fail, so an `origin.crt` left on a host — or restored by someone reading
# the old runbook — would have stopped this script dead with a message about a
# missing root, for a certificate nothing serves any more. A check that can only
# fail is worse than no check; the certificate is simply not part of this estate.
echo "  ok   $trust_crt verifies the estate leaf ($roots public root(s) added)"

# ── the step that is the owner's, and is printed rather than run ──────────────
#
# Checked rather than announced blindly: on macOS `security verify-cert` says
# whether the system already trusts this CA, so a re-run after the owner has
# done it stays quiet instead of nagging.
# Printed paths must survive an ABSOLUTE $CF_CERT_DIR. `$(pwd)/$ca_crt` produced
# `/…/deploy//tmp/certs/ca.crt` — a path that does not exist, in the one command
# the owner is asked to run by hand.
ca_abs=$(cd "$(dirname "$ca_crt")" && pwd)/$(basename "$ca_crt")

trusted=0
if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  security verify-cert -c "$ca_crt" >/dev/null 2>&1 && trusted=1
fi

if [ "$trusted" = 1 ]; then
  echo "  ok   this machine already trusts the estate CA — a browser will be clean"
else
  echo
  echo "  ─────────────────────────────────────────────────────────────────────"
  echo "  ONE COMMAND IS LEFT AND IT NEEDS YOUR PASSWORD, so it is not run here."
  echo "  Until it is run, pages load after a click-through and every CROSS-ORIGIN"
  echo "  call still fails — a browser never offers an interstitial for an XHR, so"
  echo "  sign-in reports \"Cannot reach the server\" with the estate perfectly healthy."
  echo
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "      security add-trusted-cert -d -r trustRoot \\"
    echo "        -k ~/Library/Keychains/login.keychain-db \\"
    echo "        \"$ca_abs\""
    echo
    echo "  (-d is the admin domain and prompts once. To undo:"
    echo "      security delete-certificate -c 'CloudsForge Estate Local CA' \\"
    echo "        ~/Library/Keychains/login.keychain-db )"
  else
    echo "      sudo cp $ca_abs /usr/local/share/ca-certificates/cloudsforge-estate.crt"
    echo "      sudo update-ca-certificates"
  fi
  echo
  echo "  Firefox keeps its OWN store and ignores the system one: Settings →"
  echo "  Privacy & Security → Certificates → View Certificates → Authorities →"
  echo "  Import, then tick \"Trust this CA to identify websites\"."
  echo "  ─────────────────────────────────────────────────────────────────────"
fi
