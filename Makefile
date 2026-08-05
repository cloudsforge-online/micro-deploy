# One command up, one command down. Everything else here is a check that can be
# run before a change lands rather than discovered after it.

COMPOSE_PROJECT_NAME ?= cfmicro
TELEMETRY := -f compose/docker-compose.telemetry.yml
GATEWAY   := -f compose/docker-compose.gateway.yml
PROM_IMG  := prom/prometheus:v2.55.1
AM_IMG    := prom/alertmanager:v0.27.0
OTEL_IMG  := otel/opentelemetry-collector-contrib:0.115.1

.DEFAULT_GOAL := help
.PHONY: help up down gateway logs ps config check check-rules check-alertmanager \
        check-collector check-runbooks dashboards estate clean

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
check: config check-rules check-alertmanager check-collector check-runbooks ## Run every check
	@echo "ok: all checks passed"

check-rules: ## promtool over the recording and alerting rules
	@docker run --rm --entrypoint /bin/promtool \
		-v "$(PWD)/prometheus:/p:ro" $(PROM_IMG) \
		check rules /p/rules/slo.yaml /p/rules/alerts.yaml
	@docker run --rm --entrypoint /bin/promtool \
		-v "$(PWD)/prometheus:/p:ro" $(PROM_IMG) \
		check config --syntax-only /p/prometheus.yml

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

check-secrets: ## No secret is a placeholder, too short, or already in a transcript
	@# CI guards a secret that is COMMITTED. Neither failure this catches is a
	@# commit, so neither was ever visible to it: a placeholder-shaped signing key
	@# live in an accept list (40 chars, so every length gate passed; not one of
	@# the eight known strings, so every placeholder gate passed), and a secret
	@# printed into an agent transcript by `docker inspect`. See
	@# runbooks/runbook-secret-leaked-to-transcript.md. Prints NO secret values.
	@python3 scripts/check-secret-hygiene.py \
		--files compose/secrets/*.env compose/estate/tokens.env compose/.env

estate: ## Confirm the existing eighteen containers are still healthy
	@docker ps --filter name=cloudsforge- --format '{{.Names}}\t{{.Status}}' | sort

# --------------------------------------------------- the estate environment --
ESTATE  := -f compose/docker-compose.estate.yml
# The gateway, wired to the estate's network and bound to 443. Needed by every
# browser surface: a bundle derives its sibling hosts as `https://<sub>.<apex>`
# with NO PORT, so 9096 is unreachable to the page that was served on it.
GW_ESTATE := -f compose/docker-compose.telemetry.yml \
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

.PHONY: estate-up estate-down estate-verify estate-browser estate-ps check-gateway check-web check-surfaces check-cert estate-gateway estate-gateway-testnet estate-gateway-testnet-down check-restart check-restart-live

estate-up: ## Everything: 21 services, 15 frontends, bootstrap, gateway, verify
	@./scripts/estate-up.sh

estate-gateway: ## Just the gateway half, against an estate that is already up
	@docker compose -p $(COMPOSE_PROJECT_NAME) $(GW_ESTATE) up -d

estate-gateway-testnet: ## The TESTNET gateway on 9181 — without it every *-testnet host is 502
	@docker compose $(GW_TESTNET) up -d gateway
	@echo "ok: cftestnet-gateway-1 on 127.0.0.1:9181 (tunnel) and 127.0.0.1:10443 (TLS)"

estate-gateway-testnet-down: ## Stop the testnet gateway. Every *-testnet hostname goes 502
	@docker compose $(GW_TESTNET) down

estate-verify: ## Drive the running environment through every real flow
	@./scripts/estate-verify.sh

estate-browser: ## Drive the tier-3 BROWSER journeys in a real Chromium
	@./scripts/estate-browser.sh

estate-ps: ## What the environment is running, and whether it is healthy
	@docker compose $(ESTATE) ps

estate-down: ## Stop the environment. Add VOLUMES=1 to delete its databases too
	@docker compose -p $(COMPOSE_PROJECT_NAME) $(GW_ESTATE) down
	@docker compose $(ESTATE) down $(if $(VOLUMES),--volumes,)

check-gateway: ## Compare the public route map against what the services serve
	@python3 scripts/gateway-check.py

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
	@python3 scripts/check-restart-policy.py \
		-f compose/docker-compose.estate.yml --project mainnet
	@python3 scripts/check-restart-policy.py --env-file compose/testnet.env \
		-f compose/docker-compose.estate.yml --project testnet

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
