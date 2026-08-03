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
-- The first title SERVICE in this environment: emberkin and aetherholm have web
-- bundles here and no backend, so this is the first time a title's own database
-- exists at all. It is a persistent world — 23-tessera.md §4 puts it plainly,
-- "persistence means Postgres, and nothing else": there is no per-ward tick and
-- no per-user simulation process, so an object placed IS a row, and this
-- database is the entire authoritative world.
CREATE DATABASE tessera;
