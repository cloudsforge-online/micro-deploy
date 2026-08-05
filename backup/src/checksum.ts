/**
 * Checksums, computed **while the bytes are moving** and never by reading a file twice.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **WHY THE HASH IS A TRANSFORM IN THE PIPELINE AND NOT A SECOND PASS.**
 *
 * The obvious implementation writes the dump, then re-opens it and hashes it. Three things are
 * wrong with that, in increasing order of seriousness:
 *
 *   1. It reads ~300 MB twice per run, per environment, nightly, off the same spindle the chain is
 *      being written to.
 *   2. It hashes what is on disk at read time, not what was written — so a truncated write that
 *      the filesystem completed silently produces a checksum that matches the truncation. The
 *      backup then verifies perfectly and restores nothing, which is the exact failure
 *      `backup.verify` exists to catch and which a second-pass hash would help hide.
 *   3. It cannot hash a stream that was never a file, which the pre-restore safety dump wants to be.
 *
 * Hashing the stream as it passes commits to the bytes THIS PROCESS PRODUCED. The size is counted
 * in the same pass for the same reason.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */

import { createHash } from 'node:crypto'
import { createReadStream, createWriteStream } from 'node:fs'
import { Transform, type Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'

export interface Digest {
  readonly sha256: string
  /** Bigint because a size is a size: `Number` silently rounds above 2^53 and dumps only grow. */
  readonly bytes: bigint
}

/**
 * A pass-through that hashes and counts. Exposed so a caller can put it anywhere in a pipeline —
 * the point at which the hash is taken is a decision, not an implementation detail.
 */
export class HashingPassThrough extends Transform {
  readonly #hash = createHash('sha256')
  #bytes = 0n

  override _transform(chunk: Buffer, _encoding: BufferEncoding, done: (error?: Error | null) => void): void {
    this.#hash.update(chunk)
    this.#bytes += BigInt(chunk.length)
    this.push(chunk)
    done()
  }

  /**
   * Only valid once the stream has ended. Calling it early would return the digest of a prefix,
   * which is a checksum that looks entirely normal and matches nothing.
   */
  digest(): Digest {
    return { sha256: this.#hash.digest('hex'), bytes: this.#bytes }
  }
}

/**
 * Stream `source` to `destination`, returning the digest of exactly what was written.
 *
 * `pipeline` rather than `.pipe()`: on an error anywhere in the chain `pipeline` destroys every
 * stream and rejects, whereas `.pipe()` leaves the write stream open and the file half-written with
 * no error surfacing. A backup system whose failure mode is "a plausible-looking short file" is
 * worse than one with no error handling at all, because the short file gets a row.
 */
export async function streamToFileWithDigest(source: Readable, destination: string): Promise<Digest> {
  const hasher = new HashingPassThrough()
  await pipeline(source, hasher, createWriteStream(destination))
  return hasher.digest()
}

/** Hash a file that already exists. Used only on the verify path, where there is nothing to stream. */
export async function digestOfFile(path: string): Promise<Digest> {
  const hasher = new HashingPassThrough()
  // The sink discards; the hash is the product. `pipeline` still needs somewhere for the bytes to
  // go, and a Transform with no reader would stall on backpressure.
  await pipeline(createReadStream(path), hasher, new Transform({ transform: (_c, _e, done) => done() }))
  return hasher.digest()
}

/** Digest of an in-memory buffer — the manifest itself, which is small and must be hashed exactly. */
export function digestOfBuffer(buffer: Buffer): Digest {
  return { sha256: createHash('sha256').update(buffer).digest('hex'), bytes: BigInt(buffer.length) }
}

/**
 * Constant-time-ish comparison of two hex digests.
 *
 * Timing is not the threat here — an attacker who can time this can read the file — but the shape
 * check is: `===` on a value taken from a manifest would happily accept `undefined === undefined`
 * if a future refactor let one side go missing, and that compares equal.
 */
export function digestsMatch(expected: string, actual: string): boolean {
  return (
    typeof expected === 'string' &&
    typeof actual === 'string' &&
    /^[0-9a-f]{64}$/.test(expected) &&
    /^[0-9a-f]{64}$/.test(actual) &&
    expected === actual
  )
}
