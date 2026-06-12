SHELL := /bin/bash

PORT ?= 4000
POSTGRES_PORT ?= 5433
POSTGRES_WAIT_TIMEOUT ?= 60
POSTGRES_WAIT_ATTEMPTS ?= 30
DEV_POSTGRES_DB := codex_pooler_dev
DEV_POSTGRES_USER := postgres
DEV_POSTGRES_PASSWORD := postgres
DEV_PID := tmp/dev-server.pid
DEV_LOG := tmp/dev-server.log
DEV_COMPOSE := POSTGRES_PORT=$(POSTGRES_PORT) docker compose -f docker-compose.dev.yml
DEV_DB_ENV := POSTGRES_HOST=localhost POSTGRES_PORT=$(POSTGRES_PORT) POSTGRES_DB=$(DEV_POSTGRES_DB) POSTGRES_USER=$(DEV_POSTGRES_USER) POSTGRES_PASSWORD=$(DEV_POSTGRES_PASSWORD)
DEV_SECRET_ENV := if [ -f .env ]; then while IFS= read -r line; do case "$$line" in CODEX_POOLER_UPSTREAM_SECRET_KEY=*|CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION=*) export "$$line";; esac; done < .env; fi;

.PHONY: dev dev-db dev-compile dev-migrate dev-pricing dev-stop dev-status dev-logs precommit smoke

dev: dev-db dev-compile dev-migrate dev-pricing dev-stop
	@mkdir -p tmp
	@echo "starting Phoenix dev server on http://localhost:$(PORT)"
	@$(DEV_SECRET_ENV) PORT=$(PORT) $(DEV_DB_ENV) nohup mix phx.server > $(DEV_LOG) 2>&1 < /dev/null & echo $$! > $(DEV_PID)
	@sleep 2
	@$(MAKE) --no-print-directory dev-status

dev-db:
	@$(DEV_COMPOSE) up -d --wait --wait-timeout $(POSTGRES_WAIT_TIMEOUT) db
	@printf "ALTER ROLE $(DEV_POSTGRES_USER) WITH PASSWORD :'dev_password';\n" | $(DEV_COMPOSE) exec -T db psql --username=$(DEV_POSTGRES_USER) --dbname=postgres --set=ON_ERROR_STOP=1 --set=dev_password=$(DEV_POSTGRES_PASSWORD) >/dev/null
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

dev-compile:
	@$(DEV_SECRET_ENV) $(DEV_DB_ENV) mix compile --force

dev-migrate:
	@$(DEV_SECRET_ENV) $(DEV_DB_ENV) mix ecto.create --quiet
	@$(DEV_SECRET_ENV) $(DEV_DB_ENV) mix ecto.migrate

dev-pricing:
	@$(DEV_SECRET_ENV) $(DEV_DB_ENV) mix pricing.import_openai

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
