/**
 * Tarring the things that are not databases: the custody vault, studio's assets, Tessera's sprites.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE VAULT TARBALL'S DIRECTORY NAMES ARE LOAD-BEARING, NOT COSMETIC.**
 *
 * `docs/custody-backup-restore.md` §1.2: every custody blob is sealed with AES-256-GCM and the
 * slot name — the chain address, or `seed:<uuid>` — is authenticated as additional data
 * (`setAAD("<slot>|v<n>")`, `custody/src/crypto.ts`). Moving `key.enc` from one address's
 * directory to another's does not decrypt to the wrong key; it fails the GCM tag outright. The
 * document states the consequence in its own words: **"the vault must be restored with its
 * directory names intact."**
 *
 * So this archives with `-C <dir> .` — members are `./<slot>/key.enc`, relative, one level, exactly
 * as §2's rehearsed command produces and exactly what §3's `tar -xzf … -C /vault/keys` expects.
 * Anything that changes the depth (archiving the parent, stripping components, flattening) turns
 * every blob in the estate into ciphertext nobody can open, and it does so silently — the tarball
 * is fine, the restore succeeds, and the failure appears the first time somebody tries to SPEND.
 *
 * `--numeric-owner` for the same reason the restore procedure chowns to 1000:1000: the vault is
 * mode 0700 owned by uid 1000 and a tarball carrying owner *names* restores to whatever uid holds
 * that name on the restoring host, which is not necessarily custody's.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * **THE ARCHIVER REFUSES rather than skips.** If a forbidden entry (a `.env`, a `secrets/`) turns
 * up inside a mounted source directory, the whole artefact fails. Skipping it would produce a
 * backup whose contents differ from its manifest, and the entire value of a manifest is that it
 * says what is in the set.
 */

import { spawn } from 'node:child_process'
import { readdir, stat } from 'node:fs/promises'
import { streamToFileWithDigest, type Digest } from './checksum.ts'
import { FORBIDDEN_ARCHIVE_ENTRY } from './keyring.ts'
import { errorText, redact } from './paths.ts'

export class ArchiveError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ArchiveError'
  }
}

export interface DirectorySurvey {
  /** Regular files only. Directories are structure, not content, and the manifest counts content. */
  readonly fileCount: bigint
  readonly byteCount: bigint
}

/**
 * Walk a source directory before archiving it.
 *
 * Two products, both needed before `tar` starts:
 *   · `fileCount` becomes the manifest's `entryCount`, which is what a restore is checked against.
 *     §2's rehearsed procedure does the same thing (`tar -tzf … | grep -c 'key\\.enc$'`) and then
 *     compares it against `custody_keys + custody_seeds`.
 *   · `byteCount` feeds the space projection, so a run that cannot fit refuses BEFORE writing
 *     rather than filling the disk and then discovering it.
 *
 * The forbidden-entry check happens here, on the walk, rather than after the tarball exists —
 * finding a keyring inside a backup you have already written is finding it too late.
 */
export async function surveyDirectory(sourceDir: string): Promise<DirectorySurvey> {
  const entries = await readdir(sourceDir, { recursive: true, withFileTypes: true })
  let fileCount = 0n
  let byteCount = 0n

  for (const entry of entries) {
    const forbidden = FORBIDDEN_ARCHIVE_ENTRY.test(entry.name)
    if (forbidden) {
      // The NAME, never the contents, and never the parent path — which for a secrets directory is
      // itself a disclosure of where the estate keeps them.
      throw new ArchiveError(
        `refusing to archive ${JSON.stringify(sourceDir)}: it contains an entry named ` +
          `${JSON.stringify(entry.name)}, which is credential-shaped. The custody vault and any key ` +
          `material must never enter the same backup set (docs/custody-backup-restore.md §4.1).`,
      )
    }
    if (!entry.isFile()) continue
    fileCount += 1n
    // `stat` per file is the cost of an honest projection. For the vault (502 files) and the world
    // assets (394 files) that is under a thousand syscalls, once a night.
    const info = await stat(`${entry.parentPath}/${entry.name}`)
    byteCount += BigInt(info.size)
  }

  return { fileCount, byteCount }
}

export interface ArchiveResult extends Digest {
  readonly entryCount: bigint
}

/**
 * Archive a directory's CONTENTS to a gzipped tarball, hashing the stream as it is written.
 *
 * The hash is taken on the way past (`checksum.ts`), so the checksum in the manifest commits to
 * the bytes this process produced rather than to whatever is on disk afterwards.
 */
export async function archiveDirectory(options: {
  readonly sourceDir: string
  readonly destination: string
  readonly timeoutMs: number
}): Promise<ArchiveResult> {
  const survey = await surveyDirectory(options.sourceDir)

  const child = spawn(
    'tar',
    [
      '--create',
      '--gzip',
      // See the header: uids, not names.
      '--numeric-owner',
      // `-C <dir> .` — members are `./x/y`, so the archive is rooted at the directory's CONTENTS
      // and restoring it into an equivalent directory reproduces the exact layout.
      '--directory',
      options.sourceDir,
      '--file',
      '-',
      '.',
    ],
    {
      stdio: ['ignore', 'pipe', 'pipe'],
      // A deliberately bare environment: `tar` needs nothing from this process, and inheriting the
      // parent's environment into a child is how variables travel where nobody intended.
      env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', LC_ALL: 'C' },
      signal: AbortSignal.timeout(options.timeoutMs),
    },
  )

  let stderr = ''
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk: string) => {
    if (stderr.length < 32 * 1024) stderr += chunk
  })

  const exited = new Promise<void>((resolve, reject) => {
    child.on('error', (err) => reject(new ArchiveError(`tar could not start: ${errorText(err)}`)))
    child.on('close', (code, signal) => {
      if (code === 0) {
        resolve()
        return
      }
      // GNU tar exits 1 for "some files differ" — a file changed underneath it while it read. That
      // is not a warning to swallow: the tarball then holds a torn copy of a file, and for the
      // custody vault a torn `key.enc` is an unspendable address. Fail, let the queue retry, and
      // let the next run take a consistent copy.
      reject(
        new ArchiveError(
          `tar exited ${code ?? 'null'}${signal ? ` (signal ${signal})` : ''} archiving ` +
            `${JSON.stringify(options.sourceDir)}${code === 1 ? ' — a file changed while it was being read' : ''}: ` +
            `${redact(stderr).trim().slice(-1_000) || '(no stderr)'}`,
        ),
      )
    })
  })

  // Both awaited together: if `tar` fails mid-stream the pipeline rejects too, and awaiting them in
  // sequence would leave one unhandled rejection whichever order they are written in.
  const [digest] = await Promise.all([streamToFileWithDigest(child.stdout, options.destination), exited])

  return { ...digest, entryCount: survey.fileCount }
}
