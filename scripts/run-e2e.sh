#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KRAKEND_NODEPORT="${KRAKEND_NODEPORT:-30443}"
KRAKEND_URL="${KRAKEND_URL:-https://127.0.0.1:${KRAKEND_NODEPORT}}"
ORY_NAMESPACE="${ORY_NAMESPACE:-security}"
HYDRA_PUBLIC_URL="${HYDRA_PUBLIC_URL:-http://hydra-public.${ORY_NAMESPACE}.svc.cluster.local:4444}"
HYDRA_ADMIN_URL="${HYDRA_ADMIN_URL:-http://hydra-admin.${ORY_NAMESPACE}.svc.cluster.local:4445}"
OIDC_TOKEN_URL="${OIDC_TOKEN_URL:-${HYDRA_PUBLIC_URL}/oauth2/token}"
E2E_LANCAMENTOS_CLIENT="${E2E_LANCAMENTOS_CLIENT:-svc-lancamentos}"
E2E_CONSULTA_CLIENT="${E2E_CONSULTA_CLIENT:-svc-consulta}"
E2E_SECRET_NAME="${E2E_SECRET_NAME:-e2e-oidc-material}"
E2E_MERCHANT_ID="${E2E_MERCHANT_ID:-00000000-0000-4000-8000-000000000001}"
E2E_LANCAMENTO_VALOR="${E2E_LANCAMENTO_VALOR:-10.00}"
E2E_POLL_MAX_ATTEMPTS="${E2E_POLL_MAX_ATTEMPTS:-90}"
E2E_POLL_DELAY="${E2E_POLL_DELAY:-2}"

cleanup_e2e_secret() {
  kubectl_cmd -n "${ORY_NAMESPACE}" delete secret "${E2E_SECRET_NAME}" --ignore-not-found >/dev/null 2>&1
}

read_hydra_client_secret() {
  local client_id="$1"
  kubectl_cmd -n "${ORY_NAMESPACE}" get secret "fluxo-oidc-${client_id}" \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true
}

# Obtain client_credentials token via Ory Hydra; ensures client metadata carries merchant_id.
obtain_access_token_via_hydra() {
  local oidc_client="$1"
  local known_secret="${2:-}"

  cleanup_e2e_secret
  kubectl_cmd -n "${ORY_NAMESPACE}" delete pod "e2e-oidc-${oidc_client}" --ignore-not-found >/dev/null 2>&1

  kubectl_cmd -n "${ORY_NAMESPACE}" run "e2e-oidc-${oidc_client}" --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --env="OIDC_CLIENT=${oidc_client}" \
    --env="MERCHANT_ID=${E2E_MERCHANT_ID}" \
    --env="HYDRA_ADMIN_URL=${HYDRA_ADMIN_URL}" \
    --env="OIDC_TOKEN_URL=${OIDC_TOKEN_URL}" \
    --env="KNOWN_CLIENT_SECRET=${known_secret}" \
    --command -- sh -ce 'set -euo pipefail
client_secret="${KNOWN_CLIENT_SECRET}"
if [ -z "${client_secret}" ]; then
  client_secret="$(curl -sf "${HYDRA_ADMIN_URL}/clients/${OIDC_CLIENT}" | sed -n "s/.*\"client_secret\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"
fi
[ -n "${client_secret}" ] || { echo "client secret missing for ${OIDC_CLIENT}" >&2; exit 1; }
curl -sf -X PUT "${HYDRA_ADMIN_URL}/clients/${OIDC_CLIENT}" \
  -H "Content-Type: application/json" \
  --data "{\"client_id\":\"${OIDC_CLIENT}\",\"client_secret\":\"${client_secret}\",\"grant_types\":[\"client_credentials\"],\"response_types\":[\"token\"],\"token_endpoint_auth_method\":\"client_secret_post\",\"scope\":\"openid\",\"metadata\":{\"merchant_id\":\"${MERCHANT_ID}\"}}" >/dev/null
curl -sf -X POST "${OIDC_TOKEN_URL}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${OIDC_CLIENT}&client_secret=${client_secret}&scope=openid" \
  | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p"' 2>/dev/null
}

assert_oidc_discovery() {
  local url="${HYDRA_PUBLIC_URL}/.well-known/openid-configuration"

  log_info "E2E: Ory Hydra OIDC discovery"
  kubectl_cmd -n "${ORY_NAMESPACE}" delete pod ory-oidc-e2e-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${ORY_NAMESPACE}" run ory-oidc-e2e-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${url}" | grep -q '"issuer"' >/dev/null 2>&1 || {
    log_error "OIDC discovery failed at ${url}"
    exit 1
  }
  log_info "OIDC discovery OK for Ory Hydra"
}

assert_krakend_rejects_unauthenticated() {
  local data http_code body_file

  data="$(date +%Y-%m-%d)"
  body_file="$(mktemp)"
  trap 'rm -f "${body_file}"' RETURN

  http_code="$(curl -sk -o "${body_file}" -w '%{http_code}' \
    "${KRAKEND_URL}/v1/consolidado/${data}")"
  case "${http_code}" in
    401|403)
      log_info "KrakenD rejects unauthenticated GET /v1/consolidado (HTTP ${http_code})"
      ;;
    *)
      log_error "expected 401/403 without JWT on GET /v1/consolidado, got HTTP ${http_code}: $(cat "${body_file}")"
      exit 1
      ;;
  esac

  http_code="$(curl -sk -o "${body_file}" -w '%{http_code}' \
    -X POST "${KRAKEND_URL}/v1/lancamentos" \
    -H "Content-Type: application/json" \
    -d '{"valor":10.00,"tipo":"CREDITO","data_competencia":"'"${data}"'"}')"
  case "${http_code}" in
    401|403)
      log_info "KrakenD rejects unauthenticated POST /v1/lancamentos (HTTP ${http_code})"
      ;;
    *)
      log_error "expected 401/403 without JWT on POST /v1/lancamentos, got HTTP ${http_code}: $(cat "${body_file}")"
      exit 1
      ;;
  esac
}

assert_token_merchant_id() {
  local access_token="$1"
  local claim

  claim="$(python3 -c "
import base64
import json
import sys

token = sys.argv[1]
try:
    payload = token.split('.')[1]
    payload += '=' * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
except Exception as exc:
    sys.stderr.write(f'invalid JWT payload: {exc}\n')
    sys.exit(1)

merchant_id = claims.get('merchant_id')
if isinstance(merchant_id, list):
    merchant_id = merchant_id[0] if merchant_id else ''
if not merchant_id or not str(merchant_id).strip():
    sys.stderr.write('merchant_id claim missing or empty\n')
    sys.exit(1)
print(str(merchant_id).strip())
" "${access_token}")" || {
    log_error "token missing non-empty merchant_id claim"
    exit 1
  }

  log_info "token merchant_id claim OK (${claim})"
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

  assert_oidc_discovery
  assert_krakend_rejects_unauthenticated

  log_info "E2E: Ory Hydra OIDC client_credentials (${E2E_LANCAMENTOS_CLIENT} + ${E2E_CONSULTA_CLIENT})"
  lanc_secret="$(read_hydra_client_secret "${E2E_LANCAMENTOS_CLIENT}")"
  consulta_secret="$(read_hydra_client_secret "${E2E_CONSULTA_CLIENT}")"

  lanc_token="$(obtain_access_token_via_hydra "${E2E_LANCAMENTOS_CLIENT}" "${lanc_secret}" | tr -d '\n\r')"
  consulta_token="$(obtain_access_token_via_hydra "${E2E_CONSULTA_CLIENT}" "${consulta_secret}" | tr -d '\n\r')"
  if [[ -z "${lanc_token}" ]] || [[ -z "${consulta_token}" ]]; then
    log_error "could not obtain OIDC tokens for ${E2E_LANCAMENTOS_CLIENT} / ${E2E_CONSULTA_CLIENT}"
    exit 1
  fi

  assert_token_merchant_id "${lanc_token}"
  assert_token_merchant_id "${consulta_token}"

  data_competencia="$(date +%Y-%m-%d)"
  log_info "E2E: POST lancamento (data_competencia=${data_competencia})"
  lancamento_id="$(post_lancamento "${lanc_token}" "${data_competencia}")"
  log_info "lancamento accepted id=${lancamento_id}"

  log_info "E2E: poll GET consolidado until fresh"
  poll_consolidado_until_fresh "${consulta_token}" "${data_competencia}" >/dev/null

  log_info "run-e2e.sh — E2E complete (auth → POST → consolidado fresh)"
}

main "$@"
