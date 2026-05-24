#!/usr/bin/env bash
# Validate podman-docker nodocker marker and Gitea admin exec (no root / podman required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

test_gitea_admin_uses_git_user() {
  if grep -q 'docker exec -u git gitea gitea -c /data/gitea/conf/app.ini' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh runs admin CLI as git user with data config path"
  else
    log_error "deploy-gitea.sh missing git user docker exec for Gitea admin CLI"
    failures=$((failures + 1))
  fi
  if grep -q '\-w /etc/gitea' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must not use /etc/gitea work path (config is under /data/gitea/conf)"
    failures=$((failures + 1))
  fi
  if grep -q 'GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must not default GITEA_ADMIN_USER to reserved name admin"
    failures=$((failures + 1))
  elif grep -q 'gitea_admin_username_reserved' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh rejects Gitea-reserved admin usernames"
  else
    log_error "deploy-gitea.sh missing gitea_admin_username_reserved guard"
    failures=$((failures + 1))
  fi
  if grep -q 'https://oauth2:' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must use HTTP (not HTTPS) for in-VM Gitea git remotes"
    failures=$((failures + 1))
  elif grep -q 'gitea_auth_git_remote' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh builds git remotes from GITEA_BASE_URL scheme"
  else
    log_error "deploy-gitea.sh missing gitea_auth_git_remote helper"
    failures=$((failures + 1))
  fi
  if grep -q 'gitea_git()' "${SCRIPT_DIR}/deploy-gitea.sh" \
    && grep -q 'GIT_CONFIG_GLOBAL=/dev/null' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh ignores global http->https git URL rewrite for Gitea"
  else
    log_error "deploy-gitea.sh missing gitea_git helper (GIT_CONFIG_GLOBAL=/dev/null)"
    failures=$((failures + 1))
  fi
  if grep -q 'ensure_repo_secret "GITEA_TOKEN"' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must not set GITEA_TOKEN repo secret (Gitea forbids GITEA_/GITHUB_ prefix)"
    failures=$((failures + 1))
  elif grep -q 'skipping GITEA_TOKEN repo secret' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh skips forbidden GITEA_TOKEN repo secret"
  else
    log_error "deploy-gitea.sh missing GITEA_TOKEN repo secret skip guard"
    failures=$((failures + 1))
  fi
  if grep -qE 'act_runner-.*\.tar\.gz' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must download act_runner .xz archives (tar.gz URLs return 404)"
    failures=$((failures + 1))
  elif grep -q 'act_runner-.*\.xz' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh downloads act_runner .xz release archive"
  else
    log_error "deploy-gitea.sh missing act_runner .xz download URL"
    failures=$((failures + 1))
  fi
  if grep -q "trap 'rm -rf \"\${tmp" "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must not use EXIT traps that reference local tmp (set -u unbound variable on failure)"
    failures=$((failures + 1))
  elif grep -q 'trap "rm -rf '"'"'${tmp}' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh embeds tmp paths in EXIT traps"
  else
    log_error "deploy-gitea.sh missing embedded-path EXIT trap for act_runner download"
    failures=$((failures + 1))
  fi
  if grep -q 'fetch_runner_registration_token' "${SCRIPT_DIR}/deploy-gitea.sh" \
    && grep -q 'generate-runner-token' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh falls back to gitea actions generate-runner-token for runner registration"
  else
    log_error "deploy-gitea.sh missing act_runner registration-token API/CLI fallback"
    failures=$((failures + 1))
  fi
  if grep -q 'GITEA_VERSION="${GITEA_VERSION:-1.22' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_error "deploy-gitea.sh must not default to Gitea 1.22 (admin registration-token API requires 1.24+)"
    failures=$((failures + 1))
  elif grep -q 'GITEA_VERSION="${GITEA_VERSION:-1.24' "${SCRIPT_DIR}/deploy-gitea.sh"; then
    log_info "OK deploy-gitea.sh defaults to Gitea 1.24+ with registration-token API"
  else
    log_error "deploy-gitea.sh missing Gitea 1.24+ default version"
    failures=$((failures + 1))
  fi
}

test_nodocker_wired_in_scripts() {
  local script
  for script in bootstrap-vm.sh deploy-gitea.sh deploy-registry.sh; do
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
  log_info "test-podman-nodocker.sh — podman-docker nodocker + Gitea admin exec"
  test_common_defines_nodocker_helper
  test_nodocker_wired_in_scripts
  test_gitea_admin_uses_git_user
  if (( failures > 0 )); then
    log_error "test-podman-nodocker.sh — ${failures} failure(s)"
    exit 1
  fi
  log_info "test-podman-nodocker.sh — all checks passed"
}

main "$@"
