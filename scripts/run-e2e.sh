#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KRAKEND_NODEPORT="${KRAKEND_NODEPORT:-30443}"
KRAKEND_URL="${KRAKEND_URL:-https://127.0.0.1:${KRAKEND_NODEPORT}}"
OIDC_NAMESPACE="${OIDC_NAMESPACE:-security}"
OIDC_TOKEN_URL="${OIDC_TOKEN_URL:-http://authentik.${OIDC_NAMESPACE}.svc.cluster.local/application/o/token/}"
E2E_LANCAMENTOS_CLIENT="${E2E_LANCAMENTOS_CLIENT:-svc-lancamentos}"
E2E_CONSULTA_CLIENT="${E2E_CONSULTA_CLIENT:-svc-consulta}"
E2E_SECRET_NAME="${E2E_SECRET_NAME:-e2e-oidc-material}"
E2E_MERCHANT_ID="${E2E_MERCHANT_ID:-00000000-0000-4000-8000-000000000001}"
E2E_LANCAMENTO_VALOR="${E2E_LANCAMENTO_VALOR:-10.00}"
E2E_POLL_MAX_ATTEMPTS="${E2E_POLL_MAX_ATTEMPTS:-90}"
E2E_POLL_DELAY="${E2E_POLL_DELAY:-2}"

cleanup_e2e_secret() {
  kubectl_cmd -n "${OIDC_NAMESPACE}" delete secret "${E2E_SECRET_NAME}" --ignore-not-found >/dev/null 2>&1
}

# Obtain client_credentials token via OIDC token endpoint (Authentik stub — filled by follow-up tasks).
obtain_access_token_via_oidc() {
  local client_id="$1"
  local client_secret="$2"

  cleanup_e2e_secret
  kubectl_cmd -n "${OIDC_NAMESPACE}" delete pod "e2e-oidc-${client_id}" --ignore-not-found >/dev/null 2>&1

  kubectl_cmd -n "${OIDC_NAMESPACE}" run "e2e-oidc-${client_id}" --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --env="OIDC_CLIENT_ID=${client_id}" \
    --env="OIDC_CLIENT_SECRET=${client_secret}" \
    --env="OIDC_TOKEN_URL=${OIDC_TOKEN_URL}" \
    --command -- sh -ce \
    'curl -sf -X POST "${OIDC_TOKEN_URL}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d grant_type=client_credentials \
      -d client_id="${OIDC_CLIENT_ID}" \
      -d client_secret="${OIDC_CLIENT_SECRET}" \
      | sed -n "s/.*\"access_token\":\"\\([^\"]*\\)\".*/\\1/p"' 2>/dev/null
}

read_oidc_client_secret() {
  local client_id="$1"
  kubectl_cmd -n "${OIDC_NAMESPACE}" get secret "fluxo-oidc-${client_id}" \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true
}

new_idempotency_key() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

post_lancamento() {
  local access_token="$1"
  local data_competencia="$2"
  local idempotency_key body http_code response_file

  idempotency_key="$(new_idempotency_key)"
  body="$(printf '{"valor":%s,"tipo":"CREDITO","data_competencia":"%s","descricao":"e2e-run"}' \
    "${E2E_LANCAMENTO_VALOR}" "${data_competencia}")"
  response_file="$(mktemp)"
  trap 'rm -f "${response_file}"' RETURN

  http_code="$(curl -sk -o "${response_file}" -w '%{http_code}' \
    -X POST "${KRAKEND_URL}/v1/lancamentos" \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: ${idempotency_key}" \
    -d "${body}")"

  case "${http_code}" in
    201|200)
      log_info "POST /v1/lancamentos HTTP ${http_code} (idempotency=${idempotency_key})"
      python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "${response_file}"
      ;;
    *)
      log_error "POST /v1/lancamentos failed HTTP ${http_code}: $(cat "${response_file}")"
      exit 1
      ;;
  esac
}

poll_consolidado_until_fresh() {
  local access_token="$1"
  local data="$2"
  local attempt=1 headers_file body_file http_code stale

  while (( attempt <= E2E_POLL_MAX_ATTEMPTS )); do
    headers_file="$(mktemp)"
    body_file="$(mktemp)"

    http_code="$(curl -sk -D "${headers_file}" -o "${body_file}" -w '%{http_code}' \
      -H "Authorization: Bearer ${access_token}" \
      "${KRAKEND_URL}/v1/consolidado/${data}")"

    stale="$(grep -i '^x-consolidado-stale:' "${headers_file}" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)"
    rm -f "${headers_file}"

    if [[ "${http_code}" == "200" ]] && [[ "$(echo "${stale}" | tr '[:upper:]' '[:lower:]')" != "true" ]]; then
      log_info "GET /v1/consolidado/${data} fresh (attempt ${attempt}/${E2E_POLL_MAX_ATTEMPTS})"
      cat "${body_file}"
      rm -f "${body_file}"
      return 0
    fi

    if [[ "${http_code}" != "200" ]]; then
      log_warn "GET /v1/consolidado/${data} HTTP ${http_code} (attempt ${attempt}/${E2E_POLL_MAX_ATTEMPTS})"
    else
      log_info "consolidado stale (X-Consolidado-Stale=true); retry ${attempt}/${E2E_POLL_MAX_ATTEMPTS} in ${E2E_POLL_DELAY}s"
    fi
    rm -f "${body_file}"
    sleep "${E2E_POLL_DELAY}"
    attempt=$((attempt + 1))
  done

  log_error "consolidado not fresh within $((E2E_POLL_MAX_ATTEMPTS * E2E_POLL_DELAY))s"
  exit 1
}

main() {
  local data_competencia lanc_token consulta_token lancamento_id
  local lanc_secret consulta_secret

  log_info "run-e2e.sh — E2E via KrakenD (${KRAKEND_URL})"
  configure_kubeconfig
  trap cleanup_e2e_secret EXIT

  log_info "pre-flight: wait-healthy.sh --check-only"
  "${SCRIPT_DIR}/wait-healthy.sh" --check-only

  log_info "E2E: KrakenD public health"
  require_cmd curl
  require_cmd python3
  curl -skf "${KRAKEND_URL}/health" >/dev/null
  curl -skf "${KRAKEND_URL}/__health" >/dev/null
  log_info "KrakenD /health and /__health OK"

  log_info "E2E: OIDC client_credentials (${E2E_LANCAMENTOS_CLIENT} + ${E2E_CONSULTA_CLIENT})"
  lanc_secret="$(read_oidc_client_secret "${E2E_LANCAMENTOS_CLIENT}")"
  consulta_secret="$(read_oidc_client_secret "${E2E_CONSULTA_CLIENT}")"
  if [[ -z "${lanc_secret}" ]] || [[ -z "${consulta_secret}" ]]; then
    log_error "OIDC client secrets missing (fluxo-oidc-* in ${OIDC_NAMESPACE}) — deploy Authentik first"
    exit 1
  fi

  lanc_token="$(obtain_access_token_via_oidc "${E2E_LANCAMENTOS_CLIENT}" "${lanc_secret}" | tr -d '\n\r')"
  consulta_token="$(obtain_access_token_via_oidc "${E2E_CONSULTA_CLIENT}" "${consulta_secret}" | tr -d '\n\r')"
  if [[ -z "${lanc_token}" ]] || [[ -z "${consulta_token}" ]]; then
    log_error "could not obtain OIDC tokens for ${E2E_LANCAMENTOS_CLIENT} / ${E2E_CONSULTA_CLIENT}"
    exit 1
  fi
  log_info "OIDC tokens obtained (merchant_id=${E2E_MERCHANT_ID})"

  data_competencia="$(date +%Y-%m-%d)"
  log_info "E2E: POST lancamento (data_competencia=${data_competencia})"
  lancamento_id="$(post_lancamento "${lanc_token}" "${data_competencia}")"
  log_info "lancamento accepted id=${lancamento_id}"

  log_info "E2E: poll GET consolidado until fresh"
  poll_consolidado_until_fresh "${consulta_token}" "${data_competencia}" >/dev/null

  log_info "run-e2e.sh — E2E complete (auth → POST → consolidado fresh)"
}

main "$@"
