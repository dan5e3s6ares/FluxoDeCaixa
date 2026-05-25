#!/usr/bin/env bash
# Unit tests for Ory postgres DSN URL-encoding (no cluster required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FLUXO_PG_APP_USER='app@user'
FLUXO_PG_APP_PASSWORD='p@ss/w+rd?'
ORY_PG_HOST='fluxo-pg-rw.database.svc.cluster.local'
ORY_PG_PORT='5432'

ory_postgres_dsn() {
  local db_name="$1"
  local encoded_user encoded_password
  encoded_user="$(urlencode_component "${FLUXO_PG_APP_USER}")"
  encoded_password="$(urlencode_component "${FLUXO_PG_APP_PASSWORD}")"
  printf 'postgres://%s:%s@%s:%s/%s?sslmode=disable' \
    "${encoded_user}" "${encoded_password}" "${ORY_PG_HOST}" "${ORY_PG_PORT}" "${db_name}"
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "FAIL ${name}: expected '${needle}' in '${haystack}'" >&2
    exit 1
  fi
  echo "ok ${name}"
}

assert_not_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "FAIL ${name}: did not expect '${needle}' in '${haystack}'" >&2
    exit 1
  fi
  echo "ok ${name}"
}

dsn="$(ory_postgres_dsn kratos)"
assert_contains "dsn encodes user @" "${dsn}" 'app%40user'
assert_contains "dsn encodes password special chars" "${dsn}" 'p%40ss%2Fw%2Brd%3F'
assert_not_contains "dsn raw password not present" "${dsn}" 'p@ss/w+rd?'
assert_contains "dsn host preserved" "${dsn}" '@fluxo-pg-rw.database.svc.cluster.local:5432/kratos'

echo "scripts/test-ory-dsn.sh — all tests passed"
