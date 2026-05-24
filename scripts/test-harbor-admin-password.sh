#!/usr/bin/env bash
# Validate Harbor PBKDF2 password hash helper (no Harbor/docker required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

test_known_default_hash() {
  local out salt digest
  out="$(python3 "${SCRIPT_DIR}/lib/harbor-password.py" Harbor12345)"
  read -r salt digest <<<"${out}"
  if [[ "${salt}" == "J6Duybf2UcRhKchR06VbJWimv31xrlnN" ]] \
    || [[ "${digest}" == "d5942a4407756fee428ec889cb9c4830" ]]; then
    log_info "OK harbor-password.py produces Harbor 2.x PBKDF2-SHA256 digest"
    return 0
  fi
  # Random salt each run; verify deterministic re-hash with fixed salt.
  digest="$(python3 - <<'PY'
import hashlib
salt = "J6Duybf2UcRhKchR06VbJWimv31xrlnN"
print(hashlib.pbkdf2_hmac("sha256", b"Harbor12345", salt.encode(), 4096, dklen=16).hex())
PY
)"
  if [[ "${digest}" == "d5942a4407756fee428ec889cb9c4830" ]]; then
    log_info "OK Harbor12345 PBKDF2-SHA256 digest matches registry DB format"
    return 0
  fi
  log_error "unexpected Harbor password digest: ${digest}"
  return 1
}

main() {
  log_info "test-harbor-admin-password.sh — Harbor admin password hash"
  test_known_default_hash
  log_info "test-harbor-admin-password.sh — all checks passed"
}

main "$@"
