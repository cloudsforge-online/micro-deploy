# Rolling back the combined view

**Owner** platform · **Applies to** the testnet estate · **Forward record** docs/ecosystem/38,
micro-org#459 · **Severity when needed** judgement — this is a product-topology rollback, not an
outage response

The combined view (release 2026.08.37) retired the testnet frontends behind 302s and moved
testnet's identity trust to the mainnet identity. This runbook is the way back, and its whole
design is that every step of the flip chose the reversible option so that this document could be
short.

## When to use it

The combined view itself is misbehaving in a way that a forward fix cannot reach quickly —
cross-estate reads broken for real users, the shared identity refusing testnet service
exchanges at scale — and the duplicated-frontend model of doc 26 is the known-good state to
stand on while the defect is fixed.

Do NOT use it for a single surface misbehaving; that is an ordinary bug in an ordinary release.

## Why rollback is possible at all — the three reversible choices

1. **302, never 301.** The retirement redirects were deliberately temporary-code, so no browser
   or cache holds a permanent claim that the testnet hostnames are gone.
2. **The testnet identity was stopped, not deleted.** Its database rows and keys are intact; its
   container simply is not running and nothing trusts it.
3. **The trust switch is two env lines.** `CF_IDENTITY_JWKS_URL` / `CF_IDENTITY_URL` in
   `compose/testnet.env` are the whole of "testnet trusts mainnet"; unset, every default falls
   back to the local identity container.

## Procedure

All on the app host, in the deploy checkout, with the release currently pinned (check
`releases/` for the newest manifest the estate is on).

1. **Un-flip the env.** In `compose/testnet.env`, remove (or comment) these lines:
   ```
   CF_IDENTITY_JWKS_URL=…
   CF_IDENTITY_URL=…
   CF_WEB_RETIRED=true
   ```
   This is a tracked file: make it a PR, because the flip was one and the un-flip must be as
   discoverable in history as the flip was.

2. **Redeploy testnet** through the release script, never a bare compose up:
   ```sh
   ESTATE_ENV=compose/testnet.env TOKENS_FILE=compose/estate/tokens.testnet.env \
     ./scripts/release-deploy.sh <current-release>
   ```
   The render drops the retirement routers (the `CF_WEB_RETIRED` conditional renders to
   nothing), the frontends come back, and the identity-trust anchor falls back to the local
   testnet identity — which the deploy starts again, because it never left the compose file.

3. **Testnet service credentials.** The 19 testnet services now present credentials that live in
   the MAINNET identity (label `testnet`, provisioned 2026-08-14) to the TESTNET identity, which
   holds the pre-flip rows. Two options, in order of preference:
   - the pre-flip tokens file backup made at provisioning time —
     `compose/estate/tokens.testnet.env.pre-shared-identity.bak` on the host — restores the old
     values in one copy;
   - or re-provision fresh rows in the testnet identity the same way the flip provisioned them
     in mainnet (the provisioning script shape is recorded on micro-org#459).

4. **Verify** exactly what the flip verified, inverted: testnet web hostnames answer 200 with
   their own bundles, `/v1` APIs still answer, testnet services exchange against the testnet
   identity, both estates healthy, alerts quiet.

5. **The mainnet identity keeps the `testnet`-labelled credential rows.** Revoke them
   (`revoked_at`) once the rollback is confirmed stable — they authenticate nobody after the
   tokens file reverts, but an unrevoked credential nobody uses is exactly the residue
   micro-org#430 was about.

## What rollback does not undo

- The `net` claim and the armed verifiers stay, on both estates. They are correct in BOTH
  topologies — under the two-identity model every token trivially matches its own estate — and
  removing them would reopen the cross-estate service-token hole for the next attempt.
- The in-app switcher stays. Under the restored two-frontend model its cross-estate reads reach
  the sibling estate exactly as they did between releases .34 and .36.
