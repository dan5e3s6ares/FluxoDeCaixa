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

scope_mapping_pk_from_body() {
  local scope="$1"
  local body pk

  body="$(cat)"
  if ! printf '%s' "${body}" | json_field_present scope_name "${scope}"; then
    return 1
  fi
  pk="$(printf '%s' "${body}" | json_pk)"
  [ -n "${pk}" ] || return 1
  printf '%s' "${pk}"
}

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

assert_eq "scope_name filter body" "3" \
  "$(printf '{"results":[{"scope_name": "openid","pk":3}]}' | scope_mapping_pk_from_body openid)"
assert_eq "search fallback body" "7" \
  "$(printf '{"results":[{"scope_name": "profile","pk":7,"name":"x"}]}' | scope_mapping_pk_from_body profile)"

managed_body='{"results":[{"scope_name": "openid","pk":1,"managed":"goauthentik.io/providers/oauth2/scope-openid"}]}'
assert_match "managed scope body" "${managed_body}" scope_name openid
assert_eq "managed scope pk" "1" "$(printf '%s' "${managed_body}" | json_pk)"

echo "platform/authentik/test-bootstrap-helpers.sh — all tests passed"
