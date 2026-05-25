#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

KRAKEND_NODEPORT="${KRAKEND_NODEPORT:-30443}"
KRAKEND_URL="${KRAKEND_URL:-https://127.0.0.1:${KRAKEND_NODEPORT}}"
AUTHENTIK_NAMESPACE="${AUTHENTIK_NAMESPACE:-security}"
AUTHENTIK_SERVER_URL="${AUTHENTIK_SERVER_URL:-http://authentik-server.${AUTHENTIK_NAMESPACE}.svc.cluster.local:9000}"
AUTHENTIK_APP_SLUG="${AUTHENTIK_APP_SLUG:-fluxo-caixa}"
OIDC_TOKEN_URL="${OIDC_TOKEN_URL:-${AUTHENTIK_SERVER_URL}/application/o/${AUTHENTIK_APP_SLUG}/token/}"
E2E_LANCAMENTOS_CLIENT="${E2E_LANCAMENTOS_CLIENT:-svc-lancamentos}"
E2E_CONSULTA_CLIENT="${E2E_CONSULTA_CLIENT:-svc-consulta}"
E2E_SECRET_NAME="${E2E_SECRET_NAME:-e2e-oidc-material}"
E2E_MERCHANT_ID="${E2E_MERCHANT_ID:-00000000-0000-4000-8000-000000000001}"
E2E_LANCAMENTO_VALOR="${E2E_LANCAMENTO_VALOR:-10.00}"
E2E_POLL_MAX_ATTEMPTS="${E2E_POLL_MAX_ATTEMPTS:-90}"
E2E_POLL_DELAY="${E2E_POLL_DELAY:-2}"

cleanup_e2e_secret() {
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" delete secret "${E2E_SECRET_NAME}" --ignore-not-found >/dev/null 2>&1
}

read_authentik_bootstrap_token() {
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get secret fluxo-authentik \
    -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true
}

read_oidc_client_secret() {
  local client_id="$1"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get secret "fluxo-oidc-${client_id}" \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null || true
}

# Obtain client_credentials token via Authentik application fluxo-caixa; ensures SA carries merchant_id.
obtain_access_token_via_authentik() {
  local api_token="$1"
  local oidc_client="$2"
  local known_secret="${3:-}"

  cleanup_e2e_secret
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" delete pod "e2e-oidc-${oidc_client}" --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" create secret generic "${E2E_SECRET_NAME}" \
    --from-literal=authentik-api-token="${api_token}" >/dev/null

  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" run "e2e-oidc-${oidc_client}" --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --env="OIDC_CLIENT=${oidc_client}" \
    --env="MERCHANT_ID=${E2E_MERCHANT_ID}" \
    --env="AUTHENTIK_URL=${AUTHENTIK_SERVER_URL}" \
    --env="OIDC_TOKEN_URL=${OIDC_TOKEN_URL}" \
    --env="KNOWN_CLIENT_SECRET=${known_secret}" \
    --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "e2e-oidc-${oidc_client}",
      "image": "curlimages/curl:8.12.1",
      "stdin": true,
      "stdinOnce": true,
      "env": [
        {"name": "AUTHENTIK_API_TOKEN", "valueFrom": {"secretKeyRef": {"name": "${E2E_SECRET_NAME}", "key": "authentik-api-token"}}},
        {"name": "OIDC_CLIENT", "value": "${oidc_client}"},
        {"name": "MERCHANT_ID", "value": "${E2E_MERCHANT_ID}"},
        {"name": "AUTHENTIK_URL", "value": "${AUTHENTIK_SERVER_URL}"},
        {"name": "OIDC_TOKEN_URL", "value": "${OIDC_TOKEN_URL}"},
        {"name": "KNOWN_CLIENT_SECRET", "value": "${known_secret}"}
      ],
      "command": ["sh", "-ce", "set -euo pipefail\napi() { curl -sf -H \"Authorization: Bearer \${AUTHENTIK_API_TOKEN}\" -H \"Content-Type: application/json\" \"\$@\"; }\njson_pk() { sed -n 's/.*\\\"pk\\\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p' | head -n 1 | tr -d ' \\\"'; }\nPROVIDER_PK=\$(api \"\${AUTHENTIK_URL}/api/v3/providers/oauth2/?client_id=\${OIDC_CLIENT}\" | json_pk)\n[ -n \"\${PROVIDER_PK}\" ] || { echo \"provider not found for \${OIDC_CLIENT}\" >&2; exit 1; }\nif [ -n \"\${KNOWN_CLIENT_SECRET}\" ]; then\n  CLIENT_SECRET=\"\${KNOWN_CLIENT_SECRET}\"\nelse\n  CLIENT_SECRET=\$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \\n')\n  api -X PATCH \"\${AUTHENTIK_URL}/api/v3/providers/oauth2/\${PROVIDER_PK}/\" --data \"{\\\"client_secret\\\":\\\"\${CLIENT_SECRET}\\\"}\" >/dev/null\nfi\nSA_USERNAME=\"ak-\${OIDC_CLIENT}-client_credentials\"\ncurl -sf -X POST \"\${OIDC_TOKEN_URL}\" -H 'Content-Type: application/x-www-form-urlencoded' -d \"grant_type=client_credentials&client_id=\${OIDC_CLIENT}&client_secret=\${CLIENT_SECRET}\" >/dev/null || true\nUSER_PK=\$(api \"\${AUTHENTIK_URL}/api/v3/core/users/?username=\${SA_USERNAME}\" | json_pk)\n[ -n \"\${USER_PK}\" ] || { echo \"service account \${SA_USERNAME} not found\" >&2; exit 1; }\napi -X PATCH \"\${AUTHENTIK_URL}/api/v3/core/users/\${USER_PK}/\" --data \"{\\\"attributes\\\":{\\\"merchant_id\\\":[\\\"\${MERCHANT_ID}\\\"]}}\" >/dev/null\ncurl -sf -X POST \"\${OIDC_TOKEN_URL}\" -H 'Content-Type: application/x-www-form-urlencoded' -d \"grant_type=client_credentials&client_id=\${OIDC_CLIENT}&client_secret=\${CLIENT_SECRET}&scope=openid+merchant_id\" | sed -n 's/.*\\\"access_token\\\":\\\"\\([^\\\"]*\\)\\\".*/\\1/p'"]
    }]
  }
}
EOF
)" 2>/dev/null
}

assert_oidc_discovery() {
  local url="${AUTHENTIK_SERVER_URL}/application/o/${AUTHENTIK_APP_SLUG}/.well-known/openid-configuration"

  log_info "E2E: Authentik OIDC discovery (${AUTHENTIK_APP_SLUG})"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" delete pod authentik-oidc-e2e-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" run authentik-oidc-e2e-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${url}" | grep -q '"issuer"' >/dev/null 2>&1 || {
    log_error "OIDC discovery failed at ${url}"
    exit 1
  }
  log_info "OIDC discovery OK for application ${AUTHENTIK_APP_SLUG}"
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
  local bootstrap_token lanc_secret consulta_secret

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

  log_info "E2E: Authentik OIDC client_credentials (${E2E_LANCAMENTOS_CLIENT} + ${E2E_CONSULTA_CLIENT}) via application ${AUTHENTIK_APP_SLUG}"
  bootstrap_token="$(read_authentik_bootstrap_token)"
  if [[ -z "${bootstrap_token}" ]]; then
    log_error "fluxo-authentik AUTHENTIK_BOOTSTRAP_TOKEN missing — deploy Authentik first"
    exit 1
  fi

  lanc_secret="$(read_oidc_client_secret "${E2E_LANCAMENTOS_CLIENT}")"
  consulta_secret="$(read_oidc_client_secret "${E2E_CONSULTA_CLIENT}")"

  lanc_token="$(obtain_access_token_via_authentik "${bootstrap_token}" "${E2E_LANCAMENTOS_CLIENT}" "${lanc_secret}" | tr -d '\n\r')"
  consulta_token="$(obtain_access_token_via_authentik "${bootstrap_token}" "${E2E_CONSULTA_CLIENT}" "${consulta_secret}" | tr -d '\n\r')"
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
