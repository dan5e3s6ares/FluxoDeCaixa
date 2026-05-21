#!/usr/bin/env sh
# Idempotent Keycloak realm import per docs 05/07.
set -eu

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.security.svc.cluster.local:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD is required}"
REALM_NAME="${REALM_NAME:-fluxo-caixa}"
REALM_FILE="${REALM_FILE:-/realm/realm-fluxo-caixa.json}"
REQUIRED_CLIENTS="${REQUIRED_CLIENTS:-svc-lancamentos,svc-consolidado,svc-consulta,krakend}"

log() {
  echo "[keycloak-bootstrap] $*"
}

wait_for_keycloak() {
  local attempt=1
  local max="${KEYCLOAK_WAIT_ATTEMPTS:-60}"
  local delay="${KEYCLOAK_WAIT_DELAY:-2}"
  while [ "${attempt}" -le "${max}" ]; do
    if curl -sf "${KEYCLOAK_URL}/health/ready" >/dev/null 2>&1; then
      log "Keycloak ready at ${KEYCLOAK_URL}"
      return 0
    fi
    log "waiting for Keycloak (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
  log "Keycloak not ready at ${KEYCLOAK_URL}"
  return 1
}

admin_token() {
  curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

realm_http_code() {
  local token="$1"
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}"
}

client_exists() {
  local token="$1"
  local client_id="$2"
  curl -sf \
    -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${client_id}" \
    | grep -q "\"clientId\":\"${client_id}\""
}

all_clients_present() {
  local token="$1"
  local client_id
  IFS=','
  for client_id in ${REQUIRED_CLIENTS}; do
    if ! client_exists "${token}" "${client_id}"; then
      return 1
    fi
  done
  return 0
}

import_realm() {
  local token="$1"
  log "importing realm ${REALM_NAME}"
  curl -sf -X POST "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data-binary "@${REALM_FILE}"
}

main() {
  local token code

  wait_for_keycloak

  token="$(admin_token)"
  if [ -z "${token}" ]; then
    log "failed to obtain admin token"
    return 1
  fi

  code="$(realm_http_code "${token}")"
  if [ "${code}" = "200" ] && all_clients_present "${token}"; then
    log "realm ${REALM_NAME} already imported with required clients"
    return 0
  fi

  if [ "${code}" = "404" ]; then
    import_realm "${token}"
    log "realm ${REALM_NAME} imported"
    return 0
  fi

  log "realm ${REALM_NAME} exists but clients incomplete (http ${code}); re-import not supported"
  return 1
}

main "$@"
