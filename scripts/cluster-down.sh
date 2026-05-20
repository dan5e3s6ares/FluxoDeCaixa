#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PURGE_PVC=false
if [[ "${1:-}" == "--purge-pvc" ]]; then
  PURGE_PVC=true
fi

if [[ "${PURGE_PVC}" == true ]]; then
  log_info "cluster-down.sh — stub (derruba cluster e remove PVCs)"
else
  log_info "cluster-down.sh — stub (derruba cluster; preserva PVCs)"
fi
