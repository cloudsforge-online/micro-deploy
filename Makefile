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

estate: ## Confirm the existing eighteen containers are still healthy
	@docker ps --filter name=cloudsforge- --format '{{.Names}}\t{{.Status}}' | sort
