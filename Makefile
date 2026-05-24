.PHONY: start stop status test test-e2e clean help logs restart

CLUSTER_TYPE ?= k3s
ENV ?= dev
SVC ?=
KRAKEND_NODEPORT ?= 30443
export CLUSTER_TYPE ENV KRAKEND_NODEPORT

start:
	@echo ">> Provisionando cluster e dependências (CLUSTER_TYPE=$(CLUSTER_TYPE), ENV=$(ENV))..."
	CLUSTER_TYPE=$(CLUSTER_TYPE) ENV=$(ENV) ./scripts/bootstrap-vm.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ENV=$(ENV) ./scripts/deploy-registry.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ENV=$(ENV) ./scripts/deploy-gitea.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/cluster-up.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/deploy-platform.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ENV=$(ENV) ./scripts/seed-images.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ENV=$(ENV) ./scripts/deploy-apps.sh
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/wait-healthy.sh
	@echo ">> Stack pronta. Gateway: https://localhost:8080 (NodePort $(KRAKEND_NODEPORT))"

stop:
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/cluster-down.sh

status:
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/wait-healthy.sh --check-only

test:
	cd services/lancamentos && uv run pytest tests/unit
	cd services/consolidado && uv run pytest tests/unit
	cd services/consulta && uv run pytest tests/unit
	cd platform/krakend && uv run --with pytest --with pyyaml pytest tests

test-e2e:
	CLUSTER_TYPE=$(CLUSTER_TYPE) KRAKEND_NODEPORT=$(KRAKEND_NODEPORT) ./scripts/run-e2e.sh

clean:
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/cluster-down.sh --purge-pvc

logs:
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/logs.sh $(SVC)

restart:
	CLUSTER_TYPE=$(CLUSTER_TYPE) ./scripts/restart-svc.sh $(SVC)

help:
	@grep -E '^[a-zA-Z_-]+:' Makefile | sed 's/://'
