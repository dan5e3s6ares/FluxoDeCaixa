#!/usr/bin/env bash
# Phase B Ory Kratos/Hydra IdP acceptance validation (task 6a14c0ad6cf5924ec8318906).
# Static + unit checks always; live cluster checks when kubectl/kubeconfig available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ORY_NAMESPACE="${ORY_NAMESPACE:-security}"
HYDRA_PUBLIC_URL="${HYDRA_PUBLIC_URL:-http://hydra-public.${ORY_NAMESPACE}.svc.cluster.local:4444}"
# Per-phase retry budget: 72 × 5s = 6 min (doc: IdP ready < 10 min after PG).
ORY_MAX_WAIT_SECONDS="${ORY_MAX_WAIT_SECONDS:-600}"

validate_static_ory_config() {
  local krakend="${REPO_ROOT}/platform/krakend/krakend.json"

  log_info "validate: KrakenD JWKS/issuer point to Ory Hydra"
  grep -q 'hydra-public.security.svc.cluster.local:4444/.well-known/jwks.json' "${krakend}"
  if grep -qi authentik "${krakend}"; then
    log_error "KrakenD config still references Authentik"
    exit 1
  fi
  if grep -qi keycloak "${krakend}"; then
    log_error "KrakenD config still references Keycloak"
    exit 1
  fi

  log_info "validate: deploy/ory and platform/ory present"
  [[ -f "${REPO_ROOT}/deploy/ory/kratos-values.yaml" ]]
  [[ -f "${REPO_ROOT}/deploy/ory/hydra-values.yaml" ]]
  log_info "validate: Kratos external secret seeds smtpConnectionURI when chart sets connection_uri"
  if grep -q 'connection_uri:' "${REPO_ROOT}/deploy/ory/kratos-values.yaml"; then
    grep -q 'smtpConnectionURI' "${REPO_ROOT}/scripts/deploy-platform.sh" || {
      log_error "deploy-platform must seed smtpConnectionURI when kratos-values sets courier.smtp.connection_uri"
      exit 1
    }
  fi
  [[ -f "${REPO_ROOT}/platform/ory/bootstrap.sh" ]]
  [[ ! -d "${REPO_ROOT}/deploy/authentik" ]]
  [[ ! -d "${REPO_ROOT}/deploy/keycloak" ]]

  log_info "validate: deploy-platform seeds Ory secrets (fluxo-kratos, fluxo-hydra)"
  grep -q 'ensure_kratos_secret' "${REPO_ROOT}/scripts/deploy-platform.sh"
  grep -q 'ensure_hydra_secret' "${REPO_ROOT}/scripts/deploy-platform.sh"
  grep -q 'urlencode_component' "${REPO_ROOT}/scripts/lib/common.sh"
  grep -q 'secretsCipher' "${REPO_ROOT}/scripts/deploy-platform.sh"
  grep -q 'secretsCookie' "${REPO_ROOT}/scripts/deploy-platform.sh"
  grep -q 'smtpConnectionURI' "${REPO_ROOT}/scripts/deploy-platform.sh"
  grep -q 'ory_kratos_cipher_secret' "${REPO_ROOT}/scripts/deploy-platform.sh"
  grep -q 'log_ory_helm_progress' "${REPO_ROOT}/scripts/deploy-platform.sh"

  log_info "validate: Kratos cipher secret length guard"
  bash "${REPO_ROOT}/scripts/test-ory-secrets.sh"

  log_info "validate: Hydra token_hook config (no webhook auth.type none)"
  if grep -E '^[[:space:]]+type:[[:space:]]*none[[:space:]]*$' "${REPO_ROOT}/deploy/ory/hydra-values.yaml" >/dev/null; then
    log_error "deploy/ory/hydra-values.yaml must not set oauth2.token_hook.auth.type to none (Hydra v2.3 rejects it at startup)"
    exit 1
  fi
  grep -q 'token_hook:' "${REPO_ROOT}/deploy/ory/hydra-values.yaml"

  log_info "validate: Ory bootstrap uses Hydra admin API and merchant_id metadata"
  grep -q 'ensure_oauth2_client' "${REPO_ROOT}/platform/ory/bootstrap.sh"
  grep -q 'metadata' "${REPO_ROOT}/platform/ory/bootstrap.sh"
  grep -q 'ORY_SKIP_READY_WAIT' "${REPO_ROOT}/deploy/ory/bootstrap-job.yaml"
  grep -q 'preflight_commands' "${REPO_ROOT}/platform/ory/bootstrap.sh"
  grep -q 'alpine:3.20' "${REPO_ROOT}/deploy/ory/bootstrap-job.yaml"
  grep -q 'ory-token-hook' "${REPO_ROOT}/deploy/ory/token-hook.yaml"

  log_info "validate: Ory bootstrap helper unit tests"
  sh "${REPO_ROOT}/platform/ory/test-bootstrap-helpers.sh"
}

validate_idp_wait_budget() {
  local attempts="${ORY_READY_ATTEMPTS:-90}"
  local delay="${ORY_READY_DELAY:-5}"
  local per_phase=$((attempts * delay))

  log_info "validate: Ory wait budget after PG (target < ${ORY_MAX_WAIT_SECONDS}s per phase)"
  if (( per_phase >= ORY_MAX_WAIT_SECONDS )); then
    log_error "ORY_READY_ATTEMPTS×DELAY (${per_phase}s) must stay under ${ORY_MAX_WAIT_SECONDS}s"
    exit 1
  fi
  log_info "deploy-platform Ory per-phase retry cap ${per_phase}s (< ${ORY_MAX_WAIT_SECONDS}s)"
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
  log_info "validate: make test-e2e (Ory Hydra OIDC + KrakenD JWT + merchant_id + flow)"
  if command -v make >/dev/null 2>&1; then
    make -C "${REPO_ROOT}" test-e2e
  else
    CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}" KRAKEND_NODEPORT="${KRAKEND_NODEPORT:-30443}" \
      "${SCRIPT_DIR}/run-e2e.sh"
  fi
}

main() {
  log_info "validate-auth-e2e.sh — Phase B Ory IdP acceptance criteria"
  validate_static_ory_config
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
