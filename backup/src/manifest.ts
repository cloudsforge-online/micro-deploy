/**
 * `MANIFEST.json` — the load-bearing artefact, and the environment gate that reads it.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE MANIFEST IS THE BACKUP. THE DATABASE ROW IS A CONVENIENCE.**
 *
 * `backup_runs` lives in `admin_api`, on the cluster being backed up. In the disaster this system
 * exists for — the one `docs/custody-backup-restore.md` §3 describes, "the host is gone" — that row
 * is gone with it. What survives is a directory of files on the second disk, and the only thing in
 * that directory that says what the files ARE is this JSON. So it carries, self-contained:
 *
 *   · which estate it came from        (`environment`, and the gate below is why)
 *   · which cluster                    (`clusterSystemId`, from pg_control_system())
 *   · what each file is and hashes to  (`artefacts[]`)
 *   · what is deliberately NOT here    (`excluded[]`)
 *   · that the keyring is not here     (`custodyKeyringIncluded: false`)
 *
 * `excluded` is not decoration. `/data/chains` is 553 GB and its absence from a backup directory
 * is indistinguishable, to somebody restoring at 3 a.m. two years from now, from a backup that
 * failed halfway. Recording it with its reason makes the absence read as a decision.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * **`custodyKeyringIncluded` IS A LITERAL `false`, NOT A COMPUTED VALUE.** A computed value is a
 * value that can compute to `true`, and there must be no expression anywhere in this repository
 * capable of producing that. See `keyring.ts`.
 *
 * **AND THE `secrets` ARTEFACT IS NOT AN EXCEPTION TO THAT.** A `secrets` artefact is the miner
 * coinbase key, encrypted to an `age` recipient whose private half has never existed on this host
 * (`secrets.ts`). That is a different artefact from the custody keyring, in a different position:
 * §4.2 step 6 records that the coinbase keys are plaintext, unrotatable, and covered by no
 * procedure at all, whereas the custody keyring has one (§4) and its whole value depends on never
 * being adjacent to the vault. Encrypting the coinbase key to an off-host recipient adds
 * durability without adding a place to steal it from; doing the same for the custody keyring would
 * put B and C in one directory and only an off-host key would stand between this estate and §1.5.
 * So there is no code path from the keyring to `secrets.ts`, and `keyring.ts` refuses to boot if
 * one is ever wired up by a deploy.
 */

import { digestOfBuffer, type Digest } from './checksum.ts'
import { assertSafeRelPath } from './paths.ts'

export const MANIFEST_VERSION = 1
export const MANIFEST_FILENAME = 'MANIFEST.json'
export const TOOL_NAME = 'cloudsforge-backup'
export const TOOL_VERSION = '1.0.0'

export type Environment = 'mainnet' | 'testnet' | 'development'
export type BackupKind = 'full' | 'databases' | 'custody' | 'files'
export type ArtefactKind = 'database' | 'vault' | 'files' | 'secrets'

export interface ArtefactEntry {
  readonly kind: ArtefactKind
  /** The database name, the volume name, or the file-set name. Matches `backup_artefacts.name`. */
  readonly name: string
  readonly relPath: string
  /** For a `secrets` artefact these are the CIPHERTEXT's size and digest. There is no other form. */
  readonly bytes: bigint
  readonly sha256: string
  /**
   * Rows for a database, files for a tarball.
   *
   * **For a tarball it is exact. For a database it is ADVISORY, and the difference matters.**
   *
   * It is an exact `count(*)` summed over every user table rather than the `n_live_tup` estimate
   * most tools use — an estimate reads 0 on a freshly restored database until `analyze` runs, which
   * would report a perfect restore as a total loss. But it is taken by a separate query beside the
   * dump, not from inside the dump's own snapshot, and the estate is live. Measured 2026-08-05:
   * `identity` restored 34,099 rows against a source reading 34,101 four minutes later, because
   * `users` grew by 8 in between; `sessions` and `refresh_tokens` matched exactly and the restored
   * copy had zero orphaned sessions, so the dump was a coherent transactional snapshot throughout.
   *
   * So a verify records this number and never fails on it. What it passes or fails on is
   * `integrityOf` in `pg.ts` — see the block comment there.
   */
  readonly entryCount?: bigint
  /**
   * The PUBLIC address a `secrets` artefact is the key for. Mandatory for that kind
   * (`backup_artefacts_secrets_name_their_address`), absent for every other.
   *
   * It is how a recovery is proved without printing anything secret: decrypt off-host, re-derive
   * the address from the recovered key, compare it to this. **Compare addresses, never keys** —
   * the same verification `docs/custody-backup-restore.md` §5.3 performs, and for the same reason.
   * The schema's CHECK (`^0x[0-9a-fA-F]{40}$`) is what stops this column ever becoming somewhere
   * a key gets put: an address is 42 characters, a secp256k1 private key is 64 hex.
   */
  readonly publicRef?: string
}

export interface Exclusion {
  readonly path: string
  readonly reason: string
}

export interface Manifest {
  readonly manifestVersion: number
  readonly backupRunId: string
  readonly environment: Environment
  readonly composeProject: string
  readonly clusterSystemId: string
  readonly kind: BackupKind
  readonly tool: string
  readonly toolVersion: string
  readonly pgServerVersion: string
  readonly startedAt: string
  readonly finishedAt: string
  readonly artefacts: readonly ArtefactEntry[]
  readonly excluded: readonly Exclusion[]
  /** Always `false`. Typed as the literal so a `true` does not compile. */
  readonly custodyKeyringIncluded: false
  /**
   * Things true about this set that a restorer needs to know and that no other field can say.
   *
   * Not a log — a log is on a host that may be gone. These are the caveats that travel WITH the
   * artefact: that the miner key's source is plaintext at rest on the host, that a `secrets`
   * artefact cannot be verified here beyond its checksum because this machine holds no private
   * identity, or that a source directory was absent and its artefact is therefore missing by
   * circumstance rather than by the decision recorded in `excluded`.
   */
  readonly warnings: readonly string[]
}

/**
 * What this system deliberately does not back up, and why.
 *
 * `/data/chains` is 553 GB of public Bitcoin, Litecoin and Dogecoin block data. It is
 * reconstructible from the network by definition — that is what a public chain IS — and copying it
 * nightly onto the same host would consume the 1.4 TB of headroom the destination disk has and
 * stop the miner, which is a second outage the backup system would have caused rather than
 * survived. It is also load-bearing for other work on this host.
 */
export const EXCLUSIONS: readonly Exclusion[] = Object.freeze([
  Object.freeze({
    path: '/data/chains',
    reason: 'public blockchain data, reconstructible from the network',
  }),
])

export interface ManifestInput {
  readonly backupRunId: string
  readonly environment: Environment
  readonly composeProject: string
  readonly clusterSystemId: string
  readonly kind: BackupKind
  readonly pgServerVersion: string
  readonly startedAt: Date
  readonly finishedAt: Date
  readonly artefacts: readonly ArtefactEntry[]
  readonly excluded?: readonly Exclusion[]
  readonly warnings?: readonly string[]
}

export function buildManifest(input: ManifestInput): Manifest {
  return {
    manifestVersion: MANIFEST_VERSION,
    backupRunId: input.backupRunId,
    environment: input.environment,
    composeProject: input.composeProject,
    clusterSystemId: input.clusterSystemId,
    kind: input.kind,
    tool: TOOL_NAME,
    toolVersion: TOOL_VERSION,
    pgServerVersion: input.pgServerVersion,
    startedAt: input.startedAt.toISOString(),
    finishedAt: input.finishedAt.toISOString(),
    // Sorted so two runs of the same estate produce byte-identical ordering. A manifest whose
    // artefact order depends on which `readdir` returned first is a manifest two operators cannot
    // usefully diff.
    artefacts: [...input.artefacts].sort((a, b) => (a.relPath < b.relPath ? -1 : a.relPath > b.relPath ? 1 : 0)),
    excluded: input.excluded ?? EXCLUSIONS,
    custodyKeyringIncluded: false,
    warnings: input.warnings ?? [],
  }
}

/**
 * Serialise to the exact bytes that get hashed and written.
 *
 * `bytes` and `entryCount` are bigint in memory and JSON numbers on disk, because a manifest read
 * by `jq` at 3 a.m. during a restore should not need a bigint-aware parser. The conversion asserts
 * safety rather than assuming it: above 2^53 `Number` rounds silently, and a size that rounds is a
 * checksum comparison that passes against the wrong file. 2^53 bytes is 9 PB, so this throws only
 * if something is very wrong — which is the point of asserting rather than commenting.
 */
export function serialiseManifest(manifest: Manifest): Buffer {
  const json = JSON.stringify(
    manifest,
    (_key, value: unknown) => {
      if (typeof value !== 'bigint') return value
      if (value > BigInt(Number.MAX_SAFE_INTEGER) || value < 0n) {
        throw new RangeError(`manifest carries a size outside the safe integer range: ${value}`)
      }
      return Number(value)
    },
    2,
  )
  return Buffer.from(`${json}\n`, 'utf8')
}

/** The manifest's own digest — the single value `backup_runs.manifest_sha256` commits to. */
export function digestOfManifest(manifest: Manifest): { buffer: Buffer; digest: Digest } {
  const buffer = serialiseManifest(manifest)
  return { buffer, digest: digestOfBuffer(buffer) }
}

export class ManifestError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ManifestError'
  }
}

const ENVIRONMENTS: ReadonlySet<string> = new Set(['mainnet', 'testnet', 'development'])
const ARTEFACT_KINDS: ReadonlySet<string> = new Set(['database', 'vault', 'files', 'secrets'])

/** `backup_artefacts_public_ref_is_an_address`, restated. An address, never a key. */
const PUBLIC_REF_SHAPE = /^0x[0-9a-fA-F]{40}$/
const BACKUP_KINDS: ReadonlySet<string> = new Set(['full', 'databases', 'custody', 'files'])

function str(source: Record<string, unknown>, key: string): string {
  const value = source[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw new ManifestError(`${MANIFEST_FILENAME} field ${key} is missing or not a string`)
  }
  return value
}

/**
 * Parse a manifest read off disk.
 *
 * **Every field is checked, including the ones a well-formed manifest always has.** This function's
 * caller is a restore, and a restore is the one operation that overwrites live money data — so the
 * input has to be treated as an attacker's file that happens to be in the right directory. The
 * `relPath` check is the sharpest of these: see the header of `paths.ts`.
 */
export function parseManifest(raw: string | Buffer): Manifest {
  let parsed: unknown
  try {
    parsed = JSON.parse(typeof raw === 'string' ? raw : raw.toString('utf8'))
  } catch (err) {
    throw new ManifestError(`${MANIFEST_FILENAME} is not valid JSON: ${err instanceof Error ? err.message : err}`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ManifestError(`${MANIFEST_FILENAME} is not a JSON object`)
  }
  const source = parsed as Record<string, unknown>

  if (source['manifestVersion'] !== MANIFEST_VERSION) {
    // Refuse rather than best-effort. A future format this build does not understand could differ
    // in what `relPath` means, and guessing at that is how a restore writes somewhere unintended.
    throw new ManifestError(
      `${MANIFEST_FILENAME} is version ${String(source['manifestVersion'])}; this tool understands ${MANIFEST_VERSION}`,
    )
  }

  const environment = str(source, 'environment')
  if (!ENVIRONMENTS.has(environment)) throw new ManifestError(`unknown environment ${JSON.stringify(environment)}`)
  const kind = str(source, 'kind')
  if (!BACKUP_KINDS.has(kind)) throw new ManifestError(`unknown backup kind ${JSON.stringify(kind)}`)

  const rawArtefacts = source['artefacts']
  if (!Array.isArray(rawArtefacts)) throw new ManifestError(`${MANIFEST_FILENAME} artefacts is not an array`)

  const artefacts: ArtefactEntry[] = rawArtefacts.map((entry, index) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new ManifestError(`artefacts[${index}] is not an object`)
    }
    const item = entry as Record<string, unknown>
    const artefactKind = str(item, 'kind')
    if (!ARTEFACT_KINDS.has(artefactKind)) {
      throw new ManifestError(`artefacts[${index}].kind ${JSON.stringify(artefactKind)} is unknown`)
    }
    const sha256 = str(item, 'sha256')
    if (!/^[0-9a-f]{64}$/.test(sha256)) throw new ManifestError(`artefacts[${index}].sha256 is not 64 hex characters`)

    const bytes = item['bytes']
    if (typeof bytes !== 'number' || !Number.isSafeInteger(bytes) || bytes <= 0) {
      throw new ManifestError(`artefacts[${index}].bytes is not a positive safe integer`)
    }
    const entryCount = item['entryCount']
    if (entryCount !== undefined && (typeof entryCount !== 'number' || !Number.isSafeInteger(entryCount) || entryCount < 0)) {
      throw new ManifestError(`artefacts[${index}].entryCount is not a non-negative safe integer`)
    }

    const publicRef = item['publicRef']
    if (publicRef !== undefined && (typeof publicRef !== 'string' || !PUBLIC_REF_SHAPE.test(publicRef))) {
      // Rejecting the wrong SHAPE is the control, not rejecting a wrong value: an 0x-prefixed
      // 40-hex string cannot be a secp256k1 private key, which is 64 hex. A manifest that put a key
      // here would fail this check before anything read it.
      throw new ManifestError(`artefacts[${index}].publicRef is not an 0x-prefixed 40-hex address`)
    }
    if (artefactKind === 'secrets' && publicRef === undefined) {
      throw new ManifestError(
        `artefacts[${index}] is a secrets artefact with no publicRef — without the address there is ` +
          `no way to prove a recovery without printing the key, which is not a way that exists`,
      )
    }

    return {
      kind: artefactKind as ArtefactKind,
      name: str(item, 'name'),
      // THE CHECK THAT MATTERS. Throws `UnsafePathError` on `..` or an absolute path.
      relPath: assertSafeRelPath(str(item, 'relPath')),
      bytes: BigInt(bytes),
      sha256,
      ...(entryCount === undefined ? {} : { entryCount: BigInt(entryCount) }),
      ...(publicRef === undefined ? {} : { publicRef }),
    }
  })

  const rawExcluded = source['excluded']
  const excluded: Exclusion[] = Array.isArray(rawExcluded)
    ? rawExcluded.map((entry, index) => {
        if (typeof entry !== 'object' || entry === null) throw new ManifestError(`excluded[${index}] is not an object`)
        const item = entry as Record<string, unknown>
        return { path: str(item, 'path'), reason: str(item, 'reason') }
      })
    : []

  // A manifest claiming the keyring is inside is either a forgery or the catastrophe itself. There
  // is no reading of `true` here under which continuing is correct.
  if (source['custodyKeyringIncluded'] !== false) {
    throw new ManifestError(
      `${MANIFEST_FILENAME} does not state custodyKeyringIncluded: false — refusing to touch this set`,
    )
  }

  return {
    manifestVersion: MANIFEST_VERSION,
    backupRunId: str(source, 'backupRunId'),
    environment: environment as Environment,
    composeProject: str(source, 'composeProject'),
    clusterSystemId: str(source, 'clusterSystemId'),
    kind: kind as BackupKind,
    tool: str(source, 'tool'),
    toolVersion: str(source, 'toolVersion'),
    pgServerVersion: str(source, 'pgServerVersion'),
    startedAt: str(source, 'startedAt'),
    finishedAt: str(source, 'finishedAt'),
    artefacts,
    excluded,
    custodyKeyringIncluded: false,
    warnings: Array.isArray(source['warnings'])
      ? source['warnings'].filter((entry): entry is string => typeof entry === 'string')
      : [],
  }
}

/**
 * Raised by the environment gate. Distinct from every other failure because it is not a failure:
 * it is the system working, and the restore is recorded `refused` rather than `failed`.
 */
export class EnvironmentMismatchError extends Error {
  readonly manifestEnvironment: string
  readonly runnerEnvironment: string

  constructor(manifestEnvironment: string, runnerEnvironment: string) {
    super(
      `REFUSED: that backup was taken in the ${manifestEnvironment} estate and this runner is the ` +
        `${runnerEnvironment} estate — a cross-environment restore destroys real balances. ` +
        `Nothing has been read or written.`,
    )
    this.name = 'EnvironmentMismatchError'
    this.manifestEnvironment = manifestEnvironment
    this.runnerEnvironment = runnerEnvironment
  }
}

/**
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **THE SECOND OF TWO INDEPENDENT ENVIRONMENT GATES.**
 *
 * The first is `restore_runs_environment_guard`, a trigger in `admin_api` (migration 10) that
 * compares `backup_runs.environment` against the immutable `estate_identity` row and refuses the
 * INSERT. This one compares the environment recorded INSIDE the artefact on disk against this
 * process's own `BACKUP_ENVIRONMENT`.
 *
 * They are not the same check twice. The trigger reads two database rows; this reads a file that
 * may have arrived from another host on a disk, in the cold-restore case where the database saying
 * what the backup is no longer exists. Either one can be bypassed by a route, a `psql`, or a
 * directory copied by hand — and the intersection cannot.
 *
 * Environment confusion has happened on this estate twice (migration 10's own comment: the seeder
 * ran `docker compose` against the mainnet project whatever the target parameter said). Both times
 * the defence that failed was a parameter. Neither side of this comparison is a parameter: one is
 * baked into the artefact when it was written, the other into this container when it was created.
 *
 * **This is checked BEFORE a single byte is read.** Not before writing — before reading. A
 * mainnet operator must not even be able to learn the shape of a testnet dump through this path,
 * and more practically, "we verified the checksums and then refused" is a sentence describing a
 * process that already opened the wrong set.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 */
export function assertEnvironmentMatches(manifestEnvironment: string, runnerEnvironment: string): void {
  if (manifestEnvironment !== runnerEnvironment) {
    throw new EnvironmentMismatchError(manifestEnvironment, runnerEnvironment)
  }
}
