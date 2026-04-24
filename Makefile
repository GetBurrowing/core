.PHONY: help bootstrap db db-stop db-logs setup check server precommit test format clean nuke

PG_CONTAINER := suite-pg
PG_IMAGE     := postgres:16
PG_PORT      := 5432
PLATFORM_DIR := apps/platform

help:
	@echo "Targets:"
	@echo "  bootstrap   - db + setup (one-shot local bring-up)"
	@echo "  db          - start Postgres 16 in Docker ($(PG_CONTAINER))"
	@echo "  db-stop     - stop the Postgres container"
	@echo "  db-logs     - tail Postgres container logs"
	@echo "  setup       - mix local.hex/rebar + mix setup (deps, DB, assets)"
	@echo "  check       - mix precommit (compile, format, tests) — run before pushing"
	@echo "  server      - mix phx.server (localhost:4000)"
	@echo "  test        - mix test"
	@echo "  format      - mix format"
	@echo "  clean       - mix clean + drop _build/deps build artifacts"
	@echo "  nuke        - clean + stop & remove Postgres container (destroys dev DB)"

bootstrap: db setup
	@echo "Ready. Run 'make check' to verify, or 'make server' to start."

db:
	@if [ -z "$$(docker ps -q -f name=^/$(PG_CONTAINER)$$)" ]; then \
		if [ -n "$$(docker ps -aq -f name=^/$(PG_CONTAINER)$$)" ]; then \
			echo "Starting existing container $(PG_CONTAINER)..."; \
			docker start $(PG_CONTAINER) >/dev/null; \
		else \
			echo "Creating container $(PG_CONTAINER) ($(PG_IMAGE))..."; \
			docker run -d --name $(PG_CONTAINER) --restart unless-stopped \
				-e POSTGRES_PASSWORD=postgres \
				-p $(PG_PORT):5432 \
				$(PG_IMAGE) >/dev/null; \
		fi; \
	else \
		echo "$(PG_CONTAINER) already running."; \
	fi
	@echo "Waiting for Postgres to accept connections..."
	@for i in $$(seq 1 30); do \
		if docker exec $(PG_CONTAINER) pg_isready -U postgres >/dev/null 2>&1; then \
			echo "Postgres ready."; exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "Postgres did not become ready in 30s." >&2; exit 1

db-stop:
	@docker stop $(PG_CONTAINER) >/dev/null 2>&1 || true
	@echo "$(PG_CONTAINER) stopped."

db-logs:
	@docker logs -f $(PG_CONTAINER)

setup:
	cd $(PLATFORM_DIR) && mix local.hex --force && mix local.rebar --force
	cd $(PLATFORM_DIR) && mix setup

check precommit:
	cd $(PLATFORM_DIR) && mix precommit

server:
	cd $(PLATFORM_DIR) && mix phx.server

test:
	cd $(PLATFORM_DIR) && mix test

format:
	cd $(PLATFORM_DIR) && mix format

clean:
	cd $(PLATFORM_DIR) && mix clean
	rm -rf $(PLATFORM_DIR)/_build $(PLATFORM_DIR)/deps

nuke: clean
	@docker rm -f $(PG_CONTAINER) >/dev/null 2>&1 || true
	@echo "Removed $(PG_CONTAINER) and build artifacts."
