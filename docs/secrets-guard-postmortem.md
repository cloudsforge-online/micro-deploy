# The secrets guard: what shipped, and why it cost what it did

**Written 2026-08-06, after the work completed.** Author: Claude, at the owner's request, about
its own failure. Nothing here is inferred — every number was measured from the running estate or
from git.

---

## 1. What the guard is, and why it exists

A string was found acting as a **live signing key across 44 containers on both networks**:

```
estate-only-outbox-secret-00000000000000
```

It survived because the old guard asked two questions:

1. *Is it at least 24 characters?* — it is 40.
2. *Is it one of these eight known placeholder strings?* — it was not the ninth.

Both are **membership tests dressed as security**. A deny-list can only refuse a placeholder
somebody already imagined, so it fails in precisely the case it exists for — a new one. And length
is not entropy: `'x'.repeat(24)` clears any 24-character floor while carrying almost no key
material.

The replacement, `@cloudsforge/secrets`, does not ask what the string *is*. It **measures how many
bytes of key material the value carries for the alphabet it is written in**, and requires 32. So:

| value | old guard | new guard |
| --- | --- | --- |
| `estate-only-outbox-secret-` + zeros | accepted (40 chars, not on the list) | refused |
| `'x'.repeat(24)` | accepted | refused — *"carries 18 bytes… at least 32 are required"* |
| a genuine 32-byte key | accepted | accepted |

The error message carries the lesson: *"length in CHARACTERS is not the unit that matters."*

**Three guard classes, because one rule does not fit.** This distinction caused a near-outage and
is the most important technical content in this document:

- **Generated keys** — wholly base64 or hex, high entropy → `assertGeneratedSecret`
- **Service credentials** — `cfsc_` prefix, base64url body → `assertServiceCredential`
- **Opaque third-party tokens** — an SMTP password has whatever shape the vendor chose →
  `assertOpaqueSecret`

**The classes are not predictable from variable names.** `SETTLEMENT_SERVICE_TOKEN` is a `cfsc_`
credential; `MARKET_SERVICE_TOKEN` is a JWT. Each value's actual shape must be measured.

---

## 2. Final state

**28 mainnet / 29 testnet services enforce the guard in the running image. Zero remaining. Zero
unhealthy.** The other 18 containers per estate are nginx and postgres, which have no Node runtime.

Thirty repositories carry it in source. Verification is by importing the shipped module **inside
each running container** and driving it — not by reading a manifest, and not per-service.

---

## 3. The claim that the code was "a few lines" — was it true?

**Yes, and that is the point.** Measured from the commits:

| repo | `src/env.ts` diff |
| --- | --- |
| indexer | 47 lines changed |
| trade | 51 |
| notify | 73 |
| policy | 84 |

And most of those lines are **comments explaining why the old check was insufficient**. The
mechanical change per service is: swap one function call, add one import, add one dependency,
re-wrap the error class. Under ten lines of behaviour.

**The code was never the work.** Roughly five million tokens went somewhere else, and the rest of
this document is an honest account of where.

---

## 4. Where the cost actually went

### 4.1 Verification asymmetry — the largest single cause

Every agent was told to verify in-container. Every agent did. **Not one verified the estate.**

Each was given four or five services, guarded them, confirmed *those* worked, and reported "done."
That report was true and useless: "my four services are guarded" is not "the estate is guarded,"
and nothing in the process ever measured the difference.

So the work looked finished repeatedly while five services were still unguarded. The owner had to
say *"working on guard again and again"* before anyone ran the scan that spans all 51 containers.

**The fix is one command, and it should have been the first thing written**, not the last:

```bash
for c in $(docker ps --format '{{.Names}}'); do
  docker exec "$c" sh -c 'command -v node >/dev/null || exit 3
    grep -rq assertGeneratedSecret /app/node_modules/@cloudsforge/secrets/ || exit 1'
done
```

A definition of done that any single agent can evaluate against the **whole** system. Without it,
"done" is a local claim and coordination has nothing to converge on.

### 4.2 I supplied wrong context, repeatedly, and agents inherited it

Every number I passed to an agent about the scope of the problem was wrong:

| I said | The truth |
| --- | --- |
| "twelve services carry the guard" | nine at the time |
| "20 of 51 containers missing" | five per estate |
| "`ledger`, `billing` and `mint` are affected" | `nda`, `mint`, `studio`, `devplatform`, `aetherholm` |
| "zero containers missing the guard" | three Node services were miscounted as non-Node |
| "`@cloudsforge/secrets` needs publishing" | it is never published; images carry it via build contexts |

Each agent therefore began by **re-deriving the real picture from scratch** — a full estate scan,
a full source survey — because the brief it was given did not survive contact with the system.
Fifteen agents each paying that cost is most of the five million tokens.

**A wrong brief does not merely waste the work it describes. It buys a full rediscovery.**

### 4.3 My own probes returned false results three times

- Scanned for containers named `nimbus`, `vault`, `pay` — those are *hostnames*; the services are
  `identity`, `custody`, `billing`, `wallet`. Reported healthy services as undeployed.
- Counted a failed `docker exec` as "missing the guard" — 36 nginx and postgres containers
  reported as an estate-wide emergency.
- Counted `NOPKG` (package absent) as "not a Node service", hiding three genuinely unguarded
  services behind a clean "zero missing."

Every one of these read as a *finding* rather than a broken probe. The pattern is identical to the
defect class the guard exists to catch: **a check that reports success while measuring the wrong
thing.**

### 4.4 Merged is not deployed — discovered far too late

**GHCR tags are immutable.** A release manifest pins a tag; if `package.json` did not move, that
tag still resolves to the pre-fix build. So a fix can be merged, CI-green and correct, and reach
nobody — and *nothing in the pipeline compares merged code against running code.*

Two of the five stragglers were exactly this: `devplatform` and `aetherholm` had the guard in
source at 1.1.0, and GHCR's 1.1.0 predated it. **No code change was required. The version bump was
the fix.**

Three others (`nda`, `mint`, `studio`) had correct images in GHCR and correct pins in the release
file, and nobody had run the deploy.

**So four of five "unguarded services" were not code problems at all.** They were the gap between
merged, published and running — three states that had been treated as one.

### 4.5 Session limits killed eight agents mid-flight

Work stopped in place and left **five orphaned working trees** containing complete, green,
uncommitted changes. `trade`'s was the costly one: a finished guard implementation with an
unbumped version, sitting in a working tree. Its CI was green — for the *previous* commit — so
`micro-trade:1.1.0` was reported as "green CI but no published image," which I relayed as a broken
publish pipeline. It was neither. Nobody had committed it.

### 4.6 Tests that defended the defect — real work, paid for many times

This was genuine engineering, not waste, but each agent met it independently:

- `devplatform` asserted `'x'.repeat(24)` **was a valid signing key**
- `identity` **required** `'x'.repeat(28)` to load
- `custody` had a test named *"OUTBOX_SIGNING_SECRET is DELIBERATELY not held to the master-secret rule"*
- `indexer` asserted the failure message read `at least 24 characters` — pinning **characters** as
  the unit, which is the exact bar the real leak walked through
- `emberkin`'s fixture was `'a-real-secret-of-sufficient-length-000'`
- three services shared `cfsc_a-long-lived-credential-that-does-not-expire` — a typed English
  phrase at 3.785 bits per character

**Fixing the code alone would have turned CI red and looked like a regression.** In each case the
test had to be corrected too — and *that*, not the guard, is why a "ten-line change" needed
judgement per repository.

### 4.7 The environment asymmetry that nearly caused an outage

Service credentials differ between estates: **testnet's base64url body contains a hyphen and
mainnet's does not** — and it runs both ways (`mint` has one on mainnet and none on testnet; `nda`
the reverse). A "no hyphens" rule — correct for a *generated* key, and obviously right on
inspection — **passes one estate and crash-loops the other, whichever way you write it.**

Caught in preflight, not production. Fixtures now carry a hyphen deliberately so the asymmetry
fails CI instead of an estate at boot.

---

## 5. The one real bug, found at the very end

`indexer` 1.2.0 would not start. Its migrator would not migrate:

```
schema is at version 5 but this build requires 6
migration 4 (chain) was modified after it was applied
```

An earlier change had derived the chain-list CHECK constraint from a shared constant — correct in
intent, and it fixed a real drift where Litecoin was rejected. But that constant is **embedded in
the SQL text of migration 4**, which Postgres had already executed on both estates. `@cloudsforge/db`
hashes applied migrations and refuses when one changes.

**Both refusals were guards working exactly as designed.** The service correctly refused to run
against an unmigrated schema; the migrator correctly refused to rewrite history.

Resolution: roll back to restore service, pin the historical spelling as `CHAIN_CK_AS_APPLIED`
exactly as it shipped, let the derived list apply from migration 6 onward, ship 1.2.1. Both estates
migrated 5→6 cleanly, zero restarts.

---

## 6. What I would do differently

1. **Write the whole-estate verification command first.** One check any agent can run, whose result
   is the definition of done. Without it, parallel agents optimise a local claim.
2. **Never hand an agent a count I have not measured myself in the last five minutes.** Say
   "measure this yourself" rather than passing a number that buys a rediscovery.
3. **Treat merged, published and running as three separate states**, and name which one a claim is
   about. Most of this work was deployment archaeology, not engineering.
4. **Do the small mechanical job directly.** Delegation is for work that needs judgement per unit.
   Bumping five versions and running two deploys needed none — and took about forty minutes when
   done directly, most of it waiting for CI.
5. **When a probe returns a surprising result, suspect the probe.** Three times it was mine.

---

## 7. Summary

The guard is a genuine improvement: 28 and 29 services now refuse a class of weak secret that a
deny-list-plus-length-floor accepted, including one that was live across 44 containers. Six
categories of test that had been *pinning the defect as correct* are fixed. Three guard classes
are separated so a rule appropriate to a generated key cannot kill an estate holding a service
credential.

The code was, as claimed, a few lines per service.

**The cost was not the code. It was fifteen agents each rediscovering an estate I kept describing
incorrectly, verifying their own slice against a definition of done that nobody could evaluate
globally, and repeatedly finding that "merged" and "running" were different things.**

The owner's instruction to stop delegating and do it directly was correct, and it finished the job.
