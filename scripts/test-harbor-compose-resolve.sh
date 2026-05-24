#!/usr/bin/env bash
# Validate resolve_harbor_compose and compose wrapper exec targets (no PATH recursion).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HARBOR_INSTALL_DIR="${HARBOR_INSTALL_DIR:-/opt/harbor}"

failures=0

harbor_compose_search_path() {
  local shim_dir="${HARBOR_INSTALL_DIR}/.bin"
  if [[ "${PATH}" == "${shim_dir}:"* ]]; then
    printf '%s\n' "${PATH#${shim_dir}:}"
    return 0
  fi
  printf '%s\n' "${PATH}"
}

resolve_harbor_compose() {
  local candidate search_path
  search_path="$(harbor_compose_search_path)"
  if candidate="$(PATH="${search_path}" command -v docker-compose 2>/dev/null)"; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  for candidate in \
    /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/bin/docker-compose \
    /usr/local/bin/docker-compose; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if PATH="${search_path}" docker-compose version >/dev/null 2>&1; then
    if candidate="$(PATH="${search_path}" command -v docker-compose 2>/dev/null)"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    printf '%s\n' "docker-compose"
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s\n' "docker compose"
    return 0
  fi
  return 1
}

resolve_harbor_compose_absolute() {
  local raw="$1"
  local candidate search_path
  search_path="$(harbor_compose_search_path)"
  case "${raw}" in
    "docker compose")
      printf '%s\n' "${raw}"
      return 0
      ;;
    /*)
      printf '%s\n' "${raw}"
      return 0
      ;;
    "docker-compose")
      if candidate="$(PATH="${search_path}" command -v docker-compose 2>/dev/null)"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
      for candidate in \
        /usr/libexec/docker/cli-plugins/docker-compose \
        /usr/bin/docker-compose \
        /usr/local/bin/docker-compose; do
        if [[ -f "${candidate}" ]]; then
          printf '%s\n' "${candidate}"
          return 0
        fi
      done
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

compose_wrapper_exec_line() {
  local real_compose="$1"
  local compose_backend=path
  if [[ "${real_compose}" == "docker compose" ]]; then
    compose_backend=plugin
  else
    real_compose="$(resolve_harbor_compose_absolute "${real_compose}")"
  fi
  if [[ "${compose_backend}" == "plugin" ]]; then
    printf '%s\n' 'exec docker compose "$@"'
  else
    printf 'exec "${REAL_COMPOSE}" "$@"\nREAL_COMPOSE=%s\n' "${real_compose}"
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    log_error "${name}: expected '${expected}', got '${actual}'"
    failures=$((failures + 1))
  else
    log_info "OK ${name}=${actual}"
  fi
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

test_absolute_from_path_binary() {
  local tmp_bin resolved
  tmp_bin="$(mktemp -d)"
  cat >"${tmp_bin}/docker-compose" <<'EOF'
#!/bin/bash
echo "compose $*"
EOF
  chmod +x "${tmp_bin}/docker-compose"

  resolved="$(PATH="${tmp_bin}" resolve_harbor_compose_absolute "docker-compose")"
  assert_eq "absolute-from-path" "${tmp_bin}/docker-compose" "${resolved}"
  rm -rf "${tmp_bin}"
}

test_wrapper_uses_absolute_path_not_path_lookup() {
  local tmp_bin shim_dir resolved output
  tmp_bin="$(mktemp -d)"
  shim_dir="${tmp_bin}/harbor/.bin"
  mkdir -p "${shim_dir}"
  cat >"${tmp_bin}/docker-compose" <<'EOF'
#!/bin/bash
echo "real-compose $*"
EOF
  chmod +x "${tmp_bin}/docker-compose"

  HARBOR_INSTALL_DIR="${tmp_bin}/harbor"
  PATH="${shim_dir}:${tmp_bin}:/usr/bin:/bin"
  resolved="$(resolve_harbor_compose)"
  assert_eq "wrapper-backend" "${tmp_bin}/docker-compose" "${resolved}"

  output="$(compose_wrapper_exec_line "${resolved}")"
  if grep -q 'exec docker-compose' <<<"${output}"; then
    log_error "wrapper must not exec bare docker-compose (PATH recursion risk)"
    failures=$((failures + 1))
  elif grep -q "REAL_COMPOSE=${tmp_bin}/docker-compose" <<<"${output}"; then
    log_info "OK compose wrapper exec uses absolute REAL_COMPOSE path"
  else
    log_error "unexpected wrapper output: ${output}"
    failures=$((failures + 1))
  fi
  rm -rf "${tmp_bin}"
}

test_wrapper_skips_shim_dir_on_path() {
  local tmp_bin shim_dir resolved
  tmp_bin="$(mktemp -d)"
  shim_dir="${tmp_bin}/harbor/.bin"
  mkdir -p "${shim_dir}" "${tmp_bin}/bin"
  cat >"${shim_dir}/docker-compose" <<'EOF'
#!/bin/bash
echo "shim $*"
EOF
  chmod +x "${shim_dir}/docker-compose"
  cat >"${tmp_bin}/bin/docker-compose" <<'EOF'
#!/bin/bash
echo "real $*"
EOF
  chmod +x "${tmp_bin}/bin/docker-compose"

  HARBOR_INSTALL_DIR="${tmp_bin}/harbor"
  PATH="${shim_dir}:${tmp_bin}/bin:/usr/bin:/bin"
  resolved="$(resolve_harbor_compose)"
  if [[ "${resolved}" == "${tmp_bin}/bin/docker-compose" ]]; then
    log_info "OK resolve_harbor_compose skips Harbor shim on PATH"
  else
    log_error "expected real backend ${tmp_bin}/bin/docker-compose, got: ${resolved}"
    failures=$((failures + 1))
  fi
  rm -rf "${tmp_bin}"
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
    local candidate search_path
    search_path="$(harbor_compose_search_path)"
    if candidate="$(PATH="${tmp_bin}:${search_path}" command -v docker-compose 2>/dev/null)"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    if PATH="${tmp_bin}:${search_path}" command -v docker >/dev/null 2>&1 \
      && PATH="${tmp_bin}:${search_path}" docker compose version >/dev/null 2>&1; then
      printf '%s\n' "docker compose"
      return 0
    fi
    return 1
  }

  resolved="$(PATH="${tmp_bin}" resolve_harbor_compose_no_system_paths)"
  assert_eq "docker-compose-subcommand" "docker compose" "${resolved}"
  rm -rf "${tmp_bin}"
}

main() {
  log_info "test-harbor-compose-resolve.sh — resolve_harbor_compose + wrapper exec"
  test_finds_path_binary
  test_absolute_from_path_binary
  test_wrapper_uses_absolute_path_not_path_lookup
  test_wrapper_skips_shim_dir_on_path
  test_falls_back_to_docker_compose_subcommand
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-compose-resolve.sh — all checks passed"
}

main "$@"
