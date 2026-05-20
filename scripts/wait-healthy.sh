#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
CHECK_ONLY=false
NATS_NAMESPACE="${NATS_NAMESPACE:-messaging}"
NATS_RELEASE="${NATS_RELEASE:-nats}"
READY_ATTEMPTS="${READY_ATTEMPTS:-30}"
READY_DELAY="${READY_DELAY:-5}"

if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=true
fi

kubectl_cmd() {
  if [[ "${CLUSTER_TYPE}" == "k3s" ]] && command -v k3s >/dev/null 2>&1; then
    k3s kubectl "$@"
  else
    require_cmd kubectl
    kubectl "$@"
  fi
}

configure_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" ]] && kubectl_cmd cluster-info >/dev/null 2>&1; then
    return 0
  fi
  if [[ -r "${K3S_KUBECONFIG}" ]]; then
    export KUBECONFIG="${K3S_KUBECONFIG}"
    return 0
  fi
  if command -v k3s >/dev/null 2>&1; then
    return 0
  fi
  log_error "Kubernetes cluster not reachable"
  exit 1
}

nats_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${NATS_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=nats,app.kubernetes.io/instance=${NATS_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${NATS_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=nats,app.kubernetes.io/instance=${NATS_RELEASE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

nats_bootstrap_complete() {
  local status
  status="$(kubectl_cmd -n "${NATS_NAMESPACE}" get job nats-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

nats_stream_lancamentos_events_exists() {
  kubectl_cmd -n "${NATS_NAMESPACE}" run "nats-stream-check-${RANDOM}" --rm -i --restart=Never \
    --image=natsio/nats-box:0.14.3 \
    --env="NATS_URL=nats://nats.${NATS_NAMESPACE}.svc.cluster.local:4222" \
    --command -- nats stream info lancamentos.events >/dev/null 2>&1
}

check_nats() {
  log_info "checking NATS JetStream (${NATS_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_pods_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_bootstrap_complete
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_stream_lancamentos_events_exists
  log_info "NATS healthy — stream lancamentos.events present"
}

main() {
  configure_kubeconfig

  if [[ "${CHECK_ONLY}" == true ]]; then
    log_info "wait-healthy.sh — check-only"
  else
    log_info "wait-healthy.sh — waiting for platform components"
  fi

  check_nats

  log_info "wait-healthy.sh — platform checks passed (NATS)"
}

main "$@"
