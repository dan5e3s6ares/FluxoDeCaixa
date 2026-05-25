#!/usr/bin/env bash
# Phase B Authentik IdP acceptance validation (task 6a14197586a7b6a7a5698c09).
# Static + unit checks always; live cluster checks when kubectl/kubeconfig available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AUTHENTIK_NAMESPACE="${AUTHENTIK_NAMESPACE:-security}"
AUTHENTIK_SERVER_URL="${AUTHENTIK_SERVER_URL:-http://authentik-server.${AUTHENTIK_NAMESPACE}.svc.cluster.local:9000}"
AUTHENTIK_APP_SLUG="${AUTHENTIK_OIDC_APP_SLUG:-fluxo-caixa}"
# Per-phase retry budget: 72 × 5s = 6 min (doc: IdP ready < 10 min after PG).
AUTHENTIK_MAX_WAIT_SECONDS="${AUTHENTIK_MAX_WAIT_SECONDS:-600}"

validate_static_authentik_config() {
  local krakend="${REPO_ROOT}/platform/krakend/krakend.json"

  log_info "validate: KrakenD JWKS/issuer point to Authentik application ${AUTHENTIK_APP_SLUG}"
  grep -q 'authentik-server.security.svc.cluster.local:9000/application/o/fluxo-caixa' "${krakend}"
  if grep -qi keycloak "${krakend}"; then
    log_error "KrakenD config still references Keycloak"
    exit 1
  fi

  log_info "validate: deploy/authentik and platform/authentik present"
  [[ -f "${REPO_ROOT}/deploy/authentik/values.yaml" ]]
  [[ -f "${REPO_ROOT}/platform/authentik/bootstrap.sh" ]]
  [[ ! -d "${REPO_ROOT}/deploy/keycloak" ]]
}

validate_idp_wait_budget() {
  local attempts="${AUTHENTIK_READY_ATTEMPTS:-90}"
  local delay="${AUTHENTIK_READY_DELAY:-5}"
  local per_phase=$((attempts * delay))

  log_info "validate: Authentik wait budget after PG (target < ${AUTHENTIK_MAX_WAIT_SECONDS}s per phase)"
  if (( per_phase >= AUTHENTIK_MAX_WAIT_SECONDS )); then
    log_error "AUTHENTIK_READY_ATTEMPTS×DELAY (${per_phase}s) must stay under ${AUTHENTIK_MAX_WAIT_SECONDS}s"
    exit 1
  fi
  log_info "deploy-platform Authentik per-phase retry cap ${per_phase}s (< ${AUTHENTIK_MAX_WAIT_SECONDS}s)"
}

run_unit_tests() {
  log_info "validate: make test (unit + KrakenD config)"
  if command -v make >/dev/null 2>&1; then
    make -C "${REPO_ROOT}" test
    return 0
  fi

  log_warn "make not found — running pytest via uv directly"
  cd "${REPO_ROOT}/services/lancamentos" && uv run pytest tests/unit -q
  cd "${REPO_ROOT}/services/consolidado" && uv run pytest tests/unit -q
  cd "${REPO_ROOT}/services/consulta" && uv run pytest tests/unit -q
  cd "${REPO_ROOT}/platform/krakend" && uv run --with pytest --with pyyaml pytest tests -q
}

run_live_e2e() {
  log_info "validate: make test-e2e (Authentik OIDC + KrakenD JWT + merchant_id + flow)"
  if command -v make >/dev/null 2>&1; then
    make -C "${REPO_ROOT}" test-e2e
  else
    CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}" KRAKEND_NODEPORT="${KRAKEND_NODEPORT:-30443}" \
      "${SCRIPT_DIR}/run-e2e.sh"
  fi
}

main() {
  log_info "validate-auth-e2e.sh — Phase B Authentik IdP acceptance criteria"
  validate_static_authentik_config
  validate_idp_wait_budget
  run_unit_tests

  if command -v kubectl >/dev/null 2>&1; then
    configure_kubeconfig 2>/dev/null || true
    if kubectl_cmd cluster-info >/dev/null 2>&1; then
      run_live_e2e
      log_info "validate-auth-e2e.sh — all criteria passed (static + unit + live e2e)"
      return 0
    fi
  fi

  log_warn "kubectl/cluster unavailable — static + unit checks passed; run on VM with stack up for live e2e"
  log_info "validate-auth-e2e.sh — partial validation complete (static + unit)"
}

main "$@"
