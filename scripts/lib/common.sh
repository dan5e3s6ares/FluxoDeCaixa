#!/usr/bin/env bash
set -euo pipefail

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}"
    exit 1
  fi
}

retry() {
  local attempts="${1}"
  shift
  local delay="${1}"
  shift
  local i=1
  until "$@"; do
    if (( i >= attempts )); then
      return 1
    fi
    log_warn "Attempt ${i}/${attempts} failed; retrying in ${delay}s..."
    sleep "${delay}"
    i=$((i + 1))
  done
}
