-- One server, one database per service.
--
-- ── WHY ONE SERVER, AND WHY THAT IS NOT A RULE VIOLATION ──────────────────────
--
-- Rule 1 of 03 §2 is that a service owns exactly one database and reads no
-- other. That rule is about OWNERSHIP — no service may read another's tables —
-- and it is kept here: every service below gets its own database, its own
-- migrator, its own connection string, and no grant to anything else. What is
-- shared is the SERVER PROCESS, not the data.
--
-- Production isolation is a separate requirement and it is NOT met here. In
-- production each of these is its own Postgres instance with its own failure
-- domain, its own backup schedule and its own credentials; a noisy neighbour
-- there takes down one service, and here it takes down all of them.
--
-- This file is DEV-ONLY, and the compromise is deliberate: twenty-one Postgres
-- containers on a laptop is ~21x the memory floor and a boot time long enough
-- that nobody runs the environment, and an environment nobody runs is the exact
-- condition this deployment work exists to end. One server with a database per
-- service preserves the property the verification actually depends on — that a
-- service cannot reach another's tables — at a fraction of the cost.
--
-- The one thing this must never become is a shared SCHEMA. Separate databases
-- rather than separate schemas, because a shared schema would let a stray join
-- succeed and would prove the opposite of what this environment is here to
-- prove.

-- -- the four the first slice proved ------------------------------------------
CREATE DATABASE identity;
CREATE DATABASE ledger;
CREATE DATABASE activity;
CREATE DATABASE notify;

-- -- policy and pricing: no upstream but identity ------------------------------
CREATE DATABASE policy;
CREATE DATABASE pricing;

-- -- the rest of the 22 domain services (03 §1.1) ------------------------------
-- hub-api is absent from this list ON PURPOSE: it is a BFF with no migrator and
-- no database of its own (it has no src/migrator.ts), so a database for it would
-- be an empty one that nothing ever opens.
CREATE DATABASE wallet;
CREATE DATABASE settlement;
CREATE DATABASE billing;
CREATE DATABASE custody;
CREATE DATABASE indexer;
CREATE DATABASE studio;
CREATE DATABASE mint;
CREATE DATABASE market;
CREATE DATABASE trade;
CREATE DATABASE worlds;
CREATE DATABASE nda;
CREATE DATABASE community;
CREATE DATABASE devplatform;
CREATE DATABASE analytics;
-- admin_api, not admin-api: a hyphen in an unquoted identifier is a syntax
-- error, and quoting it would force every psql invocation in the verify script
-- to quote it too.
CREATE DATABASE admin_api;

-- -- the fourth Forge Worlds title (docs/ecosystem/23-tessera.md) --------------
-- The first title SERVICE in this environment. That claim was written when
-- emberkin and aetherholm had web bundles here and no backend; both now have a
-- database below, so this is first in ORDER only and no longer the only one.
-- It is a persistent world — 23-tessera.md §4 puts it plainly,
-- "persistence means Postgres, and nothing else": there is no per-ward tick and
-- no per-user simulation process, so an object placed IS a row, and this
-- database is the entire authoritative world.
CREATE DATABASE tessera;

-- -- the observability sink (docs/ecosystem/13-operational-model.md) ------------
-- micro-lantern, and it was ABSENT FROM THIS ENVIRONMENT ENTIRELY: `grep -c
-- lantern` over the estate compose file returned 0. Every frontend in the estate
-- has been posting browser telemetry for months to a service that was not
-- deployed, and the failure was invisible from the page — a cross-origin POST to
-- a host that is not there is reported to the script as `TypeError: Failed to
-- fetch`, which is indistinguishable from the wrong-path 404 the bundles were
-- also sending. Both defects were live at once, and neither could be seen
-- without fixing the other.
--
-- The service holds four planes: normalised log events, deduplicated issues,
-- rollups, and `rum_samples` — the browser sink. Everything here expires; the
-- RUM plane at thirty days, and by policy it carries NO `user_id` column at all.
CREATE DATABASE lantern;

-- -- the five deployables this estate had never once run ------------------------
--
-- micro-org's `deployableRepos()` lists 45 services. This compose file served 40
-- of them, and `scripts/web-check.py` had been reporting the other five by name
-- and by derived port on every run — "registry rows with no container in this
-- compose file" — which is not a failure and is also not nothing. Three of the
-- five are the BACKENDS OF FRONTENDS THIS ESTATE ALREADY SERVES: foresight-web,
-- emberkin-web and aetherholm-web have been answering on their own hostnames
-- with their APIs absent, which from a browser is a page that renders and then
-- cannot do anything.
--
-- A NOTE ON WHEN THIS FILE RUNS, because it caught this work out: postgres runs
-- /docker-entrypoint-initdb.d ONLY when its data directory is empty. Adding a
-- line here does nothing to a volume that already exists, so each database below
-- was also created by hand against the running server. This file is what makes a
-- FRESH estate come up whole; it is not what fixed the running one.

-- The sky-island strategy MMO, and the second Forge Worlds title. Inbound-only:
-- worlds calls POST /v1/provision with a credential carrying `aetherholm:provision`
-- and this service makes no outbound HTTP call at all, which is why its block in
-- the compose file has no upstream URL and no service credential.
CREATE DATABASE aetherholm;

-- The monster-collecting RPG, the second Forge Worlds title with a container
-- here. Unlike aetherholm it DOES call out — ledger, billing and worlds — and
-- presents a ten-minute token to do it (`emberkin/src/index.ts:60`).
CREATE DATABASE emberkin;

-- The release gate: synthetic journeys, incidents and SLOs. It had never been
-- started in any environment, so every judgement made about this estate so far
-- was made without the service whose job is to judge it.
CREATE DATABASE beacon;

-- The testnet faucet. It holds NO key — `faucet/src/custodyclient.ts` sends an
-- unsigned legacy transfer to micro-custody and receives bytes — so what lives in
-- this database is dispense state and the rate-limit ledger: `dispenses` with the
-- two partial unique indexes that make two in-flight transactions on one nonce
-- impossible, and the budget CHECK. Those are exactly the objects the migrator
-- must create BEFORE the service boots, which is why the one-shot is not
-- optional here in a way it is merely tidy elsewhere.
CREATE DATABASE faucet;

-- Prediction markets. The last of the five, and the one with a frontend
-- (`foresight-web`, `foresight-admin-web`) that this estate has been serving
-- against nothing at all. It deploys contracts to the EMBER testnet through
-- custody's `deployer` purpose, so this database holds the market registry, the
-- proposal queue and the settlement record for each.
CREATE DATABASE foresight;


-- The mining pool. Shares, jobs, blocks found and the PPLNS window each was
-- decided against — a DEBT RECORD, not money: `pool/src/payouts.ts` is a typed
-- seam that throws, and there is deliberately no payouts table, because an empty
-- `pool_payout_credits` would read to the next person as a feature that exists
-- and is not firing.
--
-- Created here even though the service is behind the `pool` profile and does not
-- start by default. This file only ever runs on an EMPTY data directory, so a
-- database left out now is one that has to be created by hand on every estate
-- that already exists — which is the manual step this file exists to remove. On
-- the estates already running, it was created by hand once, deliberately, and
-- that is recorded rather than assumed.
CREATE DATABASE pool;


-- The public square. Voices, posts, circles, whispers, reports and the
-- moderation record, all keyed to an identity account that already exists —
-- micro-agora issues nothing and stores no password.
--
-- Whispers are the reason this is its own database rather than a schema inside
-- `community`: a private message between two people is the one thing here that
-- no other service may ever join against, and rule 1 makes that structural
-- instead of a convention somebody remembers.
--
-- Same note as `pool` above: this file only runs on an EMPTY data directory, so
-- on the estates already running this database was created by hand once,
-- deliberately, and that is recorded rather than assumed.
CREATE DATABASE agora;
