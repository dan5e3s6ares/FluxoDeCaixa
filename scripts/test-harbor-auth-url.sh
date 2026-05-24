#!/usr/bin/env bash
# Validate Harbor HTTPS API base selection when HTTP auth redirects (308).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

failures=0

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

test_https_api_bases() {
  export HARBOR_ALIAS="harbor.local"
  local first
  first="$(harbor_https_api_bases | head -1)"
  assert_eq "https api base" "https://harbor.local:443" "${first}"
}

test_auth_redirect_detection() {
  HARBOR_API_BASE="http://harbor.local:8080"
  curl() {
    if [[ "$*" == *"/api/v2.0/users/current"* ]]; then
      echo "308"
      return 0
    fi
    command curl "$@"
  }
  export -f curl
  if harbor_api_auth_redirects_to_https; then
    log_info "OK detects HTTP auth redirect to HTTPS"
  else
    log_error "expected redirect detection for HTTP auth endpoint"
    failures=$((failures + 1))
  fi
  unset -f curl
}

test_no_redirect_on_https_base() {
  HARBOR_API_BASE="https://harbor.local:443"
  curl() {
    echo "401"
    return 0
  }
  export -f curl
  if harbor_api_auth_redirects_to_https; then
    log_error "HTTPS base should not be treated as redirecting"
    failures=$((failures + 1))
  else
    log_info "OK HTTPS base is not a redirect candidate"
  fi
  unset -f curl
}

main() {
  log_info "test-harbor-auth-url.sh — Harbor HTTPS API base selection"
  test_https_api_bases
  test_auth_redirect_detection
  test_no_redirect_on_https_base
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-auth-url.sh — all checks passed"
}

main "$@"
