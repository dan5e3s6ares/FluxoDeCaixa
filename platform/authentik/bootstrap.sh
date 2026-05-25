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

  if [ -n "${body}" ]; then
    curl -sf -X "${method}" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      "${AUTHENTIK_URL}${path}" \
      --data "${body}"
  else
    curl -sf -X "${method}" \
      -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
      -H "Content-Type: application/json" \
      "${AUTHENTIK_URL}${path}"
  fi
}

json_pk() {
  sed -n 's/.*"pk":"\([^"]*\)".*/\1/p' | head -n 1
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

application_exists() {
  api GET "/api/v3/core/applications/?slug=${APP_SLUG}" | grep -q "\"slug\":\"${APP_SLUG}\""
}

mapping_exists() {
  api GET "/api/v3/propertymappings/all/?search=${MAPPING_NAME}" | grep -q "\"name\":\"${MAPPING_NAME}\""
}

provider_client_exists() {
  local client_id="$1"
  api GET "/api/v3/providers/oauth2/?client_id=${client_id}" | grep -q "\"client_id\":\"${client_id}\""
}

flow_pk() {
  local slug="$1"
  api GET "/api/v3/flows/instances/?slug=${slug}" | json_pk
}

signing_key_pk() {
  api GET "/api/v3/crypto/certificatekeypairs/?search=authentik%20Self-signed%20Certificate" | json_pk
}

ensure_merchant_id_mapping() {
  if mapping_exists; then
    log "property mapping ${MAPPING_NAME} already exists"
    return 0
  fi

  log "creating property mapping ${MAPPING_NAME} (claim merchant_id)"
  api POST "/api/v3/propertymappings/oauth2/" "$(cat <<EOF
{
  "name": "${MAPPING_NAME}",
  "scope_name": "merchant_id",
  "expression": "return user.attributes.get(\\\"merchant_id\\\", [None])[0]"
}
EOF
)"
}

ensure_application_provider() {
  local auth_flow invalid_flow signing_key mapping_pk openid_pk email_pk profile_pk
  local property_mappings provider_pk

  if application_exists && jwks_available && mapping_exists; then
    log "application ${APP_SLUG} already configured with JWKS and merchant_id mapping"
    return 0
  fi

  ensure_merchant_id_mapping
  mapping_pk="$(api GET "/api/v3/propertymappings/all/?search=${MAPPING_NAME}" | json_pk)"
  auth_flow="$(flow_pk default-provider-authorization-implicit-consent)"
  invalid_flow="$(flow_pk default-provider-invalidation-flow)"
  signing_key="$(signing_key_pk)"
  openid_pk="$(api GET "/api/v3/propertymappings/oauth2/?scope_name=openid" | json_pk)"
  email_pk="$(api GET "/api/v3/propertymappings/oauth2/?scope_name=email" | json_pk)"
  profile_pk="$(api GET "/api/v3/propertymappings/oauth2/?scope_name=profile" | json_pk)"

  if [ -z "${auth_flow}" ] || [ -z "${invalid_flow}" ] || [ -z "${signing_key}" ]; then
    log "missing default Authentik flows or signing key"
    return 1
  fi

  property_mappings="[${openid_pk},${email_pk},${profile_pk},${mapping_pk}]"

  if ! provider_client_exists "${APP_SLUG}"; then
    log "creating OAuth2 provider ${APP_SLUG}"
    provider_pk="$(api POST "/api/v3/providers/oauth2/" "$(cat <<EOF
{
  "name": "${APP_SLUG}",
  "client_id": "${APP_SLUG}",
  "client_type": "confidential",
  "authorization_flow": "${auth_flow}",
  "invalidation_flow": "${invalid_flow}",
  "redirect_uris": "",
  "property_mappings": ${property_mappings},
  "signing_key": "${signing_key}",
  "access_code_validity": "minutes=1",
  "access_token_validity": "minutes=15",
  "refresh_token_validity": "days=30"
}
EOF
)" | json_pk)"
  else
    provider_pk="$(api GET "/api/v3/providers/oauth2/?client_id=${APP_SLUG}" | json_pk)"
    log "OAuth2 provider ${APP_SLUG} already exists"
  fi

  if ! application_exists; then
    log "creating application ${APP_SLUG}"
    api POST "/api/v3/core/applications/" "$(cat <<EOF
{
  "name": "fluxo-caixa",
  "slug": "${APP_SLUG}",
  "provider": ${provider_pk}
}
EOF
)"
  fi

  if ! jwks_available; then
    log "JWKS not yet available at /application/o/${APP_SLUG}/jwks/"
    return 1
  fi

  log "JWKS available at /application/o/${APP_SLUG}/jwks/"
}

ensure_service_clients() {
  local client_id auth_flow invalid_flow signing_key openid_pk email_pk profile_pk mapping_pk
  local property_mappings

  auth_flow="$(flow_pk default-provider-authorization-implicit-consent)"
  invalid_flow="$(flow_pk default-provider-invalidation-flow)"
  signing_key="$(signing_key_pk)"
  openid_pk="$(api GET "/api/v3/propertymappings/oauth2/?scope_name=openid" | json_pk)"
  email_pk="$(api GET "/api/v3/propertymappings/oauth2/?scope_name=email" | json_pk)"
  profile_pk="$(api GET "/api/v3/propertymappings/oauth2/?scope_name=profile" | json_pk)"
  mapping_pk="$(api GET "/api/v3/propertymappings/all/?search=${MAPPING_NAME}" | json_pk)"
  property_mappings="[${openid_pk},${email_pk},${profile_pk},${mapping_pk}]"

  IFS=','
  for client_id in ${REQUIRED_CLIENTS}; do
    if provider_client_exists "${client_id}"; then
      log "OAuth2 client ${client_id} already exists"
      continue
    fi

    log "creating OAuth2 client ${client_id}"
    api POST "/api/v3/providers/oauth2/" "$(cat <<EOF
{
  "name": "${client_id}",
  "client_id": "${client_id}",
  "client_type": "confidential",
  "authorization_flow": "${auth_flow}",
  "invalid_flow": "${invalid_flow}",
  "redirect_uris": "",
  "property_mappings": ${property_mappings},
  "signing_key": "${signing_key}",
  "access_code_validity": "minutes=1",
  "access_token_validity": "minutes=15",
  "refresh_token_validity": "days=30"
}
EOF
)"
  done
}

main() {
  wait_for_authentik
  ensure_application_provider
  ensure_service_clients
  log "bootstrap complete — issuer ${AUTHENTIK_URL}/application/o/${APP_SLUG}/"
}

main "$@"
