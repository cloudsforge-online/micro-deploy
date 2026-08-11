/**
 * The twenty questions micro-foresight runs: the opening nine, and the eleven
 * that came after them.
 *
 * ── TWO BATCHES, KEPT APART ON PURPOSE ───────────────────────────────────────
 *
 * `FORESIGHT_QUESTIONS` below is the concatenation, because the seeder wants one
 * list and nothing about seeding cares which batch an entry came from. The two
 * arrays it is built from are separate, separately named and separately exported
 * anyway, and that is the part worth defending: each batch was researched on ONE
 * DAY against readings taken that day, and its `observed` notes are only
 * intelligible next to the others taken beside them. Blending the twenty into a
 * single literal would lose the only thing that lets a reader check whether a
 * threshold was set to be uncertain — which reading it was set from, and when.
 *
 * `OPENING_NINE` was written 2026-08-04 and lives here.
 * `QUESTIONS_2026H2` was written 2026-08-11 and lives in **micro-foresight**, at
 * `seed/questions-2026h2.mjs`, merged as micro-foresight PR #17. The copy below
 * is that file's `FORESIGHT_QUESTIONS_2026H2` array, entry for entry.
 *
 * ── AND WHY THE SECOND BATCH IS A COPY RATHER THAN AN IMPORT ─────────────────
 *
 * Its own header argues that it belongs in the service, because the service owns
 * the rules an entry has to satisfy: `categories.ts` decides which categories
 * exist and which source kind may settle each, `markets.ts` decides that a close
 * time in the past is a 400. Sitting beside those files it is CHECKED against
 * them by `src/seedquestions.test.ts` on every push, without a database, a chain
 * or a running estate. That argument is right and it is why the batch was
 * authored there.
 *
 * It cannot be imported from there. This repository has no dependency on the
 * micro-foresight checkout — `estate-seed.mjs` runs from a deploy worktree
 * mounted into a container, and the only sibling repository it reaches for is
 * `../hearth`, for the transaction codec, which is a hard requirement it already
 * reports on. Adding a second cross-repository path for a data file would make a
 * seeding run depend on a checkout being present to create content, which is the
 * failure this file's own history is full of. So the array is copied, and the
 * provenance is written down here rather than implied by a path.
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
 *      contract (`foresight/src/markets.ts`), so the source cannot be
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
 * `OPENING_NINE`'s readings were all taken on 2026-08-04, and
 * `QUESTIONS_2026H2`'s all on 2026-08-11, from the sources named in each entry.
 *
 * ── CATEGORIES ARE THE SERVICE'S, NOT THIS FILE'S ────────────────────────────
 *
 * `category` and `resolutionSourceKind` are checked against `foresight/src/
 * categories.ts` at create time, and a wrong pairing is a 400
 * (`bad_source_kind`, `markets.ts`). The three categories are
 * `protocol_network`, `market_prices` and `scheduled_public_events`; the opening
 * nine wrote three questions for each, so no category renders as an empty tab,
 * and the second batch keeps all three populated rather than piling onto one.
 *
 * ── DISPUTE WINDOWS ARE NOT ALL THE SAME, DELIBERATELY ───────────────────────
 *
 * A question that settles off a machine-readable endpoint read at a single
 * instant needs a day. One that settles off a document a human body publishes on
 * its own schedule — an official election return, a final championship
 * classification — needs longer, because the window has to outlive the gap
 * between the event and its publication. 86,400s for the first kind, 604,800s
 * for the second. The ceiling is 2,592,000s (`server.ts`).
 *
 * ── OUTCOMES ARE BINARY BECAUSE THE SERVICE IS ───────────────────────────────
 *
 * `stake(uint8)` takes 0 = YES and 1 = NO and there is no N-ary form
 * (`foresight/src/server.ts`, `migrations.ts`). Every question below is
 * therefore phrased so that YES and NO are exhaustive and mutually exclusive,
 * and `resolutionCriteria` always says what NO means rather than leaving it to
 * be inferred.
 */

/** @typedef {{
 *   question: string,
 *   // The COVER BRIEF: what a header illustration for this market should DRAW.
 *   //
 *   // Deliberately NOT the question. The first batch of covers was generated with the question
 *   // itself as the subject, and FLUX typeset it into the picture — badly. One read "Will Arsenal
 *   // win tho27 English Premier League tible?"; the US House cover rendered "at least 218 … 435
 *   // votiing seats in the 2026 general". Garbled prose is embarrassing; the fabricated NUMERALS
 *   // are the defect, because an invented "218" beside a real market on a platform that custodies
 *   // money reads as a figure somebody could act on.
 *   //
 *   // So each is a short noun phrase describing objects, carrying no sentence, no numeral, no
 *   // date, no proper noun and no team or party mark. The failed batch is kept under
 *   // assets/seed/foresight/candidates/ rather than deleted.
 *   cover: string,
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

/**
 * The nine the estate opened with, researched 2026-08-04.
 *
 * @type {readonly SeedQuestion[]}
 */
export const OPENING_NINE = [
  /* ─────────────────────────────── protocol_network ──────────────────────────
   * Source kinds available: chain_rpc, block_explorer, protocol_publication.
   */
  {
    question:
      'Will the Bitcoin mainnet block height be strictly greater than 969,200 at 2026-09-30T00:00:00Z?',
    cover:
      'a chain of solid rectangular blocks linked end to end, extending away to one side',
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
    cover:
      'modular interlocking components on a grid, one of them being lifted out and replaced by a new one',
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
    cover:
      'a balance beam with weights sliding along it as it settles level, mechanical and precise',
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
    cover:
      'a single heavy coin resting on a raised horizontal ledge, with empty space above it',
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
    cover:
      'a faceted angular gemstone resting on a raised horizontal ledge, with empty space above it',
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
    cover:
      'a large mechanical dial with a lever beside it, set against a plain institutional facade',
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
    cover:
      'rows of empty seats arranged in a wide semicircle inside a domed chamber',
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
    cover:
      'a plain unmarked association football — a round soccer ball with hexagonal panels — beside ' +
      'an empty two-handled trophy cup',
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
    // `foresight/src/categories.ts` describes this category as "About the
    // event, never about an individual", and `REFUSALS[0]` refuses "a market on
    // a named private individual". A competing Formula One driver is not a
    // private individual and a championship classification is not their life, so
    // the refusal is arguably not engaged — but the CATEGORY's own sentence is
    // not arguable, and a seed market that an operator would have to defend at
    // approval is the wrong thing for the platform's own first content to be.
    // The constructors' title asks the same question of the same season from the
    // same document, and its subject is an entity.
    question: 'Will Mercedes win the 2026 Formula One World Constructors\' Championship?',
    cover:
      'the silhouette of an open-wheel racing car beside an empty two-handled trophy cup',
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
 * Eleven more, researched 2026-08-11 — micro-foresight PR #17,
 * `seed/questions-2026h2.mjs`, exported there as `FORESIGHT_QUESTIONS_2026H2`.
 *
 * Copied entry for entry, including every `observed` note, because the note IS
 * the evidence that a threshold was set to be uncertain rather than set to be
 * already true. An entry stripped of it is a number nobody can check.
 *
 * That file carries the reasoning at length and it is not repeated here. The
 * three things a reader of THIS file needs are:
 *
 *   * **No duplicates of the nine above, checked one by one.** Three candidates
 *     were written and dropped for colliding with a question the estate already
 *     runs — a September FOMC market, a second Glamsterdam deadline that the
 *     existing one strictly implies, and a second ETH-USD threshold. The BTC-USD
 *     and Bitcoin-height entries below survived because they are different
 *     thresholds at closes three months later, which is a second question rather
 *     than a second row.
 *
 *   * **One refused outright**, and it is worth knowing which: a market on the
 *     SEC's "Regulation Crypto" proposing release reaching the Federal Register.
 *     The Federal Register API is the best machine-readable source in the batch,
 *     and that is the problem — the condition is a TITLE MATCH, so a commission
 *     that files under a different name settles it NO on a technicality while
 *     every reader can see the rule was published.
 *
 *   * **Every close is genuinely before its answer is public.** The Fed prints
 *     at 18:00Z and its market closes 17:59Z; the S&P 500 prints at the 21:00Z
 *     bell and its market closes an hour earlier; the World Series market closes
 *     before the first pitch of the postseason rather than on the eve of the
 *     series, when the pennants are already decided.
 *
 * @type {readonly SeedQuestion[]}
 */
export const QUESTIONS_2026H2 = [
  /* ─────────────────────────────── market_prices ─────────────────────────────
   * Source kinds available: exchange_api, price_index, regulator_publication.
   */
  {
    question:
      'Will the Coinbase BTC-USD spot price be at or above 75,000 USD at 2026-12-31T23:59:59Z?',
    cover: 'a faceted metal disc resting on a stepped stone pedestal, with empty space above it',
    resolutionCriteria:
      'YES if the `price` field of the Coinbase Exchange BTC-USD ticker, read once at or after ' +
      '2026-12-31T23:59:59Z, is greater than or equal to 75000.00. NO if it is lower, and NO if ' +
      'the BTC-USD product is no longer listed on Coinbase Exchange at that instant. Coinbase is ' +
      'the venue named at open and no other venue settles this question, whatever it prints. If ' +
      'the endpoint does not answer, the reading is retried every 60 seconds for six hours and the ' +
      'first successful response settles it; if none succeeds in that window the market resolves ' +
      'NO, because the question asks what Coinbase printed and the answer is then that it printed ' +
      'nothing.',
    category: 'market_prices',
    resolutionSourceKind: 'exchange_api',
    resolutionSourceRef: 'https://api.exchange.coinbase.com/products/BTC-USD/ticker — field `price`',
    closeTime: '2026-12-31T23:59:59.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      'BTC-USD `price` was 63,918.23 at 2026-08-11T14:33:14Z, read from the endpoint named above. ' +
      'Corroborated the same day by CoinGecko (64,148 at 14:08:30Z) and by coindesk.com/price/' +
      'bitcoin (64,153.46). The threshold is 17.3% above that reading, and CoinDesk\'s markets ' +
      'blog on 2026-08-11 recorded bitcoin failing to hold 65,000 for a fourth consecutive day — ' +
      'so the asset was range-bound BELOW the threshold when the question was written. Distinct ' +
      'from the existing 70,000-at-2026-10-01 market: different threshold, and a close three ' +
      'months later.',
  },
  {
    question:
      'Will the official closing level of the S&P 500 index on the last trading day of 2026 be at ' +
      'or above 8,000.00?',
    cover: 'a rising staircase of stacked rectangular bars beneath a single thin ruled line',
    resolutionCriteria:
      'YES if S&P Dow Jones Indices publishes an official closing level for the S&P 500 (SPX) for ' +
      'the last regular NYSE trading session of calendar year 2026 that is greater than or equal ' +
      'to 8000.00. NO if that published close is below 8000.00. The figure is the index owner\'s ' +
      'own official close, not an intraday high, not a futures print and not a level quoted by a ' +
      'data vendor. If S&P Dow Jones Indices has not published it within five business days of ' +
      'that session, the closing level printed for the same session in the Wall Street Journal ' +
      'market data pages settles it; if neither is available the market resolves NO.',
    category: 'market_prices',
    resolutionSourceKind: 'price_index',
    resolutionSourceRef:
      'https://www.spglobal.com/spdji/en/indices/equity/sp-500/ — the official S&P 500 (SPX) ' +
      'closing level for the last regular NYSE trading session of 2026',
    closeTime: '2026-12-31T20:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'The S&P 500 stood at 7,759.57 on 2026-08-11, with an all-time high of 7,793.68 set earlier ' +
      'that month and a 20.38% year-over-year gain, read from tradingeconomics.com/united-states/' +
      'stock-market; SPY on NYSE Arca was 773.70 at 10:15 EDT the same day (stockanalysis.com/etf/' +
      'spy). The threshold is 3.1% above spot and about 2.6% above the record, which is the most ' +
      'defensible place to put it — not already true, and not a fantasy either. Both authoring ' +
      'readings are from aggregators because spglobal.com and FRED both refused an automated ' +
      'fetch; SETTLEMENT is the index owner\'s own number, so a second-hand reading at authoring ' +
      'time does not reach it. Close is 20:00Z, an hour before the 21:00Z bell, so the level ' +
      'cannot be known while the market is open.',
  },
  {
    question:
      'Will the Federal Open Market Committee\'s statement for the meeting concluding on 9 ' +
      'December 2026 specify a target range for the federal funds rate whose UPPER limit is 4.00 ' +
      'percent or higher?',
    cover: 'a columned neoclassical façade behind a level two-pan balance scale',
    resolutionCriteria:
      'YES if the FOMC statement published on federalreserve.gov at the conclusion of the meeting ' +
      'ending 9 December 2026 states a target range for the federal funds rate whose upper limit ' +
      'is 4.00 percent or more — "3-3/4 to 4 percent" is YES, and so is anything above it. NO if ' +
      'the stated upper limit is below 4.00 percent, which includes the range being left unchanged ' +
      'at 3-1/2 to 3-3/4 percent and includes any cut. The statement itself is the document, not a ' +
      'press conference, not the minutes and not the Summary of Economic Projections. If the ' +
      'meeting is rescheduled, the statement from the rescheduled meeting settles it provided it ' +
      'is issued before 2027-01-01; if no statement is issued by then the market resolves NO.',
    category: 'market_prices',
    resolutionSourceKind: 'regulator_publication',
    resolutionSourceRef:
      'https://www.federalreserve.gov/newsevents/pressreleases/monetary20261209a.htm',
    closeTime: '2026-12-09T17:59:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'The target range was 3-1/2 to 3-3/4 percent, maintained at the meeting of 28-29 July 2026 — ' +
      'read on 2026-08-11 from federalreserve.gov/newsevents/pressreleases/monetary20260729a.htm, ' +
      'which states the Committee "decided to maintain the target range for the federal funds rate ' +
      'at 3-1/2 to 3-3/4 percent". The vote was 9-3, with THREE dissenters favouring a quarter-' +
      'point INCREASE, which is unusual and is what makes the hawkish side of this question live ' +
      'rather than theoretical. The last actual change was a 25bp cut on 2025-12-11 ' +
      '(federalreserve.gov/monetarypolicy/openmarket.htm). The 8-9 December 2026 meeting is on the ' +
      'Board\'s own 2026 calendar (federalreserve.gov/monetarypolicy/fomccalendars.htm), and the ' +
      'statement URL follows the fixed `monetary<YYYYMMDD>a.htm` pattern, which is what lets the ' +
      'source be NAMED at open rather than described. Close is 17:59Z, one minute before the ' +
      '18:00Z (1pm ET) release. Deliberately NOT the September meeting, which the estate already ' +
      'runs a market on, and deliberately about the LEVEL rather than the direction.',
  },

  /* ─────────────────────────────── protocol_network ──────────────────────────
   * Source kinds available: chain_rpc, block_explorer, protocol_publication.
   */
  {
    question:
      'Will the Bitcoin mainnet block height be at or above 982,500 at 2027-01-01T00:00:00Z?',
    cover: 'a chain of solid rectangular blocks linked end to end, receding to one side',
    resolutionCriteria:
      'YES if the tip height of the Bitcoin mainnet chain, read once at or after ' +
      '2027-01-01T00:00:00Z, is greater than or equal to 982500. NO if it is lower. The chain is ' +
      'the one with the most cumulative proof of work as reported by the source; a fork of Bitcoin ' +
      'under any other name is not this chain, and no testnet counts. Height is a property of the ' +
      'chain rather than of the endpoint, so if the source is unreachable the same height as ' +
      'published by blockstream.info/api/blocks/tip/height, or by a `getblockcount` against any ' +
      'Bitcoin Core node the operator runs, settles it — the first successful reading within six ' +
      'hours. If none succeeds the market resolves NO.',
    category: 'protocol_network',
    resolutionSourceKind: 'chain_rpc',
    resolutionSourceRef: 'https://mempool.space/api/blocks/tip/height',
    closeTime: '2027-01-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      'Tip height was 962,013 at 2026-08-11T14:09Z, read from the endpoint named above; ' +
      'coindesk.com/price/bitcoin showed 962,012 the same day. The threshold needs 20,487 blocks ' +
      'in the 142.4 days to close — 143.9 blocks a day, a 10.01-minute mean interval, which is the ' +
      'protocol\'s nominal rate and therefore very close to a coin flip. It is not a formality in ' +
      'either direction: mempool.space/api/v1/difficulty-adjustment on the same day gave the ' +
      'running epoch a `timeAvg` of 631,973 ms (10.53 min/block) at 18.90% progress with a -3.02% ' +
      'retarget coming, so the near-term drift is toward NO while any renewed hashrate growth over ' +
      'the autumn pushes toward YES. Distinct from the existing 969,200-at-2026-09-30 market: a ' +
      'different height, three months later.',
  },
  {
    question:
      'Will the Ethereum mainnet block height be at or above 26,750,000 at 2027-01-01T00:00:00Z?',
    cover: 'a stack of thin translucent plates rising in even increments',
    resolutionCriteria:
      'YES if the best block height of Ethereum mainnet, read once at or after ' +
      '2027-01-01T00:00:00Z, is greater than or equal to 26750000. NO if it is lower. The ' +
      'canonical chain is the one the source recognises as Ethereum mainnet; no testnet and no ' +
      'layer-2 counts. If the source is unreachable the height returned by an `eth_blockNumber` ' +
      'JSON-RPC call against any Ethereum execution client the operator runs settles it — the ' +
      'first successful reading within six hours — and if none succeeds the market resolves NO.',
    category: 'protocol_network',
    resolutionSourceKind: 'chain_rpc',
    resolutionSourceRef: 'https://api.blockchair.com/ethereum/stats — field `best_block_height`',
    closeTime: '2027-01-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_DAY,
    feeBps: FEE_BPS,
    observed:
      '`best_block_height` was 25,732,339 at about 2026-08-11T14:15Z, read from the endpoint named ' +
      'above (the same response gave `market_price_usd` 1886.79, which agrees with the Coinbase ' +
      'ETH-USD ticker that day to within 0.5%). Ethereum\'s slot time is 12 seconds nominal, so a ' +
      'chain that missed no slot would gain 7,200 blocks a day; the threshold needs 7,146 a day, ' +
      'an effective 12.09-second interval, which tolerates about a 0.75% missed-slot rate. That is ' +
      'INSIDE the band the network has historically occupied rather than at its edge, which is ' +
      'what makes the question uncertain — and it is settled by one integer from one endpoint, ' +
      'which is what makes it unarguable.',
  },

  /* ───────────────────────── scheduled_public_events ─────────────────────────
   * Source kinds available: official_announcement, primary_source_publication.
   */
  {
    question:
      'Will Grand Theft Auto VI be on sale and playable on both PlayStation 5 and Xbox Series X/S ' +
      'on or before 2026-11-19T23:59:59Z?',
    cover: 'a handheld game controller resting on a folded paper road map',
    resolutionCriteria:
      'YES if, at or before 2026-11-19T23:59:59Z, the game can be bought and played on BOTH the ' +
      'PlayStation Store and the Xbox Store in at least one territory — evidenced by a Rockstar ' +
      'Games Newswire post announcing the launch, or by the two storefront listings themselves. NO ' +
      'if that is not true at that instant, which includes an announced delay, a launch on only ' +
      'one of the two platforms, and a paid-early-access or preview release that is not the full ' +
      'retail launch. Physical copies reaching shops does not settle it; being playable does. If ' +
      'the Newswire cannot be read the two storefront listings govern, and if those cannot be read ' +
      'either the market resolves NO.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'official_announcement',
    resolutionSourceRef:
      'https://www.rockstargames.com/newswire — with the PlayStation Store and Xbox Store product ' +
      'pages for Grand Theft Auto VI as the fallback evidence named in the criteria',
    closeTime: '2026-11-20T00:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'On 2026-08-11 the announced date was 19 November 2026 for PS5 and Xbox Series X/S, with ' +
      'physical copies (download codes rather than discs) in shops from 12 November for ' +
      'pre-loading. The date has already moved twice: an original 2025 window, then 26 May 2026 ' +
      '(announced May 2025), then 19 November 2026 (announced November 2025, attributed to further ' +
      'polish) — which is what makes a third slip a real possibility rather than a rhetorical one. ' +
      'Milestones already passed: cover art on 18 June 2026, pre-orders opened 25 June 2026 at ' +
      '79.99 USD, and an extended look scheduled to premiere on Netflix on 27 August 2026. Read ' +
      'from en.wikipedia.org/wiki/Grand_Theft_Auto_VI, because rockstargames.com refuses automated ' +
      'fetches — the resolution source is still Rockstar\'s own Newswire, and an operator should ' +
      're-read it by hand before approving.',
  },
  {
    question:
      'Will SpaceX fly the next integrated flight test of Starship on or before ' +
      '2026-09-30T23:59:59Z?',
    cover: 'a tall polished cylinder standing between two converging mechanical arms',
    resolutionCriteria:
      'YES if a Super Heavy and Starship stack lifts off from a SpaceX launch site on the next ' +
      'integrated flight test after the flight of 24 July 2026 — the one designated Flight 14, or ' +
      'whatever designation SpaceX gives that flight — at any time on or before ' +
      '2026-09-30T23:59:59Z, as recorded on spacex.com/launches. LIFTOFF settles it YES: the ' +
      'flight need not reach orbit, catch either stage, or be judged a success. NO if no such ' +
      'liftoff has occurred by that instant, for any reason including scrubs, a static-fire-only ' +
      'campaign, a vehicle change and a regulatory grounding. If spacex.com cannot be read, the ' +
      'FAA\'s commercial space launch record settles it; if that cannot be read either the market ' +
      'resolves NO.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'official_announcement',
    resolutionSourceRef: 'https://www.spacex.com/launches/',
    closeTime: '2026-10-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'On 2026-08-11 the next flight was listed NET late August 2026 — Block 3, Booster 21 and ' +
      'Ship 41 from Starbase OLP-2 — with the first orbital insertion and the first catch of the ' +
      'second stage as objectives (en.wikipedia.org/wiki/List_of_Starship_launches). The previous ' +
      'flight went on 2026-07-24 at 22:51Z carrying 20 Starlink V3 satellites: the launch ' +
      'succeeded, but the booster lit only 10 of 13 planned landing engines and struck the water ' +
      'hard, and that anomaly is unresolved in public. Programme totals that day: 13 launches, 8 ' +
      'successes, 5 failures, with Block 3 flown twice. Spaceflight Now\'s launch schedule, read ' +
      'the same day, listed NO Starship flight at all, which is itself a statement about how firm ' +
      '"late August" was. A five-week cushion against a cadence that has run nearer one flight per ' +
      'quarter than one per month is what makes this uncertain. Resolving on LIFTOFF rather than ' +
      'on mission success is deliberate: the objectives are ambitious enough that "did it work" ' +
      'would be the arguable question.',
  },
  {
    question:
      'Will the Nancy Grace Roman Space Telescope lift off on or before 2026-09-30T23:59:59Z?',
    cover: 'a segmented dish reflector on a boom against a field of small scattered points',
    resolutionCriteria:
      'YES if the launch vehicle carrying the Nancy Grace Roman Space Telescope lifts off on or ' +
      'before 2026-09-30T23:59:59Z, confirmed by a NASA blog post or press release. Liftoff ' +
      'settles it YES whether or not the observatory is successfully separated, deployed or later ' +
      'commissioned. NO if no liftoff has occurred by that instant, for any reason including ' +
      'scrubs, a vehicle or payload problem, a range conflict, a change of launch vehicle that ' +
      'delays the flight past the date, and a lapse in government funding. If NASA\'s pages cannot ' +
      'be read the market resolves NO.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'official_announcement',
    resolutionSourceRef:
      'https://science.nasa.gov/mission/roman-space-telescope/ and https://blogs.nasa.gov/roman/',
    closeTime: '2026-10-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'NASA\'s own mission page, read 2026-08-11 and last updated 2026-07-27, stated Roman is "set ' +
      'to launch August 30, 2026 at 07:26 am EDT" on a Falcon Heavy from Kennedy Space Center ' +
      'LC-39A, with status posts recording that integrated operations for launch had begun and ' +
      'that the observatory had been fuelled. Spaceflight Now\'s launch schedule independently ' +
      'gave NET 30 August, Falcon Heavy, LC-39A, 7:26 a.m. EDT the same day. The close is one ' +
      'month past the target rather than two, which is what keeps the question live: a flagship ' +
      'observatory absorbs a one-to-three-week slip routinely, and this deadline does not.',
  },
  {
    question:
      'Will Sierra Space\'s Dream Chaser spaceplane lift off on its first spaceflight on or before ' +
      '2027-03-31T23:59:59Z?',
    cover: 'a lifting-body glider with upswept wingtips resting on a launch adapter',
    resolutionCriteria:
      'YES if a Dream Chaser vehicle lifts off on an orbital launch on or before ' +
      '2027-03-31T23:59:59Z, confirmed by a Sierra Space or NASA announcement — on any launch ' +
      'vehicle, and whether or not the mission subsequently succeeds, berths with the ISS or ' +
      'returns. NO if no such liftoff has occurred by that instant, which includes a further slip, ' +
      'a cancellation and the vehicle being reassigned to a later mission. If neither named source ' +
      'can be read the market resolves NO.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'official_announcement',
    resolutionSourceRef:
      'https://www.sierraspace.com/newsroom/ and https://blogs.nasa.gov/spacestation/',
    closeTime: '2027-04-01T00:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'Listed NET Q4 2026 on a Vulcan Centaur in the VC4L configuration from Cape Canaveral ' +
      'SLC-41, read 2026-08-11 from spaceflightnow.com/launch-schedule/, which annotates the entry ' +
      '"Repeatedly postponed since 2022" and "Delayed from 2025" and shows it as the only Vulcan ' +
      'flight on the schedule. That history is the whole question: a vehicle that has slipped every ' +
      'year since 2022, with a target one quarter before this close. The authoring reading is from ' +
      'a trade publication because sierraspace.com could not be reached; settlement is Sierra ' +
      'Space\'s or NASA\'s own announcement, and an operator should re-read the current NET before ' +
      'approving, since a slip announced between now and open changes the fair price materially.',
  },
  {
    question:
      'Will the Milwaukee Brewers be one of the two clubs that play in the 2026 Major League ' +
      'Baseball World Series?',
    cover: 'a stitched leather ball beside a tapered wooden bat on bare ground',
    resolutionCriteria:
      'YES if the Milwaukee Brewers are one of the two clubs recorded as participants in the 2026 ' +
      'World Series on MLB.com\'s official postseason bracket, once both League Championship ' +
      'Series have concluded. NO if they are not, which includes missing the postseason and being ' +
      'eliminated in any earlier round. If the 2026 World Series is not played at all, the market ' +
      'resolves void rather than NO, because the question presupposes the fixture. If MLB.com ' +
      'cannot be read the market resolves NO.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'primary_source_publication',
    resolutionSourceRef: 'https://www.mlb.com/postseason',
    closeTime: '2026-09-29T00:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'Milwaukee led all of baseball at 74-45 (.622) with the best run differential in the sport at ' +
      '+140, and had gone 6-4 over their previous ten — standings dated 2026-08-11 from ' +
      'mlb.com/standings. Next best: Atlanta 71-48, the Los Angeles Dodgers 71-48 (2-8 over their ' +
      'last ten), Tampa Bay 72-46 leading the American League. The schedule is confirmed on ' +
      'en.wikipedia.org/wiki/2026_Major_League_Baseball_season, read the same day: regular season ' +
      'ends 27 September, postseason begins 29 September, World Series begins 23 October. The best ' +
      'record in the sport with seven weeks to play converts to a pennant only about a quarter to ' +
      'a third of the time under a six-team-per-league bracket, which is why this is a question ' +
      'rather than an observation. The subject is a club, not a person. Close is 29 September, ' +
      'before the first pitch of the postseason — NOT the eve of the World Series, which would ' +
      'leave the market open after the pennants were decided.',
  },
  {
    question:
      'Will the National Football Conference champion win Super Bowl LXI, scheduled for 14 ' +
      'February 2027 at SoFi Stadium?',
    cover: 'an oblong pointed ball above two opposed directional chevrons',
    resolutionCriteria:
      'YES if the club representing the National Football Conference is recorded as the winner of ' +
      'Super Bowl LXI on NFL.com. NO if the American Football Conference representative is ' +
      'recorded as the winner. A Super Bowl cannot end level, so these two outcomes are ' +
      'exhaustive. If the game is postponed, the result of the rescheduled game settles it ' +
      'provided it is played before 2027-04-30; if it is not played by then, or if NFL.com cannot ' +
      'be read at resolution, the market resolves NO.',
    category: 'scheduled_public_events',
    resolutionSourceKind: 'primary_source_publication',
    resolutionSourceRef: 'https://www.nfl.com/super-bowl/',
    closeTime: '2027-02-14T20:00:00.000Z',
    disputeWindowSeconds: ONE_WEEK,
    feeBps: FEE_BPS,
    observed:
      'Super Bowl LXI is confirmed for 14 February 2027 at SoFi Stadium, Inglewood, California, on ' +
      'ABC and ESPN — the first on Valentine\'s Day and the latest calendar date the league has ' +
      'ever held the game; venue selected 2023-12-13, logo revealed 2026-02-08 ' +
      '(en.wikipedia.org/wiki/Super_Bowl_LXI, read 2026-08-11). NO TEAMS ARE DETERMINED: the 2026 ' +
      'regular season had not begun on the authoring date. It opens 2026-09-09 with New England at ' +
      'defending champion Seattle — a Super Bowl LX rematch — runs to 2027-01-10, and the ' +
      'conference championships are 2027-01-31 (en.wikipedia.org/wiki/2026_NFL_season). ' +
      'Structurally a coin flip settled by one line on the league\'s own site, with no individual ' +
      'named anywhere in the question. Close is 20:00Z on the day, well before the expected 23:30Z ' +
      'kick-off.',
  },
]

/**
 * What the seeder reads: both batches, in the order they were written.
 *
 * ORDER MATTERS ONLY ONCE, and it is not on the page — the browse surface sorts
 * for itself. It matters in `seed/foresight.mjs`, which walks this array,
 * creates whatever is missing, and then drives every market it touched through
 * approve → deploy → fund → open in PHASES. Keeping the nine first means a
 * re-run finds them already `open` and does nothing to them, which is the
 * property the seeder's idempotency claim rests on.
 *
 * @type {readonly SeedQuestion[]}
 */
export const FORESIGHT_QUESTIONS = [...OPENING_NINE, ...QUESTIONS_2026H2]

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
 *     agree" (`foresight/src/server.ts`) — and the oracle path needs the market to be
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
 * (`foresight-market-journey.mjs` — `hearth` is 7411, `hearth-testnet` is 7412 per
 * `hearth/node/src/params.js`). Left pinned, this would have stopped matching its own
 * artefacts on the mainnet estate and quietly left every one of them standing as a real market —
 * a false NEGATIVE, which is the direction that does damage here.
 *
 * Still anchored and still specific: it is the exact sentence the journey builds and nothing else,
 * so the reverse mistake — voiding a market somebody meant — stays impossible.
 */
export function isTestArtefact(question) {
  return /^Will the EMBER (?:mainnet|testnet) \(chain 741[12]\) be above block height \d+ at /.test(question)
}
