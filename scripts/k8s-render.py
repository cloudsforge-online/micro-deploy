#!/usr/bin/env python3
"""Turn `compose/docker-compose.estate.yml` into Kubernetes workloads.

    ./scripts/k8s-render.py --network mainnet --release ../org/releases/2026.8.81.yaml \
        --outdir k8s/estate/mainnet

WHAT IT EMITS, AND WHY IN FOUR FILES
------------------------------------
    20-pvc.yaml           the two stateful volumes
    30-migrate-jobs.yaml  the `-migrate` containers, as Jobs
    40-services.yaml      one ClusterIP per service that listens
    50-deployments.yaml   everything long-running

Filename order IS apply order, and that is load-bearing rather than tidy. Compose
expressed "the migrator finishes before the service starts" as
`depends_on: {x-migrate: {condition: service_completed_successfully}}`, and
Kubernetes has no equivalent: a Deployment does not wait for a Job. The ordering
therefore moves OUT of the manifest and into the deploy script, which applies
30-, waits for every Job to reach `complete`, and only then applies 50-. That is
why the waves are numbered and why nothing here reproduces `depends_on`.

THE OTHER `depends_on` — 92 OF THEM — IS DELETED ON PURPOSE
-----------------------------------------------------------
`condition: service_healthy` appears 92 times, and none of it is translated.
Under compose it delays a container's START until its dependency answers. Under
Kubernetes the same property is expressed by the READINESS PROBE that every one
of these services already has: a pod that cannot reach `identity` fails
`/readyz`, is removed from its Service's endpoints, and receives no traffic
until it recovers.

The difference is that compose's version is a one-shot check at boot and
Kubernetes' is continuous. A compose service whose dependency died an hour after
boot went on receiving traffic and failing; the pod does not. So this is the one
place the migration is not a faithful translation, and it is not faithful in the
direction of being correct.

WHERE THE IMAGES COME FROM
--------------------------
82 of the 86 compose services carry `build:` and no `image:`. Kubernetes cannot
build, so every image is resolved from a RELEASE MANIFEST — the same file
`scripts/release-render.py` consumes, by digest where the manifest has one.

`compose/docker-compose.release.yml` is deliberately NOT the input even though it
is sitting right there, because it is a generated artifact of whichever release
was last rendered into the working tree; today that is 2026.08.2, which is
stale by eighty releases. Reading it would silently deploy the wrong estate. The
manifest is named on the command line so that a deploy and a rollback are the
same command with a different file, exactly as they are under compose.

The four services with a literal `image:` keep it: `postgres` (excluded entirely
— CloudNativePG owns it now, see k8s/database/) and the three utility containers
that run stock alpine/busybox rather than an estate build.

SECRETS ARE NEVER RENDERED, ONLY REFERENCED
-------------------------------------------
Every rendered file in `k8s/estate/` is committed, so no value from
`compose/estate/tokens.env` may appear in one. Three shapes occur and each has a
different answer:

  1. THE WHOLE VALUE IS THE SECRET — `IDENTITY_CREDENTIAL: ${X_IDENTITY_CREDENTIAL}`,
     72 occurrences. Emitted as `valueFrom.secretKeyRef`.

  2. THE SECRET IS EMBEDDED IN A LARGER STRING — the 60 DSNs of the form
     `postgres://cloudsforge:${CF_POSTGRES_PASSWORD}@postgres:5432/identity`,
     plus four uses of `${EMBER_RPC_URL}`. `secretKeyRef` cannot fill part of a
     value, so the variable is injected as its own env entry FIRST and the string
     then references it as `$(CF_POSTGRES_PASSWORD)`, which is Kubernetes' own
     expansion. The DSN stays legible in the manifest — you can still read which
     database a service opens — and the credential still is not in it.

     Kubernetes only expands a reference to a variable defined EARLIER in the
     same container's `env` list, so the injected entries are emitted first and
     the ordering below is not cosmetic.

  3. THE SECRET IS IN A CONDITIONAL — `SETTLEMENT_RPC_URLS`, whose value is
     `{"ember":"..."${BTC_RPC_URL:+,"btc":"$BTC_RPC_URL"}...}`. `$(VAR)` has no
     conditional form, and the compose file argues at length why an unset chain
     must contribute NOTHING rather than an empty entry: `,"doge":""` is refused
     by `jsonMap` at import and takes settlement's migrator down with it.

     So this one value is ASSEMBLED BY `k8s-secrets.py`, stored whole in the
     `estate-derived` Secret, and referenced here by name. The conditional runs
     once, where the values legitimately live. `render-vars.<network>.yaml`
     records the exact compose expression it was assembled from, and this script
     refuses to render if the compose file has since changed it — otherwise the
     two would drift and settlement would boot against last month's chain list.

A MISSING SECRET NOW STOPS A POD INSTEAD OF STARTING A BROKEN ONE
-----------------------------------------------------------------
Every one of these is written `${NAME:-}` in the compose file, and its header
says what that costs: a bare `docker compose up` without `--env-file` resolves
all of them to EMPTY and the estate comes up authenticating nowhere. The
rendered `secretKeyRef` carries `optional: false`, so an absent key is a pod
stuck in `CreateContainerConfigError` naming the key it wants.

That is a behaviour CHANGE and it is the point. The defaults are not preserved.

CONFIG, BY CONTRAST, IS RESOLVED TO A LITERAL
---------------------------------------------
`${CF_WEB_SUFFIX:-.cloudsforge.localtest.me}` and its kind are not secrets; they
are the difference between mainnet and testnet. They are resolved here from
`compose/<network>.env` plus the compose default, and written into the manifest
as plain text — which is what makes the rendered file reviewable, and what lets
`check-k8s-render-matches-compose.py` regenerate and byte-compare it.
"""
import argparse
import pathlib
import re
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(
        "FAIL: PyYAML is not installed, so the compose file cannot be read.\n"
        "       python3 -m pip install pyyaml"
    )


# ── LOADING COMPOSE WITHOUT EXECUTING IT ─────────────────────────────────────
#
# `docker-compose.release.yml` uses `!reset null`, a compose-specific YAML tag
# that `yaml.safe_load` rejects outright ("could not determine a constructor").
# This script does not read that file, but the same loader is used for anything
# compose-shaped and a future overlay would hit it, so the tag is taught here
# rather than left as a landmine.
#
# THIS IS STILL A SAFE LOADER. It subclasses `SafeLoader`, not `Loader`, so the
# `!!python/object` family that makes `yaml.load` dangerous is still unregistered
# and still refused. The two constructors added below yield `None` and a plain
# scalar respectively; neither can construct a Python type. Reaching for
# `yaml.safe_load` instead would not be safer, it would just fail on `!reset`.
#
# `${VAR}` needs no special handling: YAML has no interpolation, so it arrives
# as literal text and stays that way until this script decides what it means.
class ComposeLoader(yaml.SafeLoader):
    pass


ComposeLoader.add_constructor("!reset", lambda loader, node: None)
ComposeLoader.add_constructor("!override", lambda loader, node: loader.construct_object(node))


# ── WRITING YAML A HUMAN WILL REVIEW ─────────────────────────────────────────
#
# These files are committed and read in diffs, so three of PyYAML's defaults are
# actively unhelpful:
#
#   ANCHORS. The same `labels` dict is attached to a Deployment, its selector and
#   its pod template. PyYAML notices the shared object and emits `&id001` once
#   then `*id001` twice. kubectl accepts it, but a reviewer asking "what labels
#   does this pod carry" gets a pointer instead of an answer, and any tool that
#   round-trips the file may or may not preserve it — which would make the
#   byte-comparison guard fail on a file nobody edited.
#
#   LINE FOLDING. At the default width, `IDENTITY_HANDOFF_ORIGINS` — 21 URLs —
#   is broken across six lines. Re-flowing on an unrelated edit produces a diff
#   touching lines whose content did not change.
#
#   MULTI-LINE STRINGS. `IDENTITY_SERVICE_TOKEN_GRANTS` is a JSON document with
#   real newlines. PyYAML double-quotes it and escapes them, so the grant table
#   that decides which service may call which arrives as one unreadable line of
#   `\"admin-api\":[\"identity:admin\"...\n`. Block style keeps it legible, and
#   whether a service can post to the ledger is exactly the kind of thing that
#   should be reviewable.
class EstateDumper(yaml.SafeDumper):
    def ignore_aliases(self, data):
        return True


def _block_style_for_multiline(dumper, value):
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


EstateDumper.add_representer(str, _block_style_for_multiline)


NETWORKS = {
    "mainnet": "cloudsforge-estate",
    "testnet": "cf-testnet",
}

# Which compose profiles are admitted, per network — read from `COMPOSE_PROFILES`
# in the network's env file, exactly as compose reads it. This is only the
# fallback for a network whose env file does not say, and it matches what the two
# files actually contain today: mainnet `pool`, testnet `ember-testnet`.
#
# The two are disjoint, which is the correct answer rather than an oversight.
# `faucet` is testnet-only because mainnet EMBER is mined money; `pool` is
# mainnet-only because there is nothing to mine on a regtest chain.
DEFAULT_PROFILES = {"mainnet": {"pool"}, "testnet": {"ember-testnet"}}

# ── THE TESTNET WEB BUNDLES THAT NOTHING ROUTES TO ──────────────────────────
#
# Wave 1 of `docs/network-consolidation.md`. Every one of these was measured on
# 2026-08-21 against the running testnet gateway: behind no live router, named by
# no beacon target, and with an nginx log containing worker-startup notices and
# not one request.
#
# AN EXPLICIT LIST, NOT `name.endswith("-web")`, and the reason is `site`. The
# testnet gateway's live web routers are `cf-web-site`, `cf-web-nimbus`,
# `cf-web-pay`, `cf-web-studio` and `cf-web-vault`; the last four point at APIs
# (identity, wallet, studio, custody), and the first at this bundle. A pattern
# would have taken `site` with the rest and turned a consolidation into an
# outage. `network-site` is a different service and is in the list.
RETIRED_TESTNET_SURFACES = frozenset({
    "admin-web", "aetherholm-web", "agora-web", "beacon-web", "devportal-web",
    "emberkin-web", "exchange-web", "explorer-web", "foresight-web", "hub-web",
    "journal-web", "lantern-web", "market-web", "mint-web", "network-site",
    "pool-web", "status-web", "tessera-web", "trade-web", "worlds-web",
})


def is_retired_surface(name, service):
    """True when this service is a web bundle the retirement gate has orphaned.

    Membership is by NAME so that a service added later is rendered by default —
    the safe direction. A new surface that should also be retired has to be named
    here, which is a decision somebody makes rather than a pattern that swallows
    it silently.
    """
    return name in RETIRED_TESTNET_SURFACES

# `postgres` is not rendered. CloudNativePG owns the database now and
# k8s/database/ carries the Cluster, the 30 Database objects and the `postgres`
# Service alias that keeps all 57 DSNs spelling `@postgres:5432`.
# ── CONSOLIDATED, BUT KEEPING ONE DATABASE ───────────────────────────────────
#
# A subset of CONSOLIDATED_SERVICES. These cross like the others — CNAME in the
# testnet namespace, no Deployment there — but they get NO second DSN, because
# they were designed to serve both estates from a single database with a
# `network` column rather than from two pools (§5.3, §5.4, §5.5).
#
# Emitting `<PREFIX>_DATABASE_URL_TESTNET` for them would name a database that
# does not exist in this cluster. Their code ignores the variable today, so it
# would be inert — and an inert environment variable pointing at a nonexistent
# database is precisely the kind of artefact that reads as intentional to the
# next person and is acted on.
SINGLE_DATABASE_SERVICES: set[str] = {
    "identity",
    "notify",
    # beacon is class B′ too — §5.3 corrected the plan's class-C listing. One
    # database with a `network` column, because its rows are OBSERVATIONS rather
    # than an estate's user data, and the public status page wants both estates
    # in one query.
    "beacon",
    # indexer keeps one database too — §5.4 found it needed no code change at all,
    # because every table that matters already carried `network`.
    "indexer",
    # custody and settlement, 2026-08-25. Both keep one database with a `network`
    # column. custody's 31 testnet keys and 2 surviving seeds were merged by hand
    # first (micro-org#510); settlement follows because its treasuries and sweep
    # sources name custody addresses.
    "custody",
    "settlement",
}

# ── THE BRIDGE THAT RUNS THE OTHER WAY ───────────────────────────────────────
#
# Everything above moves testnet callers to `cloudsforge-estate`. This is the
# one name that has to travel the other way.
#
# `docs/network-consolidation.md` §6.3 moved the testnet gateway into
# `cloudsforge-estate`, and its router table — the same file the mainnet gateway
# reads — names `http://faucet:4000` as a literal. The faucet itself did NOT
# move: `faucet/src/env.ts` is `export const NETWORK = 'testnet' as const`, and
# the estate-web.yml note above the router is explicit that a mainnet faucet is
# not a thing that will ever exist.
#
# WHY THIS CANNOT LEAK INTO MAINNET, which is the question a CNAME named
# `faucet` in the mainnet namespace obviously raises: the faucet router AND its
# `cf-svc-faucet` upstream are both wrapped in
# `{{ if eq (env "CF_EMBER_NETWORK") "testnet" }}`. The mainnet gateway emits
# neither, so it has nothing that could resolve this name — the CNAME is
# reachable only from the testnet gateway's own router table. That conditional
# is load-bearing, and `check-k8s-gateway-matches-compose.py` asserts it stays.
#
# The port is declared even though an ExternalName ignores it. `k8s-gateway.sh`
# proves every upstream has a Service on the port its router uses, by reading
# `.spec.ports`; without it the faucet would be reported missing on every deploy
# and the real signal would be trained away.
TESTNET_ONLY_BRIDGED: dict[str, int] = {"faucet": 4000}


# ── SERVICES THAT SERVE BOTH ESTATES FROM ONE POD ────────────────────────────
#
# `docs/network-consolidation.md` §6. A name lands here when its cutover is done:
# its testnet database has been adopted into the mainnet cluster as
# `<db>_testnet`, and its testnet router points at the mainnet namespace.
#
# Two things follow from membership, and they are opposite sides of one change:
#
#   * The MAINNET deployment gains `<PREFIX>_DATABASE_URL_TESTNET`, derived from
#     its own `<PREFIX>_DATABASE_URL` by suffixing the database name. Derived
#     rather than written into compose because the two strings differ in exactly
#     one token, and thirty hand-written copies are thirty chances to point a
#     service at the wrong estate's rows — the failure this whole plan exists to
#     make impossible.
#
#   * The TESTNET render drops the service entirely. No Deployment, no Service,
#     no migrate Job. Leaving it rendered would hand a pod a DSN for a database
#     that is no longer authoritative, and a second migrator for a schema the
#     mainnet pod now owns.
#
# An explicit list rather than a flag, so that adding a name is a reviewable diff
# that says which service crossed and when.
CONSOLIDATED_SERVICES: set[str] = {
    # Wave 2, 2026-08-25 — the six the plan chose because a defect here costs
    # nobody money. agora went first alone, as the pilot; §6.1 records what that
    # changed. The other five followed as one batch once the mechanism was proven.
    #
    # Three of the six (community, analytics, policy) have no public router at
    # all and are reached only service-to-service, which is why the testnet
    # Service is a CNAME rather than a deletion.
    "agora",
    "community",
    "analytics",
    "policy",
    "pricing",
    "devplatform",

    # Wave 3, 2026-08-25 — the fifteen product services. hub-api is here without a
    # database of its own: its isolation was always peers and a cache key, never a
    # pool, so it crosses with a CNAME and no adoption (§5.2).
    "activity",
    "studio",
    "lantern",
    "emberkin",
    "worlds",
    "nda",
    "tessera",
    "market",
    "mint",
    "billing",
    "hub-api",
    "admin-api",
    "aetherholm",
    "foresight",
    "trade",

    # Wave 6, 2026-08-25 — the money core. Moved last, as the plan requires, and
    # only once every caller was already forwarding the header in production.
    # Both are two-pool services, so this is the same adoption the others had:
    # ledger carried 14,137 rows, wallet 89.
    "ledger",
    "wallet",

    # The class B′ singletons, 2026-08-25. One account set and one mail pipeline,
    # as micro-org#459 settled and §5.5 records — so they are in
    # SINGLE_DATABASE_SERVICES too and take no second handle.
    #
    # Their testnet databases were measured before this: three rows each, both in
    # `jobs`, and nothing else at all. No users, no sessions, no deliveries, no
    # notifications. "Vestigial" was the plan's word for identity's testnet pod
    # and it turned out to be exact for both.
    "identity",
    "notify",

    # beacon, 2026-08-25. Its eight live probes were carried over by hand first,
    # renamed with the `-testnet` suffix §5.3 argues for and relabelled
    # `network='testnet'`, and verified running from the mainnet pod before this
    # landed. The twenty-one disabled ones were left behind: their last check is
    # 2026-08-14, the day the frontends they name were retired.
    "beacon",

    # indexer, 2026-08-25. Its seven testnet watched addresses were carried over
    # by hand; everything else in that database is derived from the chain and the
    # merged indexer re-observes it from its own checkpoint.
    "indexer",

    # custody and settlement, 2026-08-25. See §6.2 — the merge was row work plus a
    # keyring that briefly held V2 beside V4, not a schema change.
    "custody",
    "settlement",

    # site, 2026-08-25. Not a database service at all — it is here purely so the
    # testnet render stops emitting its Deployment and emits a CNAME instead.
    #
    # Scaling it to zero by hand did not hold: the next `k8s-deploy.sh --network
    # testnet` restored it from the render, twice, which is exactly what a render
    # is for. Retiring a service means removing it from the render, and nothing
    # else is durable.
    #
    # The CNAME is not optional. `cf-retired-web-apex`, `cf-retired-web-sub` and
    # `cf-web-www` all declare `cf-web-site` as their `service:` even though the
    # retirement middleware answers first, and `k8s-gateway.sh` refuses to apply
    # a router whose upstream resolves to nothing.
    "site",
}

EXCLUDED_SERVICES = {"postgres"}

# ── THE WEB BUNDLES ARE ONE POD NOW, RENDERED ELSEWHERE ──────────────────────
#
# Twenty bundles were twenty Deployments serving static files. They are now one
# `web` Deployment emitted by `scripts/k8s-render-web.py`, which runs each
# bundle's own nginx.conf unchanged on a loopback port — see that script's
# header for why the configs are not merged into one route table.
#
# They stay in the COMPOSE file, because compose is still how the estate runs
# locally and each bundle is still its own image, its own repo and its own
# release entry. What changes is only how Kubernetes groups them, which is the
# thing that was costing twenty pods.
#
# `status-web` is deliberately absent from this set and still renders its own
# Deployment: a status page that shares a pod with what it reports on cannot
# report the interesting outage (`docs/apex-consolidation.md` §1).
MERGED_INTO_WEB_POD = {
    "site", "market-web", "mint-web", "trade-web", "worlds-web", "emberkin-web",
    "aetherholm-web", "tessera-web", "explorer-web", "devportal-web", "foresight-web",
    "pool-web", "exchange-web", "journal-web", "agora-web", "hub-web", "admin-web",
    "network-site", "lantern-web", "beacon-web",
}

# ── SERVICES THAT ARE NOW MODULES OF ANOTHER SERVICE ─────────────────────────
#
# `absorbed -> absorber`. Wave M of `docs/service-merge-plan.md`: the absorbed
# service's code ships INSIDE the absorber's image as plain directories under
# its `src/`, so there is no second container to run and no second migrate Job —
# the absorber's migrator runs both schemas, and both databases are kept under
# their existing `*_DATABASE_URL` names.
#
# THE NAME STILL RESOLVES, and that is why this is a CNAME rather than a
# deletion, for the same reason `CONSOLIDATED_SERVICES` above is. Callers are
# not required to move on cutover day; they move at leisure, and rollback is the
# old image plus flipping this map back rather than a coordinated edit across
# every caller.
#
# Both sides of a merge must serve the SAME PORT for the alias to be transparent
# — an ExternalName is a DNS CNAME and carries no port mapping. analytics and
# lantern are both on 4000, which is what makes this alias free.
MERGED_INTO = {
    # 2026-08-27. lantern absorbs analytics even though analytics is the larger
    # of the two (5.1k vs 4.3k LOC), because lantern holds the public hostname,
    # the gateway router and the OTLP endpoint every service in the estate pushes
    # to. Absorb by blast radius, not by line count.
    "analytics": "lantern",
    # 2026-08-27. Both games hold a public hostname and an apex mount, so the
    # blast-radius tiebreak that decided lantern/analytics does not separate this
    # pair. emberkin absorbs on upstream count: it already reaches ledger,
    # billing, worlds and identity and holds a service credential; aetherholm
    # reaches no service at all. Folding the zero-upstream side into the
    # four-upstream side widens nothing.
    "aetherholm": "emberkin",
    # 2026-08-27. activity absorbs notify despite notify being the larger (10.5k
    # vs 5.9k LOC), a third of which is table data rather than surface. activity
    # holds the pair's only public router, is the only one a synthetic monitor
    # probes, and notify has no public hostname at all.
    #
    # THIS ONE BREAKS THE "no caller changes on cutover day" PROMISE, and the
    # CNAME below does not rescue it: both services mounted `POST /ingest` and
    # verified it with DIFFERENT signing secrets, so the merged process serves
    # `/ingest/activity` and `/ingest/notify`. A CNAME moves a host, not a path.
    # Every producer subscription is re-pointed in the same change.
    "notify": "activity",
    # 2026-08-27, wave M4a. nda joins the titles service as its third module.
    # The cleanest merge in the estate: nda's upstreams (BILLING_URL, WORLDS_URL,
    # IDENTITY_URL) are a strict SUBSET of emberkin's, so the absorbing pod gains
    # no reach it did not already have, and nda binds 4000 like emberkin, so the
    # alias below is transparent.
    #
    # TESSERA IS NOT HERE, DELIBERATELY, and it is the obvious fourth title:
    #   * it binds 4022, and an ExternalName is a DNS CNAME that carries NO port
    #     mapping — the cutover and rollback mechanism this map provides simply
    #     does not exist for it;
    #   * `GET /v1/title` and `POST /v1/provision` are FROZEN contract constants
    #     (contracts/packages/worlds) that aetherholm already mounts, so
    #     first-wins matching would have `worlds` provision a tessera ward and
    #     receive aetherholm's 200 — with no second way in, because worlds
    #     addresses a title by base URL and appends a fixed path;
    #   * it verifies its webhook with INBOUND_SIGNING_SECRET, which this pod has
    #     never read and which is deliberately held apart from OUTBOX_SIGNING_SECRET.
    "nda": "emberkin",
    # 2026-08-29, wave M5a — the platform-monolith SEED (micro-deploy#282). agora
    # absorbs the four platform-tier services it shares no ledger authority with:
    # devplatform, policy, pricing and studio. All four bind 4000, as does agora,
    # so every alias below is transparent — the tessera port-mismatch trap does
    # not apply. Each keeps its own database; the merged `agora/src/index.ts`
    # opens one pool per module and cannot cross them.
    #
    # These aliases are the SAFETY NET for service-to-service callers that still
    # spell the old name (market -> pricing, and agora -> its own `POLICY_URL`,
    # which resolves right back here). The gateway upstreams are re-pointed at
    # `agora` directly, exactly as analytics/notify/aetherholm/nda were.
    "devplatform": "agora",
    "policy": "agora",
    "pricing": "agora",
    "studio": "agora",
    # 2026-08-30, wave M5b — the commerce/games tier joins the monolith
    # (micro-deploy#282, micro-agora#8). Twelve modules in one process now.
    #
    # SIX OF THESE SEVEN HOLD `ledger.postEntry`, and that is a rule being
    # OVERRULED rather than satisfied: the owner's under-20 decision (plan §M5)
    # trades the money-authority isolation for the container count. What is NOT
    # traded is the machinery that makes it survivable — per-route
    # `RouteSpec.sql`, one JobRunner per module, `module` metric labels, and a
    # separate signed inbox per module (`/v1/events/<module>`, the bare path 410s).
    # identity, ledger and custody stay OUT, which is what still keeps the worst
    # platform bug away from minting a token, rewriting the book, or signing.
    #
    # ── THE TWO PORTS THAT ARE NOT 4000, AND WHY THE ALIAS IS STILL SAFE ──────
    #
    # foresight bound 4021 and tessera 4022, and an ExternalName carries NO port
    # mapping — the exact trap that refused tessera at M4a. It does not bite here
    # because nothing addresses either by port any more: as MODULES they mount
    # into agora's single 4000 listener (their `PORT:` lines are deliberately
    # absent from agora's compose block), and the only callers that ever named
    # `:4021`/`:4022` were four gateway upstreams and one erasure row, all
    # re-pointed at `agora:4000` in this same change. Measured, not assumed:
    # `grep -rE "http://(foresight|tessera):[0-9]+"` over compose and gateway
    # returns nothing else.
    "community": "agora",
    "market": "agora",
    "billing": "agora",
    "mint": "agora",
    "foresight": "agora",
    "worlds": "agora",
    "tessera": "agora",
    # 2026-08-30, wave M5c — the bus tail and the telemetry sink (micro-agora#9).
    # These two are already ABSORBERS themselves: `notify` merged into activity at
    # M2 and `analytics` into lantern at M1. Adding these two entries therefore
    # lengthens two existing chains rather than starting them, and that is safe
    # because `merge_target()` FOLLOWS MERGES TO THE END — notify now resolves
    # notify -> activity -> agora and is emitted as a single ExternalName straight
    # at agora, not as a CNAME hop through a name that no longer has a pod.
    #
    # Both bind 4000, so both aliases are transparent. Sixteen modules.
    "activity": "agora",
    "lantern": "agora",
}


def merge_target(name: str) -> str:
    """The service a name actually resolves to, following merges to the end.

    Written as a loop rather than a single lookup so that a later `b -> c` on top
    of an existing `a -> b` cannot leave `a` pointing at a service that no longer
    runs. Guarded against a cycle, because a typo that made one is otherwise an
    infinite loop inside a deploy.
    """
    seen = [name]
    while name in MERGED_INTO:
        name = MERGED_INTO[name]
        if name in seen:
            raise SystemExit(f"MERGED_INTO has a cycle: {' -> '.join([*seen, name])}")
        seen.append(name)
    return name

# The Secret each compose `env_file:` becomes. Compose interpolates the network
# into the path (`secrets/outbox.${CF_EMBER_NETWORK:-mainnet}.env`); the Secret
# name drops the network because the namespace already carries it. Kept in step
# with the FILES table in scripts/k8s-secrets.py — one of these two lists moving
# without the other is what `check-k8s-render-matches-compose.py` catches.
# ── THE SECOND ESTATE'S HALF OF A SPLIT ENV FILE ─────────────────────────────
#
# `env_file` stem -> the Secret carrying the OTHER network's keys for it.
#
# A service that keeps ONE database with a `network` column
# (`docs/network-consolidation.md` §5.4) runs one pod for both estates, so
# anything the testnet half of these files configures has to arrive on that pod
# too. Both entries exist for the indexer: `env/chain` carries
# `INDEXER_RPC_EMBER_TESTNET` and the start heights, `secrets/chainrpc` carries
# `INDEXER_RPC_LTC_TESTNET`.
#
# Each is FILTERED to keys ending `_TESTNET` by k8s-secrets.py, which is what
# makes mounting two copies of one file's Secret on one pod safe: `envFrom`
# resolves a duplicate key by list order, so an unfiltered second copy would
# quietly replace the first's values rather than extend them.
#
# Mainnet only. On a testnet render the pod IS the testnet estate and these
# files are already its primary.
SECOND_ESTATE_ENV_FILES = {
    "env/chain": "env-chain-testnet",
    # `secrets/chainrpc` WAS here, for `INDEXER_RPC_LTC_TESTNET`. It came back
    # out when `ltc:testnet` left `INDEXER_CHAINS`, because the indexer's env
    # guard is symmetric: it refuses a chain named with no provider AND a
    # provider set for a chain not named. Restoring LTC testnet means putting
    # both back, together with a node that answers.
}

ENV_FILE_SECRETS = {
    "secrets/outbox": "secret-outbox",
    "secrets/identity-key": "secret-identity-key",
    "secrets/analytics-pepper": "secret-analytics-pepper",
    "secrets/custody": "secret-custody",
    "secrets/studio": "secret-studio",
    "secrets/chainrpc": "secret-chainrpc",
    "env/chain": "env-chain",
}

TOKENS_SECRET = "estate-tokens"
DERIVED_SECRET = "estate-derived"

INTERP = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-+?])?([^}]*)\}")


def fail(message):
    sys.exit(f"FAIL: {message}")


def parse_env_file(path):
    """The non-secret env files, read for their VALUES — these are config, not credentials.

    Deliberately simpler than the dotenv parser in `k8s-secrets.py`: that one
    implements compose's quoting rules because it handles credentials, where a
    stray pair of quotes becomes a 401 nobody can see. These files hold hostnames
    and feature flags and are audited to contain no quoting at all.
    """
    out = {}
    for raw in path.read_text().split("\n"):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        out[name.strip()] = re.split(r"\s+#", value.strip(), maxsplit=1)[0].rstrip()
    return out


class Resolver:
    """Turns one compose value into either a literal or a set of secret references.

    Returns `(text, injected)` where `injected` is the ordered set of secret
    variable names the text now references as `$(NAME)` and which must therefore
    be emitted ahead of it — see shape 2 in the module docstring.
    """

    def __init__(self, config, secret_vars):
        self.config = config
        self.secret_vars = secret_vars

    def resolve(self, service, key, value):
        value = str(value)
        injected = []

        # An env var whose ENTIRE value is one secret becomes a secretKeyRef and
        # never passes through here as text. Detected by the caller; asserted
        # here so a future edit cannot quietly turn one into an interpolation.
        match = INTERP.fullmatch(value)
        if match and match.group(1) in self.secret_vars:
            fail(f"{service}.{key} is a whole-value secret and should not reach Resolver.resolve")

        def substitute(m):
            name, op, arg = m.group(1), m.group(2) or "", m.group(3)
            if name in self.secret_vars:
                if "+" in op:
                    # Unreachable for anything but SETTLEMENT_RPC_URLS, which is
                    # declared `derived` and handled before this point. If a new
                    # one appears, it needs the same treatment and a decision —
                    # not a silently dropped chain.
                    fail(
                        f"{service}.{key} uses the conditional form `${{{name}:+...}}` on a SECRET.\n"
                        f"      Kubernetes has no conditional expansion, so this value cannot be rendered.\n"
                        f"      Declare `{key}` under `derived_vars:` in the render-vars file and teach\n"
                        f"      scripts/k8s-secrets.py to assemble it, as SETTLEMENT_RPC_URLS already is."
                    )
                if name not in injected:
                    injected.append(name)
                # Kubernetes' own expansion. The default is dropped deliberately:
                # see "a missing secret now stops a pod" in the module docstring.
                return f"$({name})"

            # ── CONFIG: RESOLVED HERE, TO A LITERAL ──────────────────────────
            present = name in self.config and self.config[name] != ""
            if "+" in op:
                # `${VAR:+alt}` — the alternate value, only when VAR is set.
                # `beacon.BEACON_IDENTITY_FOREIGN` is the only config user.
                return self._expand_literals(arg) if present else ""
            if present:
                return self.config[name]
            if "?" in op:
                fail(
                    f"{service}.{key} requires `{name}`, which is set in neither the network env file\n"
                    f"      nor the secret list. The compose file's own message for it is: {arg!r}"
                )
            if op:
                return self._expand_literals(arg)
            fail(
                f"{service}.{key} references `${{{name}}}` with no default and no value.\n"
                f"      Compose would have substituted an empty string. Refusing to render a service\n"
                f"      whose configuration is silently blank; set it in compose/<network>.env or add\n"
                f"      it to secret_vars in the render-vars file."
            )

        return INTERP.sub(substitute, value), injected

    def _expand_literals(self, text):
        """A default may itself contain `$VAR` — expand only from config, never secrets."""

        def one(m):
            name = m.group(1)
            if name in self.secret_vars:
                fail(f"a compose default expands the secret `{name}`; that cannot be rendered")
            return self.config.get(name, "")

        return re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)", one, text)


def probe_from_healthcheck(service, healthcheck):
    """A compose healthcheck becomes a startupProbe and a readinessProbe.

    The URL is PARSED OUT of the test command rather than looked up in a table
    keyed by service name. The estate listens on four different ports — 4000 for
    29 services, 8080 for the 21 frontends, 4022 for tessera and 4021 for
    foresight — and a table would have to be maintained beside the compose file
    that already states each one.

    NO livenessProbe IS EMITTED, and that is a decision. Compose defined none,
    and the compose file says why the endpoint being probed is `/readyz` and not
    `/livez`: "liveness answers while the database is unreachable, which is the
    whole distinction those two endpoints exist to draw". Wiring `/readyz` to a
    liveness probe would restart every service in the estate whenever Postgres
    hiccuped — turning a brief dependency outage into a full restart storm.
    Adding liveness is a real decision to make later, with a real endpoint.
    """
    test = healthcheck.get("test")
    if not isinstance(test, list) or len(test) < 2:
        fail(f"{service} has a healthcheck this cannot read: {test!r}")
    command = test[-1]
    match = re.search(r"http://127\.0\.0\.1:(\d+)(/[A-Za-z0-9_./-]*)", command)
    if not match:
        fail(
            f"{service}'s healthcheck does not probe a local http URL and cannot become an\n"
            f"      httpGet probe: {command!r}\n"
            f"      Teach this function the new shape rather than letting the service run unprobed."
        )
    port, path = int(match.group(1)), match.group(2)

    def seconds(field, default):
        raw = str(healthcheck.get(field, default))
        unit = re.fullmatch(r"(\d+)(s|m)?", raw)
        if not unit:
            fail(f"{service}'s healthcheck has an unreadable {field}: {raw!r}")
        return int(unit.group(1)) * (60 if unit.group(2) == "m" else 1)

    interval = seconds("interval", "30s")
    timeout = seconds("timeout", "5s")
    retries = int(healthcheck.get("retries", 3))
    start_period = seconds("start_period", "0s")
    start_interval = seconds("start_interval", "5s")

    probes = {
        "readinessProbe": {
            "httpGet": {"path": path, "port": port},
            "periodSeconds": interval,
            "timeoutSeconds": timeout,
            "failureThreshold": retries,
        }
    }
    if start_period:
        # compose's `start_period` plus `start_interval` is exactly what a
        # startupProbe is: probe fast while booting, and do not count failures
        # against the service until the budget is spent. Expressing it as a long
        # `initialDelaySeconds` instead would make every rollout wait the full
        # 90 seconds even when the service was ready in four.
        probes["startupProbe"] = {
            "httpGet": {"path": path, "port": port},
            "periodSeconds": start_interval,
            "timeoutSeconds": timeout,
            "failureThreshold": max(1, start_period // max(1, start_interval)),
        }
    return probes, port


def env_from(service, service_def, network):
    """`env_file:` → `envFrom: secretRef:`, with the network stripped from the path."""
    refs = []
    for entry in service_def.get("env_file") or []:
        path = entry["path"] if isinstance(entry, dict) else entry
        required = entry.get("required", True) if isinstance(entry, dict) else True
        stem = re.sub(r"\.\$\{CF_EMBER_NETWORK:-mainnet\}\.env$", "", path)
        stem = re.sub(r"\.env$", "", stem)
        if stem not in ENV_FILE_SECRETS:
            if stem == "generated/stratum":
                # Written by the pool's own tooling on the app host, never
                # committed, and `required: false` — so compose starts without
                # it. Deliberately not carried across: on Kubernetes the pool's
                # stratum configuration comes from the pool Secret. Flagged
                # rather than skipped silently so the omission is visible.
                print(f"  note: {service} does not carry {path} (see render-vars)", file=sys.stderr)
                continue
            fail(
                f"{service} reads env_file `{path}`, which maps to no Secret.\n"
                f"      Add it to ENV_FILE_SECRETS here AND to FILES in scripts/k8s-secrets.py.\n"
                f"      A service missing an env_file starts and fails authentication."
            )
        refs.append({"secretRef": {"name": ENV_FILE_SECRETS[stem], "optional": not required}})

        # ── THE SECOND ESTATE'S CHAIN RPCs ───────────────────────────────────
        #
        # The indexer keeps ONE database with a `network` column
        # (`docs/network-consolidation.md` §5.4), so one pod indexes BOTH
        # estates' chains — and `INDEXER_CHAINS` in `chain.mainnet.env` now
        # names both. Naming a chain without giving it an RPC is a boot failure,
        # so the `_TESTNET` variables have to arrive on the same pod.
        #
        # Mainnet only: on a testnet render this pod IS the testnet estate and
        # `chain.testnet.env` is already its primary.
        #
        # SAFE TO MOUNT SECOND because `k8s-secrets.py` filters that Secret to
        # keys ending `_TESTNET`. The two chain files also share
        # `INDEXER_CHAINS` and two `FORESIGHT_` names, and `envFrom` resolves a
        # duplicate by list order — so an unfiltered copy here would replace the
        # estate's chain list with testnet's two entries and stop mainnet
        # indexing. The key sets are disjoint by construction instead.
        if network == "mainnet" and stem in SECOND_ESTATE_ENV_FILES:
            refs.append({"secretRef": {"name": SECOND_ESTATE_ENV_FILES[stem], "optional": True}})
    return refs


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--network", required=True, choices=sorted(NETWORKS))
    parser.add_argument("--release", required=True, help="org/releases/<version>.yaml — the image source of truth")
    parser.add_argument("--compose", default="compose/docker-compose.estate.yml")
    parser.add_argument("--vars", help="default: k8s/estate/render-vars.<network>.yaml")
    parser.add_argument("--outdir", help="write the four files here instead of stdout")
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    namespace = NETWORKS[args.network]

    compose_path = pathlib.Path(args.compose)
    vars_path = pathlib.Path(args.vars) if args.vars else root / "k8s/estate" / f"render-vars.{args.network}.yaml"
    release_path = pathlib.Path(args.release)
    for required in (compose_path, vars_path, release_path):
        if not required.exists():
            fail(f"{required} does not exist")

    compose = yaml.load(compose_path.read_text(), Loader=ComposeLoader)
    services = compose["services"]
    render_vars = yaml.safe_load(vars_path.read_text())
    release = yaml.safe_load(release_path.read_text())

    secret_vars = set(render_vars["secret_vars"])
    derived_vars = render_vars.get("derived_vars") or {}

    config = parse_env_file(root / "compose" / f"{args.network}.env")
    # `CF_EMBER_NETWORK` decides which env_file path compose builds, and mainnet's
    # env file omits it because the compose default IS mainnet. Supply it so the
    # `${CF_EMBER_NETWORK:-mainnet}` in every env_file path resolves the same way
    # here as it does under compose.
    config.setdefault("CF_EMBER_NETWORK", args.network)

    profiles = set(filter(None, config.get("COMPOSE_PROFILES", "").split(","))) or DEFAULT_PROFILES[args.network]

    # ── IMAGES, BY DIGEST WHERE THE MANIFEST HAS ONE ─────────────────────────
    #
    # Same rule as scripts/release-render.py and for the same reason: a tag is a
    # mutable pointer and this estate's own CI moves it. An entry with a digest
    # is pinned to the artifact; one without is all the manifest knows.
    images = {}
    for entry in release.get("services") or []:
        image = entry["image"]
        images[entry["name"]] = f"{image}@{entry['digest']}" if entry.get("digest") else f"{image}:{entry['tag']}"

    resolver = Resolver(config, secret_vars)
    pvcs, jobs, svcs, deployments = [], [], [], []
    unresolved = []
    retired_surfaces: list[str] = []

    for name in sorted(services):
        # ── A CONSOLIDATED SERVICE, SEEN FROM THE TESTNET NAMESPACE ──────────
        #
        # No Deployment and no migrate Job here: the service exists once, in
        # `cloudsforge-estate`, and running a second migrator against a schema
        # that pod now owns is the fastest way to corrupt it.
        #
        # The NAME still has to resolve, though, and that is the whole reason
        # this is an ExternalName rather than a deletion. Two kinds of caller
        # reach `http://agora:4000` inside `cf-testnet`:
        #
        #   * the testnet gateway, whose backends are namespace-local by design;
        #   * every other testnet service making a service-to-service call.
        #
        # An ExternalName is a DNS CNAME, so BOTH keep working with no edit to
        # the gateway file and no edit to any caller. It also means the testnet
        # gateway's `CF-Network: testnet` header — stamped on its own entrypoint
        # chain — rides along unchanged, which is what lets one pod answer for
        # both estates without either gateway lying about which is asking.
        if args.network == "testnet" and name.removesuffix("-migrate") in CONSOLIDATED_SERVICES:
            if not name.endswith("-migrate"):
                svcs.append(
                    {
                        "apiVersion": "v1",
                        "kind": "Service",
                        "metadata": {
                            "name": name,
                            "namespace": namespace,
                            "labels": {"app.kubernetes.io/name": name, "app.kubernetes.io/part-of": "cloudsforge"},
                            "annotations": {
                                "online.cloudsforge.why": (
                                    "Consolidated: one pod in cloudsforge-estate serves both estates. "
                                    "A CNAME rather than a deletion so the gateway's namespace-local "
                                    "backend and every service-to-service call keep resolving unchanged."
                                )
                            },
                        },
                        "spec": {
                            "type": "ExternalName",
                            # RESOLVED THROUGH THE MERGE, NOT INTO IT. A merged
                            # service's mainnet Service is itself a CNAME, and
                            # chaining `analytics.cf-testnet -> analytics.<estate>
                            # -> lantern.<estate>` would make every testnet caller
                            # depend on a resolver following two hops. One hop to
                            # the pod that actually answers.
                            "externalName": f"{merge_target(name)}.{NETWORKS['mainnet']}.svc.cluster.local",
                        },
                    }
                )
            continue
        if name in EXCLUDED_SERVICES or name in MERGED_INTO_WEB_POD:
            continue
        # An absorbed service is not in the compose file at all — see the
        # MERGED_INTO block after this loop — so there is nothing to skip here.
        service = services[name]

        service_profiles = set(service.get("profiles") or [])
        if service_profiles and not (service_profiles & profiles):
            continue

        # ── A RETIRED SURFACE IS NOT DEPLOYED, IT IS ABSENT ──────────────────
        #
        # Wave 1 of the network consolidation (`docs/network-consolidation.md`).
        # The combined view (micro-org#459) made ONE bundle serve both networks:
        # the reader switches network in place and the bundle re-points its reads
        # at the other estate. `CF_WEB_RETIRED=true` on testnet has since gated
        # every testnet web ROUTER off, so on 2026-08-21 these twenty pods were
        # measured to be behind no live router, probed by no beacon target, and
        # serving zero requests — twenty nginx containers rendering byte-identical
        # bundles that nothing could reach.
        #
        # Scaling them to zero by hand does not survive the next deploy, which is
        # why the decision belongs here rather than in a kubectl command: the
        # renderer is the thing that decides what exists.
        #
        # `site` IS STILL RENDERED, and that exception is measured too — the
        # testnet gateway's live router set is exactly `cf-web-site`,
        # `cf-web-nimbus`, `cf-web-pay`, `cf-web-studio`, `cf-web-vault`, and of
        # those only the first has a web bundle behind it; the other four point at
        # APIs (identity, wallet, studio, custody). Dropping `site` would be an
        # outage, so it is named rather than pattern-matched.
        if config.get("CF_WEB_RETIRED") == "true" and is_retired_surface(name, service):
            retired_surfaces.append(name)
            continue

        # ── WHICH IMAGE ──────────────────────────────────────────────────────
        image = service.get("image")
        if image:
            # The three utility containers run stock upstream images. Compose
            # spells them literally and they carry no `${}`, so they pass
            # through; anything else with a literal image is new and worth
            # noticing rather than assuming.
            image, injected = resolver.resolve(name, "<image>", image)
            if injected:
                fail(f"{name} interpolates a secret into its image name")
        else:
            base = name[: -len("-migrate")] if name.endswith("-migrate") else name
            if base not in images:
                unresolved.append(name)
                continue
            # A migrator is pinned to the SAME image as its service, deliberately.
            # A migrator running a different build from the service that then
            # asserts its schema is the oldest way to brick a deploy.
            image = images[base]

        # ── ENVIRONMENT ──────────────────────────────────────────────────────
        injected_secrets, plain_env, secret_env = [], [], []
        for key in sorted(service.get("environment") or {}):
            value = str(service["environment"][key])

            if key in derived_vars:
                expected = derived_vars[key]["from"]
                if value != expected:
                    fail(
                        f"{name}.{key} is declared derived, but the compose file no longer holds the\n"
                        f"      expression {vars_path.name} records. scripts/k8s-secrets.py assembles the\n"
                        f"      value from the recorded one, so rendering now would point the service at a\n"
                        f"      Secret built from a stale definition.\n"
                        f"      compose:      {value}\n"
                        f"      render-vars:  {expected}\n"
                        f"      Update both, together."
                    )
                secret_env.append(
                    {"name": key, "valueFrom": {"secretKeyRef": {"name": DERIVED_SECRET, "key": key, "optional": False}}}
                )
                continue

            match = INTERP.fullmatch(value)
            if match and match.group(1) in secret_vars:
                secret_env.append(
                    {
                        "name": key,
                        "valueFrom": {
                            "secretKeyRef": {"name": TOKENS_SECRET, "key": match.group(1), "optional": False}
                        },
                    }
                )
                continue

            text, injected = resolver.resolve(name, key, value)
            for variable in injected:
                if variable not in injected_secrets:
                    injected_secrets.append(variable)
            plain_env.append({"name": key, "value": text})

        # ── THE SECOND ESTATE'S HANDLE ───────────────────────────────────────
        #
        # Same host, same role, same options — only `datname` differs, which is
        # the isolation §2.2 chose. Built by splitting the DSN rather than by
        # string-replacing the database name, because `agora` also appears in
        # the hostname of some services and a replace would rewrite both.
        # `name.removesuffix("-migrate")` and not `name`, because the MIGRATOR needs the
        # second handle more than the server does. Matched on `name` alone it got one DSN,
        # logged `network: primary` and exited 0 — and the adopted database would have
        # stood still through every future release until a boot-time schema assertion
        # refused testnet with the rest of the estate up. Caught on agora's cutover, by
        # reading the migrator's log rather than its exit code.
        if (
            args.network == "mainnet"
            and name.removesuffix("-migrate") in CONSOLIDATED_SERVICES
            and name.removesuffix("-migrate") not in SINGLE_DATABASE_SERVICES
        ):
            for entry in list(plain_env):
                if not entry["name"].endswith("_DATABASE_URL"):
                    continue
                head, _, tail = entry["value"].rpartition("/")
                dbname, sep, query = tail.partition("?")
                plain_env.append(
                    {"name": entry["name"] + "_TESTNET", "value": f"{head}/{dbname}_testnet{sep}{query}"}
                )

        # The injected entries come FIRST. Kubernetes expands `$(NAME)` only
        # against variables defined earlier in this same list; emitted after,
        # every DSN would reach Postgres with the literal text
        # `$(CF_POSTGRES_PASSWORD)` as its password.
        env = [
            {
                "name": variable,
                "valueFrom": {"secretKeyRef": {"name": TOKENS_SECRET, "key": variable, "optional": False}},
            }
            for variable in injected_secrets
        ] + secret_env + plain_env

        # ── VOLUMES ──────────────────────────────────────────────────────────
        volume_mounts, volumes = [], []
        for spec in service.get("volumes") or []:
            # Resolved BEFORE splitting, because `${CF_WORLD_ASSETS:-./estate/world-assets}`
            # contains a colon of its own — splitting first cut the default off
            # the variable and produced a source called `${CF_WORLD_ASSETS`.
            spec, injected = resolver.resolve(name, "<volume>", str(spec))
            if injected:
                fail(f"{name} interpolates a secret into a volume path")
            source, _, rest = spec.partition(":")
            mount_path, _, options = rest.partition(":")
            read_only = "ro" in options.split(",")
            if source in (compose.get("volumes") or {}):
                claim = source
                volume_mounts.append({"name": claim, "mountPath": mount_path, "readOnly": read_only})
                volumes.append({"name": claim, "persistentVolumeClaim": {"claimName": claim}})
            else:
                # A bind mount of repository content. There is no repository on
                # the cluster, so each one is named in render-vars and mounted
                # from what that says — a ConfigMap for a file, a PVC for a tree.
                binds = render_vars.get("bind_mounts") or {}
                if source not in binds:
                    fail(
                        f"{name} bind-mounts `{source}`, which render-vars does not describe.\n"
                        f"      Kubernetes has no host checkout to mount. Add an entry under\n"
                        f"      `bind_mounts:` saying whether it is a configMap or a persistentVolumeClaim,\n"
                        f"      and make sure something puts the content there."
                    )
                bind = binds[source]
                volume_mounts.append(
                    {
                        "name": bind["name"],
                        "mountPath": mount_path,
                        "readOnly": read_only,
                        **({"subPath": bind["subPath"]} if bind.get("subPath") else {}),
                    }
                )
                # `name` in a render-vars entry names the VOLUME. The source
                # underneath it takes a different key per kind — `claimName` for a
                # PVC, `name` for a ConfigMap — so each is built explicitly rather
                # than by copying the entry through a filter. The filter version
                # passed `name` into the PVC source as well, which the API rejects
                # under strict validation and which `kubectl apply` accepts in
                # its default mode by silently dropping.
                if bind["kind"] == "persistentVolumeClaim":
                    source_spec = {"claimName": bind["claimName"]}
                else:
                    source_spec = {"name": bind["configMap"]}
                volumes.append({"name": bind["name"], bind["kind"]: source_spec})

        # ── EVERY CONTAINER TRUSTS THE ESTATE'S OWN CA ───────────────────────
        #
        # Under compose exactly one service carried `NODE_EXTRA_CA_CERTS` —
        # beacon, because beacon is the only one that deliberately calls the
        # estate at the addresses a person uses. Everything else that names a
        # public hostname (`IDENTITY_JWKS_URL=https://nimbus.<apex>/...`, which
        # is EVERY testnet service, because testnet verifies tokens against the
        # shared identity) resolved that name on the public internet, went out
        # through Cloudflare, and came back to a publicly-trusted certificate.
        #
        # In the cluster that is no longer what happens. `k8s-cluster-dns.sh`
        # answers the estate's hostnames with the gateway's ClusterIP — it has
        # to, or a pod probing `hub.<apex>` is answered by a DIFFERENT estate —
        # and the gateway serves the estate CA leaf on testnet and a Cloudflare
        # ORIGIN CA leaf on mainnet. Neither is in a public root store. Measured
        # from `deploy/ledger` in cf-testnet on 2026-08-19, before this block:
        #
        #     UNABLE_TO_VERIFY_LEAF_SIGNATURE | unable to verify the first certificate
        #
        # and the visible consequence was every authenticated assertion in the
        # suite turning from `401` — testnet's own pre-existing shared-identity
        # defect, micro-org#472 — into `503 verifier_unavailable`, including
        # `an EXPIRED service token was answered 503; expiry is not being
        # enforced`. A verifier that cannot reach its JWKS does not fail closed
        # on expiry; it fails ambiguous on everything.
        #
        # UNIFORM RATHER THAN CONDITIONAL. The alternative was to attach this
        # only where an env value happens to hold an `https://…<apex>` URL, and
        # that rule is right until a service gains such a URL, or builds one
        # from two variables, or follows a redirect into one. `trust.crt` is the
        # estate CA PLUS every public root, so a container that gets it loses
        # nothing and no longer depends on which variable holds what today.
        #
        # A service that already sets the variable keeps its own value: beacon's
        # is the same path from its own bind mount, and this must not become a
        # second opinion about where the bundle is.
        trust = render_vars.get("cluster_tls_trust")
        if trust and not any(e["name"] == "NODE_EXTRA_CA_CERTS" for e in env):
            env.append({"name": "NODE_EXTRA_CA_CERTS", "value": trust["mountPath"]})
            if not any(m["mountPath"] == trust["mountPath"] for m in volume_mounts):
                volume_mounts.append(
                    {
                        "name": trust["volume"],
                        "mountPath": trust["mountPath"],
                        "readOnly": True,
                        "subPath": trust["key"],
                    }
                )
                volumes.append({"name": trust["volume"], "configMap": {"name": trust["configMap"]}})

        # ── EVERY SINGLE-NETWORK POD DECLARES WHICH NETWORK IT IS ────────────────
        #
        # `CF_NETWORK_SINGLE` was documented as a `pnpm dev` convenience and "never
        # in production". That was wrong, and it broke both estates on the first
        # deploy of the consolidation. Two reasons it is required here:
        #
        #  1. A pod has to key its OWN database handle. `networkSql({ mainnet: sql })`
        #     hardcoded on a testnet deployment means the testnet pod holds its DSN
        #     under the name `mainnet`, so every request the gateway stamps
        #     `CF-Network: testnet` is REFUSED by the pod's own data — which is
        #     exactly what five testnet services did, in a crash loop.
        #
        #  2. SERVICE-TO-SERVICE CALLS DO NOT PASS THROUGH THE GATEWAY. An outbox
        #     relay POSTing `/v1/events` to admin-api:4014 goes container to
        #     container; nothing stamps a header on it, and nothing can — the
        #     gateway is not in that path. Without a declared network those requests
        #     answer 500 `network_unknown`, which is what took mainnet's admin-api
        #     out. The gateway stamping "every request" was only ever true of
        #     requests that arrive through the gateway.
        #
        # So: a pod serving ONE estate says so, and the header is what OVERRIDES it
        # when a pod serves both. `requestNetwork` still prefers the header, so this
        # cannot mask a mis-stamped external request — it only answers the internal
        # callers that never had one.
        if not any(e["name"] == "CF_NETWORK_SINGLE" for e in env):
            env.append({"name": "CF_NETWORK_SINGLE", "value": args.network})

        container = {
            "name": name,
            "image": image,
            "imagePullPolicy": "IfNotPresent",
        }
        if service.get("command"):
            container["command"] = service["command"]
        if env:
            container["env"] = env
        froms = env_from(name, service, args.network)
        if froms:
            container["envFrom"] = froms
        if volume_mounts:
            container["volumeMounts"] = volume_mounts

        pod_spec = {"containers": [container]}
        if volumes:
            # De-duplicated: two mounts of one volume produce one entry.
            seen, unique = set(), []
            for volume in volumes:
                if volume["name"] in seen:
                    continue
                seen.add(volume["name"])
                unique.append(volume)
            pod_spec["volumes"] = unique
        if service.get("user"):
            uid, _, gid = str(service["user"]).partition(":")
            pod_spec["securityContext"] = {"runAsUser": int(uid), **({"runAsGroup": int(gid)} if gid else {})}
        # ── `extra_hosts` NEEDS A DECISION PER NAME, NOT A DEFAULT ───────────
        #
        # Kubernetes has no Docker bridge, so `name:host-gateway` has no
        # translation — only a choice between an explicit address and deliberate
        # removal. Both are recorded in render-vars, and an undeclared name is
        # fatal: guessing wrong points a money-tier service's chain RPC at the
        # wrong machine, and nothing about that announces itself.
        aliases = []
        for entry in service.get("extra_hosts") or []:
            hostname, _, target = str(entry).partition(":")
            declared = (render_vars.get("extra_hosts") or {}).get(hostname)
            if declared is None:
                fail(
                    f"{name} declares `extra_hosts: {entry}` and {vars_path.name} does not say what\n"
                    f"      `{hostname}` should mean on the cluster. Add it under `extra_hosts:` as either\n"
                    f"      an IP address or `drop`, with the reason."
                )
            if declared == "drop":
                continue
            aliases.append({"ip": declared, "hostnames": [hostname]})
        if aliases:
            pod_spec["hostAliases"] = aliases

        labels = {
            "app.kubernetes.io/name": name,
            "app.kubernetes.io/part-of": "cloudsforge-estate",
            "online.cloudsforge.network": args.network,
        }

        # ── JOB OR DEPLOYMENT ────────────────────────────────────────────────
        #
        # `restart: no` is the compose file's own marker for "runs once and
        # exits 0", argued there at length: a migrator under `unless-stopped`
        # re-runs its migrations on every daemon start, forever. So the restart
        # policy IS the classification, and it does not need a name convention.
        if service.get("restart") == "no":
            release_tag = str(release.get("version", "release")).replace(".", "-")
            jobs.append(
                {
                    "apiVersion": "batch/v1",
                    "kind": "Job",
                    # A Job's pod template is immutable, so a fixed name cannot be
                    # re-applied with a new image — `kubectl apply` fails on the
                    # next release with "field is immutable". Naming it after the
                    # release makes each deploy a new object and each rollback a
                    # re-apply of an old one, which is the same shape the release
                    # manifest already has.
                    "metadata": {"name": f"{name}-{release_tag}", "namespace": namespace, "labels": labels},
                    "spec": {
                        "backoffLimit": 2,
                        # Kept an hour, not deleted on success: a migrator's logs
                        # are the only record of what a release did to the schema,
                        # and they are wanted most in the minutes after a deploy
                        # goes wrong.
                        "ttlSecondsAfterFinished": 3600,
                        "template": {"metadata": {"labels": labels}, "spec": {**pod_spec, "restartPolicy": "Never"}},
                    },
                }
            )
            continue

        if service.get("healthcheck"):
            probes, port = probe_from_healthcheck(name, service["healthcheck"])
            container.update(probes)
        else:
            port = None

        # ── PORTS: THE HOST BINDING IS DROPPED, THE CONTAINER PORT IS NOT ────
        #
        # Every mapping is `127.0.0.1:<host>:<container>` — bound to loopback so
        # that only Traefik on the same host could reach it. A ClusterIP Service
        # gives exactly that property natively and needs no host port at all, so
        # the left-hand side is discarded. The single exception is the pool's
        # stratum listeners, which are bound to `0.0.0.0` on mainnet because real
        # miners connect from the internet; those become a LoadBalancer.
        container_ports, stratum_ports = [], []
        for mapping in service.get("ports") or []:
            resolved, injected = resolver.resolve(name, "<ports>", mapping)
            if injected:
                fail(f"{name} interpolates a secret into a port mapping")
            parts = resolved.split(":")
            bind, container_port = (parts[0], parts[-1]) if len(parts) == 3 else ("127.0.0.1", parts[-1])
            container_ports.append({"containerPort": int(container_port)})
            if bind not in ("127.0.0.1", "localhost"):
                stratum_ports.append(int(container_port))

        # ── A SERVICE WITH NO `ports:` STILL NEEDS A Service, AND THIS IS WHY ──
        #
        # Six frontends — exchange-web, journal-web, agora-web, lantern-web,
        # pool-web, beacon-web — publish NO host port on purpose, and the compose
        # file argues the case at each one: "the gateway resolves it by container
        # name and a second address for the same bundle is the one nobody tests".
        # Under compose that is complete. A container on the network answers to
        # its own name whether or not anything is published; `ports:` was only
        # ever about reaching it from the HOST.
        #
        # Kubernetes does not work that way. A Pod has no DNS name — a SERVICE
        # does — so rendering only from `ports:` left those six with no address
        # at all, and the gateway's `http://exchange-web:8080` resolved to
        # nothing. Measured on the live cluster: 6 of 67 routers answered 502
        # while all 50 Deployments read 1/1 Running and every readiness probe
        # passed, because the probe talks to localhost inside the pod and never
        # crosses the network that was missing.
        #
        # The port is not guessed and not tabled: it is the one the healthcheck
        # already proved the service listens on, the same value `probe_from_
        # healthcheck` returns for the readiness probe above. A service with
        # neither `ports:` nor a healthcheck gets no Service, which is right —
        # nothing has established that it listens at all.
        if not container_ports and port is not None:
            container_ports.append({"containerPort": port})

        if container_ports:
            seen, unique = set(), []
            for entry in container_ports:
                if entry["containerPort"] in seen:
                    continue
                seen.add(entry["containerPort"])
                unique.append(entry)
            container["ports"] = unique
            svcs.append(
                {
                    "apiVersion": "v1",
                    "kind": "Service",
                    "metadata": {"name": name, "namespace": namespace, "labels": labels},
                    "spec": {
                        "type": "ClusterIP",
                        "selector": {"app.kubernetes.io/name": name},
                        "ports": [
                            {"name": f"p{entry['containerPort']}", "port": entry["containerPort"],
                             "targetPort": entry["containerPort"]}
                            for entry in unique
                        ],
                    },
                }
            )
        if stratum_ports:
            svcs.append(
                {
                    "apiVersion": "v1",
                    "kind": "Service",
                    "metadata": {
                        "name": f"{name}-stratum",
                        "namespace": namespace,
                        "labels": labels,
                        "annotations": {
                            "online.cloudsforge.why": (
                                "Bound to 0.0.0.0 under compose because miners connect from the "
                                "internet. The only service in the estate not fronted by Traefik: "
                                "Stratum is a persistent line-delimited JSON socket, not HTTP."
                            )
                        },
                    },
                    "spec": {
                        "type": "LoadBalancer",
                        "selector": {"app.kubernetes.io/name": name},
                        "ports": [{"name": f"stratum-{p}", "port": p, "targetPort": p} for p in sorted(stratum_ports)],
                    },
                }
            )

        deployments.append(
            {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {"name": name, "namespace": namespace, "labels": labels},
                "spec": {
                    # One replica, matching compose. Scaling is a per-service
                    # decision about whether that service holds state in memory,
                    # and answering it for 52 services at once as a side effect of
                    # a platform migration would be guessing.
                    "replicas": 1,
                    "selector": {"matchLabels": {"app.kubernetes.io/name": name}},
                    # `Recreate` because a ReadWriteOnce PVC cannot be attached to
                    # the old and new pods at once — a rolling update would wedge
                    # with the new pod Pending on a volume the old one still holds.
                    # The test is PVC-BACKED volumes specifically, not "has any
                    # mount at all": every container now mounts the `gateway-trust`
                    # ConfigMap, and a ConfigMap mounts into as many pods as ask
                    # for it. Keyed off the mount list, the trust bundle would have
                    # quietly converted all 52 services to downtime-per-deploy.
                    "strategy": (
                        {"type": "Recreate"}
                        if any("persistentVolumeClaim" in v for v in volumes)
                        else {"type": "RollingUpdate"}
                    ),
                    "template": {"metadata": {"labels": labels}, "spec": pod_spec},
                },
            }
        )

    if unresolved:
        fail(
            "these services have no `image:` and are not named by the release manifest, so there is\n"
            "      nothing to run:\n        " + "\n        ".join(unresolved) + "\n"
            f"      Cut a release that includes them, or point --release at one that does."
        )

    # Two sources of claims: compose's own named volumes, and the bind mounts
    # render-vars redirects into a PVC because there is no checkout to bind. Both
    # need a PersistentVolumeClaim object and neither exists without one.
    sizes = render_vars.get("volume_sizes") or {}
    claims = set(compose.get("volumes") or {}) | {
        bind["claimName"]
        for bind in (render_vars.get("bind_mounts") or {}).values()
        if bind["kind"] == "persistentVolumeClaim"
    }
    for claim in sorted(claims):
        if claim not in sizes:
            fail(
                f"volume `{claim}` has no size in {vars_path.name}. Add it under `volume_sizes:`;\n"
                f"      a PVC with no request is not a PVC."
            )
        pvcs.append(
            {
                "apiVersion": "v1",
                "kind": "PersistentVolumeClaim",
                "metadata": {"name": claim, "namespace": namespace,
                             "labels": {"online.cloudsforge.network": args.network}},
                "spec": {
                    "accessModes": ["ReadWriteOnce"],
                    # `cf-retain`, the same StorageClass the database uses:
                    # deleting the claim orphans the directory instead of erasing
                    # it. custody-keys holds encrypted key blobs.
                    "storageClassName": "cf-retain",
                    "resources": {"requests": {"storage": sizes[claim]}},
                },
            }
        )

    header = (
        f"# GENERATED by scripts/k8s-render.py — do not hand-edit.\n"
        f"#\n"
        f"# Network:   {args.network}\n"
        f"# Namespace: {namespace}\n"
        f"# Release:   {release.get('version')}  ({release_path.name})\n"
        f"# Source:    {compose_path.as_posix()} + {vars_path.name}\n"
        f"#\n"
        f"# Regenerate with:\n"
        f"#   ./scripts/k8s-render.py --network {args.network} --release {release_path} \\\n"
        f"#       --outdir k8s/estate/{args.network}\n"
        f"#\n"
        f"# Contains NO secret values. Every credential is a secretKeyRef by name; see the\n"
        f"# script's docstring for the three shapes and why each is handled the way it is.\n"
    )

    # ── AN ABSORBED SERVICE IS A NAME WITH NO WORKLOAD ───────────────────────
    #
    # Emitted from MERGED_INTO rather than from the compose file, because an
    # absorbed service IS NOT IN THE COMPOSE FILE. That is the difference between
    # this and MERGED_INTO_WEB_POD above, and it is worth stating plainly:
    #
    #   * A web bundle keeps its compose service. It is still its own image and
    #     its own repo, and `make up` still runs twenty containers locally. Only
    #     Kubernetes groups them differently.
    #   * An ABSORBED service does not. Its code now ships inside the absorber's
    #     image, so its old image is stale by construction — and running that
    #     stale image beside the absorber under compose would point two different
    #     versions of the same code at the same database. Leaving the compose
    #     entry in place to "keep local dev working" would be the bug.
    #
    # So the name survives here and only here: one Service, of type ExternalName,
    # so that every `http://analytics:4000` still resolves on cutover day and no
    # caller has to be edited in the same change that moves the code. Callers
    # migrate to the absorber's name at leisure; rollback is deleting the map
    # entry and re-adding the compose service.
    # The two halves of a merge have to land together. If the compose service is
    # still there, the loop above has ALREADY emitted a real ClusterIP under this
    # name and the alias below would be a second Service with the same name in the
    # same namespace — which `kubectl apply` rejects on the second document, half
    # way through a deploy. Refuse here instead, where the message can say why.
    for absorbed in sorted(MERGED_INTO):
        if absorbed in services:
            raise SystemExit(
                f"'{absorbed}' is in MERGED_INTO but still has a compose service. Its code now "
                f"ships inside {merge_target(absorbed)}'s image, so the old image is stale by "
                f"construction and running both would point two versions of the same code at one "
                f"database. Delete the '{absorbed}' and '{absorbed}-migrate' services from the "
                f"compose file, and move any environment only they declared onto "
                f"{merge_target(absorbed)}."
            )

    for absorbed in sorted(MERGED_INTO):
        target = merge_target(absorbed)
        svcs.append(
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {
                    "name": absorbed,
                    "namespace": namespace,
                    "labels": {
                        "app.kubernetes.io/name": absorbed,
                        "app.kubernetes.io/part-of": "cloudsforge",
                    },
                    "annotations": {
                        "online.cloudsforge.why": (
                            f"Merged into {target}: this service's code now runs inside that "
                            f"pod as a module, so it has no Deployment and no migrate Job of "
                            f"its own — a second migrator against a schema that pod now owns "
                            f"is the fastest way to corrupt it. A CNAME rather than a deletion "
                            f"so service-to-service calls keep resolving unchanged."
                        )
                    },
                },
                "spec": {
                    "type": "ExternalName",
                    # ALWAYS the mainnet namespace. The absorber is consolidated —
                    # one pod answers for both estates — so pointing a testnet
                    # alias at a testnet copy would name a pod that does not exist.
                    "externalName": f"{target}.{NETWORKS['mainnet']}.svc.cluster.local",
                },
            }
        )

    # ── the reverse CNAMEs; see TESTNET_ONLY_BRIDGED ─────────────────────────
    if args.network == "mainnet":
        for bridged, port in sorted(TESTNET_ONLY_BRIDGED.items()):
            svcs.append(
                {
                    "apiVersion": "v1",
                    "kind": "Service",
                    "metadata": {
                        "name": bridged,
                        "labels": {
                            "app.kubernetes.io/name": bridged,
                            "app.kubernetes.io/part-of": "cloudsforge",
                        },
                        "annotations": {
                            "online.cloudsforge.why": (
                                "Testnet-only service, reached from here because the TESTNET "
                                "gateway now runs in this namespace. The mainnet gateway emits "
                                "no router and no upstream for it: both sit inside "
                                "{{ if eq (env \"CF_EMBER_NETWORK\") \"testnet\" }}, so this "
                                "name is resolvable only from the testnet router table."
                            )
                        },
                    },
                    "spec": {
                        "type": "ExternalName",
                        "externalName": f"{bridged}.{NETWORKS['testnet']}.svc.cluster.local",
                        # Ignored by an ExternalName; present so k8s-gateway.sh's
                        # upstream proof can see the port its router uses.
                        "ports": [{"name": f"p{port}", "port": port, "targetPort": port}],
                    },
                }
            )

    outputs = {
        "20-pvc.yaml": pvcs,
        "30-migrate-jobs.yaml": jobs,
        "40-services.yaml": svcs,
        "50-deployments.yaml": deployments,
    }
    for filename, documents in outputs.items():
        body = header + "".join(
            "---\n"
            + yaml.dump(
                document,
                Dumper=EstateDumper,
                sort_keys=False,
                default_flow_style=False,
                width=10**9,  # never fold; see EstateDumper
            )
            for document in documents
        )
        if args.outdir:
            target = pathlib.Path(args.outdir) / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body)
        else:
            sys.stdout.write(body)

    print(
        f"{args.network}: {len(pvcs)} PVC, {len(jobs)} Job, {len(svcs)} Service, "
        f"{len(deployments)} Deployment  (release {release.get('version')})",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
