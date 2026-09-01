// derive-grants: what `IDENTITY_SERVICE_TOKEN_GRANTS` must be, read off the services themselves.
//
//   usage: node scripts/derive-grants.mjs [--estate <dir>] [--json] [--check] [--write]
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────────────────────────
//
// `IDENTITY_SERVICE_TOKEN_GRANTS` decides what every service in the estate may ask identity to
// mint. Until now it was fourteen lines of hand-maintained JSON in a compose file, and four
// separate agents hit a missing grant in one week: `nda` could not post a cross-title achievement
// because it held `worlds:read,worlds:write` and the unlock route demands `worlds:title`;
// `emberkin` and `aetherholm` had no entry at all; `beacon` had none, so its own env refused to
// start. A hand-maintained list of what other repositories need is the same class of artefact as
// the gateway route map that "had never once loaded" and the MAP.md files that were stale — it is
// a copy of a fact that lives somewhere else, and copies rot silently.
//
// The fact lives in the SERVICES. Each one already declares, in its own source, the scopes its
// deploy must mint for it — `community/src/index.ts` says so in as many words: "The scopes it
// needs are named in `LEDGER_SCOPES`, `POLICY_SCOPES` and `INDEXER_SCOPES` so the deploy can mint
// exactly those." Twenty repositories follow that convention and NOTHING CONSUMED IT. This is the
// consumer.
//
// ── THE DERIVATION, AND WHY EACH STEP IS THE SHAPE IT IS ──────────────────────────────────────
//
// A module that PRESENTS a credential is one that constructs an `HttpClient` with a `token`
// option. That is the discriminator, and it is not a filename heuristic:
//
//   * It excludes every `outbox.ts` in the estate — twenty-two of them — automatically. The outbox
//     relay authenticates with `cf-signature` over the body and carries no bearer at all, so it
//     needs no scopes. A filename rule would have had to special-case them; this one does not.
//   * It excludes a service's INBOUND vocabulary. `admin-api/src/scopes.ts` exports `ALL_SCOPES`
//     holding `admin:read` — the scope admin-api ENFORCES on its callers, not one it presents.
//     That file constructs no client, so it is never read as a grant. Getting this backwards would
//     have granted every service the authority to call ITSELF, which is meaningless, and would
//     have hidden the real grant it needs behind a plausible-looking entry.
//
// Both directions are then checked, because a derivation that can only fail one way fails silently
// the other way:
//
//   1. Every derived scope must be in `@cloudsforge/contracts-auth`. identity validates this at
//      import and refuses to boot on a bad value, so an underived scope is a dead container. This
//      catches it here, where the message can name the file.
//   2. A service may never be granted a scope IT ITSELF enforces. The registry records the
//      enforcing service per scope, so this is checkable rather than a matter of opinion, and it
//      is what makes step 1's soundness meaningful.
//
// ── "NEEDS NOTHING" IS A DECLARATION, NOT A SILENCE ───────────────────────────────────────────
//
// `export const FOO_SCOPES = NO_SCOPES_REQUIRED` — or the bare `Object.freeze([])` — is read as
// the author saying their client presents a credential no scope makes stronger: a bearer forwarded
// from the caller, an external API key, a route nobody gates. It is CLEANLY DECLARED: no gaps
// entry, no grant, and a gaps entry for such a module now fails as stale like any other the owning
// repository has made good on. `NO_SCOPES_REQUIRED` is `@cloudsforge/contracts-auth`'s name for the
// empty list and is the spelling to prefer — the two are identical at runtime, and only one of them
// is legible as a decision to the next person reading the module.
//
// This was not always true, and the cost was measurable. Before it, an empty freeze and no
// constant at all were the same input — zero scopes — so the honest answer failed the build and
// the expressible one was a scope the module did not need. `wallet/src/pricingclient.ts` says so
// in its own header: `pricing:read` is kept for `GET /rates`, which pricing does not gate, only
// because "there is no way to say 'this client needs nothing' from the source side". A tool that
// makes the truthful answer inexpressible does not get silence — it gets a grant wider than the
// call sites need, which is the exact failure this derivation exists to end.
//
// ── THE MODULES THIS CANNOT READ, AND WHY THAT IS NOT A CLIMBDOWN ─────────────────────────────
//
// Some modules in the estate present a credential and declare no scope constant at all. They are
// named, with reasons, in `compose/estate/grant-gaps.json`. That file is NOT the old hand-list in
// another costume, and the difference is enforced here:
//
//   * It names a FILE, not a service, so an entry cannot quietly widen to cover a service's whole
//     grant the way the compose map did.
//   * An entry whose module has since grown a declaration is STALE and FAILS — so the file shrinks
//     as the repositories that own those modules fix them, and it cannot be padded.
//   * A reason under 40 characters is not a reason, following the `scope-exemptions.json` rule
//     `service-ci.yml` already applies to the other direction of this same registry.
//
// Fourteen hand-maintained service entries became ten hand-maintained file entries and are now
// seven, each of which fails loudly when it stops being true — `market/src/policyclient.ts`,
// `wallet/src/custodyclient.ts` and `wallet/src/settlement.ts` were deleted the day their
// repositories declared for themselves, and the ratchet is what said so. Three of the seven exist
// only because their modules have not yet exported an empty constant; that is now expressible, so
// they can go too. That is the honest limit of the derivation, and it is written down rather than
// papered over.
import { readFileSync, readdirSync, existsSync, statSync, writeFileSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = fileURLToPath(new URL('.', import.meta.url))
const argv = process.argv.slice(2)
const flag = (name) => argv.includes(name)
const opt = (name, fallback) => {
  const i = argv.indexOf(name)
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback
}

const ESTATE = opt('--estate', join(HERE, '..', '..'))
const COMPOSE = join(HERE, '..', 'compose', 'docker-compose.estate.yml')
const GAPS = join(HERE, '..', 'compose', 'estate', 'grant-gaps.json')
const AUTH_INDEX = join(ESTATE, 'contracts/packages/auth/src/index.ts')
const WORLDS_INDEX = join(ESTATE, 'contracts/packages/worlds/src/index.ts')

// Floors, for the reason `estate-scopes.mjs` gives about set differences: every verdict below is
// of the form "this service needs exactly these scopes", and a derivation that silently read no
// files would answer that with an empty set for every service — which looks like a clean estate
// and is actually a total loss of authority information.
const MIN_REGISTRY = 40
const MIN_SERVICES = 12

const errors = []
const fail = (message) => errors.push(message)

if (!existsSync(AUTH_INDEX)) {
  console.error(`derive-grants: no scope registry at ${AUTH_INDEX} — this checkout is not the estate`)
  process.exit(2)
}

// ---------------------------------------------------------------- comments out, strings kept
// Six guards in this estate have fired on their own prose, and the traps section of the runbook
// records a Traefik outage caused by a template action inside a YAML comment. Strings survive
// because the scope literals ARE strings.
function stripComments(text) {
  let out = ''
  let i = 0
  const n = text.length
  while (i < n) {
    const c = text[i]
    const d = text[i + 1]
    if (c === '/' && d === '/') {
      while (i < n && text[i] !== '\n') i++
      continue
    }
    if (c === '/' && d === '*') {
      i += 2
      while (i < n && !(text[i] === '*' && text[i + 1] === '/')) {
        if (text[i] === '\n') out += '\n'
        i++
      }
      i += 2
      continue
    }
    if (c === "'" || c === '"' || c === '`') {
      const quote = c
      out += c
      i++
      while (i < n && text[i] !== quote) {
        if (text[i] === '\\') {
          out += text[i] + (text[i + 1] ?? '')
          i += 2
          continue
        }
        out += text[i]
        i++
      }
      out += text[i] ?? ''
      i++
      continue
    }
    out += c
    i++
  }
  return out
}

const lineOf = (text, offset) => text.slice(0, offset).split('\n').length

function collect(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    let st
    try {
      st = statSync(p)
    } catch {
      continue
    }
    if (st.isDirectory()) {
      if (/^(node_modules|dist|build|coverage)$/.test(name) || /testsupport/.test(name)) continue
      collect(p, out)
    } else if (
      /\.(ts|mts)$/.test(name) &&
      !/\.(test|spec)\.(ts|mts)$/.test(name) &&
      !/\.d\.ts$/.test(name) &&
      !/testsupport/.test(name)
    ) {
      out.push(p)
    }
  }
  return out
}

// ---------------------------------------------------------------- the registry: scope -> enforcer
const registryText = readFileSync(AUTH_INDEX, 'utf8')
const rFrom = registryText.indexOf('export const SCOPES')
const rTo = registryText.indexOf('as const', rFrom)
if (rFrom < 0 || rTo < 0) {
  console.error(`derive-grants: cannot find the SCOPES registry in ${AUTH_INDEX}`)
  process.exit(2)
}
const registryBlock = registryText.slice(rFrom, rTo)
/** scope -> the service that ENFORCES it */
const ENFORCER = new Map()
/**
 * The scopes the registry has marked dead, read off the same entries.
 *
 * A `deprecated` reason means no gate demands the scope and none can — `admin:audit:write` and
 * `notify:ingest` died the day their routes became MAC-only. Granting one is not fatal the way an
 * unregistered scope is (identity's `isScope` reads the wide set, so the container still boots)
 * and that is exactly why it is worth catching here: it fails NOWHERE ELSE. It is a real capability
 * on a real token that nothing on the receiving side will ever consult, which is the shape AD-05
 * exists to prevent, and it would sit in the compose file indefinitely looking correct.
 *
 * `contracts-auth` derives `DeprecatedScope` from this same field at the type level, so a
 * consumer annotating an outbound constant `readonly LiveScope[]` gets the error in its own file.
 * This is the deploy-side half of the same fact, for the modules a type cannot reach: the entries
 * in `grant-gaps.json`, whose scopes micro-deploy writes by hand and no compiler ever sees.
 */
const DEPRECATED = new Set()
for (const m of registryBlock.matchAll(/'([a-z][a-z0-9:-]+)':\s*Object\.freeze\(\{([\s\S]*?)\}\)/g)) {
  const service = m[2].match(/service:\s*'([^']+)'/)
  ENFORCER.set(m[1], service ? service[1] : null)
  if (/\bdeprecated:\s*\n?\s*'/.test(m[2])) DEPRECATED.add(m[1])
}
if (ENFORCER.size < MIN_REGISTRY) {
  console.error(
    `derive-grants: parsed ${ENFORCER.size} scopes out of the registry, expected at least ${MIN_REGISTRY} — the parser is broken, not the estate`,
  )
  process.exit(2)
}
// A floor for the same reason as the others: `DEPRECATED` empty is indistinguishable from a
// parser that stopped reading, and an empty set makes the check below silently unconditional.
// The registry has carried at least two dead scopes since micro-contracts closed the two ingest
// gates; if that ever drops to zero the check should be deleted deliberately, not decay.
if (DEPRECATED.size === 0) {
  console.error(
    `derive-grants: parsed no deprecated scopes out of the registry — either the parser broke or the registry lost a field it has had since the ingest scopes died`,
  )
  process.exit(2)
}

// ---------------------------------------------------------------- contracts-worlds' SCOPE_FOR
// `emberkin` and `nda` spell their worlds scope as `SCOPE_FOR.unlockAchievement` rather than a
// literal, deliberately: a literal is exactly what let `worlds:write` sit wrong in both of those
// files for months. Resolving it here is what lets them keep doing the right thing.
const SCOPE_FOR = new Map()
if (existsSync(WORLDS_INDEX)) {
  const wt = stripComments(readFileSync(WORLDS_INDEX, 'utf8'))
  const wFrom = wt.indexOf('export const SCOPE_FOR')
  if (wFrom >= 0) {
    const wBlock = wt.slice(wFrom, wt.indexOf('})', wFrom))
    for (const m of wBlock.matchAll(/(\w+):\s*'([a-z][a-z0-9:-]+)'/g)) SCOPE_FOR.set(m[1], m[2])
  }
}

// ---------------------------------------------------------------- the derivation
const repos = readdirSync(ESTATE)
  .filter((d) => {
    try {
      return statSync(join(ESTATE, d)).isDirectory() && existsSync(join(ESTATE, d, 'src'))
    } catch {
      return false
    }
  })
  .sort()

/**
 * A module that presents a credential: it builds an `HttpClient` AND names a bearer somewhere in
 * the file.
 *
 * The bearer test is deliberately across the WHOLE FILE rather than inside the constructor call.
 * The first version of this looked for a `token` option within 800 characters of `new HttpClient({`
 * and it silently missed `admin-api/src/upstreams.ts`, which constructs the client at :95 and
 * attaches `Bearer ${token}` from a header helper at :111 — so admin-api derived an EMPTY grant and
 * looked like a service with no upstreams, which it very much is not. A false negative here is the
 * worst failure this file has: it does not produce a wrong grant, it produces NO grant, and a
 * service with no entry cannot be minted a token at all.
 *
 * Every `outbox.ts` in the estate still drops out, because the relay signs the body with
 * `cf-signature` and names no bearer anywhere.
 */
const BUILDS_CLIENT = /new HttpClient\s*\(/
const NAMES_A_BEARER = /\btoken\b|\bcredential\b|authorization/i
const presentsCredential = (text) => BUILDS_CLIENT.test(text) && NAMES_A_BEARER.test(text)

/** service -> Map(scope -> provenance) */
const grants = new Map()
/**
 * Files micro-deploy cannot take at face value, and why. Three kinds, all requiring an entry in
 * `grant-gaps.json`:
 *
 *   `undeclared`    — presents a credential and exports no scope constant at all.
 *   `unregistered`  — exports one naming a scope `@cloudsforge/contracts-auth` does not have, so
 *                     identity could never mint it and would refuse to boot on the attempt.
 *   `self-enforced` — exports one naming ONLY scopes this repository itself enforces, so after the
 *                     inbound-vocabulary drop below there is nothing left. That is an inbound
 *                     constant being presented as an outbound demand, and saying "undeclared" to
 *                     its author would send them to write the constant they have already written.
 *
 * The second kind is the reason this is a map and not a set. Reading such a declaration at face
 * value would put an unmintable scope into the compose file and kill the identity container — so
 * the wrong declaration has to be OVERRIDDEN here and REPORTED to the repository that owns it,
 * not silently dropped and not silently trusted.
 */
const needsEntry = new Map()
/** relative path -> the scopes it declared, for staleness checks against the gaps file */
const cleanlyDeclared = new Set()
/**
 * Modules that declared, in their own source, that they need NO scope — `export const FOO_SCOPES =
 * Object.freeze([])`. Reported, never granted.
 *
 * ── WHY THIS DISTINCTION EXISTS ──────────────────────────────────────────────────────────────
 *
 * Until this, an empty declaration and no declaration at all were the same input to this tool:
 * zero scopes parsed, so the module fell into `undeclared` and failed the estate build unless
 * micro-deploy carried a hand-written entry for it. There was no way to say "this client needs
 * nothing" FROM THE SOURCE — and the cost of that was not theoretical. `wallet/src/pricingclient.ts`
 * declares `pricing:read` for a route, `GET /rates`, that pricing does not gate at all, and its
 * header says in as many words that it is kept only because "there is no way to say 'this client
 * needs nothing' from the source side. Reported to micro-deploy; narrow this to `[]` once an empty
 * declaration is expressible." A tool that makes the honest answer inexpressible does not get
 * silence — it gets a grant wider than the call sites need, which is the precise failure the
 * whole derivation exists to end.
 *
 * So an empty freeze is now the SEVENTH thing this file can read, and it is a first-class verdict:
 * the module is cleanly declared, needs no gaps entry, and contributes no scope. It is distinct
 * from `undeclared` in both directions — an empty declaration satisfies the gaps ratchet, and a
 * gaps entry for a module that has since declared empty now FAILS as stale exactly like any other
 * entry the owning repository has made good on.
 *
 * The three modules whose gaps entries carry `"scopes": []` today —
 * `devplatform/src/membership.ts`, `mint/src/index.ts`, `foresight/src/proposer.ts` — can each
 * declare nothing and have their entry deleted. That is theirs to do, not micro-deploy's: this
 * side of it is now built and those repositories have been told.
 *
 * ── TWO SPELLINGS, ONE VERDICT ────────────────────────────────────────────────────────────────
 *
 * `Object.freeze([])` and `@cloudsforge/contracts-auth`'s `NO_SCOPES_REQUIRED` are both read, and
 * the second is the one to prefer. It is `Object.freeze([])` at runtime and adds nothing a
 * reviewer can see in a diff — but it is a NAME, and the name is what a reader of the consuming
 * module encounters. Its own header states the tension it exists for: micro-wallet's
 * `PRICING_SCOPES` names `pricing:read` for a route that is ungated, kept only because this tool
 * could not tell an empty declaration from a forgotten one. An over-declaration is not a
 * formality — it is a real scope on a real token, against AD-05.
 *
 * micro-contracts asked for exactly one branch here and said the order out loud: micro-deploy
 * first, then the consumers, because a consumer that adopts it before this tool reads it fails the
 * estate build. This is that branch, and it is deliberately NOT a new way to be silent — an
 * assignment is still required, so a module that declares nothing at all still fails.
 */
const declaredNothing = new Map()

/**
 * The two forms of "I need no scope", as the consumer may write them.
 *
 * `NO_SCOPES_REQUIRED` is matched by its NAME rather than by resolving the import, for the same
 * reason `SCOPE_FOR` is resolved and a bare literal is not: the name is unambiguous in this estate
 * and a resolver would be a second, weaker copy of the module system. A file that imports it under
 * an alias is not read as declaring nothing — it falls through to `undeclared` and fails loudly,
 * which is the safe direction.
 *
 * The constant's own declaration in contracts cannot match: `[A-Z0-9_]*SCOPES\b` needs a word
 * boundary after `SCOPES`, and `NO_SCOPES_REQUIRED` continues with `_`.
 */
const DECLARES_NONE = /export const ([A-Z0-9_]*SCOPES)\b[^=]*=\s*NO_SCOPES_REQUIRED\b/g

/**
 * Which checkouts are now MODULES of another checkout, derived from the layout.
 *
 * The service merge moved twenty services into `agora/src/<name>/` (and two levels deep in three
 * cases — `agora/src/activity/notify`) without deleting a repository. This derivation walked the
 * estate directory, so it read each of them TWICE and reported the module copies under paths
 * nothing recognises: five of the six failures on 2026-09-01 were entries in `grant-gaps.json`
 * keyed `billing/src/ledger.ts` no longer matching a file now read as `agora/src/billing/ledger.ts`.
 *
 * A GRANT IS PER SERVICE AND STAYS PER SERVICE. The compose block still names `billing`,
 * `community` and the rest, because identity mints per service identity and the merge changed the
 * process, not who is asking. So an absorbed service is read from the LIVE copy — the one the pod
 * runs — and reported under its ORIGINAL path, which is what every gap entry, every issue and every
 * message a person reads is keyed on.
 *
 * Two rounds, and the second is not an optimisation: `notify` was absorbed into `activity` and
 * `activity` into `agora`, so a single round finds `activity/src/notify` first and points notify at
 * a checkout that is itself skipped — leaving notify read from nowhere.
 */
function absorptionsOf() {
  const candidates = new Set(repos)
  const discover = (absorbers) => {
    const found = []
    for (const absorber of absorbers) {
      const descend = (rel, depth) => {
        if (depth > 3) return
        let entries
        try {
          entries = readdirSync(join(ESTATE, absorber, rel)).sort()
        } catch {
          return
        }
        for (const entry of entries) {
          if (/^(node_modules|dist|build|coverage|\.git)$/.test(entry)) continue
          const relModule = join(rel, entry)
          const dir = join(ESTATE, absorber, relModule)
          try {
            if (!statSync(dir).isDirectory()) continue
          } catch {
            continue
          }
          // `hub-api` is `agora/src/hub` and `admin-api` is `agora/src/admin`: the repository name
          // carries a suffix the module directory does not. Tried as well as the exact name, never
          // instead of it, and `looksLikeACopy` still has to agree — so this is a candidate rather
          // than a rule. Without it those two services' outbound scopes were attributed to `agora`
          // itself, which is a grant widening dressed up as a derivation.
          const names = [entry, `${entry}-api`]
          for (const service of names) {
            if (
              service !== absorber &&
              candidates.has(service) &&
              !found.some((e) => e.service === service) &&
              looksLikeACopy(join(ESTATE, service, 'src'), dir)
            ) {
              found.push({ service, into: absorber, dir })
              break
            }
          }
          descend(relModule, depth + 1)
        }
      }
      descend('src', 1)
    }
    return found
  }
  const anywhere = new Set(discover([...candidates].sort()).map((e) => e.service))
  return discover([...candidates].sort().filter((r) => !anywhere.has(r)))
}

/** A majority of the standalone repository's own top-level sources, by name, present in the module. */
function looksLikeACopy(standaloneSrc, moduleDir) {
  const namesIn = (dir) => {
    try {
      return new Set(readdirSync(dir).filter((n) => n.endsWith('.ts') && !n.endsWith('.test.ts')))
    } catch {
      return new Set()
    }
  }
  const standalone = namesIn(standaloneSrc)
  if (standalone.size < 3) return false
  const module = namesIn(moduleDir)
  let shared = 0
  for (const n of standalone) if (module.has(n)) shared += 1
  return shared * 2 > standalone.size
}

const ABSORBED = new Map(absorptionsOf().map((e) => [e.service, e]))
/** Every absorbed module's directory, so an absorbing scan stops at its modules' edges. */
const MODULE_DIRS = [...ABSORBED.values()].map((e) => e.dir)
if (ABSORBED.size > 0) {
  console.log(
    `derive-grants: ${ABSORBED.size} service(s) read from their absorber's module directory rather than their own checkout: ${[...ABSORBED.keys()].sort().join(' ')}`,
  )
}

for (const repo of repos) {
  // `service-template` is a template, not a deployment. Granting it anything would put a service
  // that does not exist into identity's allowlist.
  if (repo === 'service-template') continue
  const moved = ABSORBED.get(repo)
  const base = moved ? moved.dir : join(ESTATE, repo, 'src')
  // Strictly BELOW this scan's base — which is not the same as "this repo is an absorber". `notify`
  // sits inside the `activity` module, so activity is a module that is itself an absorber.
  const nested = MODULE_DIRS.filter((d) => d !== base && d.startsWith(base + '/'))
  const found = new Map()
  for (const path of collect(base)) {
    if (nested.some((d) => path.startsWith(d + '/'))) continue
    const text = stripComments(readFileSync(path, 'utf8'))
    // The ORIGINAL layout — `billing/src/ledger.ts`, not `agora/src/billing/ledger.ts`. Every gap
    // entry and every issue is keyed on it, and a module's move is a fact about the deployment.
    const rel = moved ? `${repo}/src/${relative(base, path)}` : relative(ESTATE, path)
    const presents = presentsCredential(text)

    /** scope -> provenance, as declared by THIS file */
    const declared = new Map()
    /**
     * Where this file's `*_SCOPES` constants are, whether or not they named anything.
     *
     * Kept separately from `declared` because the two questions are different and were previously
     * conflated: `declared.size === 0` answers "did any scope come out of this file", and this
     * answers "did its author state a demand at all". `Object.freeze([])` is a stated demand of
     * nothing; no constant is no statement. See `declaredNothing` above.
     */
    const constants = []

    // `export const <ANYTHING>_SCOPES = Object.freeze([...])`, and hub-api's object-of-arrays form.
    for (const m of text.matchAll(/export const ([A-Z0-9_]*SCOPES)\b[^=]*=\s*Object\.freeze\(([\s\S]{0,600}?)\)\s*(?:satisfies|as const|;|\n)/g)) {
      const body = m[2]
      constants.push(`${m[1]} at ${rel}:${lineOf(text, m.index)}`)
      const literals = [...body.matchAll(/'([a-z][a-z0-9:-]+)'/g)].map((x) => x[1])
      const viaScopeFor = [...body.matchAll(/SCOPE_FOR\.(\w+)/g)].map((x) => x[1])
      const scopes = [...literals]
      for (const key of viaScopeFor) {
        const resolved = SCOPE_FOR.get(key)
        if (!resolved) {
          fail(`${rel}:${lineOf(text, m.index)}: SCOPE_FOR.${key} resolves to no scope in contracts-worlds — fail, do not guess`)
          continue
        }
        scopes.push(resolved)
      }
      for (const scope of scopes) declared.set(scope, `${rel}:${lineOf(text, m.index)} (${m[1]})`)
    }

    // `export const <ANYTHING>_SCOPES = NO_SCOPES_REQUIRED` — the named form of the same verdict.
    // It contributes no scope and, exactly like `Object.freeze([])`, counts as a STATEMENT: the
    // file has said what it needs. See `DECLARES_NONE`.
    DECLARES_NONE.lastIndex = 0
    for (const m of text.matchAll(DECLARES_NONE)) {
      constants.push(`${m[1]} = NO_SCOPES_REQUIRED at ${rel}:${lineOf(text, m.index)}`)
    }

    // ── THE SECOND SEAM: a service that names its scopes at the exchange itself ────────────────
    //
    // `beacon` builds no `HttpClient`; it calls `POST /service-tokens/exchange` with raw fetch and
    // states its demand in the request body — `body: { scopes: ['ledger:read'] }`
    // (beacon/src/ecosystem.ts). That is the most direct declaration of demand in the estate:
    // not a constant a deploy is trusted to read across, but the exact bytes identity is asked for.
    // Reading it is why `beacon` needs no entry in the gaps file despite following none of the
    // client conventions.
    let exchanges = false
    if (text.includes('/service-tokens/exchange')) {
      for (const m of text.matchAll(/\bscopes:\s*\[([^\]]{0,300})\]/g)) {
        const scopes = [...m[1].matchAll(/'([a-z][a-z0-9:-]+)'/g)].map((x) => x[1])
        for (const scope of scopes) {
          declared.set(scope, `${rel}:${lineOf(text, m.index)} (exchanged for at the call site)`)
          exchanges = true
        }
      }
    }

    // A file that neither presents a credential nor exchanges for one contributes NOTHING, however
    // many scope constants it exports. That is what keeps `admin-api/src/scopes.ts` — the inbound
    // vocabulary admin-api enforces — out of admin-api's own grant. See the header.
    if (!presents && !exchanges) continue

    // ── THE SECOND DISCRIMINATOR, AND THE ONE THAT NEEDS NO HEURISTIC ─────────────────────────
    //
    // The registry records the service that ENFORCES each scope. A scope this repository enforces
    // is its own inbound vocabulary and can never be part of its grant: a service does not present
    // a credential to itself. So it is dropped here rather than being read as a demand.
    //
    // This is what makes the client-detection above merely a completeness check rather than the
    // thing correctness rests on. `admin-api/src/scopes.ts` exports `admin:read`, which admin-api
    // enforces; even if a future edit made that file construct a client, it still could not turn
    // into a self-grant.
    const namedSomething = declared.size > 0
    for (const scope of [...declared.keys()]) {
      if (ENFORCER.get(scope) === repo) declared.delete(scope)
    }

    if (declared.size === 0) {
      // ── "NEEDS NOTHING", SAID OUT LOUD ─────────────────────────────────────────────────────
      //
      // An exported constant that names no scope is the author telling us their client presents a
      // credential no scope makes stronger — a bearer forwarded from the caller, an external API
      // key, a public route. That is a verdict, not a hole, so it does not want a gaps entry and
      // it does not want an exemption: it wants to be believed. See `declaredNothing`.
      if (constants.length > 0 && !namedSomething) {
        declaredNothing.set(rel, constants.join(', '))
        cleanlyDeclared.add(rel)
        continue
      }
      // The constants named only scopes THIS repository enforces, so the inbound-vocabulary drop
      // above emptied them. Telling this author "you declared nothing" would be false and would
      // send them to write a constant that is already there; name the real fault instead.
      if (constants.length > 0) {
        needsEntry.set(rel, { repo, kind: 'self-enforced', constants })
        continue
      }
      needsEntry.set(rel, { repo, kind: 'undeclared' })
      continue
    }
    const unregistered = [...declared.keys()].filter((s) => !ENFORCER.has(s))
    if (unregistered.length > 0) {
      needsEntry.set(rel, { repo, kind: 'unregistered', unregistered })
      continue
    }
    cleanlyDeclared.add(rel)
    for (const [scope, where] of declared) found.set(scope, where)
  }
  if (found.size > 0) grants.set(repo, found)
}

// ---------------------------------------------------------------- the five that cannot be read
let gaps = {}
if (existsSync(GAPS)) {
  try {
    gaps = JSON.parse(readFileSync(GAPS, 'utf8'))
  } catch (error) {
    console.error(`derive-grants: ${GAPS} is not valid JSON — ${error.message}`)
    process.exit(2)
  }
}
// Any key beginning `//` is prose, not an entry. JSON has no comments and this file has to explain
// itself — including what it no longer says, which is the part a diff loses. No module path can
// begin with a slash, so this cannot swallow a real entry.
for (const key of Object.keys(gaps)) if (key.startsWith('//')) delete gaps[key]

const covered = new Set()
for (const [rel, entry] of Object.entries(gaps)) {
  if (!entry || typeof entry !== 'object' || !Array.isArray(entry.scopes) || typeof entry.reason !== 'string') {
    fail(`${GAPS}: '${rel}' must be { "service": …, "scopes": [...], "reason": "…" }`)
    continue
  }
  if (entry.reason.trim().length < 40) {
    fail(`${GAPS}: the entry for '${rel}' has no real reason — under 40 characters is a hole, not a decision`)
  }
  if (declaredNothing.has(rel)) {
    fail(
      `${GAPS}: '${rel}' now declares, in its own source, that it needs NO scope — ${declaredNothing.get(rel)}. ` +
        `That is the same verdict this entry carries, said by the repository that owns the module instead of by micro-deploy, so delete this entry.`,
    )
    continue
  }
  if (cleanlyDeclared.has(rel)) {
    fail(
      `${GAPS}: '${rel}' now declares its own scopes, and they all resolve — the repository that owns it has done the work, so delete this entry.`,
    )
    continue
  }
  if (!needsEntry.has(rel)) {
    fail(
      `${GAPS}: '${rel}' presents no credential and exchanges for no token (or no longer exists) — the entry is stale, delete it.`,
    )
    continue
  }
  if (!entry.service) {
    fail(`${GAPS}: '${rel}' names no service`)
    continue
  }
  covered.add(rel)
  if (!grants.has(entry.service)) grants.set(entry.service, new Map())
  for (const scope of entry.scopes) {
    grants.get(entry.service).set(scope, `${rel} (supplied by grant-gaps.json)`)
  }
}

// A module micro-deploy cannot read and nobody has written down. Silence here is exactly how `nda`
// went months without `worlds:title` and how `custody` never had an entry at all.
for (const [rel, info] of needsEntry) {
  if (covered.has(rel)) continue
  if (info.kind === 'unregistered') {
    fail(
      `${rel}: declares ${info.unregistered.map((s) => `'${s}'`).join(', ')}, which @cloudsforge/contracts-auth does not register. ` +
        `identity refuses to boot on an unknown scope, so this cannot be granted as written — it is a defect in ${info.repo}, not here. ` +
        `Report it, and add an entry to ${relative(join(HERE, '..'), GAPS)} supplying the scopes the module's call sites actually need until it is fixed.`,
    )
    continue
  }
  if (info.kind === 'self-enforced') {
    fail(
      `${rel}: its scope constant(s) — ${info.constants.join(', ')} — name only scopes ${info.repo} ITSELF enforces, ` +
        `so nothing outbound is declared. A service does not present a credential to itself: that is an inbound vocabulary, and the module's ` +
        `outbound demand is still unstated. Declare the scopes its call sites need, or NO_SCOPES_REQUIRED if they need none — it is a defect in ${info.repo}, not here.`,
    )
    continue
  }
  fail(
    `${rel}: presents a credential and declares no *_SCOPES constant, and is not in ${relative(join(HERE, '..'), GAPS)}. ` +
      `Either export the scopes it needs from that module (the convention twenty repositories already follow, e.g. community/src/ledgerclient.ts) — ` +
      `or NO_SCOPES_REQUIRED from @cloudsforge/contracts-auth if it needs none, which is read as a declaration and not as silence — ` +
      `or add an entry naming the service, the scopes and why they cannot be derived.`,
  )
}

// ---------------------------------------------------------------- both directions checked
for (const [service, found] of grants) {
  for (const [scope, where] of found) {
    if (!ENFORCER.has(scope)) {
      fail(
        `${service} is granted '${scope}' (${where}) but @cloudsforge/contracts-auth does not register it — identity refuses to boot on an unknown scope, so this would be a dead container.`,
      )
      continue
    }
    const enforcer = ENFORCER.get(scope)
    if (enforcer === service) {
      fail(
        `${service} is granted '${scope}' (${where}), which ${service} itself ENFORCES. A service does not present a credential to itself; this is an inbound vocabulary constant being read as an outbound demand.`,
      )
      continue
    }
    if (DEPRECATED.has(scope)) {
      fail(
        `${service} is granted '${scope}' (${where}), which the registry marks DEPRECATED — no gate demands it and none can. ` +
          `identity still mints it, so nothing fails at boot and nothing fails at the call; the token simply carries a capability its holder can never use, ` +
          `which is the least-privilege rule broken in the one direction that is silent. Drop it from the declaration, or from grant-gaps.json if micro-deploy wrote it.`,
      )
    }
  }
}

if (grants.size < MIN_SERVICES) {
  console.error(
    `derive-grants: derived grants for only ${grants.size} service(s), expected at least ${MIN_SERVICES} — this is a partial estate, and a partial derivation silently removes authority from every service it missed`,
  )
  process.exit(2)
}

// ---------------------------------------------------------------- output
const derived = {}
for (const service of [...grants.keys()].sort()) {
  const scopes = [...grants.get(service).keys()].sort()
  // A service that needs no scope gets NO ENTRY, rather than an empty one. Absence from this map is
  // how identity refuses to mint for a service at all, and that is the correct answer for
  // `devplatform` (forwards the developer's own bearer) — an empty array would instead say "this
  // service may hold a token that opens nothing", which is a different and less honest claim.
  if (scopes.length > 0) derived[service] = scopes
}

if (errors.length > 0) {
  console.error(`derive-grants: FAILED — ${errors.length} problem(s)`)
  for (const e of errors) console.error(`  ${e}`)
  process.exit(1)
}

// The exact YAML block compose carries: a folded scalar, one service per line, sorted, so a diff
// on this file is readable and a re-run produces byte-identical output.
function composeBlock(map) {
  const lines = Object.keys(map).map((s) => `"${s}":${JSON.stringify(map[s])}`)
  return `        {${lines.join(',\n         ')}}`
}

const BEGIN = '      IDENTITY_SERVICE_TOKEN_GRANTS: >-\n'

function currentBlock() {
  const text = readFileSync(COMPOSE, 'utf8')
  const start = text.indexOf(BEGIN)
  if (start < 0) return null
  const after = start + BEGIN.length
  const rest = text.slice(after).split('\n')
  const body = []
  for (const line of rest) {
    if (!/^\s{8,}\S/.test(line)) break
    body.push(line)
  }
  return { text, start, after, body: body.join('\n') }
}

if (flag('--write')) {
  const cur = currentBlock()
  if (!cur) {
    console.error(`derive-grants: cannot find IDENTITY_SERVICE_TOKEN_GRANTS in ${COMPOSE}`)
    process.exit(2)
  }
  const next = cur.text.slice(0, cur.after) + composeBlock(derived) + cur.text.slice(cur.after + cur.body.length)
  writeFileSync(COMPOSE, next)
  console.log(`derive-grants: wrote ${Object.keys(derived).length} service grant(s) into ${relative(process.cwd(), COMPOSE)}`)
  process.exit(0)
}

if (flag('--check')) {
  const cur = currentBlock()
  if (!cur) {
    console.error(`derive-grants: cannot find IDENTITY_SERVICE_TOKEN_GRANTS in ${COMPOSE}`)
    process.exit(2)
  }
  let onDisk
  try {
    onDisk = JSON.parse(cur.body.replace(/\s+/g, ' '))
  } catch (error) {
    console.error(`derive-grants: the compose block is not valid JSON — ${error.message}`)
    process.exit(1)
  }
  // Compared as SETS, per service. Ordering and whitespace are not the property under test; what
  // each service may mint is.
  const problems = []
  const services = new Set([...Object.keys(onDisk), ...Object.keys(derived)])
  for (const service of [...services].sort()) {
    const have = new Set(onDisk[service] ?? [])
    const want = new Set(derived[service] ?? [])
    const missing = [...want].filter((s) => !have.has(s))
    const extra = [...have].filter((s) => !want.has(s))
    if (missing.length) problems.push(`${service}: compose is MISSING ${missing.join(', ')}`)
    if (extra.length) problems.push(`${service}: compose grants ${extra.join(', ')}, which no module in that service asks for`)
  }
  if (problems.length) {
    console.error(`derive-grants: the compose file disagrees with the services — ${problems.length} difference(s)`)
    for (const p of problems) console.error(`  ${p}`)
    console.error(`\nRun: node scripts/derive-grants.mjs --write`)
    process.exit(1)
  }
  console.log(
    `derive-grants: ok — compose matches the estate (${Object.keys(derived).length} services, ${new Set(Object.values(derived).flat()).size} distinct scopes, ${Object.keys(gaps).length} declared gap(s), ${declaredNothing.size} module(s) declaring they need none)`,
  )
  process.exit(0)
}

if (flag('--json')) {
  console.log(JSON.stringify(derived, null, 2))
} else {
  for (const service of Object.keys(derived)) {
    console.log(`${service.padEnd(14)} ${derived[service].join(' ')}`)
  }
  console.log(
    `\nderive-grants: ${Object.keys(derived).length} services, ${new Set(Object.values(derived).flat()).size} distinct scopes, ${Object.keys(gaps).length} declared gap(s)`,
  )
  for (const rel of [...declaredNothing.keys()].sort()) console.log(`  needs no scope, and says so: ${rel}`)
}
