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
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE SOURCE IS NO LONGER A PLAINTEXT FILE, AND FOR A WHILE THIS MODULE DID NOT KNOW THAT.**
 *
 * Everything above was written when `coinbase-key.json` — `{ address, privateKey, warning }` in
 * the clear — was the only thing on disk. micro-org#206 has since been half-fixed: the miners on
 * both hosts now run from `coinbase-keystore.json`, scrypt + AES-256-GCM, with the private key
 * never in the clear at rest. That is the outcome this whole issue wanted.
 *
 * It also silently broke the backup, and the way it broke is worth stating because the symptom
 * looks like success. `run.ts` asked for `<dir>/<env>/coinbase-key.json` by name. On the app host
 * the seal left only the keystore, so the read took the `ENOENT` branch — whose warning is
 * *"nothing to encrypt"* and whose comment reads *"On an estate with no miner this is normal."*
 * The estate has two miners. Measured on mainnet 2026-08-12: `backup_artefacts` held 264 rows,
 * 240 `database` + 16 `files` + 8 `vault`, and **zero** of kind `secrets`, ever.
 *
 * So this module now resolves its source rather than being told it:
 *
 *     coinbase-keystore.json   preferred — the file the miner actually reads
 *     coinbase-key.json        fallback  — still present on the chain host, still the only
 *                                          recovery path until the keystore is provably restorable
 *
 * Both carry a plaintext `address` field, so `readPublicAddress` works against either unchanged
 * and the `public_ref` constraint is satisfied either way.
 *
 * ── AND THE PASSPHRASE TRAVELS WITH IT, WHICH IS A DELIBERATE CHOICE ──────────────────────────
 *
 * **A keystore backup without the passphrase is a backup of nothing.** Each passphrase is 64 bytes
 * in one file at mode 0600 on one machine, covered by no cron, no timer and no runner. Backing up
 * the keystore alone would produce a green `secrets` artefact that cannot be opened — which is a
 * worse failure than no artefact, because it reads as recovered until the day it is needed.
 *
 * So one artefact holds both, as a self-describing JSON envelope (`MINER_ENVELOPE_FORMAT`), and
 * `age` encrypts the envelope. This does collapse two factors into one, and that is the trade
 * being made on purpose: the passphrase's protection becomes the age recipient alone. It is the
 * right trade here because the recipient's private half never exists on this host — so the pair is
 * no more reachable from a host compromise than the keystore alone was — and because the
 * alternative is a durability control that does not work. §1.5's rule is that an artefact and the
 * key that opens it must not share a MEDIUM; both halves being unopenable ciphertext on the backup
 * disk satisfies that, where "keystore on the backup disk, passphrase only on the mining host"
 * satisfies it by losing the money instead.
 *
 * A passphrase-less source is still backed up, with a warning that says the envelope cannot be
 * opened without a passphrase held elsewhere. Refusing outright would leave the estate with no
 * backup at all, which is the state this is fixing.
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

/**
 * The one warning that says the artefact exists and still cannot be used.
 *
 * Louder than the others on purpose. A `secrets` row in the catalogue and a `publicRef` that
 * matches the miner is exactly what a successful backup looks like from the outside, so the fact
 * that nothing in the set can open it has to travel inside the manifest.
 */
export const NO_PASSPHRASE_WARNING =
  'this envelope holds an ENCRYPTED KEYSTORE AND NO PASSPHRASE: no passphrase file was found beside the key. ' +
  'Recovering it needs the scrypt passphrase from wherever the operator keeps it — if that is one 0600 file on the ' +
  'mining host, this artefact does not make the coinbase key recoverable and micro-org#206 is not closed by it'

/**
 * The envelope written inside the `age` ciphertext, versioned so a restore two years from now does
 * not have to guess.
 *
 * A format string rather than a bare pair of fields because the recovery procedure is *"decrypt,
 * parse, write these two files back"* and every one of those steps needs to know what it is
 * looking at. `v1` holds `keystore` + `passphrase`; a plaintext-sourced set holds `key` instead of
 * both, and the `source` field is what distinguishes them without inspecting the contents.
 */
export const MINER_ENVELOPE_FORMAT = 'cloudsforge.miner-coinbase.v1'

/**
 * Where to look, in order. Resolved rather than configured for the reason `env.ts` already gives
 * about `minerKeysDir`: a path derived from `BACKUP_ENVIRONMENT` cannot be pointed at the other
 * network's key by a settings edit.
 *
 * `passphrasePaths` is a LIST because the two hosts name the file differently and one runner image
 * has to run on both. Measured 2026-08-12:
 *
 *     app host    miner-keys/secrets/coinbase-passphrase        64 bytes 0600, ONE file, both networks
 *     chain host  /home/malf/secrets/ember-coinbase-<env>.pass  64 bytes 0600, one per network
 *
 * Note where the chain host's lives: `/home/malf/secrets`, a sibling of `dev/`, NOT under the
 * miner-keys tree. So `<minerKeysDir>/secrets/ember-coinbase-<env>.pass` is a CONTAINER path that
 * only resolves if a runner deployed there also bind-mounts `/home/malf/secrets` to
 * `/miner-keys/secrets`. There is no runner on the chain host today (which is its own gap — see
 * `runbooks/runbook-miner-coinbase-key-backup.md`); this entry is what makes one work when there is.
 *
 * Trying all three beats a variable nobody sets correctly on the second host.
 */
export interface MinerKeySources {
  readonly keystorePath: string
  readonly plaintextPath: string
  readonly passphrasePaths: readonly string[]
}

export function minerKeySources(minerKeysDir: string, environment: Environment): MinerKeySources {
  return {
    keystorePath: `${minerKeysDir}/${environment}/coinbase-keystore.json`,
    plaintextPath: `${minerKeysDir}/${environment}/coinbase-key.json`,
    passphrasePaths: [
      `${minerKeysDir}/secrets/coinbase-passphrase`,
      `${minerKeysDir}/secrets/ember-coinbase-${environment}.pass`,
      `${minerKeysDir}/${environment}/coinbase-passphrase`,
    ],
  }
}

export interface SecretsResult {
  readonly artefact: ArtefactEntry | null
  readonly warnings: readonly string[]
}

/** `null` when absent, so a caller can tell "not there" from "there and unreadable" (which throws). */
async function readIfPresent(path: string): Promise<Buffer | null> {
  try {
    return await readFile(path)
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw new SecretsError(`could not read ${path}: ${errorText(err)}`)
  }
}

/**
 * Encrypt one coinbase key file into the run directory, or explain in the manifest why it is absent.
 *
 * The plaintext is read into memory and piped to `age` over stdin. It never becomes a file anywhere
 * but its 0600 original: the only thing this function creates under `/backups` is ciphertext.
 */
export async function backupMinerCoinbaseKey(options: {
  readonly sources: MinerKeySources
  readonly destination: string
  readonly relPath: string
  readonly environment: Environment
  readonly recipient: string | null
  readonly expectedAddress: string | null
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

  // KEYSTORE FIRST. It is what the miner reads today, and preferring the plaintext would keep
  // backing up a file that is on its way to being deleted while the operative one goes uncovered.
  const keystore = await readIfPresent(options.sources.keystorePath)
  const plaintext = keystore ? null : await readIfPresent(options.sources.plaintextPath)
  const key = keystore ?? plaintext

  if (!key) {
    return {
      artefact: null,
      warnings: [
        // Deliberately not the old "nothing to encrypt", which read as benign. An estate with a
        // running miner and neither file is a broken mount or a moved directory, and the manifest
        // is where a restorer finds out that a set they are trusting has no key in it.
        `NO MINER COINBASE KEY IN THIS SET for ${options.environment}: neither ` +
          `${options.sources.keystorePath} nor ${options.sources.plaintextPath} exists. That is normal only on an ` +
          `estate that runs no miner — if one is running, its key is unmounted or has moved and nothing is ` +
          `backing it up (micro-org#206).`,
      ],
    }
  }

  const passphrase = keystore ? await firstPresent(options.sources.passphrasePaths) : null
  const warnings: string[] = []

  try {
    // The ADDRESS only. The key material is never destructured, never named in a variable, and
    // never touched except as an opaque byte range on its way into `age`'s stdin.
    const address = readPublicAddress(key)

    /*
     * THE KEY THAT IS HERE IS NOT NECESSARILY THE KEY THIS RUN IS FOR (micro-org#532).
     *
     * Refusing rather than writing is the whole point. Writing it anyway and naming the mismatch in
     * a warning would repeat the defect: the artefact would exist, `backup_secrets_included` would
     * go to 1, and `MinerCoinbaseKeyUnbacked` would stay silent — which is precisely how seventeen
     * sets of the wrong key went unnoticed. Returning no artefact makes that gauge 0 and fires the
     * alert that already exists, whose text is then TRUE.
     *
     * Both addresses are public and safe to print. Naming them is what makes the warning actionable
     * instead of a puzzle.
     */
    if (options.expectedAddress && address.toLowerCase() !== options.expectedAddress.toLowerCase()) {
      return {
        artefact: null,
        warnings: [
          `the miner coinbase key for ${options.environment} is NOT in this set: the key found is ` +
            `${address}, but BACKUP_MINER_EXPECTED_ADDRESS names ${options.expectedAddress}. Nothing ` +
            `was written, because a backup under the wrong key's name is worse than no backup. Check ` +
            `which host's miner-keys directory is mounted — see micro-org#532.`,
        ],
      }
    }

    const envelope = buildMinerEnvelope({
      environment: options.environment,
      address,
      key,
      fromKeystore: keystore !== null,
      passphrase,
    })

    try {
      const digest = await encryptToFile({
        plaintext: envelope,
        recipient,
        destination: options.destination,
        timeoutMs: options.timeoutMs,
      })

      if (!keystore) warnings.push(PLAINTEXT_SOURCE_WARNING)
      if (keystore && !passphrase) warnings.push(NO_PASSPHRASE_WARNING)
      warnings.push(NO_LOCAL_DECRYPT_WARNING)

      return {
        artefact: {
          kind: 'secrets',
          name: `miner-coinbase-${options.environment}`,
          relPath: options.relPath,
          // OF THE CIPHERTEXT. There is no digest of the plaintext anywhere in this system: a digest
          // of a small file with a known structure is a meaningful brute-force target.
          bytes: digest.bytes,
          sha256: digest.sha256,
          publicRef: address,
        },
        warnings,
      }
    } finally {
      envelope.fill(0)
    }
  } finally {
    // Best-effort, and worth doing anyway. V8 may hold copies this cannot reach — a Buffer is not a
    // guarantee of single-copy — but leaving key material sitting in a long-lived process's heap
    // for the rest of a nightly run is a choice, and this is the other one.
    key.fill(0)
    passphrase?.contents.fill(0)
  }
}

/**
 * Build the envelope that goes inside the ciphertext. Pure, and separate from the encryption for
 * one reason: it is the part with a format contract, and a format contract that can only be
 * exercised by a test with `age` installed is a format contract nothing checks.
 *
 * Returns a Buffer the caller is expected to zero.
 */
export function buildMinerEnvelope(options: {
  readonly environment: Environment
  readonly address: string
  readonly key: Buffer
  readonly fromKeystore: boolean
  readonly passphrase: { path: string; contents: Buffer } | null
}): Buffer {
  return Buffer.from(
    JSON.stringify({
      format: MINER_ENVELOPE_FORMAT,
      environment: options.environment,
      address: options.address,
      source: options.fromKeystore ? 'keystore' : 'plaintext',
      // Verbatim file contents, so recovery is "write this string back to that path" and needs no
      // knowledge of either file's internal format.
      ...(options.fromKeystore
        ? { keystore: options.key.toString('utf8') }
        : { key: options.key.toString('utf8') }),
      ...(options.passphrase
        ? { passphrase: options.passphrase.contents.toString('utf8'), passphraseFrom: options.passphrase.path }
        : {}),
      recovery:
        'age -d -i <identity> this file, parse the JSON, write `keystore` back to coinbase-keystore.json and ' +
        '`passphrase` to the path named by passphraseFrom (mode 0600). Verify by re-deriving the address and ' +
        'comparing it to `address` — never by printing a key.',
    }),
    'utf8',
  )
}

/** First candidate that exists, with the path it came from — the manifest records which one won. */
async function firstPresent(paths: readonly string[]): Promise<{ path: string; contents: Buffer } | null> {
  for (const path of paths) {
    const contents = await readIfPresent(path)
    if (contents) return { path, contents }
  }
  return null
}

/**
 * Pull the public address out of the key file without going near the key.
 *
 * Validated against the same shape the schema enforces (`backup_artefacts_public_ref_is_an_address`).
 * If the file's `address` is missing or malformed the artefact is refused: a `secrets` artefact
 * without an address cannot be proven recoverable by any means that does not involve printing the
 * key, and that means does not exist here.
 */
/**
 * An address an operator configured, normalised to lower case, or a refusal.
 *
 * Beside `ADDRESS_SHAPE` rather than in `env.ts` so there is ONE definition of what an address looks
 * like in this service. The comparison it feeds is case-insensitive because the form people copy out
 * of a block explorer is EIP-55 mixed case, and a guard that rejects the thing you were told to
 * paste gets turned off.
 */
export function assertMinerAddress(value: string): string {
  if (!ADDRESS_SHAPE.test(value)) {
    throw new SecretsError('BACKUP_MINER_EXPECTED_ADDRESS must be an 0x-prefixed 20-byte address')
  }
  return value.toLowerCase()
}

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
