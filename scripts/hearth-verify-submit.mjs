#!/usr/bin/env node
/* Verify a Forge Create token's source against its deployed bytecode.
 *
 *   node scripts/hearth-verify-submit.mjs --address 0x… --verify http://127.0.0.1:9648
 *   node scripts/hearth-verify-submit.mjs --address 0x… --json > /tmp/input.json   # build only
 *
 * ── WHY THIS EXISTS AND MINT'S COMPILER SCRIPT DOES NOT DO IT ────────────────
 *
 * `mint/scripts/compile-contracts.mjs` compiles ForgeTokens.sol with an *import
 * callback*: OpenZeppelin is resolved out of `node_modules` at compile time and
 * never appears in the input. That is the right shape for a build — the pinned
 * package is what the compiler reads, and nothing can drift between a vendored
 * copy and the dependency.
 *
 * It is the wrong shape for verification. A verifier receives one JSON document
 * and compiles it in a sandbox with no callback and no node_modules; an input
 * whose sources are five bare `@openzeppelin/...` imports resolves to nothing.
 * So this walks the import graph and inlines every file it reaches, keyed by the
 * exact import path. solc treats a source already present in `sources` as
 * resolved, so the compilation is the same compilation — same compiler, same
 * settings, same bytes in, same bytes out.
 *
 * ── WHAT THIS BUYS, BEYOND ONE CONTRACT ─────────────────────────────────────
 *
 * Every token a paid Forge Create order deploys is this contract with different
 * constructor arguments. Verifying it once teaches the explorer the source for
 * all of them: `tools/verify` matches on runtime bytecode, and runtime bytecode
 * does not carry constructor arguments. A customer's token stops reading as an
 * anonymous blob without anyone having to verify it individually.
 */
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { resolve, dirname } from 'node:path'

const require = createRequire(import.meta.url)
const MINT = resolve(dirname(fileURLToPath(import.meta.url)), '../../mint')
const ENTRY = 'ForgeTokens.sol'

/* These four are quoted from mint/scripts/compile-contracts.mjs and must stay
 * quoted from it. A verifier that recompiles with different settings produces a
 * mismatch and reports it as "this is not the source", which is a false
 * accusation about the customer's contract rather than a bug in this file. */
const COMPILER = 'v0.8.26+commit.8a97fa7a'
const SETTINGS = {
  optimizer: { enabled: true, runs: 200 },
  evmVersion: 'paris',
  outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
}

function arg(name, fallback = null) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--')
    ? process.argv[i + 1]
    : fallback
}

/** Every `import "..."` in a source, whether or not it names symbols. */
function importsOf(text) {
  const found = new Set()
  for (const m of text.matchAll(/^\s*import\s+(?:\{[^}]*\}\s*from\s*)?["']([^"']+)["']/gm)) found.add(m[1])
  return [...found]
}

/** Resolve an import the way mint's callback does — out of mint's node_modules. */
function read(path) {
  if (path === ENTRY) return readFileSync(resolve(MINT, 'src/contracts', ENTRY), 'utf8')
  // Relative imports inside OpenZeppelin are already normalised by require.resolve
  // below; a bare relative path here would mean the entry file imported a sibling,
  // which ForgeTokens.sol does not do. Fail loudly rather than guess a base.
  if (path.startsWith('.')) throw new Error(`relative import ${path} has no base to resolve against`)
  return readFileSync(require.resolve(path, { paths: [MINT] }), 'utf8')
}

/** The entry file plus everything it transitively imports, keyed by import path. */
function collect() {
  const sources = {}
  const queue = [ENTRY]
  while (queue.length) {
    const path = queue.shift()
    if (sources[path]) continue
    const content = read(path)
    sources[path] = { content }
    for (const imported of importsOf(content)) {
      // OpenZeppelin imports its own files relatively ("../../utils/Context.sol").
      // Rejoin against the importer's directory and re-key by the joined path, so
      // the key a source is stored under is the key its importer will ask for.
      const key = imported.startsWith('.')
        ? resolve('/' + dirname(path), imported).slice(1)
        : imported
      if (!sources[key]) queue.push(key)
    }
  }
  return sources
}

const address = arg('address')
if (!address && !process.argv.includes('--json')) {
  console.error('usage: hearth-verify-submit.mjs --address 0x… [--verify URL] [--json]')
  process.exit(2)
}

const sources = collect()
const input = { language: 'Solidity', sources, settings: SETTINGS }

if (process.argv.includes('--json')) {
  process.stdout.write(JSON.stringify(input, null, 2) + '\n')
  process.exit(0)
}

const body = {
  address,
  compilerVersion: COMPILER,
  standardJsonInput: input,
  contractName: `${ENTRY}:FixedSupplyToken`,
}
const creationTxHash = arg('tx')
if (creationTxHash) body.creationTxHash = creationTxHash

const verifyUrl = arg('verify', 'http://127.0.0.1:9648')
const res = await fetch(new URL('/verify', verifyUrl), {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
})
const text = await res.text()
console.log(`${res.status} ${res.statusText}`)
console.log(text.slice(0, 4000))
process.exit(res.ok ? 0 : 1)
