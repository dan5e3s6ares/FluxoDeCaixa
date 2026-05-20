#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SVC="${1:-}"
if [[ -z "${SVC}" ]]; then
  log_error "Usage: restart-svc.sh <service>"
  exit 1
fi

log_info "restart-svc.sh — stub (serviço=${SVC})"
