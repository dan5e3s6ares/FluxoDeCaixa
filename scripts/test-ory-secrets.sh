#!/usr/bin/env bash
# Unit tests for Ory Kratos secret length constraints (no cluster required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok ${name}"
  else
    echo "FAIL ${name}" >&2
    exit 1
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL ${name} (expected false)" >&2
    exit 1
  else
    echo "ok ${name}"
  fi
}

cipher="$(ory_kratos_cipher_secret)"
assert_ok "cipher secret generated" test -n "${cipher}"
assert_ok "cipher length <= 32" ory_kratos_cipher_valid "${cipher}"
assert_ok "32-char hex valid" ory_kratos_cipher_valid "$(openssl rand -hex 16)"
assert_fail "base64-32 cipher invalid" ory_kratos_cipher_valid "$(openssl rand -base64 32)"

echo "scripts/test-ory-secrets.sh — all tests passed"
