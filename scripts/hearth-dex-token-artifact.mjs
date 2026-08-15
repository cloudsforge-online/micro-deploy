#!/usr/bin/env node
/* Turn `micro-mint`'s committed FixedSupplyToken into an artifact the seed script can deploy.
 *
 *   node scripts/hearth-dex-token-artifact.mjs > /tmp/FixedSupplyToken.json
 *   scp /tmp/FixedSupplyToken.json malf@192.168.1.42:dex/artifacts/
 *
 * ── WHY THE POOL'S TOKEN IS MINT'S TOKEN, AND NOT A NEW ONE ──────────────────
 *
 * Forge Exchange's first pair needs a second asset, and `docs/39` §4 says it
 * should be one "already native to Hearth, including anything `micro-mint`
 * issues". The temptation is to write a ten-line ERC-20 into
 * `hearth/contracts/src/` for the occasion. That would put an unreviewed
 * contract into the repository whose whole value is that its contracts are
 * reviewed, to test a pool against an asset no user will ever hold.
 *
 * So the pool is seeded with a token deployed from `FIXEDSUPPLYTOKEN_BYTECODE`
 * — byte for byte the creation code `micro-mint`'s catalogue ships, the same one
 * every paid Forge Create order runs. The pair therefore exercises the asset
 * type that will actually turn up in it.
 *
 * ── WHY THIS RUNS ON THE WORKSTATION AND NOT THE CHAIN HOST ──────────────────
 *
 * The chain host has neither the `micro-mint` checkout nor a `node` on any PATH
 * (see `hearth-dex-run.sh`). Both repositories are checked out here, so the
 * extraction happens here and one JSON file is copied over. `sourceSha256` is
 * mint's own `SOURCE_SHA256`, carried across so the artifact on the chain host
 * can be traced back to the .sol it was compiled from.
 */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const GENERATED = fileURLToPath(new URL('../../mint/src/contracts/generated.ts', import.meta.url))
const source = readFileSync(GENERATED, 'utf8')

/** One `export const NAME = <value>` from the generated module, without importing TypeScript. */
function constant(name, pattern) {
  const m = new RegExp(`export const ${name}\\s*=\\s*${pattern}`).exec(source)
  if (!m) throw new Error(`${name} not found in ${GENERATED} — has compile-contracts.mjs changed shape?`)
  return m[1]
}

const bytecode = constant('FIXEDSUPPLYTOKEN_BYTECODE', "\\n?\\s*'(0x[0-9a-fA-F]+)'")
const abi = constant('FIXEDSUPPLYTOKEN_ABI', '(\\[.*?\\]) as const')
const sha = constant('SOURCE_SHA256', "'([0-9a-f]{64})'")

// The compiler line is mint's, not hearth's: this contract was built by
// `mint/scripts/compile-contracts.mjs`, with different settings from the
// exchange's own contracts. Recording hearth's settings here would be a lie that
// looks like provenance.
process.stdout.write(
  JSON.stringify(
    {
      contractName: 'FixedSupplyToken',
      sourceName: 'ForgeTokens.sol',
      origin: 'micro-mint/src/contracts/generated.ts',
      sourceSha256: sha,
      compiler: {
        version: '0.8.26+commit.8a97fa7a.Emscripten.clang',
        settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'paris' },
      },
      abi: JSON.parse(abi),
      bytecode,
    },
    null,
    2,
  ) + '\n',
)
