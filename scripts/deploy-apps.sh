#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV="${ENV:-dev}"
log_info "deploy-apps.sh — stub (ArgoCD App-of-Apps, overlay=${ENV})"
