#!/usr/bin/env bash
# Validate seed-images tag detection (no Harbor/podman required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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

detect_seed_tag_from_manifests() {
  local tag
  tag="$(
    grep -rhoE 'harbor\.local:[0-9]+/fluxo-caixa/[^:]+:main-[a-f0-9]+' \
      "${REPO_ROOT}/deploy/k8s/base" 2>/dev/null \
      | sed -E 's/.*:(main-[a-f0-9]+)$/\1/' \
      | sort -u
  )"
  if [[ -z "${tag}" ]]; then
    echo ""
    return 1
  fi
  if [[ "$(printf '%s\n' "${tag}" | wc -l)" -gt 1 ]]; then
    echo "multiple"
    return 1
  fi
  echo "${tag}"
}

main() {
  log_info "test-seed-images-config.sh — tag detection"
  local tag
  tag="$(detect_seed_tag_from_manifests)"
  assert_eq "seed_tag" "main-0000000" "${tag}"

  local count
  count="$(grep -rhoE 'harbor\.local:[0-9]+/fluxo-caixa/[^:]+:main-[a-f0-9]+' \
    "${REPO_ROOT}/deploy/k8s/base" | wc -l | tr -d ' ')"
  if (( count < 6 )); then
    log_error "expected at least 6 harbor image refs in manifests, found ${count}"
    failures=$((failures + 1))
  else
    log_info "OK manifest_refs=${count}"
  fi

  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-seed-images-config.sh — all checks passed"
}

main "$@"
