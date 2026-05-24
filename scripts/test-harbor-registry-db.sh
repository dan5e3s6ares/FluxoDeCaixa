#!/usr/bin/env bash
# Validate Harbor registry DB readiness checks (mocked docker; no Harbor required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

failures=0
MOCK_DB_STATE="missing"

run_as_root() {
  "$@"
}

docker() {
  if [[ "${1:-}" == "ps" ]]; then
    echo "harbor-db"
    return 0
  fi
  if [[ "${1:-}" == "exec" && "${3:-}" == "psql" ]]; then
    case "${MOCK_DB_STATE}" in
      missing)
        if [[ "$*" == *"pg_database"* ]]; then
          return 0
        fi
        echo "psql: FATAL:  database \"registry\" does not exist" >&2
        return 2
        ;;
      db_only)
        if [[ "$*" == *"pg_database"* ]]; then
          echo "1"
          return 0
        fi
        echo "0"
        return 0
        ;;
      ready)
        if [[ "$*" == *"pg_database"* ]]; then
          echo "1"
          return 0
        fi
        echo "1"
        return 0
        ;;
    esac
  fi
  return 1
}

export -f run_as_root docker

assert_not_ready() {
  local label="$1"
  if harbor_registry_db_ready; then
    log_error "${label}: expected not ready"
    failures=$((failures + 1))
    return 1
  fi
  log_info "OK ${label}"
}

assert_ready() {
  local label="$1"
  if harbor_registry_db_ready; then
    log_info "OK ${label}"
    return 0
  fi
  log_error "${label}: expected ready"
  failures=$((failures + 1))
  return 1
}

test_registry_db_states() {
  MOCK_DB_STATE="missing"
  assert_not_ready "missing registry database"

  MOCK_DB_STATE="db_only"
  assert_not_ready "registry DB without harbor_user table"

  MOCK_DB_STATE="ready"
  assert_ready "registry DB with harbor_user table"
}

main() {
  log_info "test-harbor-registry-db.sh — Harbor registry DB readiness"
  test_registry_db_states
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-registry-db.sh — all checks passed"
}

main "$@"
