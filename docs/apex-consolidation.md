# Consolidating the product surfaces onto the apex

CloudsForge serves twenty-one public hostnames. Fourteen of them are content —
pages a stranger could arrive on from a search result — and each one is a
separate site as far as a search engine is concerned. This plan moves those
fourteen onto paths under `cloudsforge.online`, and argues for the seven that
stay where they are.

It is written the way `kubernetes-migration.md` was: the decision first, then
the reasoning, then the order of operations, then what proves each step
happened. Nothing here is speculative about the estate's shape — every router,
priority, registry field and check named below was read out of the tree on
2026-08-19, and the two live measurements are quoted with the command that
produced them.

> **Status.** Wave 1 (`journal`) is the only wave with a written step list.
> That is deliberate — see [The wave order](#the-wave-order-and-what-decides-it).
> Waves 2 and 3 get their step lists after wave 1 has been through a real
> deploy, because the point of doing `journal` alone is to find out what this
> plan gets wrong while the cost of being wrong is an archive nobody has
> bookmarked yet.

---

## 1. The decision

### Moving to a path under the apex

| Today | Becomes | Why |
| --- | --- | --- |
| `journal.<apex>` | `/journal` | Pure content, no service, no session. The whole reason the estate has an SEO problem, and the cheapest place to prove the fix. |
| `exchange.<apex>` | `/exchange` | Calls `rpc.<apex>` and nothing of its own. |
| `developers.<apex>` | `/developers` | The developer platform console. **Not documentation** — this row said so and it was wrong; `cf-api-developers` serves 35 `/v1` handlers from `micro-devplatform` on this hostname, which is why it is wave 3 and not wave 2. See §5. |
| `market.<apex>` | `/market` | |
| `create.<apex>` | `/create` | |
| `trade.<apex>` | `/trade` | |
| `worlds.<apex>` | `/worlds` | |
| `emberkin.<apex>` | `/worlds/emberkin` | A game inside Worlds, and the path can say so where a subdomain cannot. |
| `aetherholm.<apex>` | `/worlds/aetherholm` | |
| `tessera.<apex>` | `/worlds/tessera` | |
| `explorer.<apex>` | `/explorer` | |
| `pool.<apex>` | `/pool` | |
| `foresight.<apex>` | `/foresight` | |
| `agora.<apex>` | `/agora` | |

### Staying on their own hostname

| Surface | Why it is not moving |
| --- | --- |
| `hub.<apex>` | **Origin isolation.** Hub holds the wallet, the account and the session that can move money. Everything on one origin means a scripting defect on any marketing page is a scripting defect in the wallet's origin, and `SameSite` stops distinguishing between them. This overrides the SEO argument outright, and it is the only entry in this table where the two arguments point in opposite directions. |
| `admin.<apex>` | A different audience and a different blast radius. On its own hostname it can be blocked at the edge by name; on a path it can only be blocked by a rule that a later router reorder can silently outrank. |
| `status.<apex>` | Must answer when the estate does not. A status page that shares an origin with the thing it reports on cannot report the interesting outage. |
| `nimbus.<apex>` | Identity. An auth origin is a security boundary. |
| `api.<apex>` | Third-party contract. It is the address in the SDK and in somebody else's code. |
| `rpc.<apex>`, `p2p.<apex>` | Chain endpoints, rate-limited by hostname, called by machines. |
| `lantern.<apex>`, `beacon.<apex>`, `vault.<apex>`, `pay.<apex>`, `studio.<apex>` | Operator and service surfaces. No search value to consolidate, and each one is a path collision waiting to happen. |
| `www.<apex>`, `testnet.<apex>`, `*-testnet.<apex>` | Already redirects. Nothing to do. |

### The three rules the split follows

Read the two tables against each other and the boundary is not "which pages are
important" — it is these, in order:

1. **A surface that carries the money session keeps its own origin.** One
   entry, and it is `hub`. This rule wins over the other two.
2. **A surface a machine calls keeps its own hostname.** An address in an SDK,
   in a mining rig's config, in somebody's cron — moving it is a breaking change
   dressed as an SEO improvement.
3. **Everything else is content, and content belongs on one origin.** Fourteen
   entries.

---

## 2. What consolidation actually buys, and what it costs

**The gain is not a ranking trick.** Search engines evaluate authority per
origin, and `journal.cloudsforge.online` shares none of it with
`cloudsforge.online`. Fourteen origins means fourteen sites each starting from
nothing, each needing its own inbound links, each in its own Search Console
property. One origin means an article that earns a link makes the product pages
stronger, and a product page that earns a link makes the articles stronger.
That is the whole argument and it does not need to be dressed up further.

**The usability gain is smaller but real, and it is about typing.** `pool` and
`explorer` and `market` are guessable as paths in a way they are not as
hostnames: a reader who has seen `cloudsforge.online/journal` can find
`cloudsforge.online/explorer` without being told it exists. A reader who has
seen `journal.cloudsforge.online` learns nothing transferable.

**Three costs, and none of them go away:**

- **Every moved bundle acquires a base path.** It is not free — see
  [decision 1](#decision-1-the-base-path-is-baked-at-build-time).
- **Fourteen permanent redirects, which are never cleaned up.** A 301 that has
  been served for two years is still the only thing standing between an old
  link and a 404. "Remove the redirects once traffic drops" is the sentence that
  breaks them; there is no later date at which the old address stops being in
  somebody's bookmarks. They are permanent configuration.
- **Router ordering gets harder.** `estate-web.yml` is 3,318 lines, 67 routers,
  and the file's own header argues that each rule came from an incident. Adding
  fourteen path-qualified routers to one host makes the priority column
  load-bearing where it currently is not. Mitigated by
  [decision 3](#decision-3-the-path-routers-sit-at-600) and by a new check.

---

## 3. The mechanism already exists

`ui/packages/ui/src/surfaces.ts` is the estate's single registry of what
CloudsForge serves, and it already has the field this whole plan needs:

```ts
  /**
   * Set when this surface is a ROUTE on another surface's host rather than a host of its own —
   * `subdomain` and `devPort` then name the host it lives on, and the URL is that origin plus
   * this path.
   */
  readonly basePath?: string
```

Three rows use it today — `wallet` and `signin` inside Hub, `faucet` inside the
Network site — and every URL in the estate is composed from it in one line
(`ui/packages/ui/src/index.tsx:283`):

```ts
    SURFACES.map((s) => [s.key, `${origin(s)}${s.basePath ?? ''}`]),
```

**So the link half of this migration is one registry edit per surface.** Every
footer, every product switcher, every cross-surface link in every frontend
reads `cloudsforgeHosts()` and re-points itself. There is no sweep for
hardcoded hostnames, because the estate already refuses to have any — that is
what `surface-routes.py` exists to enforce.

**That is true of SOURCE and it is not true of TEST FIXTURES**, which nothing
enforces, and wave 2 proved it: `micro-hub-web`'s `main` went red without hub-web
changing at all. Two assertions in `test/convert.test.ts` read
`'https://exchange.cloudsforge.online'` as a literal — under a comment that said
"Composed, never typed":

```ts
    // The hostname comes from the registry row's `subdomain: 'exchange'` … Composed, never typed
    assert.equal(link.getAttribute('href'), 'https://exchange.cloudsforge.online')
```

The link had correctly become `https://cloudsforge.online/exchange`. Fixed by
deriving the address from the registry (`micro-hub-web#50`), which is what the
comment always claimed was happening.

**Expect one of these per moved surface, in some sibling repository**, and expect
to find it only when that sibling's `main` goes red after the merge. Two things
follow for wave 3:

- **grep the estate for the hostname before moving a surface**, not after —
  `grep -rn '<sub>\.cloudsforge\.online' */test */src` across every checkout.
  The source hits will be zero; the fixture hits are the work.
- a red sibling is the GOOD outcome here. The bad one is a fixture that asserts
  something weaker — a substring, a `toContain` — and keeps passing against an
  address that no longer exists.

What does *not* come free is the bundle: a page served at `/journal` must know
it is at `/journal` to write its own asset URLs, its router basename, its
canonical tags and its sitemap. That is the actual work, and it is the subject
of the next section.

---

## 4. Five decisions

### Decision 1: the base path is baked at build time

The obvious alternative is a Traefik `StripPrefix` middleware: route
`/journal/*` to the container with the prefix removed, and the image never
learns where it is mounted. **It does not work, for a reason that is invisible
until the page is live.**

Vite emits code-split chunks whose import paths are resolved against the
build-time `base`. With `base: '/'` a lazily-imported chunk is fetched from
`/assets/chunk-abc123.js` — an absolute path, written inside a JavaScript file.
Strip the prefix at the gateway and that request goes to `/assets/…` at the
apex, which is *the marketing site's* router, which answers 404 (or worse,
HTML). The first page loads perfectly; the first route transition fails with a
module-resolution error naming a file that does exist, one origin away.
`sub_filter` cannot fix it — nginx's substitution runs on response bodies, and
adding `application/javascript` to `sub_filter_types` means rewriting bundle
contents on every request.

`base: './'` (relative) fails differently: the prerender writes files at four
different depths (`/`, `/about`, `/a/<slug>/`, `/topics/<slug>/`), and Vite
only rewrites `index.html`. The deeper pages would resolve `./assets/` against
their own directory.

So the mount point is baked in, and **that is not the same mistake as baking in
the origin**, which this repository has an entire `vite.config.ts` header
refusing. The origin is a property of the *environment* — the same artefact is
promoted across localhost, testnet and mainnet, and baking it in means the
image that reaches production is not the image that passed CI. The base path is
a property of the *product*: `/journal` is where Forge Journal lives on every
environment, forever, including on a laptop. An artefact may know that.

The invariant that keeps it honest: **the registry's `basePath` and the
bundle's Vite `base` must be the same string**, and a test asserts it rather
than a comment asking for it. See [section 7](#7-what-ci-must-learn).

### Decision 2: the redirect is 301, and it is permanent configuration

`redirectRegex` with `permanent: true`, matching the pattern `cf-www-to-apex`
already sets:

```yaml
    cf-journal-to-apex:
      redirectRegex:
        regex: '^https?://journal\.cloudsforge\.online/(.*)'
        replacement: 'https://cloudsforge.online/journal/$${1}'
        permanent: true
```

301 rather than 302 because a 301 is what transfers accumulated authority to
the new address; a 302 tells a crawler the old address is still the real one,
which would leave the estate with the split it is trying to end plus an extra
hop. The retirement redirects for `*-testnet` use 302 deliberately and for the
opposite reason — those hostnames are *expected back* if the testnet frontends
ever return.

The old hostname keeps its DNS record and its router indefinitely. This is
written down here so that a future sweep of "unused routers" reads the reason
before deleting one.

### Decision 3: the path routers sit at 600

`estate-web.yml` already has a priority convention and this follows it rather
than inventing one:

| Band | What lives there |
| --- | --- |
| 500 | A bundle claiming a whole host — `cf-web-site`, `cf-web-journal` today |
| 550 | The retirement redirects — host-wide, but must lose to `/v1` |
| 600 | **Host + path** — every `&& PathPrefix('/v1')` router in the file |

A consolidated surface is a host-plus-path router, so it is 600. Nothing on the
apex currently sits above 500, so there is no contention today; the number is
chosen to match the convention rather than to resolve a conflict, because the
conflict arrives at wave 3 when fourteen of them share one host.

**The ordering hazard is `/worlds` against `/worlds/emberkin`.** Traefik
evaluates by priority and then by rule length, and two routers at the same
explicit priority whose prefixes nest is exactly the case where "it worked when
I tested it" and "it is correct" come apart. The three game surfaces therefore
get **610**, above their parent, and the check in
[section 7](#7-what-ci-must-learn) fails any pair of nested prefixes whose
priorities do not order longest-first.

### Decision 4: a surface with an API remounts it under its own path, and the gateway strips it back off

**TWELVE** of the fourteen have a co-hosted service — not eleven, and not all of
them under `/v1`; see §5 for the corrected count and for why `foresight` is the
one that matters. Those bundles issue *relative* requests, which is what lets
them not know their own hostname. Move the bundle to `/market` and a relative
`/v1/titles` still resolves to `/v1/titles` at the apex root, which routes
nowhere.

So each such surface's API moves with it, to `/<surface>/v1`, and the bundle's
fetch base becomes its own base path.

**The service does not change, and the first draft of this decision said it
would.** It said the move was "a change in the *service* repo's consumers, not
just the frontend". It is not, because the gateway can put the prefix back:

```yaml
    cf-api-strip-market:
      stripPrefix:
        prefixes: ["/market"]
```

The router matches `Host(apex) && PathPrefix('/market/v1')`, the middleware
removes `/market`, and `cf-svc-market` receives exactly the `/v1/titles` it
receives today. **The estate already does this** — `gateway/dynamic/public-api.yml`
carries `cf-api-strip-version` for the four services that do not serve `/v1`
themselves, with the argument written out: changing the services "would mean
editing four shipped, CI-green services and breaking every internal caller; so
the gateway presents one versioned surface and strips the prefix". The same
argument applies here and reaches the same answer.

So decision 4 costs, per surface: **one router, one middleware, and one line in
the frontend's API base.** Not a service change, not a consumer change.

**What must be checked per service before relying on it**, because stripPrefix
is invisible to the service and therefore invisible in its responses:

| Risk | Why it breaks | Where to look |
| --- | --- | --- |
| a `Location:` header | the service builds it from the path it *sees*, which no longer has the prefix — so a 201 or a 302 points at `/v1/…` on the apex root | any `reply.redirect` / `Location` |
| `Set-Cookie` with a `Path` | a cookie scoped `Path=/v1` is not sent back with a request to `/market/v1` | any `setCookie` with a path |
| absolute URLs in a JSON body | pagination links, HATEOAS, an asset URL composed server-side | any response field holding a path |

The bundle half is unaffected: decision 1 refused `StripPrefix` for the BUNDLE
because a bundle emits self-referential asset URLs and the browser resolves them
against the origin. **An API returns JSON**, which has no equivalent — except in
the three rows above, which is why they are enumerated rather than waved at.

**Audited, 2026-08-19, across all twelve services** — `market`, `mint`, `trade`,
`worlds`, `emberkin`, `aetherholm`, `tessera`, `indexer` (which serves the
`explorer` surface), `pool`, `foresight`, `agora`, `devplatform`:

```console
$ # per service: redirects, cookies with a Path, rooted paths in a response field
$ grep -rlE '\.redirect\(|header\(.location' <svc>/src        →  0 files, every service
$ grep -rlE 'setCookie|Set-Cookie'              <svc>/src        →  0 files, every service
$ grep -rnE "(url|href|link|next|self)\s*:\s*[\`'\"]/" <svc>/src  →  0 matches, every service
```

Zero on all three, twelve for twelve. These services answer JSON built from their
own database rows and nothing else — no service in the estate composes a URL for
a caller, which is the same property that let `public-api.yml` present a
different path layout than any of them serve.

**The audit is the load-bearing part of this decision, not the middleware.**
`stripPrefix` is invisible to the service: it cannot fail loudly, and a service
that did compose an absolute path would keep answering 200 while handing the
browser an address on the apex root. Re-run the three greps before adding a
thirteenth surface to this mechanism.

### Decision 5: the surface keeps `viewsAnyNetwork`, and a registry invariant was wrong

**This decision was reversed while wave 1 was being built. The first version of
this section argued the opposite — that a surface moving to the apex gives up
the flag — and it is written up here as a reversal rather than quietly replaced,
because the reasoning that produced the wrong answer is the reasoning a later
wave will reach for again.**

The registry's `viewsAnyNetwork: true` marks a bundle that can show the other
network's data in place. `journal` has it, and the reason is quoted in
`policy.yml`: without it, pressing Testnet on an article throws the reader out
of the piece and onto Forge Network.

Two invariants in `ui/packages/ui/src/network-view.test.ts` appeared to refuse
to let `journal` keep the flag once it had a `basePath`:

```ts
    const bundles = SURFACES.filter((s) => s.servesUi && !s.basePath).map((s) => s.key)
    assert.deepEqual(VIEWING_SURFACES.map((s) => s.key), bundles)
    …
    const subs = VIEWING_SURFACES.map((s) => s.subdomain)
    assert.equal(new Set(subs).size, subs.length)
```

The mistake was reading those as constraints on the migration. They are
constraints on the registry, and both were written when **every** `basePath` row
was a route inside somebody else's bundle — `wallet` and `signin` inside Forge
Hub, `faucet` on the Network site. Under that assumption `!s.basePath` and
"serves a bundle of its own" select the same set, and `subdomain` is a unique
name for a bundle. `journal` is the first row where the two come apart, and the
tests were measuring the available proxy rather than the property.

**What each one is actually about:**

- `!s.basePath` meant *serves a bundle of its own*. That is now a function,
  `servesOwnBundle()`, and it discriminates on the **dev port**: a row whose
  `devPort` no other row shares is its own bundle, and a row that shares one is
  a route inside the bundle it shares it with. Exact rather than heuristic,
  because `surfaces.test.ts` already asserts that two surfaces share a dev port
  only by deliberate `CO_HOSTED` declaration.
- unique `subdomain` meant *no bundle is flagged twice*. Two viewers may now
  legitimately share an origin — `site` and `journal` both serve from
  `cloudsforge.online` — and the CORS grant, being a list of origins, dedupes
  them. What must stay unique is the **bundle**, so the assertion is now over
  `devPort`.

Had the flag come off instead, the loss would not have been the CORS entry — the
apex is already in the grant and would have subsumed it — but the fact that
`VIEWING_SURFACES` is what micro-deploy's checks read to know a bundle owes a
`src/lib/viewed.ts`. Dropping `journal` from that list would have silently
dropped the check that its in-place switching exists, on the one surface in the
estate that had just been rebuilt. The proxy would have failed open.

Restated for the later waves: **moving a surface to the apex changes nothing
about `viewsAnyNetwork`.** Its `policy.yml` same-environment origin still goes,
because that origin has genuinely ceased to exist; its cross-environment view
grant goes too, and is subsumed by the apex's. Thirteen more times.

**The general lesson, which is why this reversal is worth six paragraphs:** a
test that has never been able to distinguish two properties is not evidence
about which one it enforces. Both of these had been green for months and both
were wrong in the same direction, because until 2026-08-19 the estate had no
surface that could tell them apart.

---

## 5. The wave order, and what decides it

Not "highest SEO value first". The ordering test is **does this surface have an
API on its own hostname** — because that is the difference between a bundle
change and a bundle-plus-API change, and doing the second kind before the first
kind has ever been deployed means debugging two new things at once.

**The test was first written as "a `/v1` router", and that was wrong.** Read the
router's UPSTREAM instead — `service: cf-svc-*` — which is the discriminator
`surface-routes.py` already uses and for the same reason. Two surfaces pass a
`/v1` test and fail the real one:

| Surface | Its API on its own host | What a `/v1` test would have said |
| --- | --- | --- |
| `foresight` | `/ideas`, `/categories`, `/image-config`, `/stake-assets`, `/me`, `/markets` | "no API" |
| `pool`, `agora` | `/v1`, plus `/livez` and `/readyz` at the root | "one prefix to move" |

`foresight` is the one that matters. Its six prefixes are **unversioned and at
the root**, so mounting that surface at `/foresight` without moving them would
put `/me` and `/markets` on the apex — names the marketing site could plausibly
want, answered by a prediction-market service. It is the hardest surface in the
estate to move and a `/v1` test called it the easiest.

| Wave | Surfaces | Why |
| --- | --- | --- |
| **1** | `journal` | No service, no API router, no session, no chain data. `micro-journal` does not exist and the container's own nginx.conf says it never will. If the base-path pattern is wrong, the cost is an archive that 404s for an hour. |
| **2** | `exchange`, alone | The ONLY other surface with no API on its own hostname — an AMM's whole state is four numbers in a pair contract, and the bundle reads them from `rpc.<apex>` cross-origin. Proves the pattern once more, on a surface that has a session and chain data where the journal had neither, before any API moves. |
| **3** | the remaining twelve | Each needs decision 4 applied. `worlds` + its three games go as one unit, because the nesting is the point; `foresight` wants its own attention for the reason above. |

**Wave 2 was planned as `exchange` + `developers` and `developers` was moved
out.** It has `cf-api-developers` on `developers.<apex>` serving 35 handlers from
`micro-devplatform` — it is the developer platform console, not a docs site, and
the plan called it "docs". Checking that claim against the router table is what
produced the corrected test above.

Each wave is its own branch, its own PR and its own release. There is no wave
that ships a moved surface on a pattern the estate has not seen work.

---

## 6. Wave 1 — `journal` → `/journal`

### 6.1 What changes, by repository

**`micro-journal-web`** — the bundle learns its mount point:

| File | Change |
| --- | --- |
| `vite.config.ts` | `base: '/journal/'`. Serves at `localhost:5196/journal` in dev too, which is what makes the registry row below true locally. |
| `src/app.tsx` | `<BrowserRouter basename="/journal">`. |
| `scripts/prerender.ts` | Renders through `StaticRouter basename`. **`dist/` stays flat** — see below. |
| `Dockerfile` | `COPY --from=build /app/dist /usr/share/nginx/html/journal`. |
| `src/lib/meta.ts`, `heads.ts`, `syndication.ts` | The one place that composes `` `${origin}${PATH}` `` becomes `` `${origin}${BASE}${PATH}` ``. This covers the canonical, `og:url`, the JSON-LD `@id`, the RSS channel and self links, and every `<loc>` in the sitemap — they are all built from that expression. |
| `nginx.conf` | Every `location` gains the prefix; `location = /healthz` does **not** (the container probe is not a public address and must stay at the root the Deployment's probe names). `error_page 404 /journal/404.html`. |
| `test/seo.test.ts` | Asserts no built file names a cloudsforge hostname — unchanged and still valuable. Gains: every absolute URL it finds begins `__CF_ORIGIN__/journal`. |
| `test/routes.test.ts` | Already asserts `/index.html` is absent from the `try_files` chain. Gains the prefix. |

**Where the prefix is applied, revised during the build.** The plan said the
prerenderer would write into `dist/journal/…`. It writes a flat `dist/` and the
**Dockerfile** puts it under the prefix, `COPY … /app/dist
/usr/share/nginx/html/journal`. One place instead of two, and the better half of
the trade is what it does to the tests: `dist/a/<slug>/index.html` is still where
the prerenderer's own tests look for an article, so they kept asserting the thing
they were written to assert rather than being re-pointed at a path whose only
purpose is deployment. The mount is nginx's business, and the image is where
nginx's business starts.

**Vite rewrites `base` into some asset references and not others**, and the line
between them is worth measuring rather than assuming — the first draft of this
paragraph drew it in the wrong place. Measured on the wave-2 build:

| Reference | Rewritten? |
| --- | --- |
| module-graph imports — the entry `<script>`, the CSS it pulls in, an `import`ed image | ✅ |
| `/`-rooted URLs in `index.html` attributes — `href`, `src`, **and `content` on `og:image`** | ✅ |
| a path composed at runtime in JS (`'/' + name`) | ❌ |
| a path written inside a file in `public/` — Vite copies those verbatim | ❌ |

The plan originally claimed the second row was NOT rewritten, and that every
favicon and og card in `index.html` would point at the apex root. They do not:
`content="/og-1200x630.png"` came out of the build as
`content="/exchange/og-1200x630.png"`. The claim was reasoned from "Vite only
sees the module graph" and never checked against a build.

What survives the correction is the reason to care. The two ❌ rows are real, they
fail exactly as described — an HTML 404 served where a PNG was expected — and
nothing in the build reports them. That is why `nginx.conf` carries a `location`
for the favicons and the og cards specifically, and why `brand-chrome.test.ts`
reads the BUILT HTML rather than the source.

**`isRegisteredPlacement()` had quietly become a tautology, and the move is what
exposed it.** The function warns when a bundle is served from an address the
registry does not know — a preview deployment, somebody's tunnel — because that
is exactly the placement where nginx never ran the `__CF_ORIGIN__` substitution
and a canonical tag may still carry a literal placeholder. It compared
`new URL(estate.journal).origin` against the page's origin. That worked while
`journal` was a hostname. It cannot fail once `journal` is the apex: the origin
the registry composes is derived, by `cloudsforgeHosts()`, from the page's own
hostname — so a preview deployment at `pr-42.example.dev` is its own apex, and
the comparison is a value against itself. **Every unregistered placement in
existence would have answered "registered."**

It now compares the whole base URL, because the *path* is what still carries
information: a correctly-placed bundle is served at or beneath `/journal`,
whatever its hostname, since that is what `base` baked into every asset href.
`=== base || startsWith(base + '/')`, for the same reason the gateway rule takes
that shape. This is the third distinct place in wave 1 where `/journalism` had to
be excluded by hand — worth noticing as a pattern rather than three coincidences.

**`micro-ui`** — one registry row:

```ts
    key: 'journal',
    subdomain: '',            // was 'journal'
    devPort: 5196,            // unchanged — this surface has always named its own dev server
    basePath: '/journal',     // new
    viewsAnyNetwork: true,    // KEPT. See decision 5, which reversed on this.
```

…and one new export, `servesOwnBundle()`, which is decision 5's replacement for
the `!s.basePath` proxy and is now what four invariants and both new micro-deploy
checks discriminate on.

One consequence worth naming because it is silent: `KNOWN_SUBS` is derived from
`SURFACES.map((s) => s.subdomain).filter(Boolean)`, so **`journal` leaves the
set of prefixes `cloudsforgeHosts()` strips to find the apex**. A bundle
running on `journal.cloudsforge.online` would from then on treat that whole
name as its apex and compose every sibling as `hub.journal.cloudsforge.online`.
No bundle ever runs there again — the hostname serves a 301 and nothing else —
but the same removal happens thirteen more times, and on a surface whose
retirement is less total it would be the defect rather than the footnote.

`subdomain: ''` is the apex. `devPort` stays 5196 rather than becoming the
site's 3000, because Vite's `base` makes the journal's own dev server answer at
`/journal` — so `http://localhost:5196/journal` is both what the registry
composes and what actually serves. This is a departure from how `wallet` and
`faucet` read (they name their host's port) and it is the better shape: the
port and the path together name something that answers.

**`micro-deploy`** — the gateway:

- `cf-web-journal` becomes
  ``Host(apex) && (Path(`/journal`) || PathPrefix(`/journal/`))`` at priority
  600, service unchanged — **not** a bare `PathPrefix`; see the measurement
  below.
- It is wrapped in `{{ if ne (env "CF_WEB_RETIRED") "true" }}`, so the router
  exists on mainnet and not on testnet. The gate is `ne`, not `not`: `env`
  returns a **string**, and `"false"` is truthy to a Go template, so `not (env
  …)` would delete the router from mainnet as well. The apex mount is
  meaningless on testnet, where the apex itself is a 302 to mainnet.
- A new `cf-journal-to-apex` redirect middleware, and `cf-web-journal-sub` — a
  tombstone router for `journal.<apex>` at 500 carrying it.
- `gateway/dynamic/policy.yml`: delete **both** journal origins — the
  same-environment `https://journal{{ env "CF_WEB_SUFFIX" }}` and the
  cross-environment `https://journal{{ env "CF_VIEW_ORIGIN_SUFFIX" }}` (decision
  5). The first is replaced by
  `https://{{ env "CF_SITE_HOST" }}`, which is **already on the list** at
  line 122 — so the account-bar handoff that line exists to protect keeps
  working, and `surface-routes.py` check 5 will fail the build if the stale
  entry is left behind. The check does this work; it does not have to be
  remembered.
- `scripts/estate-verify.sh`: four changes, and one of them is new work rather
  than an edit.
  - the provenance loop's records gain a **third field**, the path, because a
    surface is no longer always a hostname: `". journal-web /journal"`.
  - the RUM-sink loop and the sign-in hand-off loop stop naming
    `journal$WEB_SUFFIX` and name the apex. Both lists shrink by one, which is
    the move and not a loss.
  - **a new section that measures where the old hostname sends a reader**, since
    nothing else in the run would. It is environment-aware: mainnet expects
    `301 → https://<apex>/journal/…`, testnet expects `302 →
    https://journal.cloudsforge.online/…` because `cf-retired-web-sub` at
    priority 550 outranks the tombstone at 500 and answers first. Three paths
    are checked — an article, `/feed.xml`, and `/` — because the redirect must
    **preserve the path**, and a rule that dropped it would send every deep link
    to the front page while still answering 301.

  The last one has a deliberate skip. On the testnet gateway off port 443,
  `cf-retired-sub-to-mainnet`'s regex is anchored on `cloudsforge.online/` with
  no port tolerance, so it cannot match and there is nothing to measure. Rather
  than pass silently, the script says so and falls back to asserting that
  `surface-routes.py` check 13 still names the middleware — a static claim where
  a live one is impossible, which is weaker but is at least honest about which
  one it made.

**Traefik's `PathPrefix` is a raw string prefix, and this was measured rather
than assumed.** Twice, on this estate's own gateway at version 3.2.3:

| Rule | `/journal` | `/journal/` | `/journal/a/x` | `/journal/feed.xml` | `/journalism` | `/journalism/x` | `/journal-testnet` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ``PathPrefix(`/journal`)`` | ✅ | ✅ | ✅ | ✅ | **✅** | **✅** | **✅** |
| ``Path(`/journal`) \|\| PathPrefix(`/journal/`)`` | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |

The bare form does not match path *segments*; it matches *characters*. Nothing
called `/journalism` exists on the apex today, which is exactly why this needs
writing down: the rule is wrong now and harmless now, and the harm arrives with
some later page whose name happens to start with an existing mount. The
alternation is the only form used, and `check-base-paths-agree.py` rejects the
other.

The Kubernetes side needs **no manifest change**. `k8s/gateway/60-gateway.yaml`
runs the same Traefik over the same `gateway/dynamic/*.yml` files, mounted from
a ConfigMap that `k8s-gateway.sh` builds from the tree —
`check-k8s-gateway-matches-compose.py` is what keeps that true. Editing
`estate-web.yml` is editing the cluster's gateway.

### 6.2 The order on the day

1. Merge the three repos' PRs and cut a release. **The bundle is now built for
   `/journal` and is being served at `journal.<apex>`, where it is broken** —
   its assets are at `/journal/assets/…` and the host serves them at
   `/assets/…`. This window is the reason wave 1 is the journal: the surface is
   an archive with no session and no money in it.
2. Deploy the gateway change in the same release. The window closes when
   Traefik reloads, which `k8s-gateway.sh` does as part of the deploy.
3. Verify, in this order, with the old address last:

   ```sh
   curl -sI https://cloudsforge.online/journal/            # 200, text/html
   curl -s  https://cloudsforge.online/journal/sitemap.xml | grep -c '<loc>'
   curl -s  https://cloudsforge.online/journal/ | grep -o 'canonical[^>]*'
   curl -sI https://journal.cloudsforge.online/a/how-crypto-actually-works
   #  ^ must be 301 to https://cloudsforge.online/journal/a/how-crypto-actually-works
   ```

   The canonical is the one that matters. It is written as `__CF_ORIGIN__` and
   filled in by nginx per request, so it will say `https://cloudsforge.online`
   — and if the prefix is missing from it, every article tells search engines
   the real copy lives at an address that redirects, which is the failure the
   journal's own `nginx.conf` header spends four paragraphs warning about.
4. `./scripts/k8s-estate-verify.sh` — mainnet baseline is **3** failures
   (two pre-existing, one verifier race). Anything above that is this change.
5. Submit `https://cloudsforge.online/sitemap.xml` in Search Console and leave
   the `journal.<apex>` property in place. A removed property loses the
   redirect's reporting.

### 6.3 Two SEO artefacts that only exist at an origin root

**`robots.txt` is read at `/robots.txt` and nowhere else.** The journal's own
`robots.txt` — the one that serves `Disallow: /` on every non-mainnet hostname
— stops being reachable the moment the archive is a path. That is not a loss:
**the rule it enforces becomes unnecessary.** It exists because the same
articles were served on `journal-testnet.<apex>`, and two identical archives at
two addresses is textbook duplicate content. On the apex there is no second
copy — `testnet.cloudsforge.online` is already a 302 to mainnet. The
consolidation *deletes* the problem rather than relocating the mitigation.

**Revised while building: the file was deleted, not kept.** The plan said it
would stay in the container unreachable, for the reason its own comment gave —
that it keeps a `localtest.me` build and a laptop correct by construction. That
argument stops holding the moment the mount moves: at `/journal/robots.txt` no
crawler reads it on any host, laptop included, so what would have been preserved
is a file that is correct and never consulted. An unreachable config file is not
a safety net, it is a thing a future reader will find, believe, and reason
from — and the belief it invites is that the journal still controls its own
indexing policy, which it no longer does. The apex's `robots.txt` does.

**The sitemap has to be linked from the apex.** `/journal/sitemap.xml` is a
valid sitemap at a path a crawler has no reason to guess. The apex `robots.txt`
gains a second `Sitemap:` line. This is the step that actually delivers the
consolidation — without it the archive is on the right origin and invisible.

### 6.4 A pre-existing defect this exposes, and it is live right now

Measured 2026-08-19:

```console
$ curl -s https://cloudsforge.online/sitemap.xml | head -3
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
<url><loc>http://cloudsforge.online/</loc></url>

$ curl -s https://cloudsforge.online/robots.txt | tail -1
Sitemap: http://cloudsforge.online/sitemap.xml
```

**`http://`.** `site/nginx.conf` composes both files with `$scheme://$host`,
and `$scheme` is `http` for every real request — TLS ends at Cloudflare,
cloudflared speaks plain HTTP to the gateway, and the gateway speaks plain HTTP
to the container. So the apex advertises every one of its URLs at an address
that 301s, and points crawlers at a sitemap by an address that 301s.

The journal repository has the entire argument written down already, in
`nginx.conf` and again in `vite.config.ts`, and uses a literal `https` for
exactly this reason. The site does not. This was found by reading the two files
against each other while planning this migration.

It is **fixed as part of wave 1**, before the journal's URLs are added to that
sitemap, because adding correct URLs to a file that advertises them over the
wrong scheme is worse than not adding them. One-line change: `$scheme://$host`
→ `https://$host` in `site/nginx.conf`, in both the `= /sitemap.xml` and
`= /robots.txt` locations.

### 6.5 `/products/journal` already exists

The apex serves a marketing page for each product, `journal` among them
(`site/nginx.conf`, the `location ~ ^/products/(hub|…|journal|agora)/?$`
block). After this wave the apex has both `/products/journal` — "here is what
Forge Journal is" — and `/journal` — the publication itself.

That is two apex pages competing for the same query. The plan was to give
`/products/journal` a canonical pointing at `/journal` — keeping the page,
because the product grid links to it and a 404 in a grid is worse than a
duplicate, while conceding the ranking to the publication.

**Dropped, and not replaced.** A canonical is a claim that two pages are the
same page, and these are not: one says what Forge Journal is and links to it,
the other is the archive. Pointing the marketing page at the publication asks a
search engine to drop the page that answers "what is Forge Journal" in favour of
one that does not answer it at all. The two rank for different queries, which is
the outcome wanted anyway, and the duplicate-content risk the canonical was
guarding against needs the pages to be substantially the same text — which was
never checked before proposing the tag.

So `/products/journal` keeps its own canonical, pointing at itself. The same
question returns for all fourteen surfaces and now has an answer: **only add a
canonical where the two pages would be interchangeable to a reader.** For a
product page and the product, they are not.

---

## 6bis. Wave 2 — `exchange` → `/exchange`

Only what DIFFERED from wave 1 is recorded here. The mechanism is the same and
is not restated.

**It was chosen alone**, for the reason §5 now gives. It is also not a repeat:
the journal is static prose with no session and no chain data, and this has a
wallet, a signed session and live contract reads. If a base path breaks something
only an authenticated surface can break, it breaks here — on one surface, before
twelve move at once.

### Three defects it exposed, two of them pre-existing

**1. `rpcUrl()` derived the apex itself.** The body was string surgery on the
hostname — drop the first label, give up if there is none to drop:

```ts
const parts = hostname.split('.')
if (parts.length <= 2) return null
const apex = parts.slice(1).join('.')
```

That encodes "this bundle is served from a subdomain". At
`cloudsforge.online/exchange` the hostname is two labels, so it returned `null`
and every page rendered **"There is no chain endpoint for this address"** — the
honest wording for a preview deployment and completely wrong for the estate's own
apex.

The comment above the function already claimed the endpoint was "composed the
same way `viewedHosts()` composes every other address". It was not: it was a
second copy of the derivation, and the copies had drifted the moment one surface
stopped being a hostname. It is `viewedHosts().rpc` now, and there is one
derivation in the estate rather than two.

`no-build-time-config.test.ts` asserted the three lines that BUILT the address —
which is to say it asserted the private copy existed. It now asserts the
opposite, and that `parts.slice(` never comes back.

**2. `isRegisteredPlacement()` had become a tautology**, exactly as in
`journal-web`. Second copy, same fix.

**3. The sitemap composed `$scheme://$host`.** Third copy of the defect §6.4
records for `micro-site`. `$scheme` is `http` on every real request, so it
advertised every URL at an address that 301s.

### `/exchange/` is an address this surface did not used to have

While the bundle was a hostname its index was `/`, and `/` has no
trailing-slash variant to get wrong. Now the front door is a path, and a reader
who types the folder with a slash — or any tool that normalises a
directory-looking URL by adding one — arrives at a second address.

Enumerated exactly, like everything else in that file, rather than by widening
the block to the prefix form: `location /exchange` as a prefix would also claim
`/exchangeable`, and would re-open the "every address answers 200" hole the
enumeration exists to keep shut. Not a 301 either — the gateway routes both, and
a redirect would cost a round trip on the front door to remove a duplicate that
nothing links to. The canonical stays the bare form.

### A test that would have failed open

`routes.test.ts`'s "nginx enumerates nothing that is not a route" read the
alternation with a literal `^/(`. Under the mount the block is
`^/exchange/(pools|…)`, that pattern matches nothing, the loop runs zero times
and **the test passes reporting nothing, forever.** It is anchored on `BASE` now
and asserts it found the block at all.

This is the second instance of the same shape in two waves — the first was
`viewsAnyNetwork`'s invariant in wave 1, the second is this. Both were assertions
whose subject moved out from under them, and neither failed when it did. Worth
looking for deliberately in wave 3: **any check whose pattern names a path is a
check that stops checking when the path moves.**

**It happened a third time on the deploy, and that one was loud.** The first CI
build after wave 1 merged failed in `micro-journal-web`: the image step probed
`GET /` twenty times and got 404 each time, and the nginx step looked for
`error_page 404 /index.html`. The image was correct and the workflow was not.

The three instances differ in one way that matters:

| | Failed when the path moved? |
| --- | --- |
| wave 1, the `viewsAnyNetwork` invariant | no — passed, measuring a proxy |
| wave 2, the nginx alternation reader | no — matched nothing, looped zero times |
| the deploy, the CI image probes | **yes** |

A check that names a path either goes silent or goes red, and which one it does
is decided by whether an empty match is treated as success. `grep -q X || fail`
goes red; `for m in $(grep X); do assert; done` goes silent. **Prefer the first
shape, and where the second is unavoidable, assert the match set is non-empty** —
which is what `check-router-prefix-ordering.py` and the rewritten alternation
reader both now do.

Two further assertions came out of the same episode and are worth copying to
every surface wave 3 moves, because neither existed before and both are about
what a bundle must NOT serve:

- **`/` must 404 from the bundle's own container.** The apex root belongs to
  `micro-site`. A bundle answering there means the gateway can serve the wrong
  one for `/` and nothing reports it — micro-org#428, which has happened twice.
- **`/robots.txt` must 404**, in both spellings. A reappearance is two containers
  claiming one address, with the gateway deciding which one sets the indexing
  policy for the entire origin.

### The one CORS grant that was load-bearing

Every other origin in `policy.yml`'s same-environment block is there so
`consumeAuthCallback` can POST once at the end of a sign-in. The exchange has no
sign-in at all and still could not function without a grant: it reads Hearth over
JSON-RPC at `rpc.<apex>`, so **every** read it makes is preflighted — the pair
list, the reserves, the router's quote. Without a grant it does not degrade, it
renders nothing.

None of that changed; the origin did. The grant is subsumed by the apex's, which
was already the first entry in the block. The order matters: deleting the old
line before the apex was on the list would have taken every price on the page
down.

---

## 7. What CI must learn

The estate's rule is that a drift like this is closed by a check rather than by
remembering. Four checks already covered part of it; three were written in this
wave, one of which the plan did not anticipate.

**Already covers this, no change needed:**

- `scripts/surface-routes.py` **check 1** — a `basePath` surface is checked
  against the host it lives on. The apex has a router, so `journal` passes.
- **check 2** — every host a router matches must be a declared subdomain. The
  apex is declared.
- **check 5** — every browser origin has a surface and every surface has an
  origin. **This is what forces the stale `journal.<apex>` CORS entry out of
  `policy.yml`.**
- `check-k8s-gateway-matches-compose.py` — the cluster gateway is the compose
  gateway. Unchanged and still true.

**Written in this wave, both green and both negative-tested:**

1. **`check-base-paths-agree.py`** — the base path is **five** statements, not
   two: the registry's `basePath`, `src/lib/routes.ts`'s `BASE`, `vite.config.ts`'s
   `base` (with its required trailing slash), every `location` in `nginx.conf`,
   and the gateway rule. It compares all five against the registry and names
   *which two* disagree, since they live in four repositories and "something is
   wrong" is not an actionable output. Scoped by `servesOwnBundle()`, so
   `wallet`, `signin` and `faucet` — `basePath` rows that are routes inside
   another bundle — are excluded rather than failed.

   It does **not** assert the thing the plan said it would, that no `basePath`
   row carries `viewsAnyNetwork`: decision 5 reversed, and a check written from
   the plan would have failed the correct registry.

2. **`check-router-prefix-ordering.py`** — a path-mounted router must strictly
   outrank every router that can match the same URLs: the host's catch-all, any
   router parked on that host, and **any path router whose path contains its
   own**. It also requires an explicit priority, because Traefik's default is
   computed from the rule's *length*, which would make the outcome depend on how
   a hostname is spelled.

   Written in wave 1 with nothing to find, for the `/worlds` vs
   `/worlds/emberkin` collision that arrives in wave 3 — a check that arrives
   with the problem arrives after it. Confirmed against a synthetic wave-3
   fixture: it fails when the two share a priority and passes when the deeper
   path outranks the shallower.

3. **`surface-routes.py` check 13**, which the plan did not anticipate. Checks 2
   and 5 are keyed on subdomains, and a consolidated surface no longer has one —
   so the moved hostname would simply have stopped being anybody's business, and
   deleting the tombstone router would have gone unnoticed. A `CONSOLIDATED_HOSTS`
   table now names each moved hostname and the middleware that must still redirect
   it, check 2 skips those hosts by that table rather than by accident, and check
   13 asserts the router and its middleware still exist. Negative-tested four ways
   (typo'd key, deleted middleware, unrouted host, host re-declared).

Two further consequences the plan did not have:

- **`VIEW_WITNESS_REPOS` is now keyed on the surface key, not the subdomain.**
  Its first key was `""`, the apex — and the apex now has two surfaces on it.
  `view_origin_drift()` splits accordingly: the origin half still compares
  subdomains against the CORS grant (where duplicates are correct and dedupe),
  and the witness half compares surface keys against repositories (where they
  are not).
- **`KNOWN_SUBS` loses `journal`**, silently — described in §6.1. Nothing checks
  it, and nothing can: it is correct for `journal` precisely because that
  hostname is now a redirect and nothing else. The thirteen that follow need the
  same argument made each time, by hand.

**One planned work item was cancelled outright**, and it is recorded because the
plan was confidently wrong rather than merely out of date. `journal-web`'s
`nginx.conf` asserted, in two places, that nginx does not interpret backslash
escapes in a quoted string — that `'Disallow: /\n'` yields a literal backslash
and `n`. This plan believed it and carried a work item to go and *fix* two
working blocks in `micro-site` on that basis. Measured against the running pod
before touching anything, `return 200 'User-agent: *\nDisallow: /\n'` produces
real `0x0A` bytes. nginx interprets the escape. The comment was corrected in
`9c3ccca` and the work item deleted. **A false statement written as settled fact
had already propagated one repository further than the file that held it.**

---

## 8. Rollback

Per wave, and it is not symmetric with the forward path.

The **gateway half rolls back in one edit**: restore `cf-web-journal` to
`Host(journal…)` at 500, drop the redirect, redeploy. Traefik reloads and the
old address serves again.

The **bundle half does not**, because the deployed image is built for
`/journal` and will 404 its own assets at the host root. Rolling back therefore
means redeploying the *previous release's* journal image alongside the restored
router — which is why the two halves ship in one release and why the rollback
step is "roll the release back", not "revert the gateway".

The **301s are the part that does not roll back at all.** A permanent redirect
that has been served and cached is in browsers and in crawler indexes; undoing
the configuration does not undo those. Practically this bounds the decision:
after a wave has been live long enough to be indexed, forward is the only
direction. That is an argument for the wave sizes above, not against the plan.

---

## 9. Not doing

- **Moving `hub`.** Stated once more here so a future reader does not
  re-derive the SEO argument and conclude the plan was incomplete. It was
  considered and refused on origin isolation; see the table in section 1.
- **Generating `estate-web.yml` from the registry.** `surface-routes.py`
  already argues this at length: the file is an argument, not a mapping, and a
  generator either discards the prose or grows an exception table that is the
  same hand-written list one level less visible.
- **Retiring the moved hostnames' DNS records.** They serve redirects forever.
- **Touching the `/v1` API paths in wave 1.** `journal` has none, which is why
  it is wave 1.

---

## See also

- [`kubernetes-operations.md`](kubernetes-operations.md) — how to deploy the
  releases this plan produces.
- [`kubernetes-migration.md`](kubernetes-migration.md) — why the estate is
  shaped the way it is.
- `gateway/dynamic/estate-web.yml` — the routers, and the incident behind each.
- `ui/packages/ui/src/surfaces.ts` — the registry, and the `basePath` field
  this plan is built on.
