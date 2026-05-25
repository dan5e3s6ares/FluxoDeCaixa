#!/usr/bin/env sh
# Unit tests for bootstrap.sh JSON helpers (no cluster required).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Load only helper functions — do not source full bootstrap.sh (would run main).
eval "$(
  sed -n \
    -e '/^json_pk()/,/^}/p' \
    -e '/^json_field_present()/,/^}/p' \
    "${SCRIPT_DIR}/bootstrap.sh"
)"

assert_eq() {
  local name="$1"
  local want="$2"
  local got="$3"
  if [ "${want}" != "${got}" ]; then
    echo "FAIL ${name}: want '${want}' got '${got}'" >&2
    exit 1
  fi
  echo "ok ${name}"
}

assert_match() {
  local name="$1"
  if printf '%s' "$2" | json_field_present "$3" "$4"; then
    echo "ok ${name}"
    return 0
  fi
  echo "FAIL ${name}: field ${3}=${4} not found in ${2}" >&2
  exit 1
}

assert_eq "json_pk paginated" "8" \
  "$(printf '{"results":[{"pk":8,"slug":"flow"}]}' | json_pk)"
assert_eq "json_pk drf spacing" "42" \
  "$(printf '{"results":[{"pk": 42}]}' | json_pk)"
assert_eq "json_pk single" "15" \
  "$(printf '{"pk": 15}' | json_pk)"

assert_match "json_field_present slug" '{"results":[{"slug": "fluxo-caixa"}]}' slug fluxo-caixa
assert_match "json_field_present scope" \
  '{"results":[{"scope_name": "openid","pk":3}]}' scope_name openid

body='{"results":[{"scope_name": "email","pk":9}]}'
if printf '%s' "${body}" | json_field_present scope_name email; then
  assert_eq "scope body pk when scope present" "9" "$(printf '%s' "${body}" | json_pk)"
else
  echo "FAIL scope body pk when scope present" >&2
  exit 1
fi

echo "platform/authentik/test-bootstrap-helpers.sh — all tests passed"
