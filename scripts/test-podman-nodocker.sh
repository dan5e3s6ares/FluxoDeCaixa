#!/usr/bin/env bash
# Validate podman-docker nodocker marker wiring (no root / podman required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

test_nodocker_wired_in_scripts() {
  local script
  for script in bootstrap-vm.sh; do
    if grep -q 'ensure_podman_nodocker' "${SCRIPT_DIR}/${script}"; then
      log_info "OK ${script} calls ensure_podman_nodocker"
    else
      log_error "${script} missing ensure_podman_nodocker"
      failures=$((failures + 1))
    fi
  done
}

test_common_defines_nodocker_helper() {
  if grep -q 'ensure_podman_nodocker()' "${SCRIPT_DIR}/lib/common.sh"; then
    log_info "OK common.sh defines ensure_podman_nodocker"
  else
    log_error "common.sh missing ensure_podman_nodocker"
    failures=$((failures + 1))
  fi
}

main() {
  log_info "test-podman-nodocker.sh — podman-docker nodocker wiring"
  test_common_defines_nodocker_helper
  test_nodocker_wired_in_scripts
  if (( failures > 0 )); then
    log_error "test-podman-nodocker.sh — ${failures} failure(s)"
    exit 1
  fi
  log_info "test-podman-nodocker.sh — all checks passed"
}

main "$@"
