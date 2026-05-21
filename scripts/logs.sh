#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAIL_LINES="${TAIL_LINES:-100}"
FOLLOW="${FOLLOW:-false}"
SVC="all"

APP_NAMESPACES=(
  fluxo-caixa
  gateway
  security
  messaging
  database
  cache
  observability
  argocd
  cert-manager
)

configure_kubeconfig

tail_deployment() {
  local ns="$1"
  local deployment="$2"
  if ! kubectl_cmd -n "${ns}" get deployment "${deployment}" >/dev/null 2>&1; then
    log_warn "deployment/${deployment} not found in ${ns}"
    return 0
  fi
  local args=(-n "${ns}" logs "deployment/${deployment}" --tail="${TAIL_LINES}")
  if [[ "${FOLLOW}" == true ]]; then
    args+=(--follow)
  fi
  log_info "--- logs: ${ns}/deployment/${deployment} ---"
  kubectl_cmd "${args[@]}"
}

tail_selector() {
  local ns="$1"
  local selector="$2"
  local pod
  pod="$(kubectl_cmd -n "${ns}" get pods -l "${selector}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    log_warn "no pods for -l ${selector} in ${ns}"
    return 0
  fi
  local args=(-n "${ns}" logs "${pod}" --tail="${TAIL_LINES}")
  if [[ "${FOLLOW}" == true ]]; then
    args+=(--follow)
  fi
  log_info "--- logs: ${ns}/pod/${pod} (${selector}) ---"
  kubectl_cmd "${args[@]}"
}

tail_svc() {
  resolve_svc_target "$1"
  if [[ -n "${SVC_DEPLOYMENT:-}" ]]; then
    tail_deployment "${SVC_NAMESPACE}" "${SVC_DEPLOYMENT}"
  else
    tail_selector "${SVC_NAMESPACE}" "${SVC_SELECTOR}"
  fi
}

tail_all() {
  local ns
  for ns in "${APP_NAMESPACES[@]}"; do
    if ! kubectl_cmd get namespace "${ns}" >/dev/null 2>&1; then
      continue
    fi
    log_info "=== namespace ${ns} ==="
    kubectl_cmd -n "${ns}" logs --all-containers=true --tail="${TAIL_LINES}" \
      -l 'app.kubernetes.io/part-of=fluxo-caixa' 2>/dev/null \
      || kubectl_cmd -n "${ns}" get pods -o name 2>/dev/null | head -5 | while read -r pod; do
        kubectl_cmd -n "${ns}" logs "${pod#pod/}" --tail="${TAIL_LINES}" 2>/dev/null || true
      done
  done
}

parse_args() {
  SVC="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow)
        FOLLOW=true
        shift
        ;;
      all|lancamentos|consolidado|consulta|nats|postgres|pg|redis|keycloak|krakend|argocd|prometheus|grafana|otel)
        SVC="$1"
        shift
        ;;
      *)
        log_error "Unknown argument: $1"
        log_error "Usage: logs.sh [-f|--follow] <service|all>"
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  log_info "logs.sh — SVC=${SVC} TAIL_LINES=${TAIL_LINES} FOLLOW=${FOLLOW}"

  if [[ "${SVC}" == "all" ]]; then
    tail_all
    return 0
  fi

  tail_svc "${SVC}"
}

main "$@"
