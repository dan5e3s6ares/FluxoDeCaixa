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

# Suppress podman-docker "Emulate Docker CLI using podman" message (requires run_as_root).
ensure_podman_nodocker() {
  if [[ -f /etc/containers/nodocker ]]; then
    log_info "unchanged: /etc/containers/nodocker"
    return 0
  fi
  if ! declare -f run_as_root >/dev/null 2>&1; then
    log_warn "run_as_root unavailable; skip /etc/containers/nodocker"
    return 0
  fi
  run_as_root mkdir -p /etc/containers
  run_as_root touch /etc/containers/nodocker
  log_info "created /etc/containers/nodocker (quiet podman-docker emulation message)"
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

# Kustomize overlays under deploy/ reference platform/ bootstrap assets via
# configMapGenerator file paths outside the overlay root; allow that explicitly.
# k3s embeds an older kubectl where apply -k does not accept --load-restrictor;
# build with kubectl kustomize (or standalone kustomize) and pipe to apply.
kubectl_apply_k() {
  local dir="$1"
  local load_restrictor=(--load-restrictor LoadRestrictionsNone)

  if kubectl_cmd apply -h 2>&1 | grep -q -- '--load-restrictor'; then
    kubectl_cmd apply -k "${dir}" "${load_restrictor[@]}"
    return
  fi

  if command -v kustomize >/dev/null 2>&1; then
    kustomize build "${load_restrictor[@]}" "${dir}" | kubectl_cmd apply -f -
    return
  fi

  kubectl_cmd kustomize "${load_restrictor[@]}" "${dir}" | kubectl_cmd apply -f -
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

k3s_api_port_in_use() {
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(:|\])6443$'
}

k3s_service_active() {
  systemctl is-active --quiet k3s 2>/dev/null
}

conflicting_kubernetes_hints() {
  local hints=()

  if command -v snap >/dev/null 2>&1 && snap list k8s >/dev/null 2>&1; then
    if snap services k8s 2>/dev/null | grep -E 'kube-apiserver|k8sd' | grep -q active; then
      hints+=("snap k8s is using port 6443 (stop with: sudo snap stop k8s)")
    fi
  fi

  if command -v microk8s >/dev/null 2>&1; then
    if microk8s status --wait-ready=false 2>/dev/null | grep -q 'microk8s is running'; then
      hints+=("microk8s is using port 6443 (stop with: sudo microk8s stop)")
    fi
  fi

  if ((${#hints[@]} > 0)); then
    printf '%s\n' "${hints[@]}"
  fi
}

ensure_k3s_port_available() {
  if ! k3s_api_port_in_use; then
    return 0
  fi
  if k3s_service_active; then
    return 0
  fi

  log_error "Port 6443 is already in use but k3s is not running."
  local hints hint
  hints="$(conflicting_kubernetes_hints || true)"
  if [[ -n "${hints}" ]]; then
    while IFS= read -r hint; do
      [[ -n "${hint}" ]] && log_error "  ${hint}"
    done <<< "${hints}"
  else
    log_error "  Stop the process bound to port 6443 before running make start."
  fi
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
    krakend)
      SVC_NAMESPACE="gateway"
      SVC_DEPLOYMENT="krakend"
      SVC_SELECTOR="app.kubernetes.io/name=krakend"
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
      log_error "Unknown service '${svc}'. Valid: lancamentos, consolidado, consulta, nats, postgres, redis, krakend, prometheus, grafana, otel"
      return 1
      ;;
  esac
}
