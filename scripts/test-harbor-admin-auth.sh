#!/usr/bin/env bash
# Validate Harbor admin auth base ordering and HTTPS upgrade (mocked curl; no Harbor required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

failures=0
MOCK_CA="/tmp/harbor-test-ca-$$.crt"
MOCK_HARBOR_CERTS_DIR="/tmp/harbor-test-certs-$$"

cleanup() {
  rm -rf "${MOCK_HARBOR_CERTS_DIR}" "${MOCK_CA}"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    log_info "OK ${label}"
    return 0
  fi
  log_error "${label}: expected '${expected}', got '${actual}'"
  failures=$((failures + 1))
  return 1
}

setup_tls_mocks() {
  mkdir -p "${MOCK_HARBOR_CERTS_DIR}"
  cp /dev/null "${MOCK_HARBOR_CERTS_DIR}/ca.crt"
  export HARBOR_CERTS_DIR="${MOCK_HARBOR_CERTS_DIR}"
  export HARBOR_ALIAS="harbor.local"
  export HARBOR_MODE="in-vm"
  export HARBOR_REGISTRY="harbor.local:8080"
  export HARBOR_PORT="8080"
  export HARBOR_API_BASE="http://10.0.0.1:8080"
  export HARBOR_ADMIN_USER="admin"
  export HARBOR_ADMIN_PASSWORD="Harbor12345"
}

test_auth_bases_prefer_https() {
  setup_tls_mocks
  local first=""
  while IFS= read -r first || [[ -n "${first}" ]]; do
    break
  done < <(harbor_auth_api_bases)
  assert_eq "auth bases prefer HTTPS when CA exists" "https://harbor.local:443" "${first}"
}

test_resolve_upgrades_to_https_without_redirect() {
  setup_tls_mocks
  curl() {
    if [[ "$*" == *"/api/v2.0/systeminfo"* && "$*" == *"https://"* ]]; then
      return 0
    fi
    if [[ "$*" == *"/api/v2.0/systeminfo"* ]]; then
      return 0
    fi
    if [[ "$*" == *"/api/v2.0/users/current"* ]]; then
      echo "401"
      return 0
    fi
    command curl "$@"
  }
  export -f curl
  if resolve_harbor_api_base; then
    assert_eq "resolve upgrades to HTTPS without 308 redirect" "https://harbor.local:443" "${HARBOR_API_BASE}"
  else
    log_error "resolve_harbor_api_base failed"
    failures=$((failures + 1))
  fi
  unset -f curl
}

test_admin_auth_uses_https_first() {
  setup_tls_mocks
  curl() {
    if [[ "$*" == *"/api/v2.0/users/current"* && "$*" == *"https://harbor.local:443"* ]]; then
      echo "200"
      return 0
    fi
    if [[ "$*" == *"/api/v2.0/users/current"* ]]; then
      echo "401"
      return 0
    fi
    command curl "$@"
  }
  export -f curl
  if harbor_admin_auth_ok; then
    assert_eq "admin auth selects HTTPS base" "https://harbor.local:443" "${HARBOR_API_BASE}"
  else
    log_error "harbor_admin_auth_ok failed on mocked HTTPS success"
    failures=$((failures + 1))
  fi
  unset -f curl
}

main() {
  log_info "test-harbor-admin-auth.sh — Harbor admin auth base selection"
  test_auth_bases_prefer_https
  test_resolve_upgrades_to_https_without_redirect
  test_admin_auth_uses_https_first
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-admin-auth.sh — all checks passed"
}

main "$@"
