/**
 * The one control this whole deployable is organised around: **the custody keyring is not here,
 * cannot get here, and the process refuses to run if it ever does.**
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * **WHY A GUARD AND NOT JUST AN ABSENCE.**
 *
 * `docs/custody-backup-restore.md` §1.5 states the property in one line: the encrypted vault (B)
 * and the key-encryption key (C) are useless apart and catastrophic together. A backup that puts
 * both on one medium "is not a backup with a key, it is a plaintext key store with extra steps —
 * anyone who finds that medium has the coins." §4.1 makes it a rule about media: the vault and the
 * keyring must never share a medium, a backup set, a cloud bucket or a filesystem.
 *
 * This process writes the vault. So the *only* way that rule is broken is if the keyring turns up
 * in this process's environment — which needs no code change at all, just one `env_file:` line in
 * a compose file added by somebody who wanted the runner to "be able to check the keys work".
 * That edit is plausible, looks helpful, and would silently convert every backup from ciphertext
 * into spendable coins. There is nothing in the source for a reviewer to notice, because the
 * defect is in the deploy.
 *
 * So the refusal lives at boot, in the process that would be holding both halves, and it fails
 * closed: the runner will not start. A container that will not boot is a compose-file bug; a
 * container that boots and writes a plaintext key store is the end of the platform.
 *
 * **NOTHING IN THIS MODULE PRINTS A VALUE.** It reports variable NAMES and a count, exactly as
 * §7 requires (`cut -d= -f1`, names only). §7.1 is the record of what happens otherwise: on
 * 2026-08-05 three of the estate's four keyrings had to be rotated because their values were
 * *printed* into agent transcripts. A guard that logged what it caught would be the same defect
 * with a compliance label on it.
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 *
 * There is deliberately no function here that READS a keyring, no path that points at
 * `compose/secrets/`, and no manifest field that could ever say a keyring was included —
 * `custodyKeyringIncluded: false` is a literal in `manifest.ts`, not a computed value, because a
 * computed value is a value that can compute to `true`.
 */

/**
 * The shape §1.3 says the keyring is assembled by scanning for: `CUSTODY_MASTER_SECRET_V<n>`,
 * matched by pattern rather than by name (`custody/src/env.ts:256`). Matched the same way here so
 * that a rotation to V4 does not quietly slip past a hard-coded list of V1–V3.
 */
const KEYRING_VARIABLE = /^CUSTODY_MASTER_SECRET_V[0-9]+$/

/**
 * Anything that is a key by another name. `MINER_COINBASE_*` is here because
 * `docs/custody-backup-restore.md` §4.2 step 6 records that the miner coinbase keys are
 * **plaintext, unencrypted and unrotatable** — they are in the same position as the keyring and
 * are covered by no procedure but paper.
 */
const ADJACENT_SECRET_VARIABLE = /^(CUSTODY_MASTER_SECRET|CUSTODY_KEYRING|MINER_COINBASE_KEY)/

export class KeyringPresentError extends Error {
  /** Variable NAMES only. Never a value, at any level of this class. */
  readonly variables: readonly string[]

  constructor(variables: readonly string[]) {
    super(
      `REFUSING TO START: ${variables.length} custody key-material variable(s) are in this ` +
        `process's environment (${variables.join(', ')}). This process writes the custody VAULT. ` +
        `The vault and the keyring must never share a process, a medium or a backup set — see ` +
        `docs/custody-backup-restore.md §1.5 and §4.1. Remove the env_file/environment entry from ` +
        `the backup-runner service; do not weaken this check.`,
    )
    this.name = 'KeyringPresentError'
    this.variables = variables
  }
}

/** Names, sorted, of every key-material variable visible to this process. Never values. */
export function keyringVariablesIn(source: Readonly<Record<string, string | undefined>>): string[] {
  return Object.keys(source)
    .filter((name) => KEYRING_VARIABLE.test(name) || ADJACENT_SECRET_VARIABLE.test(name))
    .sort()
}

/**
 * Called first in `index.ts`, before a pool is opened or a job is claimed.
 *
 * Throws rather than returning a boolean: a caller that can ignore the result is a caller that
 * will, and this is the one check in the repository whose failure mode is unrecoverable.
 */
export function assertNoKeyring(source: Readonly<Record<string, string | undefined>> = process.env): void {
  const found = keyringVariablesIn(source)
  if (found.length > 0) throw new KeyringPresentError(found)
}

/**
 * Filenames that must never be inside a tarball this process writes.
 *
 * The archiver walks a mounted directory, and a mount is whatever the deploy points it at. If a
 * `.env` or a `secrets/` directory is ever inside one of those paths, the tarball would carry the
 * keyring into the same backup set as the vault — the exact adjacency §4.1 forbids. The archiver
 * refuses the whole artefact rather than skipping the file, because a backup missing files nobody
 * asked it to skip is a backup whose contents nobody can state.
 */
export const FORBIDDEN_ARCHIVE_ENTRY = /(^|\/)(\.env(\..*)?|secrets|.*\.env|.*\.gpg|id_rsa|id_ed25519)$/i
