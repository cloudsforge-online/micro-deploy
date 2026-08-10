# One command up, one command down. Everything else here is a check that can be
# run before a change lands rather than discovered after it.

COMPOSE_PROJECT_NAME ?= cfmicro
TELEMETRY := -f compose/docker-compose.telemetry.yml
GATEWAY   := -f compose/docker-compose.gateway.yml
PROM_IMG  := prom/prometheus:v2.55.1
# v0.28.1: v0.27.0 segfaults on any non-2xx from a `url_file` webhook
# (prometheus/alertmanager#3798). Kept equal to the image in
# compose/docker-compose.telemetry.yml — a check that validates a config against
# a different build from the one that runs it is a check that can pass wrongly.
AM_IMG    := prom/alertmanager:v0.28.1
OTEL_IMG  := otel/opentelemetry-collector-contrib:0.115.1

.DEFAULT_GOAL := help
.PHONY: help up down gateway logs ps config check check-rules check-rule-tests \
        check-alertmanager \
        check-collector check-runbooks check-prometheus-targets check-compose-ports \
        check-token-resolution check-custody-backup-guard check-backup \
        prometheus-targets \
        dashboards estate clean

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  %-18s %s\n", $$1, $$2}'

up: ## Bring the telemetry plane up beside the existing estate
	@./up.sh

gateway: ## Bring up telemetry AND the Traefik gateway
	@./up.sh --gateway

down: ## Stop it again, keeping history
	@./down.sh

clean: ## Stop it and delete all telemetry history
	@./down.sh --volumes

ps: ## What is running in this project
	@docker compose -p $(COMPOSE_PROJECT_NAME) $(TELEMETRY) $(GATEWAY) ps

logs: ## Follow every component's logs
	@docker compose -p $(COMPOSE_PROJECT_NAME) $(TELEMETRY) logs -f --tail=50

config: ## Validate and render the composed configuration
	@docker compose $(TELEMETRY) config >/dev/null && echo "ok: telemetry compose is valid"
	@docker compose $(TELEMETRY) $(GATEWAY) config >/dev/null && echo "ok: gateway overlay is valid"

dashboards: ## Regenerate dashboard JSON from the validated palette
	@python3 grafana/build-dashboards.py

# ------------------------------------------------------------------ checks --
# These are the CI job. Every one of them fails a build rather than producing a
# warning nobody reads.
check: config check-rules check-rule-tests check-alertmanager check-collector check-runbooks check-prometheus-targets check-compose-ports check-token-resolution check-custody-backup-guard check-backup ## Run every check
	@echo "ok: all checks passed"

check-rules: ## promtool over the recording and alerting rules
	@docker run --rm --entrypoint /bin/promtool \
		-v "$(PWD)/prometheus:/p:ro" $(PROM_IMG) \
		check rules /p/rules/slo.yaml /p/rules/alerts.yaml
	@docker run --rm --entrypoint /bin/promtool \
		-v "$(PWD)/prometheus:/p:ro" $(PROM_IMG) \
		check config --syntax-only /p/prometheus.yml

check-rule-tests: ## promtool UNIT TESTS — the rules actually fire, not merely parse
	@# `check-rules` above proves the rules PARSE, and that is all it proves. Three
	@# deployed rules in this file have referenced a metric or a label that nothing
	@# exported — `backup_last_success_timestamp_seconds`,
	@# `ledger_reconciliation_drift_native`, `{{ $$labels.chain }}` — and every one
	@# of them was valid YAML that passed the target above and could never page.
	@#
	@# `test rules` is the only thing that can tell those apart, because it
	@# supplies the series. The test file names its own `rule_files`, so the rules
	@# under test are chosen there and not here.
	@docker run --rm --entrypoint /bin/promtool \
		-v "$(PWD)/prometheus:/p:ro" $(PROM_IMG) \
		test rules /p/rules/alerts.test.yaml

check-alertmanager: ## amtool over the routing configuration
	@docker run --rm --entrypoint /bin/amtool \
		-v "$(PWD)/alertmanager:/a:ro" $(AM_IMG) \
		check-config /a/alertmanager.yml

check-collector: ## The collector validates its own pipeline without starting it
	@docker run --rm -v "$(PWD)/otel:/etc/otel:ro" \
		-e OTEL_ENV=ci -e OTEL_LOG_LEVEL=info \
		-e LANTERN_OTLP_ENDPOINT=http://lantern:4010/otlp \
		$(OTEL_IMG) validate --config=/etc/otel/collector.yaml
	@echo "ok: collector pipeline is valid"

check-runbooks: ## THE RUNBOOK RULE — every alert carries a link, and it resolves
	@# An alert without a runbook is deleted, not silenced, because an
	@# unactionable page teaches the on-call to ignore pages. This is the check
	@# that makes that a property rather than an intention.
	@python3 scripts/check-runbooks.py

check-compose-ports: ## No two containers composed onto one host publish the same port
	@# The backup overlay published 4130 and trade-web already had it, so the
	@# first bring-up on mainnet failed after a full image build. `config`
	@# above does this for the telemetry and gateway overlays by composing
	@# them; the estate set cannot be composed without the untracked tokens
	@# file, so it is read as YAML instead. micro-org#328.
	@python3 scripts/check-compose-host-ports.py

check-token-resolution: ## up.sh resolves each token to ONE home, and refuses two that disagree (micro-org#156)
	@./scripts/check-token-resolution.sh

check-custody-backup-guard: ## a backup set never carries the keyring beside the vault (micro-org#25)
	@./scripts/check-custody-backup-guard.sh

check-backup: ## backup/'s own suite — the one deployable that lives in this repository
	@# `deploy/backup` is a real Node service with 97 tests, and until 2026-08-10
	@# nothing ran them: not CI, not `make check`. They were enforced by whoever
	@# remembered to type `pnpm test`, which for a process holding a superuser DSN
	@# and read access to the custody vault is not enforcement.
	@#
	@# micro-runtime is a SIBLING CHECKOUT, not a dependency fetched from a
	@# registry: backup/package.json takes `link:../../runtime/packages/{jobs,
	@# lifecycle,telemetry}` — two levels up from `deploy/backup`, so one level up
	@# from here — and those packages point `main` at their own `src/index.ts`, so
	@# nothing needs building. They DO need their own `pnpm install`, because
	@# `link:` does not install the linked package's dependencies. Measured
	@# 2026-08-10: skip it and disk.test.ts alone fails with
	@# `Cannot find package '@opentelemetry/api'` while the other 8 files pass, so
	@# the omission reads as a broken test rather than as a missing install.
	@test -d ../runtime/packages/telemetry || { \
	  echo "micro-runtime must be checked out beside this repository at ../runtime"; exit 2; }
	@cd ../runtime && pnpm install --frozen-lockfile
	@cd backup && pnpm install --frozen-lockfile && pnpm typecheck && pnpm test

check-prometheus-targets: ## The scrape list is generated from the release, and excludes what cannot be scraped
	@# `prometheus/targets/services.yaml` was the literal `[]` from the telemetry
	@# plane's first deploy until 2026-08-09, so Prometheus scraped none of the 48
	@# deployed services and all twenty alert rules evaluated against no data
	@# (micro-org#308). It is generated now. This is the check that keeps the
	@# generator right in BOTH directions — a partial list means nothing is
	@# watched, and a target that cannot be scraped sits down for ever and teaches
	@# the on-call that some of the red is normal.
	@python3 scripts/check-prometheus-targets-render.py

prometheus-targets: ## Re-render the scrape list from a release by hand. RELEASE=2.5.8
	@# release-deploy.sh does this on every deploy and every rollback. This target
	@# is for the case that step is reported as having failed, and for looking at
	@# what a release WOULD scrape without deploying it.
	@test -n "$(RELEASE)" || { echo "usage: make prometheus-targets RELEASE=<version>"; exit 2; }
	@python3 scripts/render-prometheus-targets.py "../org/releases/$(RELEASE).yaml" \
		--env-file compose/mainnet.env --env-file compose/estate/tokens.env \
		--out prometheus/targets/services.yaml

check-secrets: ## No secret is a placeholder, too short, or already in a transcript
	@# CI guards a secret that is COMMITTED. Neither failure this catches is a
	@# commit, so neither was ever visible to it: a placeholder-shaped signing key
	@# live in an accept list (40 chars, so every length gate passed; not one of
	@# the eight known strings, so every placeholder gate passed), and a secret
	@# printed into an agent transcript by `docker inspect`. See
	@# runbooks/runbook-secret-leaked-to-transcript.md. Prints NO secret values.
	@python3 scripts/check-secret-hygiene.py \
	@# `.env` at the repository root is in the list because it is the ONLY home of
	@# CF_GRAFANA_ADMIN_PASSWORD — the telemetry plane reads it, `compose/.env` is
	@# a symlink to the estate's tokens and does not contain it, and so a check
	@# against the three compose paths alone had a live credential outside its
	@# field of view (measured 2026-08-10, during micro-org#156).
		--files compose/secrets/*.env compose/estate/tokens.env compose/.env .env

check-residue: ## Does any file on this host still hold a live estate secret? ROOTS=<dirs>
	@# THE LAST STEP OF EVERY ROTATION, and the one that was being skipped because
	@# it had no name. A rotation is not finished when the running containers are
	@# clean: the retired value is still in whatever `.env.bak-*` was made before
	@# the edit, and twice it was still in an exited `*-migrate-1` container. This
	@# target covers the file half; the container half is `make check-secrets`
	@# plus `docker rm` of the exited residue.
	@#
	@# It reports the MODE of each file it finds, so a hit that is world-readable
	@# is distinguishable from a hit that is not (micro-org#340). It prints
	@# variable NAMES and paths, never a value.
	@python3 scripts/check-secret-hygiene.py \
		--transcripts $(or $(ROOTS),$(HOME)) \
		--against compose/secrets/*.env compose/estate/tokens.env compose/.env .env \
		--allow prometheus/secrets alertmanager/secrets

estate: ## Confirm the existing eighteen containers are still healthy
	@docker ps --filter name=cloudsforge- --format '{{.Names}}\t{{.Status}}' | sort

# --------------------------------------------------- the estate environment --
# ── THE ENV FILES ARE PART OF THE INVOCATION, NOT AN OPTIONAL EXTRA ───────────
#
# This used to be `-f compose/docker-compose.estate.yml` alone, and that omission
# is how #152 recurred on 2026-08-05: mainnet identity was recreated with a plain
# `docker compose $(ESTATE) up -d identity`, `CF_WEB_SUFFIX` was therefore unset,
# `IDENTITY_HANDOFF_ORIGINS` resolved to its `:-.cloudsforge.localtest.me` dev
# default, and cross-surface SSO was dead on production for every surface.
#
# It fails SILENTLY on mainnet and CANNOT fail on testnet, which is why it went
# unnoticed: `compose/.env` is a symlink to `estate/tokens.env` and Compose
# auto-loads it, so a mainnet render with no `--env-file` still resolves
# `CF_POSTGRES_PASSWORD` and the stack comes up healthy — only the apex-dependent
# variables quietly take dev values. Testnet has no `.env` fallback, so the same
# mistake dies on the first interpolation.
#
# So the variable carries both files. Anything using $(ESTATE) is correct by
# default, and a mainnet deploy no longer depends on remembering.
ESTATE  := --env-file compose/mainnet.env --env-file compose/estate/tokens.env \
           -f compose/docker-compose.estate.yml
# The gateway, wired to the estate's network and bound to 443. Needed by every
# browser surface: a bundle derives its sibling hosts as `https://<sub>.<apex>`
# with NO PORT, so 9096 is unreachable to the page that was served on it.
#
# ── IT IS IN THE ESTATE'S PROJECT, WHICH IS THE WHOLE OF #257 ────────────────
#
# This was `-p $(COMPOSE_PROJECT_NAME)` — the TELEMETRY plane's project — so the
# container every public hostname depends on was labelled `cfmicro` while the
# ~50 services it serves are labelled `cloudsforge-estate`, and
# `docker compose -p cloudsforge-estate ps` did not list it. The testnet twin of
# that mistake got the testnet gateway deleted as an apparent orphan twice in
# three days, each time putting every public `*-testnet` hostname on 502 with all
# 46 services healthy. The mainnet gateway carried the same defect and the live
# traffic.
#
# NO TELEMETRY OVERLAY here any more, for the same reason `GW_TESTNET` never had
# one: with the projects split, a `-f docker-compose.telemetry.yml` on this line
# would create a SECOND telemetry plane inside the estate's project. The three
# `cf-micro-*` networks are declared `external` and are created by `make up`,
# which `estate-up.sh` runs first; if they are absent this fails by name rather
# than starting a gateway that resolves nothing.
GW_PROJECT ?= cloudsforge-estate
GW_ESTATE := -p $(GW_PROJECT) \
             -f compose/docker-compose.gateway.yml \
             -f compose/docker-compose.estate-gateway.yml

# ── the TESTNET gateway, which had never been started ────────────────────────
#
# Found 2026-08-05: nothing was listening on 127.0.0.1:9181, so EVERY testnet
# public hostname answered 502 — hub, worlds, market, explorer, status, api and
# account alike. The tunnel's ingress points every `*-testnet` name at that port
# and cloudflared reports an unreachable origin as 502, which reads as "the
# service fell over" when the truth was "the gateway for this environment has
# never run". It is the same misdiagnosis the deleted `cf-api-catchall`
# blackhole caused on `api.`, one layer further out.
#
# Every prerequisite already existed — `compose/env/traefik.testnet.env` is
# populated, `CF_GW_PORT_BASE=91`, `CF_GATEWAY_PORT=10443`, and the three
# `cf-testnet-*` networks are up — so this was a command nobody had run rather
# than work nobody had done. THAT IS WHY IT IS A TARGET NOW. This repository has
# already been bitten three times by gateway state that lived only on a running
# container (the 443 binding, the estate network, the credentials); a fourth
# instance that lives only in an operator's shell history is the same defect.
#
# NO TELEMETRY OVERLAY, unlike GW_ESTATE above: the `cf-testnet-*` networks are
# declared `external` and already exist, and the telemetry plane is a single
# mainnet-project concern that must not be duplicated per environment.
GW_TESTNET := --env-file compose/testnet.env -p cftestnet \
              -f compose/docker-compose.gateway.yml \
              -f compose/docker-compose.estate-gateway.yml

.PHONY: estate-up estate-down estate-verify estate-browser estate-ps check-gateway check-web check-surfaces check-cert estate-gateway estate-gateway-testnet estate-gateway-testnet-down check-restart check-restart-live check-client-ip check-client-ip-live check-handoff-live check-tunnel-origin check-tunnel-origin-testnet

estate-up: ## Everything: 21 services, 15 frontends, bootstrap, gateway, verify
	@./scripts/estate-up.sh

estate-gateway: ## Just the gateway half, against an estate that is already up
	@# Named service, not a bare `up -d`: the project is the estate's now, and a
	@# bare `up` in it would be an `up` of a compose file that defines one service
	@# — harmless today, and one `--remove-orphans` away from removing the estate.
	@docker compose $(GW_ESTATE) up -d gateway
	@./scripts/check-tunnel-origin.sh mainnet

estate-gateway-testnet: ## The TESTNET gateway on 9181 — without it every *-testnet host is 502
	@docker compose $(GW_TESTNET) up -d gateway
	@./scripts/check-tunnel-origin.sh testnet

# ── the check the two headers above should have been ─────────────────────────
#
# `estate-gateway-testnet` printed `ok: cftestnet-gateway-1 on 127.0.0.1:9181`
# unconditionally — an echo, after an `up -d`, asserting a thing it had not
# looked at. It would have printed that line during both outages. Now the target
# proves its own claim, and the claim is available on its own for the times
# nobody is deploying anything.
check-tunnel-origin: ## Can a browser reach MAINNET at all? Asks the way cloudflared does
	@./scripts/check-tunnel-origin.sh mainnet

check-tunnel-origin-testnet: ## Can a browser reach TESTNET at all? The check for a 502 nobody caused
	@./scripts/check-tunnel-origin.sh testnet

estate-gateway-testnet-down: ## Stop the testnet gateway. Every *-testnet hostname goes 502
	@docker compose $(GW_TESTNET) down

estate-verify: ## Drive the running environment through every real flow
	@./scripts/estate-verify.sh

estate-browser: ## Drive the tier-3 BROWSER journeys in a real Chromium
	@./scripts/estate-browser.sh

estate-ps: ## What the environment is running, and whether it is healthy
	@docker compose $(ESTATE) ps

estate-down: ## Stop the environment. Add VOLUMES=1 to delete its databases too
	@# `rm -sf gateway` and NOT `down`: `down` is scoped to the PROJECT rather than
	@# to the services in the files, and the gateway's project is the estate's, so
	@# `down` here would take the whole estate with it a line early — including
	@# `--volumes` when it is asked for.
	@docker compose $(GW_ESTATE) rm -sf gateway
	@docker compose $(ESTATE) down $(if $(VOLUMES),--volumes,)

check-gateway: ## Compare the public route map against what the services serve
	@python3 scripts/gateway-check.py

check-client-ip: ## The gateway CANNOT log a client IP address, as a rule rather than an accident
	@# micro-org#163 records that Traefik logs no client IP here — and then says
	@# the part that matters: it is true "by accident of topology, not by an
	@# explicit rule, and nothing tests it". Headers are dropped because Traefik
	@# DEFAULTS to dropping them, and `ClientHost` is loopback because cloudflared
	@# is the peer. One `--accesslog.fields.headers.names.Cf-Connecting-Ip=keep`
	@# added while debugging a rate limit, or one port published on 0.0.0.0, ends
	@# either — with nothing in the diff named "log client IPs". This is what
	@# notices. An IP address is personal data; it prints none.
	@python3 scripts/check-client-ip-logging.py

check-client-ip-live: ## The same question asked of what a RUNNING gateway actually wrote
	@# A config check reads intent. This reads the access log a live gateway has
	@# already produced and asserts no ClientHost in it is a public address — so a
	@# topology change nobody wrote into a compose file (a port opened by hand, a
	@# second proxy in front, an entrypoint reconfigured on the container) is
	@# caught by its OUTPUT. No address is printed, only counts.
	@# The GATEWAY's project, which is the estate's since micro-org#257 — this
	@# reads the gateway's access log, not the telemetry plane's.
	@python3 scripts/check-client-ip-logging.py --live $(or $(PROJECT),$(GW_PROJECT))

check-surfaces: ## Every registry surface has a gateway route, and every route a surface
	@# The drift this ends was live three times in one night: `worlds-api` (a
	@# surface worlds-web resolved its whole API against, with no router; that
	@# hostname has since been folded into `api.` and its row deleted),
	@# `beacon` (service deployed, router never written), and both title APIs.
	@# Each was introduced by an edit to a DIFFERENT file from the one that was
	@# wrong, which is exactly why a comment could never have caught it.
	@python3 scripts/surface-routes.py

gateway-reload: ## Validate gateway/dynamic in a throwaway Traefik, then reload the live one
	@# NOT `docker compose restart gateway`. That reloads whatever is on disk,
	@# including a directory that does not render — and a template failure rejects
	@# EVERY file in gateway/dynamic/, which took every surface in this estate
	@# down at once for three minutes. This renders a copy under the same Traefik
	@# image first and refuses to touch the live gateway unless it comes up clean.
	@./scripts/gateway-reload.sh

check-gateway-fresh: ## Is the running gateway serving the files that are on disk?
	@# The file provider's watch does not fire on a virtiofs mount, so an edit to
	@# gateway/dynamic/ can sit on disk indefinitely while the gateway routes the
	@# previous table — and every check in this repository would pass, against
	@# configuration nobody can read any more. This is the one that notices.
	@./scripts/gateway-reload.sh --check

check-cert: ## Mint the gateway's local CA and leaf, and verify the chain
	@# The estate was only ever verified with `curl -k` and `ignoreHTTPSErrors`,
	@# so its transport had never been exercised the way a person exercises it.
	@./scripts/gateway-cert.sh

check-restart: ## Every long-running service comes back by itself after a reboot
	@# The estate is one HP ProLiant. Whatever does not restart after a power cut
	@# is simply gone, and nobody would know which — so the policy was put on a
	@# shared anchor, `x-service-defaults`. An anchor is OPT-IN: a service that
	@# forgets `<<: *service-defaults` inherits Docker's default of `no`, and
	@# nothing noticed. This is what notices, in both environments.
	@# BOTH env files per network. The tokens file carries CF_POSTGRES_PASSWORD,
	@# which is `:?` in the compose file, so a render without it does not render.
	@python3 scripts/check-restart-policy.py \
		--env-file compose/mainnet.env --env-file compose/estate/tokens.env \
		-f compose/docker-compose.estate.yml --project mainnet
	@python3 scripts/check-restart-policy.py \
		--env-file compose/testnet.env --env-file compose/estate/tokens.testnet.env \
		-f compose/docker-compose.estate.yml --project testnet

check-handoff-live: ## Does the RUNNING identity allowlist this estate's real origins? (#152)
	@# Asked of the CONTAINER, not of a render. #152 recurred because the render
	@# guard lives inside release-deploy.sh and a bare `docker compose up -d`
	@# never reaches it — so the check that mattered was never run rather than
	@# wrongly passed. This one holds however the container got there.
	@./scripts/check-handoff-live.sh cloudsforge-estate-identity-1 .cloudsforge.online
	@./scripts/check-handoff-live.sh cf-testnet-identity-1 -testnet.cloudsforge.online

check-restart-live: ## The same question asked of what is ACTUALLY RUNNING
	@# A render cannot see an ORPHAN — a container whose service was deleted from
	@# the compose file and which keeps running under the old definition — nor a
	@# release OVERLAY, which is generated and gitignored so CI never reads it.
	@# Both were live when this was written: a stale testnet overlay still pinned
	@# `foresight-admin-web`, a service the P13 fold had removed, so compose
	@# CREATED it with an image and no restart policy at all.
	@python3 scripts/check-restart-policy.py --live --project cloudsforge-estate
	@python3 scripts/check-restart-policy.py --live --project cf-testnet

check-web: ## Recompute every host port from micro-org's registry and compare
	@# The ports here are POSITIONAL — `4100 + index in deployableRepos()` — so a
	@# row inserted into the middle of that registry moves every port below it.
	@# That happened once in silence, moving sixteen of the thirty-nine pins,
	@# while the compose file carried a comment claiming this script guarded it.
	@# The script did not exist. Now it does.
	@python3 scripts/web-check.py
