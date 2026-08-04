/**
 * The nine questions micro-foresight opens with.
 *
 * ── WHY THIS IS A DATA FILE AND NOT A LITERAL INSIDE THE SEEDER ───────────────
 *
 * Everything here is RESEARCH, and research is the expensive part. The code that
 * posts these to `POST /markets` is twenty lines and can be rewritten in an hour;
 * the close dates, the resolution sources and the readings taken to make each
 * question genuinely uncertain cannot. So they are separated, and this file is
 * committed on its own.
 *
 * ── THE BAR EVERY ENTRY HAD TO CLEAR ─────────────────────────────────────────
 *
 * A market that resolves on opinion is worse than no market. Each entry below
 * therefore has, and was rejected without:
 *
 *   1. **A close time genuinely in the future** — every one of these is after
 *      2026-08-04, the day they were written, and most are weeks or months out.
 *   2. **A question nobody can argue about afterwards.** No "significant", no
 *      "major", no "widely regarded". Every threshold is a number and every
 *      subject is a named body. Where a word could be read two ways —
 *      "lower the rate" — `resolutionCriteria` says which two documents are
 *      compared and on which field.
 *   3. **A named source of truth, recorded before the market opens.** foresight
 *      hashes `resolutionSourceRef` into `question_hash` and commits that to the
 *      contract (`foresight/src/markets.ts:232-244`), so the source cannot be
 *      changed after the fact even by an operator with a database connection.
 *      That is the property that makes naming it worth doing.
 *
 * ── THE READINGS, AND WHY THEY ARE WRITTEN DOWN ──────────────────────────────
 *
 * Several thresholds are only defensible next to the value they were set from —
 * "above 969,200" means nothing without "960,969 on the day". Each entry carries
 * an `observed` note giving the reading, its date and the endpoint it came from,
 * so a reader can check that the threshold was set to be UNCERTAIN rather than
 * set to be already true. A market whose answer was known at open is not a
 * market; it is an advertisement.
 *
 * All readings were taken on 2026-08-04 from the sources named in each entry.
 *
 * ── CATEGORIES ARE THE SERVICE'S, NOT THIS FILE'S ────────────────────────────
 *
 * `category` and `resolutionSourceKind` are checked against `foresight/src/
 * categories.ts:65-89` at create time, and a wrong pairing is a 400
 * (`bad_source_kind`, `markets.ts:250-256`). The three categories are
 * `protocol_network`, `market_prices` and `scheduled_public_events`; three
 * questions are written for each, so no category renders as an empty tab.
 *
 * ── DISPUTE WINDOWS ARE NOT ALL THE SAME, DELIBERATELY ───────────────────────
 *
 * A question that settles off a machine-readable endpoint read at a single
 * instant needs a day. One that settles off a document a human body publishes on
 * its own schedule — an official election return, a final championship
 * classification — needs longer, because the window has to outlive the gap
 * between the event and its publication. 86,400s for the first kind, 604,800s
 * for the second. The ceiling is 2,592,000s (`server.ts:747-750`).
 *
 * ── OUTCOMES ARE BINARY BECAUSE THE SERVICE IS ───────────────────────────────
 *
 * `stake(uint8)` takes 0 = YES and 1 = NO and there is no N-ary form
 * (`foresight/src/server.ts:590`, `migrations.ts:280`). Every question below is
 * therefore phrased so that YES and NO are exhaustive and mutually exclusive,
 * and `resolutionCriteria` always says what NO means rather than leaving it to
 * be inferred.
 */

/** @typedef {{
 *   question: string,
 *   resolutionCriteria: string,
 *   category: 'protocol_network' | 'market_prices' | 'scheduled_public_events',
 *   resolutionSourceKind: string,
 *   resolutionSourceRef: string,
 *   closeTime: string,
 *   disputeWindowSeconds: number,
 *   feeBps: number,
 *   observed: string,
 * }} SeedQuestion
 */

/** A day, in seconds — for a question a machine answers at an instant. */
const ONE_DAY = 86_400
/** A week — for a question a human institution answers by publishing a document. */
const ONE_WEEK = 604_800

/** The estate's default fee on the losing pool, stated rather than defaulted. */
const FEE_BPS = 200

/** @type {readonly SeedQuestion[]} */
export const FORESIGHT_QUESTIONS = [
  /* ─────────────────────────────── protocol_network ──────────────────────────
   * Source kinds available: chain_rpc, block_explorer, protocol_publication.
   */
  {
    question:
      'Will the Bitcoin mainnet block height be strictly greater than 969,200 at 2026-09-30T00:00:00Z?',
    resolutionCriteria:
      'YES if the integer returned by the source endpoint, read once at or after the close time, ' +
      'is strictly greater than 969200. NO if it is 969200 or lower. The reading is taken from the ' +
      'Bitcoin mainnet chain only; no testnet, no fork, and no other chain counts. If the endpoint ' +
      'is unreachable, the same height as published by any two independent Bitcoin block explorers ' +
      'settles it, since block height is a property of the chain and not of the endpoint.',
    category: 'protocol_network',
    resolutionSourceKind: 'block_explorer',
    resolutionSourceRef: 'https://mempool.space/api/blocks/tip/height',
    closeTime: '2026-09-30T00:00:00.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      'Tip height 960,969 read from https://mempool.space/api/blocks/tip/height on 2026-08-04. ' +
      '57 days to close at the protocol target of 144 blocks/day projects 969,177 — so 969,200 ' +
      'sits just ABOVE the expected value and the question turns on whether hashrate grows. ' +
      'Chosen for that reason: a threshold below the projection would have been a market on nothing.',
  },
  {
    question:
      'Will the Ethereum mainnet upgrade named Amsterdam/Gloas ("Glamsterdam") have activated on ' +
      'Ethereum mainnet before 2027-01-01T00:00:00Z?',
    resolutionCriteria:
      'YES if, at the close time, the Ethereum Foundation\'s network-upgrades history page lists ' +
      'Amsterdam/Gloas ("Glamsterdam") with an activation date on Ethereum mainnet earlier than ' +
      '2027-01-01T00:00:00Z. NO if that page still shows the upgrade as TBD or unscheduled, or ' +
      'lists an activation date at or after that instant. A fork activating on a testnet only ' +
      '(Holesky, Sepolia, Hoodi or any successor) is NO: the question names mainnet.',
    category: 'protocol_network',
    resolutionSourceKind: 'protocol_publication',
    resolutionSourceRef: 'https://ethereum.org/en/history/',
    closeTime: '2026-12-31T23:59:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'On 2026-08-04 that page listed Fulu-Osaka ("Fusaka") as the most recent mainnet upgrade — ' +
      'activated 2025-12-03 at block 23,935,694 / epoch 411,392 — and listed Amsterdam + Gloas ' +
      '("Glamsterdam") as "TBD - Next" with no date, block or epoch announced. So the question was ' +
      'open at the moment it was written, which is the only reason it is worth asking.',
  },
  {
    question:
      'Will the Bitcoin difficulty retarget taking effect at block height 961,632 be an INCREASE ' +
      'on the epoch before it?',
    resolutionCriteria:
      'YES if, once the Bitcoin mainnet tip is at or above height 961,632, the retarget applied at ' +
      'that height was a positive change — equivalently, the difficulty of the epoch beginning at ' +
      '961,632 is strictly greater than the difficulty of the epoch that ended at 961,631. NO if it ' +
      'is lower or exactly equal. Read from the source endpoint\'s `previousRetarget` field once ' +
      'the tip is at or above 961,632; any block explorer publishing a difficulty history for ' +
      'mainnet settles it identically, because the retarget is a consensus value.',
    category: 'protocol_network',
    resolutionSourceKind: 'block_explorer',
    resolutionSourceRef: 'https://mempool.space/api/v1/difficulty-adjustment',
    closeTime: '2026-08-06T00:00:00.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      'On 2026-08-04 that endpoint reported nextRetargetHeight 961,632, remainingBlocks 663, ' +
      'progressPercent 67.11%, a PROJECTED difficultyChange of +1.2355%, and a previousRetarget of ' +
      '-0.7384% — i.e. the epoch before this one went DOWN. estimatedRetargetDate was 2026-08-08. ' +
      'Close is set to 2026-08-06, safely before the retarget can occur, so the answer cannot be ' +
      'known while the market is open. A projection of +1.24% with 663 blocks still to mine is ' +
      'genuinely close to the line.',
  },

  /* ──────────────────────────────── market_prices ────────────────────────────
   * Source kinds available: exchange_api, price_index, regulator_publication.
   */
  {
    question:
      'Will the Coinbase BTC-USD spot price be at or above 70,000 USD at 2026-10-01T00:00:00Z?',
    resolutionCriteria:
      'YES if the `data.amount` field returned by the source endpoint, on the first successful read ' +
      'at or after the close time, parses to a number greater than or equal to 70000. NO if it is ' +
      'strictly less. The figure is Coinbase\'s published USD spot price for BTC and no other venue, ' +
      'index or pair is consulted; a different exchange printing a different number does not change ' +
      'the answer, because the question names the venue.',
    category: 'market_prices',
    resolutionSourceKind: 'exchange_api',
    resolutionSourceRef: 'https://api.coinbase.com/v2/prices/BTC-USD/spot',
    closeTime: '2026-10-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      'BTC-USD spot 63,784.425 read from that endpoint on 2026-08-04, corroborated the same day by ' +
      'CoinGecko at 63,771 USD. The threshold is about 9.7% above spot over roughly two months — ' +
      'reachable and not assured, which is the shape a question needs.',
  },
  {
    question:
      'Will the Coinbase ETH-USD spot price be at or above 2,500 USD at 2026-12-01T00:00:00Z?',
    resolutionCriteria:
      'YES if the `data.amount` field returned by the source endpoint, on the first successful read ' +
      'at or after the close time, parses to a number greater than or equal to 2500. NO if it is ' +
      'strictly less. Coinbase\'s published USD spot price for ETH only; no index, no other venue, ' +
      'no staked or wrapped derivative.',
    category: 'market_prices',
    resolutionSourceKind: 'exchange_api',
    resolutionSourceRef: 'https://api.coinbase.com/v2/prices/ETH-USD/spot',
    closeTime: '2026-12-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      'ETH 1,863.59 USD read from CoinGecko on 2026-08-04, alongside the Coinbase BTC reading above. ' +
      'The threshold is about 34% above spot over four months.',
  },
  {
    question:
      'Will the Federal Open Market Committee LOWER the target range for the federal funds rate at ' +
      'the meeting concluding on 16 September 2026?',
    resolutionCriteria:
      'YES if the upper limit of the target range for the federal funds rate stated in the FOMC ' +
      'statement issued at the conclusion of the 15-16 September 2026 meeting is strictly lower ' +
      'than the upper limit stated in the statement issued at the conclusion of the immediately ' +
      'preceding scheduled meeting, which concluded on 29 July 2026. NO if it is unchanged or ' +
      'higher. An unscheduled inter-meeting move, if one occurs, does not settle this question: ' +
      'the two documents compared are the two scheduled-meeting statements named here. If the ' +
      'September meeting does not take place, the market resolves void.',
    category: 'market_prices',
    resolutionSourceKind: 'regulator_publication',
    resolutionSourceRef:
      'https://www.federalreserve.gov/newsevents/pressreleases/monetary20260916a.htm',
    closeTime: '2026-09-16T17:59:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'The Federal Reserve\'s own FOMC calendar, read on 2026-08-04, gives the 2026 meetings as ' +
      'Jan 27-28, Mar 17-18, Apr 28-29, Jun 16-17, Jul 28-29, Sep 15-16 (with a Summary of Economic ' +
      'Projections), Oct 27-28 and Dec 8-9 — so 29 July 2026 is unambiguously the preceding meeting, ' +
      'and materials were posted through it. The statement URL follows the Board\'s fixed ' +
      '`monetary<YYYYMMDD>a.htm` pattern and is therefore knowable in advance, which is what lets ' +
      'the source be NAMED at open rather than described. Close is 17:59Z, one minute before the ' +
      '18:00Z (2pm ET) release.',
  },

  /* ───────────────────────── scheduled_public_events ─────────────────────────
   * Source kinds available: official_announcement, primary_source_publication.
   */
  {
    question:
      'Will the Republican Party win at least 218 of the 435 voting seats in the United States ' +
      'House of Representatives at the general election held on 3 November 2026?',
    resolutionCriteria:
      'YES if the Office of the Clerk of the U.S. House of Representatives, in its official ' +
      '"Statistics of the Congressional Election" for the 3 November 2026 election, records 218 or ' +
      'more seats won by candidates of the Republican Party. NO if it records 217 or fewer. Only ' +
      'the 435 voting seats are counted; delegates and the Resident Commissioner are excluded, as ' +
      'they are in that document. Seats decided by a subsequent special election, a runoff held ' +
      'after the certified return, or a party switch after the election do not change the answer: ' +
      'the figure is the one certified for the 3 November 2026 general election.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'primary_source_publication',
    resolutionSourceRef: 'https://clerk.house.gov/member_info/electionInfo.aspx',
    closeTime: '2026-11-03T11:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'Confirmed on 2026-08-04: the 2026 United States general election is held 3 November 2026, ' +
      'with all 435 voting House seats and 35 Senate seats contested. The Clerk of the House is the ' +
      'body that publishes the official certified return, which is why it is named rather than a ' +
      'news organisation\'s call. Close is 11:00Z on election day — 6am Eastern, before the first ' +
      'polls close anywhere — so no result can be known while the market is open.',
  },
  {
    question: 'Will Arsenal win the 2026-27 English Premier League title?',
    resolutionCriteria:
      'YES if Arsenal are placed first in the final league table of the 2026-27 Premier League ' +
      'season as published by the Premier League after the last match of the season. NO for any ' +
      'other final position. If the season is abandoned without a final table being published, the ' +
      'market resolves void. A points deduction, an appeal or an expulsion applied before the final ' +
      'table is published is reflected in it and therefore in the answer.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'primary_source_publication',
    resolutionSourceRef: 'https://www.premierleague.com/tables',
    closeTime: '2026-08-21T18:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'Confirmed on 2026-08-04: the 2026-27 Premier League season runs 21 August 2026 to 30 May ' +
      '2027 — both ends pushed back a week by the 2026 FIFA World Cup — with fixtures published ' +
      '19 June 2026. Arsenal enter as defending champions, having won 2025-26. Coventry City, ' +
      'Ipswich Town and Hull City are promoted; West Ham, Burnley and Wolves went down. Close is ' +
      'set to 18:00Z on 21 August, before the first fixture of the season kicks off.',
  },
  {
    // ── WHY THIS IS THE CONSTRUCTORS' TITLE AND NOT THE DRIVERS' ──────────────
    //
    // The first draft of this entry asked whether a named driver would win the
    // World Drivers' Championship. It was rewritten before it was ever posted.
    // `foresight/src/categories.ts:79-84` describes this category as "About the
    // event, never about an individual", and `REFUSALS[0]` refuses "a market on
    // a named private individual". A competing Formula One driver is not a
    // private individual and a championship classification is not their life, so
    // the refusal is arguably not engaged — but the CATEGORY's own sentence is
    // not arguable, and a seed market that an operator would have to defend at
    // approval is the wrong thing for the platform's own first content to be.
    // The constructors' title asks the same question of the same season from the
    // same document, and its subject is an entity.
    question: 'Will Mercedes win the 2026 Formula One World Constructors\' Championship?',
    resolutionCriteria:
      'YES if Mercedes is classified first in the FIA\'s final Formula One World Constructors\' ' +
      'Championship classification for the 2026 season. NO for any other classified position. The ' +
      'figure is the FIA\'s final classification after the last round, including any penalty or ' +
      'appeal applied before it is declared final; a provisional classification published on the ' +
      'day of the last race does not settle the question if the FIA subsequently amends it. A ' +
      'change of the team\'s entrant name during or after the season does not change the answer so ' +
      'long as the FIA\'s classification identifies it as the same constructor.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'official_announcement',
    resolutionSourceRef:
      'https://www.fia.com/events/fia-formula-one-world-championship/season-2026 — the FIA final ' +
      'World Constructors\' Championship classification for the 2026 season',
    closeTime: '2026-12-06T12:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'Confirmed on 2026-08-04: the 2026 Formula One season runs to 23 rounds, ending with the Abu ' +
      'Dhabi Grand Prix at Yas Marina on 6 December 2026. Mercedes led the constructors\' standings ' +
      'and Antonelli led the drivers\' championship after the Belgian Grand Prix on 19 July 2026 — ' +
      'by 45 points from Hamilton and 50 from Russell, both of whom score for other entrants. A ' +
      'lead with a third of the season to run is a lead, not a certainty. Close is set before ' +
      'lights out at the final round.',
  },
]

/**
 * The five markets already in the database when this seeding was written, and what to do with each.
 *
 * They are TEST ARTEFACTS from `scripts/foresight-market-journey.mjs` — every one asks whether the
 * EMBER testnet is above a block height at a time that has already passed. They are not fraudulent
 * and they are not junk: three of them are real contracts on the real chain and one resolved
 * correctly, which is the proof that the service works. So this file does NOT delete them, and the
 * seeder does not either. Deleting data the estate produced hides the evidence that it ran.
 *
 * The rule the seeder applies, and why it is a rule rather than a list of five ids:
 *
 *   * **A market with no `contractAddress` is voided**, with a reason naming what it was. It never
 *     reached a chain, nobody could ever have staked on it, and leaving a dead draft in the
 *     registry is how an operator later mistakes a stalled deploy for a live question.
 *     `POST /markets/:id/void` allows exactly this and refuses the other case.
 *
 *   * **A market WITH a `contractAddress` is left alone.** `POST /markets/:id/void` answers 409
 *     `on_chain` for these by design — "void it through the oracle so the chain and the registry
 *     agree" (`foresight/src/server.ts:981-988`) — and the oracle path needs the market to be
 *     `closed`, which needs it to have been `open`. Two of the three never opened, so there is no
 *     API path that voids them, and the honest thing is to say so rather than to reach past the
 *     service into its database. That is a finding, recorded here, not a licence to write SQL.
 */
export const TEST_ARTEFACT_VOID_REASON =
  'Test artefact from scripts/foresight-market-journey.mjs, voided during seeding: it asks about a ' +
  'block height at a time already past, it never reached a chain, and no stake was ever possible on ' +
  'it. Voided rather than deleted so the record of the run survives.'

/**
 * Recognises the journey script\'s questions, so seeding never voids a real market by accident.
 *
 * The network and the chain id are both alternations, not literals. This pattern was pinned to
 * `testnet` / `7412` and the journey script now emits whichever pair `CF_EMBER_NETWORK` selects
 * (`foresight-market-journey.mjs:117-118` — `hearth` is 7411, `hearth-testnet` is 7412 per
 * `hearth/node/src/params.js:37-38`). Left pinned, this would have stopped matching its own
 * artefacts on the mainnet estate and quietly left every one of them standing as a real market —
 * a false NEGATIVE, which is the direction that does damage here.
 *
 * Still anchored and still specific: it is the exact sentence the journey builds and nothing else,
 * so the reverse mistake — voiding a market somebody meant — stays impossible.
 */
export function isTestArtefact(question) {
  return /^Will the EMBER (?:mainnet|testnet) \(chain 741[12]\) be above block height \d+ at /.test(question)
}
