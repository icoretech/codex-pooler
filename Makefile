SHELL := /bin/bash

PORT ?= 4000
POSTGRES_PORT ?= 5433
POSTGRES_WAIT_TIMEOUT ?= 60
POSTGRES_WAIT_ATTEMPTS ?= 30
DEV_PID := tmp/dev-server.pid
DEV_LOG := tmp/dev-server.log
DEV_COMPOSE := docker compose -f docker-compose.dev.yml
DEV_SECRET_ENV := set -a; [ ! -f .env ] || . <(grep -E '^(CODEX_POOLER_UPSTREAM_SECRET_KEY|CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION)=' .env); set +a;

.PHONY: dev dev-db dev-migrate dev-pricing dev-stop dev-status dev-logs precommit smoke

dev: dev-db dev-migrate dev-pricing dev-stop
	@mkdir -p tmp
	@echo "starting Phoenix dev server on http://localhost:$(PORT)"
	@$(DEV_SECRET_ENV) PORT=$(PORT) POSTGRES_PORT=$(POSTGRES_PORT) mix phx.server > $(DEV_LOG) 2>&1 & echo $$! > $(DEV_PID)
	@sleep 2
	@$(MAKE) --no-print-directory dev-status

dev-db:
	@$(DEV_COMPOSE) up -d --wait --wait-timeout $(POSTGRES_WAIT_TIMEOUT) db
	@for attempt in 1 2; do \
		for _ in $$(seq 1 $(POSTGRES_WAIT_ATTEMPTS)); do \
			if (: > /dev/tcp/127.0.0.1/$(POSTGRES_PORT)) >/dev/null 2>&1; then \
				exit 0; \
			fi; \
			sleep 1; \
		done; \
		if [ $$attempt -eq 1 ]; then \
			echo "Postgres container is healthy but localhost:$(POSTGRES_PORT) is not accepting TCP connections; recreating dev db container without deleting volume"; \
			$(DEV_COMPOSE) up -d --force-recreate --wait --wait-timeout $(POSTGRES_WAIT_TIMEOUT) db; \
		fi; \
	done; \
	echo "Postgres is not reachable on 127.0.0.1:$(POSTGRES_PORT)"; \
	$(DEV_COMPOSE) ps db; \
	exit 1

dev-migrate:
	@$(DEV_SECRET_ENV) POSTGRES_PORT=$(POSTGRES_PORT) mix ecto.create --quiet
	@$(DEV_SECRET_ENV) POSTGRES_PORT=$(POSTGRES_PORT) mix ecto.migrate

dev-pricing:
	@$(DEV_SECRET_ENV) POSTGRES_PORT=$(POSTGRES_PORT) mix pricing.import_openai

dev-stop:
	@if [ -f $(DEV_PID) ]; then \
		pid=$$(cat $(DEV_PID)); \
		if kill -0 $$pid >/dev/null 2>&1; then \
			echo "stopping Phoenix dev server pid $$pid"; \
			kill $$pid; \
			for _ in 1 2 3 4 5; do \
				kill -0 $$pid >/dev/null 2>&1 || break; \
				sleep 1; \
			done; \
			kill -9 $$pid >/dev/null 2>&1 || true; \
		fi; \
		rm -f $(DEV_PID); \
	fi
	@for pid in $$(lsof -tiTCP:$(PORT) -sTCP:LISTEN 2>/dev/null); do \
		echo "stopping process listening on port $(PORT): $$pid"; \
		kill $$pid >/dev/null 2>&1 || true; \
	done

dev-status:
	@if [ -f $(DEV_PID) ] && kill -0 $$(cat $(DEV_PID)) >/dev/null 2>&1; then \
		echo "Phoenix dev server running pid $$(cat $(DEV_PID))"; \
		curl -fsS "http://localhost:$(PORT)/healthz" >/dev/null && echo "healthz ok"; \
	else \
		echo "Phoenix dev server is not running"; \
		if [ -f $(DEV_LOG) ]; then tail -n 80 $(DEV_LOG); fi; \
		exit 1; \
	fi

dev-logs:
	@tail -f $(DEV_LOG)

precommit:
	@mix precommit

smoke:
	@scripts/dev/codex-smoke.sh
