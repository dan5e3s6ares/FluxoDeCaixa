#!/usr/bin/env sh
# Idempotent Authentik OIDC bootstrap for fluxo-caixa (doc simplificacao-de-projeto).
set -eu

AUTHENTIK_URL="${AUTHENTIK_URL:-http://authentik-server.security.svc.cluster.local:9000}"
AUTHENTIK_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:?AUTHENTIK_BOOTSTRAP_TOKEN is required}"
APP_SLUG="${APP_SLUG:-fluxo-caixa}"
MAPPING_NAME="${MAPPING_NAME:-fluxo-merchant-id}"
REQUIRED_CLIENTS="${REQUIRED_CLIENTS:-svc-lancamentos,svc-consolidado,svc-consulta}"

log() {
  echo "[authentik-bootstrap] $*"
}

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response http_code

  if [ -n "${body}" ]; then
    response="$(curl -sS -w '\n%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      "${AUTHENTIK_URL}${path}" \
      --data "${body}")"
  else
    response="$(curl -sS -w '\n%{http_code}' -X "${method}" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      "${AUTHENTIK_URL}${path}")"
  fi

  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"
  if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 300 ]; then
    printf '%s' "${response}"
    return 0
  fi

  log "API ${method} ${path} failed (HTTP ${http_code}): ${response}"
  return 1
}

json_pk() {
  # Prefer the first pk in paginated "results"; fall back to the first pk in the body.
  local body pk
  body="$(cat)"
  pk="$(printf '%s' "${body}" | sed -n 's/.*"results"[^[]*\[[^]]*"pk"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | head -n 1 | tr -d ' "')"
  if [ -n "${pk}" ]; then
    printf '%s' "${pk}"
    return 0
  fi
  printf '%s' "${body}" | sed -n 's/.*"pk"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' | head -n 1 | tr -d ' "'
}

json_field_present() {
  # DRF JSON uses spaces after colons ("slug": "value"); match flexibly.
  local field="$1"
  local value="$2"
  grep -Eq "\"${field}\"[[:space:]]*:[[:space:]]*\"${value}\""
}

json_ref() {
  # Emit JSON for Authentik FK fields: bare integer pk or quoted UUID/string.
  case "$1" in
    '' ) printf 'null' ;;
    *[!0-9]* ) printf '"%s"' "$1" ;;
    * ) printf '%s' "$1" ;;
  esac
}

wait_for_authentik() {
  local attempt=1
  local max="${AUTHENTIK_WAIT_ATTEMPTS:-60}"
  local delay="${AUTHENTIK_WAIT_DELAY:-2}"

  while [ "${attempt}" -le "${max}" ]; do
    if curl -sf "${AUTHENTIK_URL}/-/health/ready/" >/dev/null 2>&1; then
      log "Authentik ready at ${AUTHENTIK_URL}"
      return 0
    fi
    log "waiting for Authentik (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  log "Authentik not ready at ${AUTHENTIK_URL}"
  return 1
}

jwks_available() {
  curl -sf "${AUTHENTIK_URL}/application/o/${APP_SLUG}/jwks/" >/dev/null 2>&1
}

wait_for_jwks() {
  local attempt=1
  local max="${JWKS_WAIT_ATTEMPTS:-60}"
  local delay="${JWKS_WAIT_DELAY:-2}"

  while [ "${attempt}" -le "${max}" ]; do
    if jwks_available; then
      log "JWKS available at /application/o/${APP_SLUG}/jwks/"
      return 0
    fi
    log "waiting for JWKS (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  log "JWKS not available at /application/o/${APP_SLUG}/jwks/ after ${max} attempts"
  return 1
}

application_exists() {
  api GET "/api/v3/core/applications/?slug=${APP_SLUG}" | json_field_present slug "${APP_SLUG}"
}

mapping_exists() {
  api GET "/api/v3/propertymappings/all/?search=${MAPPING_NAME}" | json_field_present name "${MAPPING_NAME}"
}

provider_client_exists() {
  local client_id="$1"
  api GET "/api/v3/providers/oauth2/?client_id=${client_id}" | json_field_present client_id "${client_id}"
}

flow_pk() {
  local slug="$1"
  api GET "/api/v3/flows/instances/?slug=${slug}" | json_pk
}

scope_mapping_pk() {
  # Authentik list filters vary by version; search then verify scope_name in the body.
  local scope="$1"
  local body pk

  body="$(api GET "/api/v3/propertymappings/oauth2/?search=${scope}")"
  if ! printf '%s' "${body}" | json_field_present scope_name "${scope}"; then
    return 1
  fi

  pk="$(printf '%s' "${body}" | json_pk)"
  [ -n "${pk}" ] || return 1
  printf '%s' "${pk}"
}

signing_key_pk() {
  local pk

  pk="$(api GET "/api/v3/crypto/certificatekeypairs/?search=authentik%20Self-signed%20Certificate" | json_pk)"
  if [ -n "${pk}" ]; then
    printf '%s' "${pk}"
    return 0
  fi

  log "Self-signed certificate not found via search; using first available keypair"
  pk="$(api GET "/api/v3/crypto/certificatekeypairs/" | json_pk)"
  [ -n "${pk}" ] || return 1
  printf '%s' "${pk}"
}

ensure_merchant_id_mapping() {
  if mapping_exists; then
    log "property mapping ${MAPPING_NAME} already exists"
    return 0
  fi

  log "creating property mapping ${MAPPING_NAME} (claim merchant_id)"
  if api POST "/api/v3/propertymappings/oauth2/" "$(cat <<EOF
{
  "name": "${MAPPING_NAME}",
  "scope_name": "merchant_id",
  "expression": "return user.attributes.get(\\\"merchant_id\\\", [None])[0]"
}
EOF
)"; then
    return 0
  fi

  if mapping_exists; then
    log "property mapping ${MAPPING_NAME} present after create conflict (idempotent)"
    return 0
  fi
  return 1
}

resolve_merchant_mapping_pk() {
  mapping_pk="$(api GET "/api/v3/propertymappings/all/?search=${MAPPING_NAME}" | json_pk)"
}

wait_for_merchant_mapping_pk() {
  local attempt=1
  local max="${MAPPING_WAIT_ATTEMPTS:-30}"
  local delay="${MAPPING_WAIT_DELAY:-2}"

  while [ "${attempt}" -le "${max}" ]; do
    resolve_merchant_mapping_pk
    if [ -n "${mapping_pk}" ] && mapping_exists; then
      return 0
    fi
    log "waiting for property mapping ${MAPPING_NAME} (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  resolve_merchant_mapping_pk
  [ -n "${mapping_pk}" ] && mapping_exists
}

oauth2_provider_payload() {
  local name="$1"
  local client_id="$2"
  local property_mappings="$3"
  local auth_flow="$4"
  local invalid_flow="$5"
  local signing_key="$6"

  cat <<EOF
{
  "name": "${name}",
  "client_id": "${client_id}",
  "client_type": "confidential",
  "authorization_flow": $(json_ref "${auth_flow}"),
  "invalidation_flow": $(json_ref "${invalid_flow}"),
  "redirect_uris": [],
  "property_mappings": ${property_mappings},
  "signing_key": $(json_ref "${signing_key}"),
  "access_code_validity": "minutes=1",
  "access_token_validity": "minutes=15",
  "refresh_token_validity": "days=30"
}
EOF
}

upsert_oauth2_provider() {
  local name="$1"
  local client_id="$2"
  local property_mappings="$3"
  local auth_flow="$4"
  local invalid_flow="$5"
  local signing_key="$6"
  local body provider_pk

  body="$(oauth2_provider_payload "${name}" "${client_id}" "${property_mappings}" \
    "${auth_flow}" "${invalid_flow}" "${signing_key}")"

  if provider_client_exists "${client_id}"; then
    provider_pk="$(api GET "/api/v3/providers/oauth2/?client_id=${client_id}" | json_pk)"
    log "updating OAuth2 provider ${client_id} (pk ${provider_pk})"
    api PATCH "/api/v3/providers/oauth2/${provider_pk}/" "${body}"
    printf '%s' "${provider_pk}"
    return 0
  fi

  log "creating OAuth2 provider ${client_id}"
  if api POST "/api/v3/providers/oauth2/" "${body}" | json_pk; then
    return 0
  fi

  if provider_client_exists "${client_id}"; then
    provider_pk="$(api GET "/api/v3/providers/oauth2/?client_id=${client_id}" | json_pk)"
    log "updating OAuth2 provider ${client_id} after create conflict (pk ${provider_pk})"
    api PATCH "/api/v3/providers/oauth2/${provider_pk}/" "${body}"
    printf '%s' "${provider_pk}"
    return 0
  fi
  return 1
}

resolve_oauth2_defaults() {
  auth_flow="$(flow_pk default-provider-authorization-implicit-consent)"
  invalid_flow="$(flow_pk default-provider-invalidation-flow)"
  signing_key="$(signing_key_pk)"
  openid_pk="$(scope_mapping_pk openid || true)"
  email_pk="$(scope_mapping_pk email || true)"
  profile_pk="$(scope_mapping_pk profile || true)"
}

wait_for_oauth2_defaults() {
  local attempt=1
  local max="${OAUTH2_DEFAULTS_WAIT_ATTEMPTS:-30}"
  local delay="${OAUTH2_DEFAULTS_WAIT_DELAY:-2}"

  while [ "${attempt}" -le "${max}" ]; do
    resolve_oauth2_defaults
    if oauth2_defaults_ready; then
      return 0
    fi
    log "waiting for Authentik OAuth2 defaults (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done

  resolve_oauth2_defaults
  oauth2_defaults_ready
}

oauth2_defaults_ready() {
  if [ -z "${auth_flow}" ] || [ -z "${invalid_flow}" ] || [ -z "${signing_key}" ] \
    || [ -z "${openid_pk}" ] || [ -z "${email_pk}" ] || [ -z "${profile_pk}" ]; then
    log "missing Authentik defaults (flows, signing key, or built-in scope mappings)"
    return 1
  fi
  return 0
}

ensure_application_linked() {
  local provider_pk="$1"
  local app_pk

  if ! application_exists; then
    log "creating application ${APP_SLUG}"
    if api POST "/api/v3/core/applications/" "$(cat <<EOF
{
  "name": "fluxo-caixa",
  "slug": "${APP_SLUG}",
  "provider": $(json_ref "${provider_pk}")
}
EOF
)"; then
      return 0
    fi
    if ! application_exists; then
      return 1
    fi
  fi

  app_pk="$(api GET "/api/v3/core/applications/?slug=${APP_SLUG}" | json_pk)"
  [ -n "${app_pk}" ] || return 1
  log "linking application ${APP_SLUG} to provider ${provider_pk} (pk ${app_pk})"
  api PATCH "/api/v3/core/applications/${app_pk}/" "$(cat <<EOF
{
  "provider": $(json_ref "${provider_pk}")
}
EOF
)"
}

ensure_application_provider() {
  # resolve_oauth2_defaults sets globals; do not declare those names local here (shadowing bug).
  local property_mappings provider_pk

  if application_exists && jwks_available && mapping_exists; then
    log "application ${APP_SLUG} already configured with JWKS and merchant_id mapping"
    return 0
  fi

  ensure_merchant_id_mapping
  wait_for_merchant_mapping_pk || return 1
  wait_for_oauth2_defaults || return 1

  property_mappings="[${openid_pk},${email_pk},${profile_pk},${mapping_pk}]"
  provider_pk="$(upsert_oauth2_provider "${APP_SLUG}" "${APP_SLUG}" "${property_mappings}" \
    "${auth_flow}" "${invalid_flow}" "${signing_key}")"

  ensure_application_linked "${provider_pk}"
  wait_for_jwks
}

ensure_service_clients() {
  local client_id
  local property_mappings

  wait_for_merchant_mapping_pk || return 1
  wait_for_oauth2_defaults || return 1
  property_mappings="[${openid_pk},${email_pk},${profile_pk},${mapping_pk}]"

  IFS=','
  for client_id in ${REQUIRED_CLIENTS}; do
    upsert_oauth2_provider "${client_id}" "${client_id}" "${property_mappings}" \
      "${auth_flow}" "${invalid_flow}" "${signing_key}" >/dev/null
  done
}

main() {
  wait_for_authentik
  ensure_application_provider
  ensure_service_clients
  log "bootstrap complete — issuer ${AUTHENTIK_URL}/application/o/${APP_SLUG}/"
}

main "$@"
