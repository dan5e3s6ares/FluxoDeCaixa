#!/usr/bin/env bash
# Validate Harbor podman-docker version shim detection (no root / Harbor required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

harbor_needs_docker_version_shim() {
  command -v podman >/dev/null 2>&1 || return 1
  command -v docker >/dev/null 2>&1 || return 1
  local version_line major
  version_line="$(docker --version 2>/dev/null || true)"
  if [[ "${version_line}" =~ ([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    if [[ "${major}" -lt 17 ]]; then
      return 0
    fi
  fi
  return 1
}

assert_shim_needed() {
  local name="$1" expected="$2"
  local tmp_bin
  tmp_bin="$(mktemp -d)"

  cat >"${tmp_bin}/podman" <<'EOF'
#!/bin/bash
echo "podman version 5.7.0"
EOF
  cat >"${tmp_bin}/docker" <<'EOF'
#!/bin/bash
echo "podman version 5.7.0"
EOF
  chmod +x "${tmp_bin}/podman" "${tmp_bin}/docker"

  if [[ "${expected}" == "yes" ]]; then
    if PATH="${tmp_bin}" harbor_needs_docker_version_shim; then
      log_info "OK ${name}: shim needed"
    else
      log_error "${name}: expected shim needed"
      failures=$((failures + 1))
    fi
  else
    if PATH="${tmp_bin}" harbor_needs_docker_version_shim; then
      log_error "${name}: shim not needed"
      failures=$((failures + 1))
    else
      log_info "OK ${name}: shim not needed"
    fi
  fi
  rm -rf "${tmp_bin}"
}

test_podman_docker_needs_shim() {
  assert_shim_needed "podman-docker 5.7.0" "yes"
}

test_real_docker_skips_shim() {
  local tmp_bin
  tmp_bin="$(mktemp -d)"

  cat >"${tmp_bin}/podman" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat >"${tmp_bin}/docker" <<'EOF'
#!/bin/bash
echo "Docker version 24.0.7, build abc123"
EOF
  chmod +x "${tmp_bin}/podman" "${tmp_bin}/docker"

  if PATH="${tmp_bin}" harbor_needs_docker_version_shim; then
    log_error "real docker 24.x should skip shim"
    failures=$((failures + 1))
  else
    log_info "OK real docker 24.x skips shim"
  fi
  rm -rf "${tmp_bin}"
}

main() {
  log_info "test-harbor-podman-shim.sh — Harbor docker version shim detection"
  test_podman_docker_needs_shim
  test_real_docker_skips_shim
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-podman-shim.sh — all checks passed"
}

main "$@"
