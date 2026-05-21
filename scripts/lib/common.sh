#!/usr/bin/env bash
# Shared helpers for scripts/ (doc 07).
set -euo pipefail

# Global health wait: 15 min = 180 attempts × 5s (doc 07).
export HEALTH_RETRY_ATTEMPTS="${HEALTH_RETRY_ATTEMPTS:-180}"
export HEALTH_RETRY_DELAY="${HEALTH_RETRY_DELAY:-5}"
export HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-900}"

export CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}"
export K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

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
  while (( i <= attempts )); do
    if "$@"; then
      return 0
    fi
    if (( i >= attempts )); then
      return 1
    fi
    log_warn "Attempt ${i}/${attempts} failed; retrying in ${delay}s..."
    sleep "${delay}"
    i=$((i + 1))
  done
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    log_info "helm already installed"
    return 0
  fi
  log_info "installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
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

  log_error "Kubernetes cluster not reachable; run cluster-up.sh first or set KUBECONFIG"
  exit 1
}

# Resolve namespace and label selector for logs/restart (SVC arg).
# Sets: SVC_NAMESPACE, SVC_SELECTOR, SVC_DEPLOYMENT
resolve_svc_target() {
  local svc="${1:-}"
  SVC_NAMESPACE=""
  SVC_SELECTOR=""
  SVC_DEPLOYMENT=""

  case "${svc}" in
    lancamentos|svc-lancamentos)
      SVC_NAMESPACE="fluxo-caixa"
      SVC_DEPLOYMENT="svc-lancamentos"
      SVC_SELECTOR="app=svc-lancamentos"
      ;;
    consolidado|svc-consolidado)
      SVC_NAMESPACE="fluxo-caixa"
      SVC_DEPLOYMENT="svc-consolidado"
      SVC_SELECTOR="app=svc-consolidado"
      ;;
    consulta|svc-consulta)
      SVC_NAMESPACE="fluxo-caixa"
      SVC_DEPLOYMENT="svc-consulta"
      SVC_SELECTOR="app=svc-consulta"
      ;;
    nats)
      SVC_NAMESPACE="messaging"
      SVC_DEPLOYMENT="nats"
      SVC_SELECTOR="app.kubernetes.io/name=nats"
      ;;
    postgres|pg)
      SVC_NAMESPACE="database"
      SVC_SELECTOR="cnpg.io/cluster=fluxo-pg"
      ;;
    redis)
      SVC_NAMESPACE="cache"
      SVC_DEPLOYMENT="redis-master"
      SVC_SELECTOR="app.kubernetes.io/name=redis"
      ;;
    keycloak)
      SVC_NAMESPACE="security"
      SVC_DEPLOYMENT="keycloak"
      SVC_SELECTOR="app.kubernetes.io/name=keycloak"
      ;;
    krakend)
      SVC_NAMESPACE="gateway"
      SVC_DEPLOYMENT="krakend"
      SVC_SELECTOR="app.kubernetes.io/name=krakend"
      ;;
    argocd)
      SVC_NAMESPACE="argocd"
      SVC_DEPLOYMENT="argocd-server"
      SVC_SELECTOR="app.kubernetes.io/name=argocd-server"
      ;;
    prometheus)
      SVC_NAMESPACE="observability"
      SVC_SELECTOR="app.kubernetes.io/name=prometheus"
      ;;
    grafana)
      SVC_NAMESPACE="observability"
      SVC_DEPLOYMENT="grafana"
      SVC_SELECTOR="app.kubernetes.io/name=grafana"
      ;;
    otel|otel-collector)
      SVC_NAMESPACE="observability"
      SVC_DEPLOYMENT="otel-collector"
      SVC_SELECTOR="app.kubernetes.io/name=opentelemetry-collector"
      ;;
    cert-manager)
      SVC_NAMESPACE="cert-manager"
      SVC_SELECTOR="app.kubernetes.io/instance=cert-manager"
      ;;
    *)
      log_error "Unknown service '${svc}'. Valid: lancamentos, consolidado, consulta, nats, postgres, redis, keycloak, krakend, argocd, prometheus, grafana, otel"
      return 1
      ;;
  esac
}
