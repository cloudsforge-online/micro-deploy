# Forge Exchange on Hearth: what is deployed, where, and how it got there

This is the deployment note that [`hearth/contracts/README.md`](../../hearth/contracts/README.md)
asks for. It records **five addresses on one chain**, the proof that the router can
find its own pools, and the one thing about the signer set that must not be read as
more than it is.

Sibling documents in the same genre: [`house-seed.md`](./house-seed.md) (the Foresight
house key) and [`custody-backup-restore.md`](./custody-backup-restore.md).

---

## 0. State, as of 2026-08-16

| | EMBER testnet (chain 7412) | EMBER mainnet (chain 7411) |
| --- | --- | --- |
| Contracts | **Deployed and checked.** §1 | **Deployed** from block 38840 — `docs/ecosystem/39` phase F |
| Pools | **One, funded and traded.** EMBER/FTEST — §6 | **One**, EMBER/FXR, seeded and traded both ways |
| Readable by a stranger | **Yes.** Index + verifier on `rpc-testnet` — §7 | yes, same pair of surfaces |
| Receipts (`ForgeReceipt`) | **`fLTC` and the `dEMBER` drill.** §9 | **None, and refused** on a measured reserve of zero — §9 |
| Protocol fee | Off (`feeTo()` unset) | Off (`feeTo()` unset) |
| `feeToSetter` | A 2-of-3 wallet, **all three keys on one host** — §3 | a 2-of-3 wallet, **two of three keys on the chain host** |

Contracts existing and a market existing are different claims, and until 2026-08-15
only the first one was true here. It is now both: a pair holds reserves, a swap
against it filled at exactly the quoted price, and liquidity has been withdrawn
again. Later the same day it became readable as well — an address index and a source
verifier on `rpc-testnet.cloudsforge.online`, §7 — and then tradeable by somebody
else: a wallet holding a key this host does not, driving the whole cycle from the
browser extension in blocks 17022–17034 (§6). What that does *not* yet mean is that
anyone can **find** it: there is still no user surface (§8).

---

## 1. The testnet deployment

Chain 7412, deployed from block 14119 by the chain host's miner coinbase key.

| | Address |
| --- | --- |
| `HearthMultisig` | `0x51faced76d70981e863be2987ccc811b0712e4f8` |
| `WEMBER` | `0xa26dfebc362a380e1ade6090c7c5887180d1b263` |
| `HearthV2Factory` | `0x18bbd09d51f4e9e630dd0a86fc984b6326f10e41` |
| `HearthV2Router02` | `0xba2b9db822e1f2ec3039fe474644b8405268a9b4` |
| `Multicall3` | `0x76db8cdcaf4a517a51ae474bd00cfe9a53635c03` |

The machine-readable copy lives on the chain host at
`~/dex/keys/deployment-7412.json` (`format: hearth-exchange-deployment/1`). It is the
running record the script re-reads to stay idempotent, not a summary written at the
end — see §5.

### What the chain says

Every line below was re-read from the node by `--status`, not asserted by the script
that did the deploying:

```
factory.pairCodeHash()  == 0x46b4122ae9db4a03c913cfbed4e6321064741545c60aafe3ed9410be7657a537
factory.feeToSetter()   == 0x51faced76d70981e863be2987ccc811b0712e4f8   (the multisig)
factory.feeTo()         == 0x0000…0000                                  (protocol fee off)
factory.allPairsLength() == 1                                            (§6)
multisig required       == 2, owners 3
router.factory()        == 0x18bbd09d51f4e9e630dd0a86fc984b6326f10e41
router.WETH() == router.WEMBER() == 0xa26dfebc362a380e1ade6090c7c5887180d1b263
multicall3.getChainId() == 7412
```

---

## 2. The gate, and why it is first

`HearthV2Router02` does not ask the factory where a pair is. It computes the address
arithmetically from a hard-coded `INIT_CODE_HASH`. If that constant disagrees with the
bytecode the **live** factory deploys, the router looks for pools at addresses where no
account exists: every swap reverts, or worse, reads zeroes and quotes a price against
an empty pool.

Compiling proves the constant matches what solc emitted *here*. Only
`factory.pairCodeHash()` proves it matches what is running *there*. On chain 7412 it
matches:

```
0x46b4122ae9db4a03c913cfbed4e6321064741545c60aafe3ed9410be7657a537
```

The check runs **before** anything can seed liquidity, and that ordering is the whole
value of it. A wrong hash discovered after a pool is funded is coin sent to an address
the router will never look at again.

Anything that changes compiler settings changes the hash — solc `0.8.26+commit.8a97fa7a`,
`evmVersion: shanghai`, optimizer at 999999 runs, `bytecodeHash: 'none'`, `appendCBOR: false`.
Recompiling with a different solc and redeploying the factory alone silently breaks the
router.

---

## 3. The signer set, stated plainly

`feeToSetter` is the only privileged role in the system, and it is irreversible in one
direction: moving it off an address requires a transaction **from** that address. So the
multisig has to exist before the factory does, or it never usefully exists at all. That
is why the README's order table says step 1 cannot move, and why the script deploys the
wallet first even though nothing else depends on it.

Testnet's wallet is 2-of-3:

| Owner | |
| --- | --- |
| `0x91a11854b364178ed96054d8a6e9be1dbd751d33` | the chain host's miner coinbase key, also the deployer |
| `0xf88f0c5a613940fc5d922a21ed8d13c8d2a52db5` | generated by the script, sealed at mode 0600 |
| `0x65ace932fbd7bfd86b0fa23f59ce2f4016f422c8` | generated by the script, sealed at mode 0600 |

> **All three keys are on one host.** This is one operator holding three keys, not three
> operators. It exercises the *code* path — a threshold above one, proposals,
> confirmations, an owner set that can be rotated — and it is not a custody arrangement.
> Nothing about it should be cited as evidence that the fee switch is protected.

Mainnet's signer set is an open question in `docs/39` §7–§8: **who holds the keys, and on
what devices.** The deploy script refuses to answer it — on mainnet it will not generate
an owner key at all, and demands `HEARTH_DEX_OWNERS`.

---

## 4. Running it

On the chain host (`~/dex`), with the compiled artifacts from
`hearth/contracts/out` in `~/dex/artifacts`:

```bash
./scripts/hearth-dex-run.sh --status     # read the chain, write nothing
./scripts/hearth-dex-run.sh --dry-run    # everything except the sends
./scripts/hearth-dex-run.sh              # deploy, then check
```

`hearth-dex-run.sh` runs `hearth-dex-deploy.js` inside the `hearth-node` image because
the chain host has no `node` on any PATH — it runs the EMBER daemons as host processes
and the miners as containers, and has never needed a JavaScript runtime of its own.
Installing one to run a deploy script would put a second, unpinned Node on the machine
that holds the mining keys.

Mainnet additionally requires:

```bash
CF_EMBER_NETWORK=mainnet HEARTH_DEX_OWNERS=0x…,0x…,0x… ./scripts/hearth-dex-run.sh
```

---

## 5. Four failures already paid for

Each was measured on a real run against 7412 and is fixed in the script, with the cause
written at the fix. They are recorded here because two of them cost money quietly and
the other two report a failure about a success — which on a money contract is worse.

**The receipt deadline was 180 seconds, and it was wrong.** The router's transaction was
reported "never mined" and had in fact been mined successfully about a minute later.
EMBER sits at its difficulty floor; a transient outside miner leaving raises the target
far enough to stall the tip for up to twenty minutes before the emergency rule pulls it
back (`hearth#13`, [`runbook-ember-difficulty-at-floor.md`](../runbooks/runbook-ember-difficulty-at-floor.md)).
A deploy script whose deadline is shorter than a *known* stall reports a failure about a
success. The deadline is now thirty minutes, with a per-minute line that distinguishes
"the chain is stalled" from "this transaction is stuck" by reading the tip.

**And because it threw, it lost the four addresses that had succeeded.** The note was
written after all five deployments. Four contracts were on chain and unrecorded. A re-run
would have deployed a second multisig, a second WEMBER and a second factory — and a
second factory is not a duplicate, it is a different `feeToSetter` domain and a different
set of pair addresses, with the first factory's pools stranded behind a router that no
longer points at them. The note is now written after **every** deployment, so anything on
chain survives any failure after it.

**`eth_estimateGas` was short by a cold-storage step change, and the swap reverted.**
The first swap into the fresh pool was sent with a limit of 141,163 — a 20% pad over an
estimate of 117,636 — and consumed 140,204 before reverting. Re-estimating the identical
call a few blocks later returned 162,938. Nothing about the call had changed; the *pool*
had. `HearthV2Pair._update` writes `price0CumulativeLast` and `price1CumulativeLast` only
when `timeElapsed > 0`, so an estimate taken inside the same timestamp window as the mint
skips both, and at execution time they were cold `0 → nonzero` writes at 20,000 gas each.
Any percentage pad loses this race, because the miss is a step change and not a fraction.
The lib now takes the larger of double the estimate and estimate + 100,000, capped at 90%
of the block gas limit: a gas limit is a ceiling and not a price, and the unused remainder
is refunded, so there is nothing to buy by being tight.

**A swap was reported as returning more EMBER than it cost, and the router was right.**
The reverse leg quoted 24.850965 EMBER and the script measured 35.629561, then correctly
concluded from its own numbers that the 0.30% fee was not being charged. The meter was
the trader's balance either side of the send, with gas added back — and the key these
scripts sign with **is the chain's coinbase**. Two blocks had been mined while the
transaction waited, at ~5.389 EMBER each (`params.js coinbaseRewardWei`: the subsidy less
the Commons' 10%), and 2 × 5.389 is the entire discrepancy. On this estate an
`eth_getBalance` delta across anything that waits for blocks measures **mining**, not
whatever the transaction did. The received amount is now read as the pair's EMBER reserve
delta, which only moves when someone trades.

---

## 6. The first pool

Seeded 2026-08-15 on chain 7412 by `hearth-dex-seed.js`, recorded on the chain host at
`~/dex/keys/pool-7412.json` (`format: hearth-exchange-pool/1` — a **separate** file from
the deployment note, because `hearth-dex-deploy.js` rebuilds its own note from a fixed
field set and would silently drop anything added to it).

| | |
| --- | --- |
| Pair | `0xd439a085d812b21de4b179fafe00281de50733a0` |
| Token | `0x71550efb54bcaccbe84df3efcc3529eae4be8a32` — `FTEST`, 18 decimals, 1,000,000 supply |
| Opened at | block 16753, with 5,000 EMBER / 250,000 FTEST |
| Reserves after two exercise cycles | 4,050.254774 EMBER / 202,500 FTEST, at block 16792 |

The reserves are lower than the seed because the cycle deliberately withdraws 10% each
time, not because anything leaked: the price has held at ~50 FTEST to the EMBER
throughout, which is what a proportional withdrawal is supposed to do to a pool.

**The pair token is `micro-mint`'s token, deliberately.** `docs/39` §4 asks for a second
asset already native to Hearth, and the tempting answer is a ten-line ERC-20 written into
`hearth/contracts/src/` for the occasion — an unreviewed contract in the repository whose
whole value is that its contracts are reviewed, to test a pool against an asset no user
will ever hold. `FTEST` is deployed from `FIXEDSUPPLYTOKEN_BYTECODE`, byte for byte the
creation code every paid Forge Create order runs, extracted by
`scripts/hearth-dex-token-artifact.mjs` with mint's own `SOURCE_SHA256` carried into the
artifact and the pool note. The pool therefore exercises the asset type that will actually
turn up in it.

NEFELI could not do this job: its whole supply sits at the order's recipient and the
chain host's key holds none of it.

### What the run proved, in order

Every line was re-read from the chain, and the order is not decorative — each check is
the precondition for it being safe to spend on the next one.

| | |
| --- | --- |
| The gate | `factory.pairCodeHash()` == the router's `INIT_CODE_HASH`, **before** funding anything (§2) |
| The derivation | after `addLiquidityETH`, `factory.getPair()` == `pairFor()` == the address above |
| The fill | 25 EMBER bought **exactly** the 1,239.348445 FTEST quoted — not "about" |
| The fee | k rose across both legs: the 0.30% stays in the pool, which is the liquidity providers being paid |
| The round trip | selling the FTEST straight back returned exactly the quoted 24.851047 EMBER for 25 spent — a cost of 0.148952, the fee charged twice, as it should be |
| The exit | `removeLiquidityETH` burned 3,181.980515 LP, the LP balance fell by exactly that, and the reserves fell with it |

The exit matters as much as the entry. A pool that takes deposits and cannot return them
is not a market, and "we never tried to withdraw" is how that gets discovered late.

### Running it

```bash
./scripts/hearth-dex-seed-run.sh --status     # read the pool, write nothing
./scripts/hearth-dex-seed-run.sh --dry-run    # everything except the sends
./scripts/hearth-dex-seed-run.sh              # deploy the token, fund the pair, exercise it
./scripts/hearth-dex-seed-run.sh --exercise   # trade against a pool that already exists
```

Same containerised arrangement and same reasoning as §4, with one difference: the seed
script `require`s `./lib/hearth-evm.js`, so the wrapper mounts the script's **directory**
rather than the single file. `HEARTH_DEX_SEED_EMBER` and `HEARTH_DEX_SEED_TOKEN` default
to testnet depths; on mainnet the opening depth is an owner decision (`docs/39` §7) and
the wrapper forwards it but invents nothing.

### The first trade by somebody who is not us — 2026-08-15, blocks 17022–17034

Everything above was signed by `hearth-dex-seed.js` with the key that is also the chain's
coinbase, which is why `docs/39` phase D stood at ⚠ for a day. It is now ✅, and this is
what closed it.

**A second key, and the script that exists only to make one.** `scripts/hearth-fund.js`
sends EMBER from the mining coinbase to one named address and does nothing else — no
approve, no swap, no liquidity. That restraint is the point: a funder that could trade
would make the funded wallet the house wearing a second address, which is the exact thing
the gate rules out. It caps testnet at 250 EMBER behind an explicit `--cap`, and caps
**mainnet at zero, unraisable**.

```bash
./scripts/hearth-fund-run.sh --status 0x…       # read both balances, write nothing
./scripts/hearth-fund-run.sh --dry-run 0x… 60   # everything except the send
./scripts/hearth-fund-run.sh 0x… 60             # send it
```

It ran once: **60 EMBER** to `0x41Fb601D07F652512E7ce529A2D55F5D07BCc80E` in block 16989,
21,000 gas, tx `0xdd0680c9343c2db8eff7ad4444963cd08f02c22917cdb970c785d61a9a434745`. The
arrival was measured **at the recipient**, because the sender is the coinbase and its own
balance moves with every block mined while a transaction waits — the trap §6 already
documents. The recipient rose by exactly 60.000000.

That key was generated on the developer's Mac and has never been on a chain-host disk. It
is not a faucet and there is no second recipient.

**The cycle, from the browser.** `wallet-extension/test/e2e/exchange.test.ts` launches a
real Chromium with the unpacked extension, completes onboarding — so the trading key is
generated *inside the extension*, from a phrase nothing else ever saw — funds it with 12
EMBER from the funder above, and then drives seven `eth_sendTransaction` calls through an
EIP-6963 provider, clicking Approve on each window after reading the destination, the value
and the chain off the screen:

| block | gas | operation |
| --- | --- | --- |
| 17022 | 120,268 | `swapExactETHForTokens` — 4 EMBER → **199.191327 FTEST**, exactly the quote |
| 17024 | 46,407 | `approve` the router for FTEST |
| 17026 | 146,785 | `addLiquidityETH` — 99.595663 FTEST + 1.995969 EMBER → 14.098822 LP |
| 17028 | 46,407 | `approve` the router to sell |
| 17030 | 112,569 | `swapExactTokensForETH` — 99.595663 FTEST → **1.989005 EMBER**, exactly the quote |
| 17032 | 46,196 | `approve` the router for the LP token |
| 17034 | 179,067 | `removeLiquidityETH` — 14.098822 LP → 99.644671 FTEST + 1.994990 EMBER |

Trader `0xc40bDA4111AB15a1F502fe8ac65a2F1a0b50522D`. **Three keys, on two machines:** the
coinbase `0x91a1…1d33` (the house), the funder `0x41Fb…c80E` (the Mac), the trader (the
extension). The test asserts they are three distinct addresses rather than assuming it,
because on a fresh local chain the funder *would* be the coinbase and the run would then
prove the browser half only.

*What it establishes beyond "no revert":*

- Both swaps filled at exactly the router's quote, and the quote was checked against the
  constant product computed from `getReserves()` at a pinned block **before** either trade
  was sent — a router disagreeing with its own reserves stops the run before it spends.
- *k* rose on both legs, so the fee is reaching the pool and not evaporating.
- **The position earned while it was open**: 99.595663 FTEST in, **99.644671** out —
  0.049008 FTEST of fee accrued to a liquidity provider who is not us. First time.
- The round trip cost the trader ≈0.017 EMBER against 0.018 charged, the difference being
  their own LP share returning.
- Every sender was **recovered from the signature** by `hearth/node/src/chain/transaction.js`
  from the raw bytes the extension put on the wire. `eth_getTransactionByHash`'s `from` was
  not used: the node fills it in by doing the recovery, so believing it would be circular.
  (This node has no `eth_getRawTransactionByHash` either — measured, `-32601`.)

Reproducing it needs no access to this host:

```bash
HEARTH_RPC_URL=https://rpc-testnet.cloudsforge.online/ HEARTH_CHAIN_ID=7412 \
HEARTH_COINBASE_KEY=~/.cloudsforge/ember-testnet/e2e-funder.json \
HEARTH_DEX_ROUTER=0xba2b9db822e1f2ec3039fe474644b8405268a9b4 \
HEARTH_DEX_TOKEN=0x71550efb54bcaccbe84df3efcc3529eae4be8a32 \
node --import tsx --test --test-concurrency=1 --test-timeout=900000 test/e2e/exchange.test.ts
```

`HEARTH_DEX_HOME=~/dex/keys` works instead of the two addresses when run on this host: the
test reads `deployment-7412.json` and `pool-7412.json` rather than carrying a hard-coded
address that would go stale, and silently, the first time the exchange is redeployed.

---

## 7. The read surfaces, deployed 2026-08-15

Two services out of `hearth/tools/`, brought up by
[`compose/docker-compose.hearth-devkit.yml`](../compose/docker-compose.hearth-devkit.yml) in project
`cf-testnet` and routed on `rpc-testnet.cloudsforge.online`. Neither is consensus: no key, no
mining, no writes. They answer the two questions this section, when it was a list of what is
missing, said nothing on the estate could.

| Path | Service | Answers |
| --- | --- | --- |
| `/api` | `hearth-explorer-api` | the Etherscan grammar — `txlist`, `getsourcecode`, `getabi`, balances |
| `/verify` | `hearth-verify` | POST a standard-JSON input; it recompiles and compares |
| `/contracts`, `/compilers` | `hearth-verify` | what has been submitted; which solc versions are cached |
| `/contract/0x…`, `/contract/0x…/abi` | `hearth-verify` | the native record, richer than the Etherscan shape |

`explorer-testnet.<apex>` was the obvious home and was unavailable: testnet web hostnames are
retired and that name 302s to the combined view, which would have shadowed any router placed there.

**The index answers the question a node cannot.** It follows 7412 from block 0 and keeps a
per-address transaction list, so the pool's whole history reads back over `/api`: the 250,000 FTEST
seed at 16753, the swap out at 16763, the swap back at 16767, the `removeLiquidity` at 16771, the
second cycle at 16785. `eth_getLogs` finds events; nothing in JSON-RPC finds *every transaction this
address sent or received*.

**One verification covers every identical deployment.** The verifier matches on RUNTIME bytecode,
which carries no constructor arguments, so a Forge Create token and every other token any paid order
has ever deployed are the same bytes with different arguments. That was true of the chain and false
of the software until hearth#24: records were kept one per address, and a lookup for an address
nobody had submitted answered "Contract source code not verified" even when the code at it was
byte-identical to something verified. Records are now indexed by the code deployed at them, under
the code's hash and the hash of the code with its `immutable` slots zeroed.

Measured through Cloudflare after the pin moved to `sha-7fae1bc8`, asking for NEFELI —
`0xf0f009AB1C90ed4e65D79664963ceC3c7d57c579`, which nobody ever submitted:

```
HearthMatchType                     twin-exact
HearthTwinOf                        0x71550efb54bcaccbe84df3efcc3529eae4be8a32
ContractName                        FixedSupplyToken
CompilerVersion                     v0.8.26+commit.8a97fa7a   EVMVersion paris   Runs 200
HearthConstructorArgumentsVerified  0            ConstructorArguments ""
SourceCode                          37,989 bytes              ABI 18 entries
```

`ConstructorArguments` is empty **on purpose and says so**: the native `/contract/` route carries a
`constructorArgumentsNote` explaining that runtime bytecode does not contain them and that verifying
this address directly, with its creation transaction, is what would check them. A record verified at
its own address always beats a derived one, and `/contracts` still lists only submissions — one.

Submitting is `scripts/hearth-verify-submit.mjs`, which walks the import graph and inlines all 11
sources, because mint's build resolves OpenZeppelin through a callback that a verifier compiling in
a sandbox does not have.

---

## 8. What is not done

- **`constructorArgumentsVerified` is 0 on the one direct submission.** FTEST was submitted without
  its creation transaction, so its arguments are recorded and not checked. Re-submitting with
  `--tx` flips it; nothing else changes.
- **No *public* user surface.** `micro-exchange-web` now exists, is routed, and is driven through
  the real gateway by the smoke tier — phase H, recorded in `docs/ecosystem/39`. What is still
  missing is a DNS record: `exchange.cloudsforge.online` resolves nowhere, so the surface is
  reachable from inside the estate and not from outside it. That is a Cloudflare dashboard action,
  not a repository change.
- **No trade has yet met another trade.** Closed as far as the phase-D gate goes — a wallet holding
  a key this host does not has run the full cycle from the extension (§6) — but that run was
  sequential, so nothing in this pool has ever been exposed to a second trade arriving between a
  quote and its settlement. Slippage under contention needs a frontend and more than one person, and
  that is phase H.
- **The mainnet signer set is still §3's open question**, now with contracts behind it. Two of the
  three keys are files on the chain host; the answer has not changed because the deployment
  happened, only the stakes have.

---

## 9. Forge Receipts — `fLTC`, the `dEMBER` drill, and the mainnet refusal

`scripts/hearth-receipt-deploy.js` with `scripts/hearth-receipt-run.sh`, in the idiom of the dex
pair beside them. Three modes:

```
./scripts/hearth-receipt-run.sh --status     # read the chain, write nothing, no UTXO scan
./scripts/hearth-receipt-run.sh --drill      # the redemption rehearsal
./scripts/hearth-receipt-run.sh              # scan Litecoin, deploy, publish, attest, prove
```

**The reserve is measured on the host, not in the container.** `litecoin-cli` authenticates with
the cookie in litecoind's datadir, and handing that datadir to a container that also signs EMBER
transactions and prints diagnostics would put a live credential one stray error message away from a
transcript — which is how bitcoind's rpcauth leaked once already, out of a caught exception nobody
thought contained a URL. So the wrapper scans, prints only numbers, and passes the deploy script
four values: a litoshi total, a Litecoin height, that block's hash, and the address list the total
covers. The script refuses to attest without all four.

The scan is `scantxoutset`, which walks the whole UTXO set in two to four minutes. That slowness is
the feature: it is the only reading that needs no wallet, no import, no index of ours and no
permission, so a stranger's identical command against their own node returns the identical answer.

**The address list is the contract.** Whatever is in it gets published on chain by
`setReserveAddresses`, and the attested total is the sum over exactly those. Two treasury-purpose
keys and one pool-purpose key. Per-user *deposit* addresses are deliberately excluded — coin in a
user's deposit address is that user's, and pledging it would be pledging other people's money.

**Testnet, chain 7412.** `fLTC` at `0x5ff590f4f6f29711706f485d9350666d2f8e2f02` (block 19411), issuer
the 2-of-3 multisig; both issuer actions went through submit → independent confirm → execute, as
proposals 0 and 1 in blocks 19417 and 19423. Attested reserve **0**, at Litecoin height 3161026.
`dEMBER` at `0x197f3dcb648abda5b7c678af5ac4d8042fcc8e6d` (block 19386) is the drill: attested,
issued to a second key, funded that key for its own gas, burned-then-queued, paid out for real in
`0xfc08d74d…fdf0`, and settled with that hash. `unsettledRedemptions()` is zero and the custodian
still holds more than it attested.

**Mainnet, chain 7411: nothing deployed.** The scan measured 0.00000000 LTC at Litecoin height
3161029 and the script refused, quoting `docs/ecosystem/39` §4. There is no override flag. Send
Litecoin to a published reserve address, re-run, and the refusal lifts by itself.

**One decode bug, worth recording because of how it failed.** The drill's settlement check read the
*last* word of `redemption(uint256)`'s return. That getter returns five values, one of them a
string, so the last word is the tail of the payout address — the check printed a "settled txid" of
`0x6338643261353264623500…`, which is the ASCII of `c8d2a52db5`, and declared a failure against a
settlement that was correct on chain. A verifier that cries wolf about a good result is worse than
no verifier, because the next real failure gets waved past. Fixed to the explicit head index, and
the check now lives in `--status` so it can be re-run by anybody, at any time, long after the run
that made the claim.
