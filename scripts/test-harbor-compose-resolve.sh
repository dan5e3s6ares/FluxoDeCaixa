#!/usr/bin/env bash
# Validate resolve_harbor_compose finds compose via PATH, plugin path, or docker compose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

resolve_harbor_compose() {
  local candidate
  if candidate="$(command -v docker-compose 2>/dev/null)"; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  for candidate in \
    /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/bin/docker-compose \
    /usr/local/bin/docker-compose; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s\n' "docker compose"
    return 0
  fi
  return 1
}

test_finds_path_binary() {
  local tmp_bin resolved
  tmp_bin="$(mktemp -d)"
  cat >"${tmp_bin}/docker-compose" <<'EOF'
#!/bin/bash
echo "compose $*"
EOF
  chmod +x "${tmp_bin}/docker-compose"

  resolved="$(PATH="${tmp_bin}" resolve_harbor_compose)"
  if [[ "${resolved}" == "${tmp_bin}/docker-compose" ]]; then
    log_info "OK resolve_harbor_compose prefers PATH binary"
  else
    log_error "expected PATH docker-compose, got: ${resolved}"
    failures=$((failures + 1))
  fi
  rm -rf "${tmp_bin}"
}

test_finds_plugin_path() {
  local tmp resolved
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/usr/libexec/docker/cli-plugins"
  cat >"${tmp}/usr/libexec/docker/cli-plugins/docker-compose" <<'EOF'
#!/bin/bash
echo "plugin compose $*"
EOF
  chmod +x "${tmp}/usr/libexec/docker/cli-plugins/docker-compose"

  resolve_harbor_compose() {
    local candidate
    if candidate="$(command -v docker-compose 2>/dev/null)"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    for candidate in \
      "${tmp}/usr/libexec/docker/cli-plugins/docker-compose" \
      /usr/bin/docker-compose \
      /usr/local/bin/docker-compose; do
      if [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done
    return 1
  }

  resolved="$(resolve_harbor_compose)"
  if [[ "${resolved}" == "${tmp}/usr/libexec/docker/cli-plugins/docker-compose" ]]; then
    log_info "OK resolve_harbor_compose finds docker compose plugin path"
  else
    log_error "expected plugin path, got: ${resolved}"
    failures=$((failures + 1))
  fi
  rm -rf "${tmp}"
}

test_falls_back_to_docker_compose_subcommand() {
  local tmp_bin resolved
  tmp_bin="$(mktemp -d)"
  cat >"${tmp_bin}/docker" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "compose" ]] && [[ "${2:-}" == "version" ]]; then
  exit 0
fi
echo "docker $*"
EOF
  chmod +x "${tmp_bin}/docker"

  resolve_harbor_compose_no_system_paths() {
    local candidate
    if candidate="$(PATH="${tmp_bin}" command -v docker-compose 2>/dev/null)"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    if PATH="${tmp_bin}" command -v docker >/dev/null 2>&1 \
      && PATH="${tmp_bin}" docker compose version >/dev/null 2>&1; then
      printf '%s\n' "docker compose"
      return 0
    fi
    return 1
  }

  resolved="$(resolve_harbor_compose_no_system_paths)"
  if [[ "${resolved}" == "docker compose" ]]; then
    log_info "OK resolve_harbor_compose falls back to docker compose subcommand"
  else
    log_error "expected 'docker compose', got: ${resolved}"
    failures=$((failures + 1))
  fi
  rm -rf "${tmp_bin}"
}

main() {
  log_info "test-harbor-compose-resolve.sh — resolve_harbor_compose"
  test_finds_path_binary
  test_finds_plugin_path
  test_falls_back_to_docker_compose_subcommand
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-compose-resolve.sh — all checks passed"
}

main "$@"
