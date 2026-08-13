/**
 * What address should miners dial — and, far more often, the refusal to answer that question.
 *
 * ══════════════════════════════════════════════════════════════════════════════════════════════
 * THE ASYMMETRY THIS FILE IS BUILT AROUND
 *
 * A NULL endpoint makes `pool-web` say "contact the administrator". A WRONG endpoint makes a miner
 * point firmware at a socket that refuses, retry hard, and blame the pool. The second is worse,
 * and it is the failure this service exists to prevent rather than the one it exists to fix.
 *
 * So every function here fails towards "I do not know". A reading that cannot be trusted leaves
 * the previous value in place and raises a metric; it never publishes a guess.
 */

/** A public IPv4 address, as observed and agreed. */
export type Observed =
  | { readonly kind: 'agreed'; readonly address: string }
  | { readonly kind: 'disagreed'; readonly saw: readonly string[] }
  | { readonly kind: 'unusable'; readonly address: string; readonly why: string }
  | { readonly kind: 'unreachable'; readonly errors: readonly string[] }

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/

/**
 * Is this an address the public internet can route to us on?
 *
 * ── WHY CGNAT IS REFUSED AND NOT MERELY NOTED ─────────────────────────────────────────────────
 *
 * `100.64.0.0/10` is carrier-grade NAT. A residential line behind it has a WAN address that is
 * NOT the address the internet sees, and no port-forward the owner configures on their own router
 * can make it reachable — the carrier's NAT is upstream of it. Publishing one produces exactly the
 * silent-failure shape above, and it is the single most likely wrong answer on a home connection,
 * so it is named rather than lumped in with "private".
 *
 * RFC1918 and loopback are refused for the obvious reason: they mean the resolver answered with
 * something local, which is a resolver that is not doing its job.
 */
export function usableAsPublicEndpoint(address: string): { ok: true } | { ok: false; why: string } {
  const m = IPV4.exec(address)
  if (!m) return { ok: false, why: 'not an IPv4 address' }
  const [a, b] = [Number(m[1]), Number(m[2])]
  if ([a, b, Number(m[3]), Number(m[4])].some((n) => Number.isNaN(n) || n > 255)) {
    return { ok: false, why: 'octet out of range' }
  }
  if (a === 10) return { ok: false, why: 'RFC1918 10/8 — a private address, not reachable from outside' }
  if (a === 172 && b >= 16 && b <= 31) return { ok: false, why: 'RFC1918 172.16/12 — private' }
  if (a === 192 && b === 168) return { ok: false, why: 'RFC1918 192.168/16 — private' }
  if (a === 127) return { ok: false, why: 'loopback — the resolver answered with our own address' }
  if (a === 169 && b === 254) return { ok: false, why: 'link-local — no DHCP lease' }
  if (a === 100 && b >= 64 && b <= 127) {
    return {
      ok: false,
      // The one worth spelling out, because it looks public and is not.
      why: 'CGNAT 100.64/10 — the carrier NATs this line, so no port-forward on your own router can make it reachable',
    }
  }
  if (a === 0 || a >= 224) return { ok: false, why: 'reserved range' }
  return { ok: true }
}

/**
 * Ask several independent resolvers and require them to agree.
 *
 * ── WHY A QUORUM, WHEN ONE ANSWER WOULD USUALLY DO ────────────────────────────────────────────
 *
 * A single resolver is a single point of *wrongness*, not merely of failure. If one of these
 * services is compromised, misconfigured, or returns a cached answer from another customer, the
 * consequence is not that this service stops — it is that the estate republishes a stranger's
 * address as its own mining endpoint and recreates the pool container to do it. Requiring two
 * independent hosts to say the same thing makes that take two simultaneous failures.
 *
 * Disagreement is NOT an error to retry through: it is a positive signal that something is wrong,
 * and it resolves to `disagreed`, which leaves the published value untouched.
 */
export async function observePublicAddress(
  resolvers: readonly string[],
  fetchText: (url: string) => Promise<string>,
  quorum = 2,
): Promise<Observed> {
  const answers: string[] = []
  const errors: string[] = []

  for (const url of resolvers) {
    try {
      const body = (await fetchText(url)).trim()
      if (body) answers.push(body)
    } catch (err) {
      errors.push(`${url}: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  if (answers.length < quorum) {
    return { kind: 'unreachable', errors: errors.length ? errors : ['too few resolvers answered'] }
  }

  const tally = new Map<string, number>()
  for (const a of answers) tally.set(a, (tally.get(a) ?? 0) + 1)
  const agreed = [...tally.entries()].find(([, n]) => n >= quorum)
  if (!agreed) return { kind: 'disagreed', saw: answers }

  const address = agreed[0]
  const usable = usableAsPublicEndpoint(address)
  if (!usable.ok) return { kind: 'unusable', address, why: usable.why }
  return { kind: 'agreed', address }
}

/**
 * Should the published value change, given what was observed and what is already published?
 *
 * Separated from the doing so the decision is testable without a filesystem or a container
 * runtime, and so that "no change" is a first-class outcome rather than an early return buried in
 * an effectful function. The overwhelmingly common case is `keep`, and it must cost nothing.
 */
export type Decision =
  | { readonly kind: 'keep' }
  | { readonly kind: 'publish'; readonly address: string; readonly previous: string | null }
  | { readonly kind: 'refuse'; readonly reason: string }

export function decide(observed: Observed, published: string | null): Decision {
  switch (observed.kind) {
    case 'agreed':
      return observed.address === published
        ? { kind: 'keep' }
        : { kind: 'publish', address: observed.address, previous: published }
    case 'disagreed':
      return { kind: 'refuse', reason: `resolvers disagreed: ${observed.saw.join(', ')}` }
    case 'unusable':
      return { kind: 'refuse', reason: `${observed.address} is not publishable — ${observed.why}` }
    case 'unreachable':
      return { kind: 'refuse', reason: `no quorum of resolvers answered: ${observed.errors.join('; ')}` }
  }
}
