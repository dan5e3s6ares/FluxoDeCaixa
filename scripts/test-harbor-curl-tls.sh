#!/usr/bin/env bash
# Validate Harbor API curl calls pass --cacert when HARBOR_API_BASE is HTTPS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

failures=0
MOCK_HARBOR_CERTS_DIR="/tmp/harbor-curl-tls-certs-$$"
MOCK_CA="${MOCK_HARBOR_CERTS_DIR}/ca.crt"

cleanup() {
  rm -rf "${MOCK_HARBOR_CERTS_DIR}"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    log_info "OK ${label}"
    return 0
  fi
  log_error "${label}: expected to contain '${needle}', got '${haystack}'"
  failures=$((failures + 1))
  return 1
}

setup_https_mocks() {
  mkdir -p "${MOCK_HARBOR_CERTS_DIR}"
  cp /dev/null "${MOCK_CA}"
  export HARBOR_CERTS_DIR="${MOCK_HARBOR_CERTS_DIR}"
  export HARBOR_ALIAS="harbor.local"
  export HARBOR_PROJECT="fluxo-caixa"
  export HARBOR_ADMIN_USER="admin"
  export HARBOR_ADMIN_PASSWORD="Harbor12345"
  export HARBOR_API_BASE="https://harbor.local:443"
}

test_curl_ca_opt_for_https() {
  setup_https_mocks
  local tls_opt=()
  harbor_curl_ca_opt tls_opt
  if [[ "${#tls_opt[@]}" -eq 2 && "${tls_opt[0]}" == "--cacert" && "${tls_opt[1]}" == "${MOCK_CA}" ]]; then
    log_info "OK harbor_curl_ca_opt sets --cacert for HTTPS base"
  else
    log_error "harbor_curl_ca_opt: expected (--cacert ${MOCK_CA}), got (${tls_opt[*]:-empty})"
    failures=$((failures + 1))
  fi
}

test_curl_ca_opt_skips_http() {
  setup_https_mocks
  export HARBOR_API_BASE="http://harbor.local:8080"
  local tls_opt=()
  harbor_curl_ca_opt tls_opt
  if [[ "${#tls_opt[@]}" -eq 0 ]]; then
    log_info "OK harbor_curl_ca_opt empty for HTTP base"
  else
    log_error "harbor_curl_ca_opt: expected empty opts for HTTP, got (${tls_opt[*]})"
    failures=$((failures + 1))
  fi
}

test_ensure_harbor_project_uses_cacert() {
  setup_https_mocks
  local tls_seen=0
  curl() {
    if [[ "$*" == *"--cacert ${MOCK_CA}"* ]]; then
      tls_seen=1
    fi
    if [[ "$*" == *"/api/v2.0/projects?project_name=fluxo-caixa"* ]]; then
      printf '[]'
      return 0
    fi
    if [[ "$*" == *"-X POST"* && "$*" == *"/api/v2.0/projects"* ]]; then
      return 0
    fi
    command curl "$@"
  }
  ensure_harbor_project
  if (( tls_seen )); then
    log_info "OK ensure_harbor_project passes --cacert on HTTPS API calls"
  else
    log_error "ensure_harbor_project did not pass --cacert on HTTPS API calls"
    failures=$((failures + 1))
  fi
  unset -f curl
}

main() {
  log_info "test-harbor-curl-tls.sh — Harbor HTTPS curl TLS options"
  test_curl_ca_opt_for_https
  test_curl_ca_opt_skips_http
  test_ensure_harbor_project_uses_cacert
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-curl-tls.sh — all checks passed"
}

main "$@"
