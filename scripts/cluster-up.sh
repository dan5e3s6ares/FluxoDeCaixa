#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}"
K3D_CLUSTER_NAME="${K3D_CLUSTER_NAME:-fluxo-caixa}"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
CLUSTER_READY_ATTEMPTS="${CLUSTER_READY_ATTEMPTS:-60}"
CLUSTER_READY_DELAY="${CLUSTER_READY_DELAY:-5}"

NAMESPACES=(
  gateway
  security
  messaging
  observability
  fluxo-caixa
)

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    log_error "Root privileges required: $*"
    exit 1
  fi
}

kubectl_cmd() {
  if [[ "${CLUSTER_TYPE}" == "k3s" ]] && command -v k3s >/dev/null 2>&1; then
    k3s kubectl "$@"
  else
    require_cmd kubectl
    kubectl "$@"
  fi
}

cluster_is_ready() {
  local ready
  ready="$(kubectl_cmd get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$' || true)"
  [[ "${ready}" -ge 1 ]]
}

wait_for_cluster() {
  log_info "waiting for Kubernetes API (CLUSTER_TYPE=${CLUSTER_TYPE})..."
  retry "${CLUSTER_READY_ATTEMPTS}" "${CLUSTER_READY_DELAY}" cluster_is_ready
  log_info "cluster API is ready"
}

configure_k3s_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" ]] && kubectl_cmd cluster-info >/dev/null 2>&1; then
    log_info "using existing KUBECONFIG=${KUBECONFIG}"
    return 0
  fi

  if [[ -r "${K3S_KUBECONFIG}" ]]; then
    export KUBECONFIG="${K3S_KUBECONFIG}"
    log_info "using KUBECONFIG=${KUBECONFIG}"
    return 0
  fi

  if command -v k3s >/dev/null 2>&1; then
    log_info "using k3s kubectl (embedded kubeconfig)"
    return 0
  fi

  log_error "k3s cluster not reachable; run bootstrap-vm.sh first or set KUBECONFIG"
  exit 1
}

ensure_k3s_running() {
  require_cmd k3s
  configure_k3s_kubeconfig

  if cluster_is_ready; then
    log_info "k3s cluster already running"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if ! run_as_root systemctl is-active --quiet k3s 2>/dev/null; then
      ensure_k3s_port_available
      log_info "starting k3s service..."
      run_as_root systemctl enable --now k3s
    fi
  fi

  wait_for_cluster
}

k3d_cluster_exists() {
  k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "${K3D_CLUSTER_NAME}"
}

ensure_k3d_cluster() {
  require_cmd k3d
  require_cmd kubectl

  if k3d_cluster_exists; then
    log_info "k3d cluster '${K3D_CLUSTER_NAME}' already exists"
  else
    log_info "creating k3d cluster '${K3D_CLUSTER_NAME}'..."
    k3d cluster create "${K3D_CLUSTER_NAME}" \
      --agents 0 \
      --wait \
      --timeout 300s
  fi

  export KUBECONFIG
  KUBECONFIG="$(k3d kubeconfig write "${K3D_CLUSTER_NAME}")"
  export KUBECONFIG
  log_info "using KUBECONFIG=${KUBECONFIG}"

  wait_for_cluster
}

ensure_namespace() {
  local ns="$1"
  if kubectl_cmd get namespace "${ns}" >/dev/null 2>&1; then
    log_info "namespace exists: ${ns}"
    return 0
  fi

  log_info "creating namespace: ${ns}"
  kubectl_cmd create namespace "${ns}"
}

verify_namespaces() {
  local ns missing=()
  for ns in "${NAMESPACES[@]}"; do
    if ! kubectl_cmd get namespace "${ns}" >/dev/null 2>&1; then
      missing+=("${ns}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log_error "missing namespaces: ${missing[*]}"
    kubectl_cmd get namespaces
    exit 1
  fi

  log_info "all platform namespaces present"
  kubectl_cmd get namespace "${NAMESPACES[@]}"
}

ensure_namespaces() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    ensure_namespace "${ns}"
  done
  verify_namespaces
}

main() {
  log_info "cluster-up.sh — CLUSTER_TYPE=${CLUSTER_TYPE}"

  case "${CLUSTER_TYPE}" in
    k3s)
      ensure_k3s_running
      ;;
    k3d)
      ensure_k3d_cluster
      ;;
    *)
      log_error "unsupported CLUSTER_TYPE=${CLUSTER_TYPE} (expected k3s or k3d)"
      exit 1
      ;;
  esac

  ensure_namespaces
  log_info "cluster-up.sh — complete"
}

main "$@"
