#!/usr/bin/env sh
# Idempotent Authentik OIDC bootstrap for fluxo-caixa (doc simplificacao-de-projeto).
set -eu

AUTHENTIK_URL="${AUTHENTIK_URL:-http://authentik-server.security.svc.cluster.local:9000}"
AUTHENTIK_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:?AUTHENTIK_BOOTSTRAP_TOKEN is required}"
APP_SLUG="${APP_SLUG:-fluxo-caixa}"
MAPPING_NAME="${MAPPING_NAME:-fluxo-merchant-id}"
REQUIRED_CLIENTS="${REQUIRED_CLIENTS:-svc-lancamentos,svc-consolidado,svc-consulta}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

log() {
  echo "[authentik-bootstrap] $*"
}

preflight_commands() {
  for cmd in curl grep sed head tr; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log "required command missing in container image: ${cmd} (use alpine + curl, not curlimages/curl)"
      exit 1
    fi
  done
}

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local response http_code

  if [ -n "${body}" ]; then
    response="$(curl -sS -w '\n%{http_code}' -X "${method}" \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      "${AUTHENTIK_URL}${path}" \
      --data "${body}")"
  else
    response="$(curl -sS -w '\n%{http_code}' -X "${method}" \
      --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" \
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

  if [ "${AUTHENTIK_SKIP_READY_WAIT:-0}" = "1" ]; then
    if curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        "${AUTHENTIK_URL}/-/health/ready/" >/dev/null 2>&1; then
      log "Authentik ready at ${AUTHENTIK_URL} (skip wait — deploy-platform verified)"
      return 0
    fi
    log "AUTHENTIK_SKIP_READY_WAIT=1 but health check failed; falling back to wait loop"
  fi

  while [ "${attempt}" -le "${max}" ]; do
    if curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
        "${AUTHENTIK_URL}/-/health/ready/" >/dev/null 2>&1; then
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
  curl -sf --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    "${AUTHENTIK_URL}/application/o/${APP_SLUG}/jwks/" >/dev/null 2>&1
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
  local body
  body="$(api_body "/api/v3/core/applications/?slug=${APP_SLUG}")"
  [ -n "${body}" ] && printf '%s' "${body}" | json_field_present slug "${APP_SLUG}"
}

mapping_exists() {
  local body
  body="$(api_body "/api/v3/propertymappings/all/?search=${MAPPING_NAME}")"
  [ -n "${body}" ] && printf '%s' "${body}" | json_field_present name "${MAPPING_NAME}"
}

provider_client_exists() {
  local client_id="$1"
  local body
  body="$(api_body "/api/v3/providers/oauth2/?client_id=${client_id}")"
  [ -n "${body}" ] && printf '%s' "${body}" | json_field_present client_id "${client_id}"
}

api_body() {
  # Lookup helper: never abort the script on HTTP errors (set -e safe).
  api GET "$1" 2>/dev/null || true
}

flow_pk() {
  local slug="$1"
  local body pk

  body="$(api_body "/api/v3/flows/instances/?slug=${slug}")"
  if [ -z "${body}" ] || ! printf '%s' "${body}" | json_field_present slug "${slug}"; then
    return 1
  fi
  pk="$(printf '%s' "${body}" | json_pk)"
  [ -n "${pk}" ] || return 1
  printf '%s' "${pk}"
}

scope_mapping_list_body() {
  local query="$1"
  local base path body

  for base in "/api/v3/propertymappings/provider/scope/" \
              "/api/v3/propertymappings/oauth2/"; do
    if [ -n "${query}" ]; then
      path="${base}?${query}"
    else
      path="${base}"
    fi
    body="$(api_body "${path}")"
    if [ -n "${body}" ]; then
      printf '%s' "${body}"
      return 0
    fi
  done
  return 1
}

managed_scope_filter() {
  # Authentik 2025.12.x built-in scopes use managed=goauthentik.io/providers/oauth2/scope-<name>.
  printf 'goauthentik.io/providers/oauth2/scope-%s' "$1"
}

scope_mapping_pk() {
  # Authentik 2025.x lists built-in scopes at provider/scope; legacy oauth2 path may be empty.
  local scope="$1"
  local query body pk managed

  managed="$(managed_scope_filter "${scope}")"
  body="$(api_body "/api/v3/propertymappings/provider/scope/?managed=${managed}")"
  if [ -n "${body}" ] && printf '%s' "${body}" | json_field_present scope_name "${scope}"; then
    pk="$(printf '%s' "${body}" | json_pk)"
    if [ -n "${pk}" ]; then
      printf '%s' "${pk}"
      return 0
    fi
  fi

  for query in "scope_name=${scope}" "search=${scope}"; do
    body="$(scope_mapping_list_body "${query}" || true)"
    if [ -z "${body}" ]; then
      continue
    fi
    if ! printf '%s' "${body}" | json_field_present scope_name "${scope}"; then
      continue
    fi
    pk="$(printf '%s' "${body}" | json_pk)"
    if [ -n "${pk}" ]; then
      printf '%s' "${pk}"
      return 0
    fi
  done

  body="$(scope_mapping_list_body "" || true)"
  if [ -n "${body}" ] && printf '%s' "${body}" | json_field_present scope_name "${scope}"; then
    pk="$(printf '%s' "${body}" | json_pk)"
    if [ -n "${pk}" ]; then
      printf '%s' "${pk}"
      return 0
    fi
  fi

  log "scope mapping ${scope} not found (managed=${managed}, scope_name/search, full list)"
  return 1
}

signing_key_pk() {
  local pk body

  body="$(api_body "/api/v3/crypto/certificatekeypairs/?search=authentik%20Self-signed%20Certificate")"
  if [ -n "${body}" ]; then
    pk="$(printf '%s' "${body}" | json_pk)"
    if [ -n "${pk}" ]; then
      printf '%s' "${pk}"
      return 0
    fi
  fi

  log "Self-signed certificate not found via search; using first available keypair"
  body="$(api_body "/api/v3/crypto/certificatekeypairs/")"
  [ -n "${body}" ] || return 1
  pk="$(printf '%s' "${body}" | json_pk)"
  [ -n "${pk}" ] || return 1
  printf '%s' "${pk}"
}

merchant_mapping_payload() {
  cat <<EOF
{
  "name": "${MAPPING_NAME}",
  "scope_name": "merchant_id",
  "expression": "return user.attributes.get(\\\"merchant_id\\\", [None])[0]"
}
EOF
}

ensure_merchant_id_mapping() {
  local payload path

  if mapping_exists; then
    log "property mapping ${MAPPING_NAME} already exists"
    return 0
  fi

  payload="$(merchant_mapping_payload)"
  log "creating property mapping ${MAPPING_NAME} (claim merchant_id)"
  for path in "/api/v3/propertymappings/provider/scope/" \
              "/api/v3/propertymappings/oauth2/"; do
    if api POST "${path}" "${payload}"; then
      return 0
    fi
  done

  if mapping_exists; then
    log "property mapping ${MAPPING_NAME} present after create conflict (idempotent)"
    return 0
  fi
  return 1
}

resolve_merchant_mapping_pk() {
  local body
  body="$(api_body "/api/v3/propertymappings/all/?search=${MAPPING_NAME}")"
  mapping_pk=""
  if [ -n "${body}" ]; then
    mapping_pk="$(printf '%s' "${body}" | json_pk)"
  fi
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
  "grant_types": ["authorization_code", "refresh_token", "client_credentials"],
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
  local body provider_pk provider_body

  body="$(oauth2_provider_payload "${name}" "${client_id}" "${property_mappings}" \
    "${auth_flow}" "${invalid_flow}" "${signing_key}")"

  if provider_client_exists "${client_id}"; then
    provider_body="$(api_body "/api/v3/providers/oauth2/?client_id=${client_id}")"
    provider_pk="$(printf '%s' "${provider_body}" | json_pk)"
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
    provider_body="$(api_body "/api/v3/providers/oauth2/?client_id=${client_id}")"
    provider_pk="$(printf '%s' "${provider_body}" | json_pk)"
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
  local missing=""

  [ -z "${auth_flow}" ] && missing="${missing} auth_flow"
  [ -z "${invalid_flow}" ] && missing="${missing} invalidation_flow"
  [ -z "${signing_key}" ] && missing="${missing} signing_key"
  [ -z "${openid_pk}" ] && missing="${missing} openid_scope"
  [ -z "${email_pk}" ] && missing="${missing} email_scope"
  [ -z "${profile_pk}" ] && missing="${missing} profile_scope"

  if [ -n "${missing}" ]; then
    log "missing Authentik defaults:${missing}"
    return 1
  fi
  return 0
}

ensure_application_linked() {
  local provider_pk="$1"
  local app_pk app_body

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

  app_body="$(api_body "/api/v3/core/applications/?slug=${APP_SLUG}")"
  app_pk="$(printf '%s' "${app_body}" | json_pk)"
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
  if [ "${AUTHENTIK_SKIP_JWKS_WAIT:-0}" = "1" ]; then
    log "skipping JWKS wait (deploy-platform validates OIDC discovery)"
  else
    wait_for_jwks
  fi
}

ensure_service_clients() {
  local client_id
  local property_mappings

  if [ -z "${mapping_pk}" ]; then
    wait_for_merchant_mapping_pk || return 1
  fi
  if ! oauth2_defaults_ready; then
    wait_for_oauth2_defaults || return 1
  fi
  property_mappings="[${openid_pk},${email_pk},${profile_pk},${mapping_pk}]"

  IFS=','
  for client_id in ${REQUIRED_CLIENTS}; do
    upsert_oauth2_provider "${client_id}" "${client_id}" "${property_mappings}" \
      "${auth_flow}" "${invalid_flow}" "${signing_key}" >/dev/null
  done
}

main() {
  preflight_commands
  wait_for_authentik
  ensure_application_provider
  ensure_service_clients
  log "bootstrap complete — issuer ${AUTHENTIK_URL}/application/o/${APP_SLUG}/"
}

main "$@"
