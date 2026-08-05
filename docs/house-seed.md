# The Foresight house seed: where the EMBER comes from, who holds the key, and what it costs

**This is a money runbook.** It is written for the person who is about to move real
EMBER, in the order they need to know things. Every claim below carries the file and
line that makes it true, because the alternative — following a procedure for
machinery that turned out not to exist — has already happened twice in this estate.

Sibling documents, same genre, same discipline:
[`custody-backup-restore.md`](./custody-backup-restore.md) (the custody keyring) and
[`estate-backup-restore.md`](./estate-backup-restore.md) (everything else).

---

## 0. Read this first — the state of the machinery, as of 2026-08-06

Two separate questions get confused here constantly. Keep them apart:

**The machinery is real and deployed. It has simply never been armed.** Both live
stacks were inspected directly on 2026-08-06 to establish this, because a runbook for
machinery that does not exist is the failure mode this estate has already had twice.

| | State | Evidence |
| --- | --- | --- |
| **The house seed itself** — the plan/record table, the symmetry CHECK, the at-open-only triggers, the ceilings, the approve/open routes, the market-page disclosure | **Built, deployed, fire-tested.** `house_seeds` exists in the `foresight` database of **both** stacks, migration `8 \| house_seeds` applied `2026-08-04 15:05:10`, with all six CHECKs and all three triggers present. **0 rows.** | `foresight/src/houseseed.ts`, `foresight/src/migrations.ts` version 8, `server.ts:1168`/`:1295`, `foresight-web/src/pages/market.tsx:271` |
| **`engagement_policies`** | **Exists in the `admin_api` database of both stacks**, migration `8 \| engagement`, with every named constraint and the raise-needs-approval trigger. **0 rows — no cap has ever been set.** Siblings `engagement_transfers` (0 rows) and `engagement_fee_recycle` (1 row, `recycle_bps = 0`, untouched since the migration wrote it) also exist. Routes are mounted and auth-guarded (`GET /v1/engagement/policies` → 401 unauthenticated, not 404). | `admin-api/src/migrations.ts` version 8, `admin-api/src/engagement.ts` |
| **The ledger accounts** — `platform:engagement-treasury`, `engagement:foresight` | **DO NOT EXIST.** Zero accounts matching `engagement` in either stack. The mainnet ledger holds 28 accounts (25 `user:*`, 2 `custody`, 1 `platform`); **the testnet ledger holds zero accounts at all.** No posting anywhere references an engagement subject. | — |

That last row is **not** a blocker, and it is worth saying why so nobody goes looking
for a missing migration: `subject` is free text, and the ledger creates an account
idempotently on first use (`ledger/src/accounts.ts` `ensureAccount`). The accounts do
not exist because **no transfer has ever been made**, not because anything is missing.

So: not design-only, not operational. A loaded frame with nothing in it. Arming it
takes three things, not one — a compose wiring change (§3.1), a policy row (§4 step 4),
and a funded external key (§2).

### The blocker

> **`FORESIGHT_HOUSE_ADDRESS` is unset on both live stacks, deliberately.** It is
> `optionalAddress` (`foresight/src/env.ts:591`), absent is a declared supported mode
> (`foresight/src/env.ts:415-423`), and `docker-compose.estate.yml:2623-2628` states the
> absence and the reason in the compose file itself. Confirmed absent from the
> environment of both `cloudsforge-estate-foresight-1` and `cf-testnet-foresight-1`.
> With it absent, `POST /markets/:id/approve` refuses any `houseSeedPerOutcomeWei` with
> **409 `house_address_unconfigured`** (`foresight/src/server.ts:1186-1193`).
>
> Setting it is the owner's decision — it is the decision to put real money at risk —
> and nothing in this document does it for you.

> **Do not confuse it with `FORESIGHT_TREASURY_ADDRESS`, which *is* set.** That is where
> the settlement *fee* goes, not the seed. Live values, both holding **0 EMBER**:
> mainnet `0x76C853d699B17106E5e15d7D40A38F2238cb246c`, testnet
> `0x3d90B21ED45944BEcC6299573D5A12DB85C70220`.

**One thing this document will tell you that you may not expect:** the ledger leg of
the engagement treasury is denominated in **SHARD**, a *retired* asset
(`admin-api/src/actions.ts:500-516`; `contracts/packages/chain/src/index.ts:58` lists
`SHARD` in `RETIRED_ASSETS`). The house seed itself is EMBER wei and is clean. The two
do not meet. See §9 — it changes what "fund the treasury" means, and it is why the
answer to the owner's literal question is what it is.

---

## 1. Where does the EMBER come from? (the literal question)

**Yes — you transfer EMBER from a miner coinbase address to
`FORESIGHT_HOUSE_ADDRESS`, as an ordinary on-chain EMBER transfer, and then that
address makes its own `stake(uint8)` calls into each market contract.** There is no
custody path, no service that does it for you, and no ledger operation that moves the
actual coin. Two plain transactions per seeded market, sent by you.

Why it has to be that way, rather than a design choice that could be revisited:

1. **Custody physically cannot sign a stake.** `stake(uint8)` is a value-bearing
   contract CALL. Custody has exactly three EVM signing shapes — creation (value must
   be zero, `custody/src/signing.ts:210-227`), plain value transfer (data must be
   empty, `custody/src/signing.ts:231-260`), and sweep. None of them is "call a
   contract with value". This is the same constraint that makes the Foresight oracle
   resolve a market by *creating* a contract instead of calling one
   (`docker-compose.estate.yml:2602-2609`).
2. **A seeder contract is worse, not better.** If a contract staked on the house's
   behalf, the *contract* would be the staker, and its winnings would strand at an
   address with no key (`foresight/src/houseseed.ts:9-18`, `foresight/README.md:364-366`).
3. **So the house is an ordinary bettor with a published address** — funded the way
   the platform's miner coinbases are published (21 §3), staking through the same
   entrypoint every bettor uses. `micro-foresight` records and gates the seed; it
   never sends it (`foresight/README.md:406-409`).

### 1.1 The coinbase addresses the EMBER lives at

Public addresses, safe to state. Balances read from the chain on 2026-08-06 by
`eth_getBalance`, and the coinbase confirmed as the `miner` field of the last 40 blocks
on each chain — derived from the chain, not from any key file:

| Network | Chain id | Coinbase address | Balance | Host RPC | Height |
| --- | --- | --- | --- | --- | --- |
| EMBER mainnet (`hearth`) | **7411** | `0x980d52a868d41a34a186ce890874c8e547975b45` | **10,805.95 EMBER** — real mined coin | `127.0.0.1:8545` | 2006 |
| EMBER testnet (`hearth-testnet`) | **7412** | `0x91a11854b364178ed96054d8a6e9be1dbd751d33` | 10,739.27 EMBER — disposable | `127.0.0.1:8745` | 1988 |

(Publicly: `https://rpc.cloudsforge.online` and
`https://rpc-testnet.cloudsforge.online:10443`. Chain ids are pinned in
`deploy/compose/env/chain.mainnet.env:1` and `chain.testnet.env:1`. Both miners are
producing, ~5.4 EMBER/block, so these balances rise continuously — issue #206 recorded
9,332 EMBER at an earlier block, and neither figure is wrong.)

**Rehearse on 7412 first.** The testnet coinbase holds a comparable balance and the
whole procedure below is identical there. There is no reason to make your first
mistake on mainnet.

### 1.2 The mechanics of the transfer

You do **not** need to write new tooling. Two scripts in this repository already do
every step of this against the real chain, and both read the miner key the same way:

- `deploy/scripts/ember-seed.js:177` — reads
  `$EMBER_MINER_DATA/coinbase-key.json` (default `$EMBER_HOME/miner/`), signs, and
  broadcasts plain EMBER transfers. Its header (`:57-60`) states the discipline: the
  key is *"never printed, never logged and never written anywhere"*.
- `deploy/scripts/foresight-market-journey.mjs` — the full market lifecycle on the
  live chain, including **the exact `stake(uint8)` construction you need**:

  ```js
  // deploy/scripts/foresight-market-journey.mjs:489-493
  const stakeSel = selector('stake(uint8)')          // keccak256(sig)[0..4]
  await send(yes, { to: contract, value: YES_STAKE,
                    data: Buffer.concat([stakeSel, word(0)]),   // 0 = YES
                    gasLimit: 200_000n })
  await send(no,  { to: contract, value: NO_STAKE,
                    data: Buffer.concat([stakeSel, word(1)]),   // 1 = NO
                    gasLimit: 200_000n })
  ```

  Note `word(0)` / `word(1)`: `stake(uint8)` takes **0 = YES, 1 = NO**, and there is
  no N-ary form (`deploy/scripts/seed/foresight-questions.mjs:60`).

Transactions must be **legacy (type 0)**. This chain has no fee market, and a type-2
transaction signed against a zero base fee is one the chain cannot execute
(`foresight-market-journey.mjs:204-210`). Both scripts already sign type 0.

---

## 2. Who holds the key to the house address, and what that exposes

**This is the part to read twice.**

### 2.1 It is a hot key, by necessity

The house address signs contract calls at market-open time. It cannot live in custody
(§1), it cannot be a contract (§1), and it cannot be offline — the seed must land
before the market opens, and the market's open is an operator action, not a scheduled
one. So the key is **hot: online, on disk, on the machine that signs.** There is no
arrangement of this feature in which that is not true.

Source is explicit about it rather than shy: *"The address holds its own key **OUTSIDE
this estate's custody**"* (`foresight/src/env.ts:419-420`), and the compose file
records that *"this estate has no such key"* (`docker-compose.estate.yml:2626`).

### 2.2 Where it will end up living, honestly

There is no key store for it. The estate has exactly one precedent for a
platform-owned signing key that custody cannot hold, and it is the miner coinbase.
That precedent is **issue #206**, and its finding is not softened here:

> `/home/malf/dev/cloudsforge/miner-keys/{mainnet,testnet}/coinbase-key.json` —
> 240 bytes, mode `0600`, owner `malf`. Each is a JSON object with the fields
> `address`, `privateKey`, `warning` — **the private key in the clear.** The
> plaintext-at-rest problem is **untouched**; the backup work done in August 2026 added
> durability and, in doing so, added a second place the key exists in readable form.

Re-verified 2026-08-06. Host permissions are correct (`0700` on the directory, `0600`
on each file, owner `malf`), the field names are still `address` / `privateKey` /
`warning` — so these are **plaintext keys, not encrypted keystores** — and the two
addresses now control **~21,545 EMBER** between them. **One thing #206 did not record,
found while checking:** both key files are **bind-mounted read-write into the miner
containers** at `/minerdata`, where the process runs as uid 1000 `node` and can read
*and write* them. Container escape is not required to reach these keys; container
compromise is enough.

`custody-backup-restore.md` §4.2 step 6 says the same thing in the owner's own
runbook: these keys *"cannot be rotated without abandoning the balance at the address,
so the paper copy is the only recovery path there will ever be."*

**If you create a house key the obvious way — a JSON file beside the miner keys —
it will have exactly that property, and you should assume it will.** Concretely, what
you are accepting:

- **Plaintext on one disk.** Anyone with `malf`, with root, or with the disk, has the
  money at that address. No passphrase, no HSM, no confirmation step.
- **Unrotatable in practice.** Rotating means moving the balance to a new address and
  re-publishing the address that the market-page disclosure and every past seed
  transaction point at. Old disclosures then name an address the platform no longer
  controls.
- **Agent-transcript exposure is a live, repeated failure here.** Issues #144, #156
  and `custody-backup-restore.md` §7.1 all record secrets reaching agent transcripts
  on disk. The custody runbook's rule exists because of it: do key work **at the
  machine's own console, not over SSH** (`custody-backup-restore.md:232-234`).

### 2.3 What to do about it, in order of how much it buys you

1. **Cap the exposure instead of trying to eliminate it.** This is the important one.
   The house address should hold **only what is needed for the next few days of
   seeding**, topped up from the coinbase, never the coinbase balance itself. The
   caps in §6 exist to make that number computable. A hot key holding 200 EMBER is a
   bounded loss; a hot key holding 9,332 EMBER is the whole treasury.
2. **Back it up before you fund it**, by the procedure in
   `custody-backup-restore.md` §4.2 — paper in a safe, `gpg -c` on an off-site USB,
   verified by checksum and not by eye, and the two media in different buildings.
   Do it at the console. A key you have not read back is handwriting, not a backup.
3. **Publish the address**, on the network site, beside the miner coinbases. The
   whole defensibility of this programme is that the position is disclosed
   (21 §2: *"invisible house positions — is refused outright… it is the one form of
   this that costs nothing and it is fraud"*). The market page shows the address
   already (`foresight-web/src/components/houseseed.tsx:107-114`).
4. **Do not reuse the miner coinbase as the house address.** Two reasons, both real:
   the coinbase balance changes every time it wins a block, so any statement about
   what the house holds is true only between blocks
   (`ember-seed.js:44-46` makes the same point for the custody set); and it would put
   every EMBER the platform has ever mined behind one hot key that signs contract
   calls.

**The residual risk, stated plainly:** with a plaintext hot key, a single host
compromise loses everything at the house address, irreversibly, with no recovery path
and no ability to rotate ahead of the attacker. The only control that actually bounds
this is (1) — how much you leave there.

---

## 3. The exact configuration

### 3.1 On `micro-foresight`

| Variable | Required? | Absent means | Source |
| --- | --- | --- | --- |
| `FORESIGHT_HOUSE_ADDRESS` | optional | **No engagement programme.** Approve with a seed → 409 `house_address_unconfigured`. Everything else unaffected. | `env.ts:591`, `server.ts:1186-1193` |
| `ADMIN_API_URL` | optional | **Seeding refused outright** → 409 `seed_policy_unconfigured`, because the caps cannot be read and 21 §8 says nothing moves before the caps exist. | `server.ts:1194-1201`, `adminapiclient.ts:19-21` |
| `FORESIGHT_SERVICE_TOKEN` | optional | Must carry scope **`admin:read`**, exact-matched by admin-api — `admin:*` will not do. Without it the policy read fails → seeding refused, fail-closed. | `adminapiclient.ts:29-33`, `:47` |
| `FORESIGHT_RPC_URLS` | effectively required | Empty by default; a chain with no endpoint is refused rather than falling back to a public node nobody chose. Nothing reaches a chain. | `env.ts:585`, `docker-compose.estate.yml:2652-2658` |
| `FORESIGHT_NETWORK` | required | `mainnet` additionally requires `FORESIGHT_MAINNET_ENABLED=true` or the service refuses to boot — a one-word typo cannot put a market on mainnet. | `chain.mainnet.env:56-72` |
| `FORESIGHT_DEFAULT_FEE_BPS` | optional | Default **200** (2%), max 1,000 (10%). Matters for the economics in §7. | `env.ts:555` |

`ADMIN_API_URL` **is already set** on the live estate (`http://admin-api:4000`,
`docker-compose.estate.yml:2717`), deliberately and ahead of need — the reasoning is
written out at `:2643-2650`. So the house address is the only foresight-side gap.

> **The trap in setting it.** `FORESIGHT_HOUSE_ADDRESS` is **not wired through compose
> at all.** Its only occurrence in `deploy/compose/docker-compose.estate.yml` is line
> 2623 — inside the comment block headed *"WHAT IS DELIBERATELY ABSENT, BECAUSE ABSENT
> IS A DECLARED MODE"*. There is no `FORESIGHT_HOUSE_ADDRESS: ${FORESIGHT_HOUSE_ADDRESS}`
> line in either foresight service block.
>
> **So putting it in `.env` will do nothing at all, silently.** The container will come
> up without the variable, approvals will keep returning 409
> `house_address_unconfigured`, and everything will look like the address was rejected
> rather than never delivered. Adding the env mapping to the compose service block is a
> required, separate step — see §4 step 3.
>
> (Compare `FORESIGHT_TREASURY_ADDRESS`, which *is* mapped, at
> `docker-compose.estate.yml:2687` and `:2760` — two blocks, because the migrate and
> service definitions are separate. The house address needs the same treatment.)

### 3.2 On `micro-admin-api`

The seed *sizes* are not environment variables. They are a row in `engagement_policies`
(`admin-api/src/migrations.ts:382-434`) with two columns that matter here:

- `seed_per_market_wei` — EMBER wei per **outcome side** per market
- `seed_per_day_wei` — EMBER wei per **outcome side** per UTC day

Both are `numeric(78,0)` — any uint256, exact. Two constraints will bite you:

- `engagement_policies_seed_pair` — you must set **both or neither**. A per-market size
  with no per-day bound is exactly the unbounded spend the ceilings exist to refuse
  (`:420-422`).
- `engagement_policies_seeds_are_foresights` — seed sizes may only be set on the
  `foresight` row. Every other service spends through grants and never stakes
  (`:415-417`).

You set them with the **`engagement.policy.set`** action (§6).

### 3.3 On both networks

Mainnet (7411) and testnet (7412) are separate estates with separate compose
environments, separate databases, and separate miner keys. **Everything above must be
done twice, with two different house addresses and two different keys.** Reusing one
address across both chains would make the mainnet key's compromise a testnet event and
vice versa — and the estate has already been bitten once by two chains sharing an id
(issue #23; `chain.mainnet.env:22-30` records the cleanup).

---

## 4. The operator procedure

Numbered, with the verification after each step. **Do the whole thing on testnet
first.** Every `curl` here goes through the gateway over TLS with the estate CA
supplied — never `curl -k`, for the reason `foresight-market-journey.mjs:32-41`
records at length.

### Step 0 — decide the numbers, before touching anything

Write down: the per-market per-side size `S`, the per-day per-side total, and how much
EMBER you will leave sitting at the house address. §7 tells you what those cost you;
§2.3 says why the last one is the one that matters.

### Step 1 — create the house key, back it up, publish the address

At the machine's console, not over SSH (`custody-backup-restore.md:232-234`).

**Verify:** the paper copy transcribes *back* to the same checksum
(`custody-backup-restore.md` §4.2 step 3). The address appears on the network site
beside the miner coinbases. **Do not proceed until the backup is verified** — from the
next step onward the address holds money.

### Step 2 — fund the house address from the miner coinbase

An ordinary EMBER transfer, the `ember-seed.js` shape (§1.2). Send **only** the
working balance you decided in step 0, plus gas.

**Verify** — on chain, not from any service:

```bash
curl --cacert "$ESTATE_CA" -s -X POST "$EMBER_RPC_URL" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_getBalance","params":["<HOUSE_ADDRESS>","latest"]}'
```

The result is hex wei. It must equal what you sent, exactly.

### Step 3 — wire `FORESIGHT_HOUSE_ADDRESS` through compose, then set it

**Two changes, and the first is the one people miss.** Setting the value in `.env`
alone does nothing (§3.1):

1. Add the env mapping to the foresight service block in
   `deploy/compose/docker-compose.estate.yml`, the way
   `FORESIGHT_TREASURY_ADDRESS` is mapped at `:2687` and `:2760`:
   `FORESIGHT_HOUSE_ADDRESS: ${FORESIGHT_HOUSE_ADDRESS:-}`. Leave the explanatory
   comment at `:2618-2628` in place and amend it — it is the record of why the
   variable was absent, and the amendment is the record of the decision to change that.
2. Set the value in the environment file, and restart foresight.

**Verify** the container actually received it. An unset variable, a typo'd value and a
missing compose mapping all present identically as "seeding refuses", so check the
container rather than the file you edited:

```bash
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' <foresight-container> \
  | grep -i FORESIGHT_HOUSE_ADDRESS
```

It must print your address. If it prints nothing, step 1 was skipped.

### Step 4 — set the seed caps in admin-api

Through the `engagement.policy.set` action. **Raising requires a fresh approved
approval; lowering does not** — see §6. `engagement_policies` is **empty on both
stacks**, so this will be the first row ever written to it: the `foresight` row is an
INSERT, and it goes through `engagement_raise_needs_approval` like any raise, because
setting a cap above the default 0 *is* a raise.

**Verify** by reading back the live policy the way foresight will read it:

```bash
curl --cacert "$ESTATE_CA" -s "$ADMIN_API_URL/v1/engagement/policies" \
  -H "authorization: Bearer $TOKEN"    # token must hold admin:read
```

The `foresight` row must carry both `seedPerMarketWei` and `seedPerDayWei` as decimal
strings. `adminapiclient.ts:112-118` refuses anything else — a policy it cannot read
exactly is one it will not enforce approximately.

### Step 5 — approve a market with a seed

```bash
curl --cacert "$ESTATE_CA" -s -X POST "$FORESIGHT_URL/markets/$MARKET_ID/approve" \
  -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d '{"houseSeedPerOutcomeWei":"<S in wei>"}'
```

**Verify:** the response carries a `houseSeed` object with `state: "planned"` and
`amountPerOutcomeWei` equal to what you sent (`server.ts:1240-1246`). The refusals you
might get instead, and what each means:

| Code | Status | Meaning |
| --- | --- | --- |
| `seed_out_of_range` | 400 | Above the hard schema ceiling of 1,000 EMBER/side. Nothing will accept it. |
| `house_address_unconfigured` | 409 | Step 3 did not take. |
| `seed_policy_unconfigured` | 409 | `ADMIN_API_URL` unset. |
| `no_seed_policy` | 409 | Step 4 did not take — admin-api holds no seed sizes for foresight. |
| `seed_above_policy` | 409 | Above your own per-market cap. |
| `seed_daily_cap` | 409 | Today's seeds plus this one exceed your per-day cap. |

(`server.ts:1178-1228`.)

### Step 6 — send the two stakes, from the house address

Only after the market contract is deployed (its address is on `GET /markets/:id`).
Two `stake(uint8)` transactions, **exactly `S` wei each**, outcome `0` then `1` — the
construction in §1.2.

**Exactly, not at-least.** `recordHouseStake` compares the mirror against the plan and
demands equality; an overshoot is refused because it would make the disclosure
*understate* the house, which is the direction dishonesty lives in
(`houseseed.ts:177-200`).

### Step 7 — confirm the seed landed **on chain**, not by asking the API

This is the step the brief asked for specifically, and it is worth doing separately
because the mirror is a database and databases can be behind or wrong. Ask the
contract itself:

```bash
# stakeOf(address) -> (uint256 yes, uint256 no)  — ForesightMarket.sol:352
SEL=$(printf 'stakeOf(address)' | keccak-256sum | cut -c1-8)   # or precompute
curl --cacert "$ESTATE_CA" -s -X POST "$EMBER_RPC_URL" \
  -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$MARKET_CONTRACT\",\"data\":\"0x${SEL}$(printf '%064s' ${HOUSE_ADDRESS#0x} | tr ' ' 0)\"},\"latest\"]}"
```

The answer is two 32-byte words: the house's YES stake and its NO stake. **Both must
equal `S`, and they must be equal to each other.** Cross-check the contract's total
holdings the way the journey script does (`foresight-market-journey.mjs:495-498`):
`eth_getBalance` on the contract must equal the sum of every stake in it.

Only when the chain says this is true is it true. The API's answer in step 8 is
derived from the mirror, which is derived from the chain.

### Step 8 — open the market

```bash
curl --cacert "$ESTATE_CA" -s -X POST "$FORESIGHT_URL/markets/$MARKET_ID/open" \
  -H "authorization: Bearer $ADMIN_TOKEN"
```

**This is the gate that makes the whole scheme honest, and it is why step 7 is not
merely diligence.** Opening a seeded market is *refused* unless the mirror shows the
exact symmetric position (`server.ts:1295-1308` → `houseseed.ts:185-212`). If step 7
was wrong, this returns `house_seed_not_staked` with the planned and observed figures
side by side. A market cannot open claiming a seed it does not have.

**Verify:** the response's `houseSeed.state` is `"staked"`, `stakedAt` equals the
market's `openedAt` **exactly** (the trigger `house_seeds_carry_open_timestamp`
enforces equality, not proximity — `migrations.ts:684-687`), and `txHashYes`/`txHashNo`
are the two hashes from step 6.

### Step 9 — verify the public disclosure

Load the market page. It must show the disclosure sentence, the per-outcome and total
amounts, the house address, the share of the pool, and both transaction hashes
(`foresight-web/src/components/houseseed.tsx`). The sentence is composed once by the
service and rendered verbatim (`houseseed.ts:230-243`).

If the page renders the **symmetry alarm** — *"The seed on this page is not symmetric"*
— stop and investigate; the page is telling readers not to stake
(`houseseed.tsx:140-148`).

---

## 5. Verifying a seed after the fact

To reconstruct any past seed without trusting a service:

1. `GET /markets/:id` → `houseSeed.txHashYes` / `txHashNo`.
2. `eth_getTransactionByHash` on each → `to` is the market contract, `from` is the
   house address, `value` is `S`, and `input` is the 4-byte `stake(uint8)` selector
   followed by a 32-byte word that is `0` on one and `1` on the other.
3. `eth_getTransactionReceipt` → `status` is `0x1` and the block is **at or before**
   the market's open block. A house stake in a later block is *not* part of the
   disclosed seed — the schema comment is candid that nothing can stop the house
   address staking again through the public contract, but such a stake sits in
   `positions` with a block after open and is publicly attributable
   (`foresight/src/migrations.ts:566-571`).

---

## 6. The caps, and how to change one

There are **two layers**, and they are different in kind.

### 6.1 The hard ceilings — schema facts, in two databases

| Ceiling | Value | Enforced by |
| --- | --- | --- |
| Per outcome side, per market | 10²¹ wei = **1,000 EMBER** | `house_seeds_within_market_ceiling` CHECK (`foresight/src/migrations.ts:607-609`) **and** `engagement_policies_seed_within_ceiling` (`admin-api/src/migrations.ts:426-433`) |
| Per outcome side, per UTC day | 10²² wei = **10,000 EMBER** | trigger `house_seeds_daily_ceiling` (`foresight/src/migrations.ts:709-730`) and the same admin-api CHECK |

These hold against **anyone with a database connection**, not just against the route.
They are mirrored in `houseseed.ts:46-49` and `admin-api/src/engagement.ts:56-57` so the
routes can refuse with a sentence, but the constraint is the enforcement.

**Changing a hard ceiling means editing both migrations and re-deploying both
services.** They must move together, or the operator cap could be set above what the
`house_seeds` table will accept — which would produce an approval that passes every
check and then fails at the insert.

### 6.2 The operator caps — rows, below the ceilings

`seed_per_market_wei` and `seed_per_day_wei` on the `foresight` row of
`engagement_policies`. Read at approval time, **fail-closed**: if admin-api cannot be
reached, approval *with a seed* refuses and says retry; approval *without* one is
untouched, because an unreachable operator surface must not stop ordinary markets
(`adminapiclient.ts:16-18`, `:103-110`).

**Lowering is free. Raising is approval-gated.** This asymmetry is enforced in the
schema, not restated in a route — the trigger `engagement_raise_needs_approval`
(`admin-api/src/migrations.ts:467-514`) refuses any raise that does not name a *fresh,
approved* `engagement.policy.set` approval, and refuses an approval that is not one
(`:500-505`). The route refuses too (`admin-api/src/server.ts:1252-1257`), but the
trigger is the enforcement of record.

To lower: `PUT /v1/engagement/policies/foresight` (`admin-api/src/server.ts:1257`).
To raise: raise an `engagement.policy.set` approval and execute it
(`admin-api/src/actions.ts:562-574`).

### 6.3 The number that should actually govern you

The hard ceilings are far above what this estate can fund. At the per-day ceiling you
would deploy **20,000 EMBER of capital in a single day** (10,000 per side × 2 sides) —
nearly **twice everything the mainnet miner has ever produced** (10,806 EMBER, §1.1).
The ceilings are a backstop against a runaway, not a budget.

Set your operator caps against the balance you are willing to have sitting behind a
hot key (§2.3), not against the ceilings.

---

## 7. What it costs — the honest economics

**Symmetric seeding is a subsidy. It is not free, and it is not risk-free.** Here is
exactly what happens, in plain arithmetic.

The house stakes `S` on YES and `S` on NO, so it puts in **`2S`**. Outside bettors then
stake `Y` on YES and `N` on NO. The market resolves. The contract's parimutuel maths
(`ForesightMarket.sol:381-416`) is:

- the fee is `feeBps` × the **losing** pool — charged against other people's losses,
  never against a winner's principal (`:372-385`);
- winners divide `total − fee` in proportion to their stake on the winner.

Say YES wins. The house held `S` of the `S+Y` winning pool, so it gets back

> `S × (2S + Y + N − fee) / (S + Y)`

Work through the cases:

| Situation | What the house gets back | Net |
| --- | --- | --- |
| **Nobody else bets** (`Y = N = 0`) | `2S − f·S` | Loses exactly the settlement fee — **and the fee goes to `FORESIGHT_TREASURY_ADDRESS`, which is the platform's own**. Round trip, minus gas. |
| **Outside money lands mostly on the eventual winner** | approaches `S` as `Y` grows | **This is the loss case.** |
| **Outside money lands mostly on the eventual loser** | `2S + N(1−f) − f·S` | **Gains**, and the gain grows with `N`. |

Two conclusions follow, and both are worth internalising:

**1. The maximum loss on any single market is `S` — the per-outcome amount, i.e.
*half* of what the house staked.** It is a strict bound: the payout is decreasing in
`Y` and its infimum is `S`. The house can never lose more than `S` on a market, no
matter how one-sided the crowd is.

**2. The house wins when the crowd is wrong and loses when the crowd is right.** It is
a passive liquidity provider taking the other side of everybody. Against a crowd no
better than chance it roughly breaks even. Against a crowd that is genuinely
informed — which is the *point* of a prediction market, and the outcome you should
want — **it loses steadily.** A well-functioning Foresight is one where this
programme costs money. Budget for that; do not treat a loss as a malfunction.

### 7.1 Budgeting it

Per market, at a per-side size `S`:

- **Capital deployed:** `2S`, locked until the market resolves and is claimed.
- **Worst case:** lose `S`.
- **Expected case, informed crowd:** lose some fraction of `S`.
- **Plus gas:** two `stake` transactions and one `claim` per market, plus the funding
  transfer.

So the honest planning number is: **the programme's maximum drawdown is the sum of `S`
over all live seeded markets**, and its capital requirement is twice that. At your
per-day cap `D` (per side), the most you can lose from one day's seeding is `D`, and the
most you deploy is `2D`.

**What it buys.** A parimutuel market with one bettor is a refund machine — the lone
winner splits a pool containing only their own stake, so nobody's first bet can ever be
interesting (`foresight/README.md:334-336`). The subsidy buys a market that a first
bettor can meaningfully enter. That is the entire return, and it is a product return,
not a financial one.

---

## 8. How to stop, and how to unwind

### 8.1 Stopping new seeding

Three levers, in increasing order of finality. None of them touches a seed already
placed:

1. **Approve markets without `houseSeedPerOutcomeWei`.** Nothing is planned, nothing
   is staked. This is the default and needs no configuration change.
2. **Lower the operator caps to zero** (§6.2) — free, no approval needed. Every
   approval carrying a seed then refuses with `seed_above_policy`.
3. **Unset `FORESIGHT_HOUSE_ADDRESS` and restart.** Back to the documented supported
   mode: 409 `house_address_unconfigured`, everything else untouched.

None of these can retroactively affect an open market, and that is deliberate — a
recorded stake is **immutable**, because it is the disclosure the market page shows
(trigger `house_seeds_carry_open_timestamp`, `foresight/src/migrations.ts:673-676`).

### 8.2 Money already in a market

**There is no withdraw.** `ForesightMarket.sol` has no function that takes a stake back
out of an open market — for the house or for anyone. The money comes back exactly two
ways:

**If the market is voided or cancelled — the house gets everything back, whole.**
`payoutOf` on a void market returns *"everything they put in, on both sides, exactly"*
(`ForesightMarket.sol:405-409`), the fee is zero on anything but `Resolved`
(`:381-385`), and `claimableFrom` returns the current block timestamp so there is **no
dispute window to wait out** (`:393-397`). Call `claim()` from the house address.
Voiding is available at any time, including before close — *"that is the point of it"*
(`:229-233`).

**If the market resolves normally** — the house claims its proportional winnings like
any other staker, after the dispute window (24h by default,
`foresight/src/env.ts:602-608`). `claim()` from the house address, or `claimFor(house)`
from anywhere — `claimFor` exists precisely so a batching job can push a payout, and its
failure costs nobody anything because the staker can always call `claim` themselves
(`ForesightMarket.sol:427-437`). **A double claim is impossible**, structurally: the
flag is set before the transfer (`:444-446`).

**Unclaimed money is not lost, but it is not automatic either.** Nothing in this estate
claims on the house's behalf today. If you seed markets and never claim, the EMBER sits
in the contracts indefinitely. **Keep a list of every market you seed**, and claim each
one after it settles. `GET /markets/:id` carries `houseSeed.txHashYes`, and the
`house_seeds` table is the authoritative list:

```sql
select market_id, amount_yes_wei, state, staked_at from house_seeds order by created_at;
```

### 8.3 Getting the EMBER back to the platform

From the house address the EMBER returns the way 21 §3 says everything does — **through
the front door**: deposit to a custody address, indexer confirmation, conversion
(`houseseed.ts:20-26`). There is no privileged path, and there should not be.

---

## 9. Two findings this document had to record

### 9.1 The market page says EMBER, not Shards — and that is correct

`docs/ecosystem/21-engagement-treasury.md:98` words the disclosure as *"CloudsForge
seeded this pool with X **Shards** so early odds exist."* SHARD is a **retired** asset
(`contracts/packages/chain/src/index.ts:58`), so a live surface saying it would be a
correctness problem.

**It does not.** The sentence is composed once, server-side, in EMBER
(`foresight/src/houseseed.ts:241`), rendered verbatim by the client
(`foresight-web/src/components/houseseed.tsx:62`), and the client's own fallback also
says EMBER (`foresight-web/src/lib/houseseed.ts:110`). The divergence from the document
was deliberate and is recorded in both source (`houseseed.ts:222-229`) and README
(`foresight/README.md:385-390`): converting wei through an administered price would make
the disclosed number move without anybody staking anything, so the honest unit is the
pool's own.

**The "Shards" string is doc-only on this surface.** No fix was needed to the market
page.

Do not confuse this with **Sparks** — 10⁻⁶ EMBER, a legitimate *display denomination*,
explicitly *"not a second asset code"* (`contracts/packages/chain/src/index.ts:394-425`).

### 9.2 But the engagement treasury's ledger leg genuinely is SHARD-denominated

This is the real one, and it is a defect rather than a wording problem.

`engagement.transfer` posts both sides of its ledger entry with
**`assetCode: 'SHARD'`** (`admin-api/src/actions.ts:500`, `:504`, `:512`, `:516`), the
column is `amount_shards` (`admin-api/src/migrations.ts:544`), the cap is
`transfer_cap_shards` (`:390`), and the admin operator UI renders the balances labelled
**"Shards"** (`admin-web/src/pages/engagement.tsx:154`, `:161`, `:185`, `:231`).

The UI label is *not wrong* — it faithfully describes what the ledger holds. Relabelling
it "EMBER" alone would turn a correct label into a lie. The problem is one layer down:

- **SHARD is retired.** `assertIssuable('SHARD')` throws
  (`contracts/packages/chain/src/index.ts:82-87`). No new SHARD can be issued.
- The ledger permits SHARD on `transfer` deliberately, because 69,000 SHARD sit in live
  accounts and a rule that refused those kinds would strand every unit of it
  (`ledger/src/entries.ts:271-281`) — so the transfer will *execute*. It just moves a
  retired asset.
- **Meanwhile the seed caps in the same table are EMBER wei**
  (`seed_per_market_wei`, `admin-api/src/migrations.ts:391-396`), and the seed on chain
  is EMBER. **The two legs of one programme are denominated in two different assets, one
  of which is retired.**

**The operational consequence, which is what matters for this runbook:** the balance in
`engagement:foresight` would be SHARD bookkeeping. It does **not** fund, and cannot
fund, the on-chain EMBER stake. That is why §1's answer is what it is — the EMBER moves
from the miner coinbase to the house address directly, and the ledger entry, if you make
one, is a parallel record rather than the money. 21 §4's promise that *"an auditor
reconstructs the entire programme from the ledger alone"* is **not currently true for
the house seed**: the ledger would show a SHARD movement whose on-chain counterpart is
an EMBER stake it cannot see.

**The good news is that nothing is stuck.** Because no engagement transfer has ever been
made and neither account exists (§0), there is no SHARD balance to unwind and no history
to migrate. The defect is entirely ahead of you, not behind you — which makes this the
cheapest possible moment to fix it, and the argument for fixing it *before* funding the
programme rather than after.

Filed as an issue against `micro-admin-api`. It does not block the procedure above —
follow §1 through §8 and the seed is correct, disclosed and auditable on chain — but do
not expect the admin panel's engagement figures to describe your EMBER, and do not read
a "Shards" figure there as anything to do with the money at the house address.

---

## 10. Provenance

Written 2026-08-06 by reading the source, not by transcribing
`docs/ecosystem/21-engagement-treasury.md`. Every claim above is anchored to a
`path:line`; where this document and 21 disagree, the source is right and the
disagreement is called out (§9.1).

**The live estate was inspected, not assumed.** Every claim in §0 about what exists in
the databases comes from reading both stacks (`cloudsforge-estate`, mainnet, and
`cf-testnet`) directly on 2026-08-06: table DDL and constraints from `\d`, row counts
from `select count(*)`, the ledger's account list from `accounts`, the environment from
`docker inspect`, and the coinbase balances and chain ids from JSON-RPC. Nothing was
changed, no key file was read, and `FORESIGHT_HOUSE_ADDRESS` was not set.

**Not rehearsed end to end.** Unlike `custody-backup-restore.md`, whose Appendix A
records an actual disaster drill, no house seed has ever been staked on either network —
there is no house address and no key. The procedure in §4 is assembled from the three
paths that *have* run against the live chain: `ember-seed.js` (funding transfers),
`foresight-market-journey.mjs` (the full market lifecycle including `stake(uint8)`,
close, resolve and claim), and `houseseed.test.ts` (all seven schema invariants,
fire-tested with raw SQL, routes bypassed). **Rehearse on testnet 7412 before mainnet.**
