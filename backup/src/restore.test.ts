import assert from 'node:assert/strict'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { streamToFileWithDigest } from './checksum.ts'
import { Readable } from 'node:stream'
import {
  buildManifest,
  EnvironmentMismatchError,
  serialiseManifest,
  type ArtefactEntry,
  type Environment,
} from './manifest.ts'
import { readGatedManifest, scratchNameFor, verifyArtefacts } from './restore.ts'
import { UnsafePathError } from './paths.ts'

async function writeSet(options: {
  environment: Environment
  /** Write the artefact files too, or leave the directory holding only a manifest. */
  withFiles: boolean
  corrupt?: boolean
}): Promise<{ directory: string; artefacts: ArtefactEntry[]; cleanup: () => Promise<void> }> {
  const directory = await mkdtemp(join(tmpdir(), 'cf-restore-'))
  await mkdir(join(directory, 'db'), { recursive: true })

  const payload = Buffer.from('a custom-format archive, for the purposes of this test')
  const digest = options.withFiles
    ? await streamToFileWithDigest(Readable.from([payload]), join(directory, 'db', 'identity.dump'))
    : { sha256: 'f'.repeat(64), bytes: BigInt(payload.length) }

  if (options.withFiles && options.corrupt) {
    await writeFile(join(directory, 'db', 'identity.dump'), 'not what was written')
  }

  const artefacts: ArtefactEntry[] = [
    {
      kind: 'database',
      name: 'identity',
      relPath: 'db/identity.dump',
      bytes: digest.bytes,
      sha256: digest.sha256,
      entryCount: 7n,
    },
  ]

  const manifest = buildManifest({
    backupRunId: '6f1d6a4e-0000-4000-8000-000000000002',
    environment: options.environment,
    composeProject: options.environment === 'mainnet' ? 'cloudsforge-estate' : 'cf-testnet',
    clusterSystemId: '7670192594363031586',
    kind: 'full',
    pgServerVersion: '17.10',
    startedAt: new Date('2026-08-05T10:00:00.000Z'),
    finishedAt: new Date('2026-08-05T10:05:00.000Z'),
    artefacts,
  })
  await writeFile(join(directory, 'MANIFEST.json'), serialiseManifest(manifest))

  return { directory, artefacts, cleanup: () => rm(directory, { recursive: true, force: true }) }
}

// ── THE GATE, AND ITS ORDERING ───────────────────────────────────────────────────────────────

test('a testnet set in a mainnet runner is refused BEFORE any artefact is opened', async () => {
  // `withFiles: false` is the whole test. The directory holds a manifest and NOTHING ELSE, so a
  // gate that ran after reading artefacts would fail with ENOENT. It must fail with the refusal.
  const set = await writeSet({ environment: 'testnet', withFiles: false })
  try {
    await assert.rejects(
      () => readGatedManifest(set.directory, 'mainnet'),
      (err: unknown) => {
        assert.ok(err instanceof EnvironmentMismatchError, `got ${String(err)}`)
        assert.equal(err.manifestEnvironment, 'testnet')
        assert.equal(err.runnerEnvironment, 'mainnet')
        return true
      },
    )
  } finally {
    await set.cleanup()
  }
})

test('a matching environment passes the gate and yields the manifest', async () => {
  const set = await writeSet({ environment: 'mainnet', withFiles: true })
  try {
    const manifest = await readGatedManifest(set.directory, 'mainnet')
    assert.equal(manifest.environment, 'mainnet')
    assert.equal(manifest.artefacts.length, 1)
  } finally {
    await set.cleanup()
  }
})

test('a manifest whose relPath escapes the directory is refused when it is read', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cf-restore-'))
  try {
    const manifest = buildManifest({
      backupRunId: '6f1d6a4e-0000-4000-8000-000000000003',
      environment: 'mainnet',
      composeProject: 'cloudsforge-estate',
      clusterSystemId: '1',
      kind: 'full',
      pgServerVersion: '17.10',
      startedAt: new Date(),
      finishedAt: new Date(),
      artefacts: [],
    })
    const forged = JSON.parse(serialiseManifest(manifest).toString('utf8')) as Record<string, unknown>
    forged['artefacts'] = [
      { kind: 'database', name: 'x', relPath: '../../etc/passwd', bytes: 1, sha256: 'a'.repeat(64) },
    ]
    await writeFile(join(directory, 'MANIFEST.json'), JSON.stringify(forged))

    await assert.rejects(() => readGatedManifest(directory, 'mainnet'), UnsafePathError)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

// ── CHECKSUM VERIFICATION ────────────────────────────────────────────────────────────────────

test('an intact set verifies', async () => {
  const set = await writeSet({ environment: 'mainnet', withFiles: true })
  try {
    const manifest = await readGatedManifest(set.directory, 'mainnet')
    const report = await verifyArtefacts(set.directory, manifest, [])
    assert.equal(report.verified, true)
    assert.equal(report.checked, 1)
  } finally {
    await set.cleanup()
  }
})

test('a corrupted artefact fails verification and names the file', async () => {
  const set = await writeSet({ environment: 'mainnet', withFiles: true, corrupt: true })
  try {
    const manifest = await readGatedManifest(set.directory, 'mainnet')
    const report = await verifyArtefacts(set.directory, manifest, [])
    assert.equal(report.verified, false)
    assert.match(report.mismatches[0] ?? '', /db\/identity\.dump/)
  } finally {
    await set.cleanup()
  }
})

test('a manifest that disagrees with the catalogue is caught even when the file matches it', async () => {
  // The attack the double comparison exists for: edit the dump AND the manifest so they agree. They
  // cannot also agree with a row in a database on another machine.
  const set = await writeSet({ environment: 'mainnet', withFiles: true })
  try {
    const manifest = await readGatedManifest(set.directory, 'mainnet')
    const report = await verifyArtefacts(set.directory, manifest, [
      {
        kind: 'database',
        name: 'identity',
        relPath: 'db/identity.dump',
        bytes: 1n,
        sha256: 'b'.repeat(64),
        entryCount: 7n,
        publicRef: null,
      },
    ])
    assert.equal(report.verified, false)
    assert.match(report.mismatches[0] ?? '', /manifest and the catalogue disagree/)
  } finally {
    await set.cleanup()
  }
})

// ── THE SCRATCH DATABASE ─────────────────────────────────────────────────────────────────────

test('a scratch name is a legal identifier, is unique per call, and never names a live database', () => {
  const a = scratchNameFor('custody')
  const b = scratchNameFor('custody')

  assert.match(a, /^scratch_verify_custody_[0-9a-f]{8}$/)
  assert.notEqual(a, b)
  assert.notEqual(a, 'custody')
  assert.ok(a.length <= 63)
})

test('a scratch name for the longest estate database still fits in an identifier', () => {
  assert.ok(scratchNameFor('devplatform').length <= 63)
  assert.ok(scratchNameFor('a'.repeat(30)).length <= 63)
})
