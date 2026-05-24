#!/usr/bin/env bash
# Validate registry resolution for self-contained vs legacy external modes (no root required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Stubs — apply_registry_runtime_config is not invoked in tests
write_if_changed() { return 1; }
run_as_root() { "$@"; }

failures=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    log_error "${name}: expected '${expected}', got '${actual}'"
    failures=$((failures + 1))
  else
    log_info "OK ${name}=${actual}"
  fi
}

test_self_contained_defaults() {
  unset HARBOR_EXTERNAL HARBOR_HOST HARBOR_PORT SELF_CONTAINED
  export SELF_CONTAINED=1
  resolve_harbor_config
  assert_eq "mode" "in-vm" "${HARBOR_MODE}"
  assert_eq "alias-port" "${HARBOR_ALIAS}:8080" "${HARBOR_IMAGE_REGISTRY}"
  [[ "${HARBOR_REGISTRY}" == *:* ]] || { log_error "HARBOR_REGISTRY missing port"; failures=$((failures + 1)); }
}

test_external_harbor_external_var() {
  unset HARBOR_HOST HARBOR_PORT SELF_CONTAINED
  export HARBOR_EXTERNAL="192.168.68.100:8080"
  resolve_harbor_config
  assert_eq "mode" "external" "${HARBOR_MODE}"
  assert_eq "registry" "192.168.68.100:8080" "${HARBOR_REGISTRY}"
  assert_eq "image_registry" "harbor.local:8080" "${HARBOR_IMAGE_REGISTRY}"
}

test_self_contained_zero_requires_external() {
  unset HARBOR_EXTERNAL HARBOR_HOST HARBOR_PORT
  export SELF_CONTAINED=0
  if resolve_harbor_config 2>/dev/null; then
    log_error "SELF_CONTAINED=0 without HARBOR_EXTERNAL should fail"
    failures=$((failures + 1))
  else
    log_info "OK SELF_CONTAINED=0 without HARBOR_EXTERNAL rejected"
  fi
}

test_self_contained_zero_with_external() {
  unset HARBOR_HOST HARBOR_PORT SELF_CONTAINED
  export SELF_CONTAINED=0 HARBOR_EXTERNAL="192.168.68.100:8080"
  resolve_harbor_config
  assert_eq "mode" "external" "${HARBOR_MODE}"
  assert_eq "registry" "192.168.68.100:8080" "${HARBOR_REGISTRY}"
}

test_render_registries_template() {
  export HARBOR_HOST="10.0.0.5" HARBOR_PORT="8080" HARBOR_REGISTRY="10.0.0.5:8080" HARBOR_ALIAS="harbor.local"
  local out
  out="$(render_template "${REGISTRIES_TEMPLATE}" "      insecure_skip_verify: true" "insecure")"
  echo "${out}" | grep -q '10.0.0.5:8080' || { log_error "template missing registry endpoint"; failures=$((failures + 1)); }
  echo "${out}" | grep -q 'harbor.local' || { log_error "template missing harbor.local mirror"; failures=$((failures + 1)); }
  log_info "OK registries.yaml.in renders mirrors"
}

test_render_podman_registries_template() {
  export HARBOR_HOST="10.0.0.5" HARBOR_PORT="8080" HARBOR_REGISTRY="10.0.0.5:8080" HARBOR_ALIAS="harbor.local"
  local out
  out="$(render_template "${PODMAN_REGISTRIES_TEMPLATE}" "" "")"
  echo "${out}" | grep -q 'unqualified-search-registries' \
    || { log_error "podman template missing unqualified-search-registries"; failures=$((failures + 1)); }
  echo "${out}" | grep -q 'docker.io' \
    || { log_error "podman template missing docker.io"; failures=$((failures + 1)); }
  echo "${out}" | grep -q '10.0.0.5:8080' \
    || { log_error "podman template missing registry endpoint"; failures=$((failures + 1)); }
  log_info "OK podman-registries.conf.in renders docker.io + Harbor mirrors"
}

main() {
  # shellcheck source=lib/registry.sh
  source "${SCRIPT_DIR}/lib/registry.sh"
  log_info "test-registry-config.sh — registry mode resolution"
  test_self_contained_defaults
  test_external_harbor_external_var
  test_self_contained_zero_requires_external
  test_self_contained_zero_with_external
  test_render_registries_template
  test_render_podman_registries_template
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-registry-config.sh — all checks passed"
}

main "$@"
