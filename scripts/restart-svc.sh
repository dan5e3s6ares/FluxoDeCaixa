#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SVC="${1:-}"
if [[ -z "${SVC}" ]]; then
  log_error "Usage: restart-svc.sh <service>"
  log_error "Services: lancamentos, consolidado, consulta, nats, postgres, redis, keycloak, krakend, prometheus, grafana, otel"
  exit 1
fi

configure_kubeconfig
resolve_svc_target "${SVC}"

restart_deployment() {
  local ns="$1"
  local name="$2"
  log_info "rollout restart deployment/${name} in ${ns}"
  kubectl_cmd -n "${ns}" rollout restart "deployment/${name}"
  kubectl_cmd -n "${ns}" rollout status "deployment/${name}" --timeout=5m
}

restart_statefulset() {
  local ns="$1"
  local name="$2"
  log_info "rollout restart statefulset/${name} in ${ns}"
  kubectl_cmd -n "${ns}" rollout restart "statefulset/${name}"
  kubectl_cmd -n "${ns}" rollout status "statefulset/${name}" --timeout=10m
}

main() {
  log_info "restart-svc.sh — SVC=${SVC}"

  if [[ -n "${SVC_DEPLOYMENT:-}" ]]; then
    restart_deployment "${SVC_NAMESPACE}" "${SVC_DEPLOYMENT}"
    log_info "restart-svc.sh — ${SVC_NAMESPACE}/${SVC_DEPLOYMENT} restarted"
    return 0
  fi

  if [[ "${SVC}" == "postgres" || "${SVC}" == "pg" ]]; then
    local sts
    sts="$(kubectl_cmd -n "${SVC_NAMESPACE}" get statefulset \
      -l "${SVC_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${sts}" ]]; then
      log_error "PostgreSQL statefulset not found in ${SVC_NAMESPACE}"
      exit 1
    fi
    restart_statefulset "${SVC_NAMESPACE}" "${sts}"
    log_info "restart-svc.sh — ${SVC_NAMESPACE}/${sts} restarted"
    return 0
  fi

  local deploy
  deploy="$(kubectl_cmd -n "${SVC_NAMESPACE}" get deploy \
    -l "${SVC_SELECTOR}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${deploy}" ]]; then
    log_error "No deployment found for ${SVC} in ${SVC_NAMESPACE} (selector=${SVC_SELECTOR})"
    exit 1
  fi
  restart_deployment "${SVC_NAMESPACE}" "${deploy}"
  log_info "restart-svc.sh — ${SVC_NAMESPACE}/${deploy} restarted"
}

main "$@"
