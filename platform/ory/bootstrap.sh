#!/usr/bin/env sh
# Idempotent Ory Hydra OAuth2 bootstrap for fluxo-caixa (Kratos + Hydra IdP).
set -eu

HYDRA_ADMIN_URL="${HYDRA_ADMIN_URL:-http://hydra-admin.security.svc.cluster.local:4445}"
HYDRA_PUBLIC_URL="${HYDRA_PUBLIC_URL:-http://hydra-public.security.svc.cluster.local:4444}"
KRATOS_ADMIN_URL="${KRATOS_ADMIN_URL:-http://kratos-admin.security.svc.cluster.local:4434}"
DEFAULT_MERCHANT_ID="${DEFAULT_MERCHANT_ID:-00000000-0000-4000-8000-000000000001}"
REQUIRED_CLIENTS="${REQUIRED_CLIENTS:-svc-lancamentos,svc-consolidado,svc-consulta}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

log() {
  echo "[ory-bootstrap] $*" >&2
}

preflight_commands() {
  for cmd in curl grep sed head tr; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log "required command missing in container image: ${cmd}"
      exit 1
    fi
  done
}

hydra_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response http_code

  if [ -n "${body}" ]; then
    response="$(curl -sS -w '\n%{http_code}' -X "${method}" \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      -H "Content-Type: application/json" \
      "${HYDRA_ADMIN_URL}${path}" \
      --data "${body}")"
  else
    response="$(curl -sS -w '\n%{http_code}' -X "${method}" \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      -H "Content-Type: application/json" \
      "${HYDRA_ADMIN_URL}${path}")"
  fi

  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 300 ]; then
    printf '%s' "${response}"
    return 0
  fi

  log "Hydra API ${method} ${path} failed (HTTP ${http_code}): ${response}"
  return 1
}

json_field_present() {
  local field="$1"
  local value="$2"
  grep -Eq "\"${field}\"[[:space:]]*:[[:space:]]*\"${value}\""
}

wait_for_hydra() {
  local attempt=1
  local max="${ORY_WAIT_ATTEMPTS:-60}"
  local delay="${ORY_WAIT_DELAY:-2}"

  if [ "${ORY_SKIP_READY_WAIT:-0}" = "1" ]; then
    if curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        "${HYDRA_ADMIN_URL}/health/ready" >/dev/null 2>&1; then
      log "Hydra ready at ${HYDRA_ADMIN_URL} (skip wait — deploy-platform verified)"
      return 0
    fi
    log "ORY_SKIP_READY_WAIT=1 but Hydra health check failed; falling back to wait loop"
  fi

  while [ "${attempt}" -le "${max}" ]; do
    if curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        "${HYDRA_ADMIN_URL}/health/ready" >/dev/null 2>&1; then
      log "Hydra ready at ${HYDRA_ADMIN_URL}"
      return 0
    fi
    log "waiting for Hydra (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  log "Hydra not ready at ${HYDRA_ADMIN_URL}"
  return 1
}

wait_for_kratos() {
  local attempt=1
  local max="${ORY_WAIT_ATTEMPTS:-60}"
  local delay="${ORY_WAIT_DELAY:-2}"

  while [ "${attempt}" -le "${max}" ]; do
    if curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        "${KRATOS_ADMIN_URL}/health/ready" >/dev/null 2>&1; then
      log "Kratos ready at ${KRATOS_ADMIN_URL}"
      return 0
    fi
    log "waiting for Kratos (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  log "Kratos not ready at ${KRATOS_ADMIN_URL}"
  return 1
}

jwks_available() {
  curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    "${HYDRA_PUBLIC_URL}/.well-known/jwks.json" >/dev/null 2>&1
}

wait_for_jwks() {
  local attempt=1
  local max="${JWKS_WAIT_ATTEMPTS:-60}"
  local delay="${JWKS_WAIT_DELAY:-2}"

  while [ "${attempt}" -le "${max}" ]; do
    if jwks_available; then
      log "JWKS available at ${HYDRA_PUBLIC_URL}/.well-known/jwks.json"
      return 0
    fi
    log "waiting for JWKS (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  log "JWKS not available after ${max} attempts"
  return 1
}

oidc_discovery_ok() {
  curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    "${HYDRA_PUBLIC_URL}/.well-known/openid-configuration" | json_field_present issuer \
      "http://hydra-public.security.svc.cluster.local:4444/"
}

client_exists() {
  local client_id="$1"
  curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    "${HYDRA_ADMIN_URL}/clients/${client_id}" >/dev/null 2>&1
}

random_secret() {
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

client_payload() {
  local client_id="$1"
  local client_secret="$2"
  local merchant_id="$3"

  cat <<EOF
{
  "client_id": "${client_id}",
  "client_secret": "${client_secret}",
  "grant_types": ["client_credentials"],
  "response_types": ["token"],
  "token_endpoint_auth_method": "client_secret_post",
  "scope": "openid",
  "metadata": {
    "merchant_id": "${merchant_id}"
  }
}
EOF
}

client_secret_for() {
  local client_id="$1"
  curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    "${HYDRA_ADMIN_URL}/clients/${client_id}" 2>/dev/null \
    | sed -n 's/.*"client_secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

ensure_oauth2_client() {
  local client_id="$1"
  local merchant_id="${2:-${DEFAULT_MERCHANT_ID}}"
  local client_secret body

  if client_exists "${client_id}"; then
    client_secret="$(client_secret_for "${client_id}")"
    if [ -z "${client_secret}" ]; then
      client_secret="$(random_secret)"
    fi
    log "OAuth2 client ${client_id} already exists — updating metadata merchant_id"
    hydra_api PUT "/clients/${client_id}" "$(client_payload "${client_id}" "${client_secret}" "${merchant_id}")" >/dev/null
    return 0
  fi

  client_secret="$(random_secret)"
  log "creating OAuth2 client ${client_id} (merchant_id=${merchant_id})"
  hydra_api POST "/clients" "$(client_payload "${client_id}" "${client_secret}" "${merchant_id}")" >/dev/null
}

ensure_service_clients() {
  local client_id
  IFS=','
  for client_id in ${REQUIRED_CLIENTS}; do
    ensure_oauth2_client "${client_id}" "${DEFAULT_MERCHANT_ID}"
  done
}

main() {
  preflight_commands
  wait_for_hydra
  wait_for_kratos
  ensure_service_clients
  if [ "${ORY_SKIP_JWKS_WAIT:-0}" = "1" ]; then
    log "skipping JWKS wait (deploy-platform validates OIDC discovery)"
  else
    wait_for_jwks
  fi
  log "bootstrap complete — issuer ${HYDRA_PUBLIC_URL}/"
}

main "$@"
