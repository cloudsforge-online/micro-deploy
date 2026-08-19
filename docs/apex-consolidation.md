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
| `developers.<apex>` | `/developers` | Documentation. Documentation on a subdomain is the canonical example of authority thrown away. |
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

### Decision 4: a surface with an API remounts it under its own path

Eleven of the fourteen have a co-hosted service — `cf-api-market-host`,
`cf-api-explorer`, `cf-api-pool` and so on — matching `Host(<sub>) &&
PathPrefix('/v1')`. Those bundles issue *relative* requests to `/v1/…`, which
is what lets them not know their own hostname. Move the bundle to `/market` and
a relative `/v1/titles` still resolves to `/v1/titles` at the apex root, which
routes nowhere.

So each such surface's API moves with it, to `/<surface>/v1`, and the bundle's
fetch base becomes its own base path. That is a change in the *service* repo's
consumers, not just the frontend, and it is why these surfaces are not in
wave 1.

### Decision 5: a surface that moves to the apex gives up `viewsAnyNetwork`

**Found by wave 1 rather than planned, and it applies to all fourteen.**

The registry's `viewsAnyNetwork: true` marks a bundle that can show the other
network's data in place. `journal` has it, and the reason is quoted in
`policy.yml`: without it, pressing Testnet on an article throws the reader out
of the piece and onto Forge Network.

Two invariants in `ui/packages/ui/src/network-view.test.ts` refuse to let
`journal` keep the flag once it has a `basePath`:

```ts
    const bundles = SURFACES.filter((s) => s.servesUi && !s.basePath).map((s) => s.key)
    assert.deepEqual(VIEWING_SURFACES.map((s) => s.key), bundles)
    …
    const subs = VIEWING_SURFACES.map((s) => s.subdomain)
    assert.equal(new Set(subs).size, subs.length)
```

The second is the one that matters, and it is right. **A viewing surface's
subdomain must be unique**, because the flag's real effect is a
`CF_VIEW_ORIGIN_SUFFIX` entry in the cross-environment CORS grant — and that
grant is keyed by ORIGIN. Once `journal` is a path on the apex, `journal` and
`site` are the same origin, and keeping both flagged would put a duplicate
origin in the grant. The test's own comment says exactly this about `wallet`,
`signin` and `faucet`.

So the flag comes off, **and nothing is lost**, because the apex is already in
the grant — `- https://{{ env "CF_VIEW_SITE_HOST" }}` is the first line of the
block, and `site` carries `viewsAnyNetwork: true` itself. The journal's
`policy.yml` entry is not relocated; it is *subsumed*.

The in-place switching also survives, because it was never this flag that did
it. The bundle passes `onSelect` to the shared bar and keeps the viewed network
in the URL (`src/lib/viewed.ts`); the flag is registry metadata about origins.
What does change is that `viewingSurfaceUrl('journal', …)` starts returning an
escape URL again — a wrong answer that nothing asks for, since a surface
passing `onSelect` never reaches it. **A test asserts that nothing asks**,
rather than a comment noting it, because "unreachable today" is how the escape
route became reachable the first time.

Restated for the later waves: **moving a surface to the apex means deleting its
`viewsAnyNetwork` and its `policy.yml` view-grant line.** Thirteen more times.

---

## 5. The wave order, and what decides it

Not "highest SEO value first". The ordering test is **does this surface have a
`/v1` router on its own hostname** — because that is the difference between a
bundle change and a bundle-plus-API change, and doing the second kind before
the first kind has ever been deployed means debugging two new things at once.

| Wave | Surfaces | Why together |
| --- | --- | --- |
| **1** | `journal` | No service, no API router, no session, no chain data. `micro-journal` does not exist and the container's own nginx.conf says it never will. If the base-path pattern is wrong, the cost is an archive that 404s for an hour. |
| **2** | `exchange`, `developers` | Also no `/v1` router of their own — `exchange` calls `rpc.<apex>` cross-origin, `developers` is docs. Proves the pattern twice more before any API moves. |
| **3** | the remaining eleven | Each needs decision 4 applied. `worlds` + its three games go as one unit, because the nesting is the point. |

Each wave is its own branch, its own PR and its own release. There is no wave
that ships two moved surfaces the estate has not seen the pattern work on.

---

## 6. Wave 1 — `journal` → `/journal`

### 6.1 What changes, by repository

**`micro-journal-web`** — the bundle learns its mount point:

| File | Change |
| --- | --- |
| `vite.config.ts` | `base: '/journal/'`. Serves at `localhost:5196/journal` in dev too, which is what makes the registry row below true locally. |
| `src/app.tsx` | `<BrowserRouter basename="/journal">`. |
| `scripts/prerender.ts` | Writes into `dist/journal/…` rather than `dist/…`, and renders through `StaticRouter basename`. The route set is unchanged; only where the files land moves. |
| `src/lib/meta.ts`, `heads.ts`, `syndication.ts` | The one place that composes `` `${origin}${PATH}` `` becomes `` `${origin}${BASE}${PATH}` ``. This covers the canonical, `og:url`, the JSON-LD `@id`, the RSS channel and self links, and every `<loc>` in the sitemap — they are all built from that expression. |
| `nginx.conf` | Every `location` gains the prefix; `location = /healthz` does **not** (the container probe is not a public address and must stay at the root the Deployment's probe names). `error_page 404 /journal/404.html`. |
| `test/seo.test.ts` | Asserts no built file names a cloudsforge hostname — unchanged and still valuable. Gains: every absolute URL it finds begins `__CF_ORIGIN__/journal`. |
| `test/routes.test.ts` | Already asserts `/index.html` is absent from the `try_files` chain. Gains the prefix. |

**`micro-ui`** — one registry row:

```ts
    key: 'journal',
    subdomain: '',          // was 'journal'
    devPort: 5196,          // unchanged — this surface has always named its own dev server
    basePath: '/journal',   // new
    // viewsAnyNetwork: true — REMOVED. See decision 5.
```

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

- `cf-web-journal` becomes `Host(apex) && PathPrefix('/journal')` at priority
  600, service unchanged.
- A new `cf-journal-to-apex` redirect middleware, and a router for
  `journal.<apex>` at 500 carrying it.
- `gateway/dynamic/policy.yml`: delete **both** journal origins — the
  same-environment `https://journal{{ env "CF_WEB_SUFFIX" }}` and the
  cross-environment `https://journal{{ env "CF_VIEW_ORIGIN_SUFFIX" }}` (decision
  5). The first is replaced by
  `https://{{ env "CF_SITE_HOST" }}`, which is **already on the list** at
  line 122 — so the account-bar handoff that line exists to protect keeps
  working, and `surface-routes.py` check 5 will fail the build if the stale
  entry is left behind. The check does this work; it does not have to be
  remembered.
- `scripts/estate-verify.sh`: the `"journal journal-web"` provenance probe and
  the sign-in-origin loop both address `journal$WEB_SUFFIX`. Both become the
  apex plus the path.

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

The file stays in the container anyway, unreachable, for the reason its own
comment gives: it is what makes a `localtest.me` build and a laptop correct by
construction.

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

That is two apex pages competing for the same query. **`/products/journal`
gets a canonical pointing at `/journal`** rather than being deleted: the
product grid links to it, and a 404 in a grid is worse than a duplicate. The
same question returns for all fourteen surfaces and gets the same answer, so
it is worth settling once, here.

---

## 7. What CI must learn

The estate's rule is that a drift like this is closed by a check rather than by
remembering. Four checks already cover part of it, and two do not exist yet.

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

**Must be written, in this wave:**

1. **`check-base-paths-agree.py`** — for every registry row with a `basePath`,
   the owning repository's Vite `base` is the same string, and the gateway has
   a router matching `Host(<that surface's host>) && PathPrefix(<basePath>)`.
   This is the invariant [decision 1](#decision-1-the-base-path-is-baked-at-build-time)
   rests on, and without it the two halves drift into a surface that serves
   HTML and 404s every asset. It asserts decision 5 as well: **no `basePath`
   row carries `viewsAnyNetwork`**, which `network-view.test.ts` enforces from
   the registry side and nothing enforces from the gateway side.
2. **`check-router-prefix-ordering.py`** — for any two routers on the same host
   whose `PathPrefix` values nest, the longer prefix has the higher priority.
   Today this has one instance (`/worlds` vs `/worlds/emberkin`, wave 3) and
   zero today; it is written in wave 1 while there is nothing for it to find,
   because a check that arrives with the problem arrives after it.

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
