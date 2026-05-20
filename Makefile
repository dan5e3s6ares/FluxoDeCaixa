.PHONY: start stop status test test-e2e clean help logs restart

CLUSTER_TYPE ?= k3s
ENV ?= dev
SVC ?=

start:
	@echo ">> Provisionando cluster e dependências (CLUSTER_TYPE=$(CLUSTER_TYPE))..."
	./scripts/bootstrap-vm.sh
	./scripts/cluster-up.sh
	./scripts/deploy-platform.sh
	./scripts/deploy-apps.sh
	./scripts/wait-healthy.sh
	@echo ">> Stack pronta. Gateway: https://localhost:8080"

stop:
	./scripts/cluster-down.sh

status:
	./scripts/wait-healthy.sh --check-only

test:
	cd platform/shared && uv run pytest tests
	cd services/lancamentos && uv run pytest tests/unit
	cd services/consolidado && uv run pytest tests/unit
	cd services/consulta && uv run pytest tests/unit

test-e2e:
	./scripts/run-e2e.sh

clean:
	./scripts/cluster-down.sh --purge-pvc

logs:
	./scripts/logs.sh $(SVC)

restart:
	./scripts/restart-svc.sh $(SVC)

help:
	@grep -E '^[a-zA-Z_-]+:' Makefile | sed 's/://'
