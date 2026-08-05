/**
 * The miner coinbase keys — the one artefact this system writes that is key material, and the only
 * one that is encrypted before it lands.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **WHAT IS BEING PROTECTED, AND FROM WHAT.**
 *
 * `~/dev/cloudsforge/miner-keys/{mainnet,testnet}/coinbase-key.json` is 240 bytes at mode 0600
 * holding `{ address, privateKey, warning }` with the private key in **plaintext**. Verified on the
 * host 2026-08-05: both files present, 0600, owner malf. The mainnet address
 * `0x980d…5b45` held 9,332 EMBER of mined coin. `docs/custody-backup-restore.md` §4.2 step 6 says
 * what that means: the key "cannot be rotated without abandoning the balance at the address, so the
 * paper copy is the only recovery path there will ever be."
 *
 * One disk, no backup, no rotation, and real money behind it. That is a durability problem.
 *
 * The naive fix — copy the file to the backup disk — trades a durability problem for a disclosure
 * problem, and the disclosure problem is worse. An unencrypted private key on a second disk in the
 * same room is a second place to steal it from, and a backup set is the thing most likely to be
 * copied somewhere else later.
 *
 * **SO IT IS ENCRYPTED WITH `age` TO A RECIPIENT WHOSE PRIVATE HALF NEVER EXISTS ON THIS HOST.**
 * The runner holds `BACKUP_AGE_RECIPIENT`, an `age1…` PUBLIC key. A public key is not a secret: it
 * is safe in a compose file, safe in a log line, and safe in this comment. Encryption is one-way
 * from this machine's point of view — a host compromise yields ciphertext and no way to open it.
 * The identity that can decrypt lives wherever the owner's paper and encrypted USB already live
 * (§4.1), which is a place this process cannot reach by design.
 *
 * That is strictly better than a symmetric key in the runner's environment, and it is better for
 * the same reason §1.5 gives: an artefact and the key that opens it must not share a medium. A
 * symmetric KEK here would put both in one container.
 *
 * ── THE FALLBACK THAT DOES NOT EXIST ──────────────────────────────────────────────────────────
 *
 * If `BACKUP_AGE_RECIPIENT` is unset, or `age` is not installed, or `age` exits non-zero, this
 * module writes **nothing** and records a warning in the manifest. There is deliberately no path
 * that writes the key in the clear "just this once". That fallback IS the failure mode: it fires
 * exactly when configuration is broken, which is exactly when nobody is watching, and it converts a
 * missing feature into a plaintext key on a shared disk.
 *
 * ── AND IT IS NOT A ROUTE TO THE CUSTODY KEYRING ──────────────────────────────────────────────
 *
 * This mechanism is for the coinbase keys and takes its source path from a variable that names
 * them. It must never be pointed at `compose/secrets/custody.*.env`. The coinbase key has no
 * procedure protecting it (§4.2 step 6, "covered by none of the above"); the custody keyring has
 * one, and that procedure's entire value is that the keyring is never in the same set as the
 * vault — which this process also writes. `keyring.ts` refuses to boot if a custody secret is in
 * this process's environment at all, and `archive.ts` refuses to tar anything credential-shaped.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * **NOTHING IN THIS FILE PRINTS, LOGS OR RETURNS PLAINTEXT.** The only value that leaves it is the
 * public address, the ciphertext's digest and its size. §7 is the record of what happens otherwise.
 */

import { spawn } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { streamToFileWithDigest } from './checksum.ts'
import { errorText, redact } from './paths.ts'
import type { ArtefactEntry, Environment } from './manifest.ts'

export class SecretsError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SecretsError'
  }
}

/** `age1` + 58 bech32 characters. Checked so a truncated paste fails here and not after a write. */
const AGE_RECIPIENT_SHAPE = /^age1[0-9a-z]{58}$/

const ADDRESS_SHAPE = /^0x[0-9a-fA-F]{40}$/

export function assertAgeRecipient(recipient: string): string {
  if (!AGE_RECIPIENT_SHAPE.test(recipient)) {
    throw new SecretsError(
      `BACKUP_AGE_RECIPIENT is not an age1 public key. It is a PUBLIC key and safe to check by eye; ` +
        `if an age-secret-key… value has been put here, that identity is now on this host and must be ` +
        `regenerated.`,
    )
  }
  return recipient
}

/**
 * The plaintext-at-rest caveat, carried in the manifest rather than only in a runbook.
 *
 * Backing the file up is not an endorsement of how it is stored. Whoever restores this set two
 * years from now needs to know that the source was a 0600 file on one disk, because that changes
 * what they should do next — and this repository does not own the miner and must not change how it
 * keeps its key while it is running.
 */
export const PLAINTEXT_SOURCE_WARNING =
  'the miner coinbase key is stored in PLAINTEXT at rest on the host (mode 0600, one disk, no rotation path); ' +
  'this backup encrypts it in transit to the backup disk but does not change how the miner stores it'

export const NO_LOCAL_DECRYPT_WARNING =
  'secrets artefacts cannot be verified beyond their checksum on this host: it holds no age identity, by design. ' +
  'A real proof of recovery is to decrypt off-host, re-derive the address from the recovered key, and compare it to ' +
  'the artefact publicRef — compare addresses, never keys'

export interface SecretsResult {
  readonly artefact: ArtefactEntry | null
  readonly warnings: readonly string[]
}

/**
 * Encrypt one coinbase key file into the run directory, or explain in the manifest why it is absent.
 *
 * The plaintext is read into memory and piped to `age` over stdin. It never becomes a file anywhere
 * but its 0600 original: the only thing this function creates under `/backups` is ciphertext.
 */
export async function backupMinerCoinbaseKey(options: {
  readonly sourcePath: string
  readonly destination: string
  readonly relPath: string
  readonly environment: Environment
  readonly recipient: string | null
  readonly timeoutMs: number
}): Promise<SecretsResult> {
  if (!options.recipient) {
    return {
      artefact: null,
      warnings: [
        `the miner coinbase key for ${options.environment} is NOT in this set: BACKUP_AGE_RECIPIENT is unset, ` +
          `and there is no path that writes a private key unencrypted. Set an age recipient public key and ` +
          `re-run. The key remains on one disk with no backup until then.`,
      ],
    }
  }

  const recipient = assertAgeRecipient(options.recipient)

  let plaintext: Buffer
  try {
    plaintext = await readFile(options.sourcePath)
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code
    if (code === 'ENOENT') {
      // Absent rather than unreadable. On an estate with no miner this is normal, and a warning
      // that says so is more useful than a failed run that says nothing about why.
      return {
        artefact: null,
        warnings: [`no miner coinbase key at ${options.sourcePath} for ${options.environment}; nothing to encrypt`],
      }
    }
    // `errorText` and not the raw error: an EACCES from `readFile` names the path, which is fine,
    // but everything from this module goes through redaction on principle.
    throw new SecretsError(`could not read the miner coinbase key: ${errorText(err)}`)
  }

  try {
    // The ADDRESS only. `privateKey` is never destructured, never named in a variable, and never
    // touched except as an opaque byte range inside `plaintext` on its way into `age`'s stdin.
    const address = readPublicAddress(plaintext)

    const digest = await encryptToFile({
      plaintext,
      recipient,
      destination: options.destination,
      timeoutMs: options.timeoutMs,
    })

    return {
      artefact: {
        kind: 'secrets',
        name: `miner-coinbase-${options.environment}`,
        relPath: options.relPath,
        // OF THE CIPHERTEXT. There is no digest of the plaintext anywhere in this system: a digest
        // of a 240-byte file with a known structure is a meaningful brute-force target.
        bytes: digest.bytes,
        sha256: digest.sha256,
        publicRef: address,
      },
      warnings: [PLAINTEXT_SOURCE_WARNING, NO_LOCAL_DECRYPT_WARNING],
    }
  } finally {
    // Best-effort, and worth doing anyway. V8 may hold copies this cannot reach — a Buffer is not a
    // guarantee of single-copy — but leaving a private key sitting in a long-lived process's heap
    // for the rest of a nightly run is a choice, and this is the other one.
    plaintext.fill(0)
  }
}

/**
 * Pull the public address out of the key file without going near the key.
 *
 * Validated against the same shape the schema enforces (`backup_artefacts_public_ref_is_an_address`).
 * If the file's `address` is missing or malformed the artefact is refused: a `secrets` artefact
 * without an address cannot be proven recoverable by any means that does not involve printing the
 * key, and that means does not exist here.
 */
export function readPublicAddress(plaintext: Buffer): string {
  let parsed: unknown
  try {
    parsed = JSON.parse(plaintext.toString('utf8'))
  } catch {
    // The message must not echo the content. A parse error that quotes the offending text would
    // print the key on a malformed file.
    throw new SecretsError('the miner coinbase key file is not valid JSON')
  }
  if (typeof parsed !== 'object' || parsed === null) throw new SecretsError('the miner coinbase key file is not an object')
  const address = (parsed as Record<string, unknown>)['address']
  if (typeof address !== 'string' || !ADDRESS_SHAPE.test(address)) {
    throw new SecretsError('the miner coinbase key file has no valid `address` field')
  }
  return address
}

/**
 * Run `age -r <recipient>`, plaintext in over stdin, ciphertext out to a file, hashed on the way.
 *
 * The recipient is on the command line and that is safe: it is a public key. Nothing secret is in
 * argv or in the child's environment — contrast `pg.ts`, where the password had to be moved out of
 * argv precisely because `/proc/<pid>/cmdline` is world-readable.
 */
async function encryptToFile(options: {
  plaintext: Buffer
  recipient: string
  destination: string
  timeoutMs: number
}): Promise<{ sha256: string; bytes: bigint }> {
  const child = spawn('age', ['--recipient', options.recipient, '--output', '-'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { PATH: process.env['PATH'] ?? '/usr/bin:/bin', LC_ALL: 'C' },
    signal: AbortSignal.timeout(options.timeoutMs),
  })

  let stderr = ''
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk: string) => {
    if (stderr.length < 8 * 1024) stderr += chunk
  })

  const exited = new Promise<void>((resolve, reject) => {
    child.on('error', (err) => {
      const code = (err as NodeJS.ErrnoException).code
      reject(
        new SecretsError(
          code === 'ENOENT'
            ? `\`age\` is not installed in this image, so the miner coinbase key cannot be encrypted. ` +
              `Nothing has been written: there is no unencrypted fallback, and adding one would be the ` +
              `disclosure this control exists to prevent.`
            : `age could not start: ${errorText(err)}`,
        ),
      )
    })
    child.on('close', (code, signal) => {
      if (code === 0) resolve()
      else
        reject(
          new SecretsError(
            `age exited ${code ?? 'null'}${signal ? ` (signal ${signal})` : ''}: ` +
              `${redact(stderr).trim().slice(-500) || '(no stderr)'} — nothing was written in the clear`,
          ),
        )
    })
  })

  // Written and ended before the output pipeline is awaited: 240 bytes fits in the pipe buffer, so
  // there is no deadlock, and `age` will not produce a byte until it sees EOF on stdin.
  child.stdin.end(options.plaintext)

  const [digest] = await Promise.all([streamToFileWithDigest(child.stdout, options.destination), exited])
  return digest
}
