#!/usr/bin/env node
'use strict';
/* Send EMBER from the chain host's mining coinbase to one named address.
 *
 *   ./scripts/hearth-fund-run.sh --status 0xabc…       # read both balances, write nothing
 *   ./scripts/hearth-fund-run.sh --dry-run 0xabc… 60   # everything except the send
 *   ./scripts/hearth-fund-run.sh 0xabc… 60             # send 60 EMBER
 *
 * ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
 *
 * `docs/39` phase D asks for "one EMBER pair seeded from testnet mining, swapped
 * both ways by A WALLET THAT IS NOT OURS" and "a full cycle — add, swap, swap
 * back, remove — from the browser extension". `hearth-dex-seed.js` did the pair
 * and the cycle, and it did all of it with `minerKey()` — the key that is also
 * the chain's coinbase. Every transaction in that run was signed by the house.
 *
 * Closing the gate needs a SECOND key, held somewhere the coinbase is not, and
 * on a chain whose genesis says "NO PREMINE" the only place a second key's first
 * coin can come from is a miner. That is the whole job of this script: a plain
 * value transfer, nothing else, so that a wallet on another machine can start
 * with a balance and sign everything it does itself from there on.
 *
 * ── WHAT IT DELIBERATELY DOES NOT DO ─────────────────────────────────────────
 *
 * It does not know about tokens, pools or routers, and it must not learn. If
 * this script ever approves, swaps or adds liquidity, the funded wallet has
 * stopped being an independent counterparty and has become the house wearing a
 * second address — which is the exact thing phase D exists to rule out. The
 * recipient acquires its tokens by trading, or it has proven nothing.
 *
 * It is also not a faucet: one address per invocation, named on the command
 * line, with the amount named too.
 *
 * ── THE CAP, AND WHY IT IS NOT A COMMENT ─────────────────────────────────────
 *
 * The miner's balance is the testnet's entire float and this script spends it
 * with no confirmation prompt. A typo in the amount — a trailing zero, a decimal
 * point in the wrong place — is unrecoverable, because the recipient of a
 * mistake is by construction an address this host does not hold the key for. So
 * there is a ceiling, it is small, and passing it needs `--cap` said out loud.
 *
 * On MAINNET the ceiling is zero and cannot be raised. There is no phase-D
 * equivalent on 7411 yet (`docs/39` phase F), the coins have a price, and a
 * script whose whole purpose is "move mined coins to a key held elsewhere" is
 * not one that should be a flag away from running against the real chain.
 */

const path = require('path');

const {
  dim, ok, bad, note, heading, failureCount,
  hexToBig, units, connect, minerKey,
} = require('./lib/hearth-evm.js');

// ── configuration ────────────────────────────────────────────────────────────
const HEARTH = process.env.HEARTH_REPO || path.resolve(__dirname, '../../hearth');

const EMBER_NETWORK = process.env.CF_EMBER_NETWORK || 'testnet';
const EMBER_CHAIN_IDS = { mainnet: 7411, testnet: 7412 };
const EXPECTED_CHAIN_ID = EMBER_CHAIN_IDS[EMBER_NETWORK];
if (EXPECTED_CHAIN_ID === undefined) {
  console.error(`CF_EMBER_NETWORK is "${EMBER_NETWORK}"; known: ${Object.keys(EMBER_CHAIN_IDS).join(', ')}`);
  process.exit(2);
}

const EMBER_HOME = process.env.EMBER_HOME || path.join(process.env.HOME || '/root', `.cloudsforge/ember-${EMBER_NETWORK}`);
const MINER_DATA = process.env.EMBER_MINER_DATA || path.join(EMBER_HOME, 'miner');
const RPC = process.env.EMBER_HOST_RPC || 'http://127.0.0.1:8545';

/** A decimal amount of whole units, as wei. `60` and `0.25` both work. */
function toWei(text, decimals = 18) {
  const [whole, frac = ''] = String(text).trim().split('.');
  if (!/^\d+$/.test(whole) || !/^\d*$/.test(frac)) throw new Error(`"${text}" is not an amount`);
  if (frac.length > decimals) throw new Error(`"${text}" has more than ${decimals} decimal places`);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0');
}

/* The ceiling, per network. Testnet's 250 EMBER is roughly what a phase-D cycle
 * costs with room to be wrong twice: the extension test spends about 15 on the
 * pool and the rest is gas and slack. Mainnet's zero is argued for in the header. */
const CAP = { testnet: toWei('250'), mainnet: 0n }[EMBER_NETWORK];

// ── arguments ────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const STATUS_ONLY = args.includes('--status');
const DRY_RUN = args.includes('--dry-run');
const RAISED_CAP = args.includes('--cap');
const positional = args.filter((a) => !a.startsWith('--'));

const TO = (positional[0] || '').toLowerCase();
if (!/^0x[0-9a-f]{40}$/.test(TO)) {
  console.error('usage: hearth-fund.js [--status|--dry-run] [--cap] <0xrecipient> [amount]');
  console.error('  the recipient is a 20-byte hex address; the amount is in whole EMBER');
  process.exit(2);
}
const AMOUNT = STATUS_ONLY ? 0n : toWei(positional[1] || '0');

async function main() {
  heading(`funding on EMBER ${EMBER_NETWORK}`);
  const { rpc, send, addressOf } = connect({ rpcUrl: RPC, hearthRepo: HEARTH });

  const chainId = Number(hexToBig(await rpc('eth_chainId')));
  if (chainId !== EXPECTED_CHAIN_ID) {
    bad(`${RPC} is chain ${chainId}; CF_EMBER_NETWORK=${EMBER_NETWORK} expects ${EXPECTED_CHAIN_ID}`);
    return 1;
  }
  ok(`chain ${chainId} at block ${Number(hexToBig(await rpc('eth_blockNumber')))} ${dim(RPC)}`);

  const key = minerKey(MINER_DATA, EMBER_NETWORK);
  // The key file carries an address; the one that will sign is derived from the
  // private half. A file whose two halves disagree would spend from an account
  // nobody checked the balance of.
  if (addressOf(key.priv) !== key.address) {
    bad(`the mining key file says ${key.address} but its private key derives ${addressOf(key.priv)}`);
    return 1;
  }

  const balanceOf = async (a) => hexToBig(await rpc('eth_getBalance', [a, 'latest']));
  const minerBefore = await balanceOf(key.address);
  const recipientBefore = await balanceOf(TO);
  note(`miner     ${key.address}  ${units(minerBefore)} EMBER`);
  note(`recipient ${TO}  ${units(recipientBefore)} EMBER`);

  if (STATUS_ONLY) return failureCount() === 0 ? 0 : 1;

  if (AMOUNT === 0n) { bad('an amount of zero moves nothing; name one'); return 1; }
  if (TO === key.address) { bad('the recipient is the miner itself'); return 1; }
  // A contract can be funded deliberately, but not by accident: a mistyped
  // address that happens to have code is far likelier to be a mistake than a
  // plan, and a plain transfer to a contract with no payable fallback is burned.
  const code = await rpc('eth_getCode', [TO, 'latest']);
  if (typeof code === 'string' && code.length > 2) {
    bad(`${TO} has contract code — this script sends to accounts, not to contracts`);
    return 1;
  }
  if (AMOUNT > CAP && !RAISED_CAP) {
    bad(`${units(AMOUNT)} EMBER is over the ${units(CAP)} cap for ${EMBER_NETWORK}; pass --cap if you mean it`);
    return 1;
  }
  if (AMOUNT > CAP && EMBER_NETWORK === 'mainnet') {
    bad('the mainnet cap is zero and --cap does not raise it — see this script\'s header');
    return 1;
  }
  if (minerBefore < AMOUNT * 2n) {
    bad(`the miner holds ${units(minerBefore)} EMBER; sending ${units(AMOUNT)} would leave it under half`);
    return 1;
  }

  if (DRY_RUN) {
    note(`dry run: would send ${units(AMOUNT)} EMBER to ${TO}`);
    return failureCount() === 0 ? 0 : 1;
  }

  const estimate = hexToBig(await rpc('eth_estimateGas', [{ from: key.address, to: TO, value: '0x' + AMOUNT.toString(16) }]));
  const receipt = await send(key, { to: TO, value: AMOUNT, gasLimit: estimate }, chainId, `${units(AMOUNT)} EMBER → ${TO}`);
  ok(`sent ${dim(`block ${Number(hexToBig(receipt.blockNumber))}, gas ${Number(hexToBig(receipt.gasUsed))}, tx ${receipt.transactionHash}`)}`);

  /* MEASURED AT THE RECIPIENT, NOT AT THE SENDER. The sender is the coinbase, so
   * its balance also moves with every block mined while this waited — the trap
   * `hearth-dex-seed.js` documents at length. The recipient's balance moves for
   * exactly one reason. */
  const recipientAfter = await balanceOf(TO);
  const arrived = recipientAfter - recipientBefore;
  if (arrived === AMOUNT) ok(`${TO} rose by exactly ${units(arrived)} EMBER`);
  else bad(`sent ${units(AMOUNT)} EMBER but the recipient rose by ${units(arrived)}`);

  return failureCount() === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => { console.error(`  FAIL ${err.message}`); process.exit(1); },
);
