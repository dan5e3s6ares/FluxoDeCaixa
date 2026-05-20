#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_RELEASE="${CERT_MANAGER_RELEASE:-cert-manager}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.14.5}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-gateway}"
KRAKEND_TLS_SECRET="${KRAKEND_TLS_SECRET:-krakend-tls}"
CERT_MANAGER_READY_ATTEMPTS="${CERT_MANAGER_READY_ATTEMPTS:-60}"
CERT_MANAGER_READY_DELAY="${CERT_MANAGER_READY_DELAY:-5}"
TLS_SECRET_READY_ATTEMPTS="${TLS_SECRET_READY_ATTEMPTS:-60}"
TLS_SECRET_READY_DELAY="${TLS_SECRET_READY_DELAY:-5}"

CERT_MANAGER_MANIFESTS="${REPO_ROOT}/deploy/cert-manager"
NATS_NAMESPACE="${NATS_NAMESPACE:-messaging}"
NATS_RELEASE="${NATS_RELEASE:-nats}"
NATS_CHART_VERSION="${NATS_CHART_VERSION:-1.2.6}"
NATS_VALUES="${REPO_ROOT}/deploy/nats/values.yaml"
NATS_BOOTSTRAP_MANIFESTS="${REPO_ROOT}/deploy/nats"
NATS_READY_ATTEMPTS="${NATS_READY_ATTEMPTS:-60}"
NATS_READY_DELAY="${NATS_READY_DELAY:-5}"
NATS_BOOTSTRAP_ATTEMPTS="${NATS_BOOTSTRAP_ATTEMPTS:-60}"
NATS_BOOTSTRAP_DELAY="${NATS_BOOTSTRAP_DELAY:-5}"

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

cert_manager_deployments_ready() {
  local ready desired
  ready="$(kubectl_cmd -n "${CERT_MANAGER_NAMESPACE}" get deploy \
    -l app.kubernetes.io/instance="${CERT_MANAGER_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  desired="$(kubectl_cmd -n "${CERT_MANAGER_NAMESPACE}" get deploy \
    -l app.kubernetes.io/instance="${CERT_MANAGER_RELEASE}" \
    -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  [[ "${desired}" -ge 1 && "${ready}" -ge "${desired}" ]]
}

wait_for_cert_manager() {
  log_info "waiting for cert-manager deployments in ${CERT_MANAGER_NAMESPACE}..."
  retry "${CERT_MANAGER_READY_ATTEMPTS}" "${CERT_MANAGER_READY_DELAY}" cert_manager_deployments_ready
  log_info "cert-manager is ready"
}

deploy_cert_manager_helm() {
  ensure_helm
  ensure_namespace "${CERT_MANAGER_NAMESPACE}"

  log_info "helm upgrade --install ${CERT_MANAGER_RELEASE} (chart ${CERT_MANAGER_CHART_VERSION})"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack >/dev/null

  helm upgrade --install "${CERT_MANAGER_RELEASE}" jetstack/cert-manager \
    --namespace "${CERT_MANAGER_NAMESPACE}" \
    --version "${CERT_MANAGER_CHART_VERSION}" \
    --set installCRDs=true \
    --wait \
    --timeout 10m

  wait_for_cert_manager
}

apply_cert_manager_manifests() {
  if [[ ! -d "${CERT_MANAGER_MANIFESTS}" ]]; then
    log_error "cert-manager manifests not found: ${CERT_MANAGER_MANIFESTS}"
    exit 1
  fi

  ensure_namespace "${CERT_MANAGER_NAMESPACE}"
  ensure_namespace "${GATEWAY_NAMESPACE}"

  log_info "applying cert-manager issuers and certificates from ${CERT_MANAGER_MANIFESTS}"
  kubectl_cmd apply -k "${CERT_MANAGER_MANIFESTS}"
}

certificate_is_ready() {
  local name="$1"
  local namespace="$2"
  kubectl_cmd -n "${namespace}" get certificate "${name}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True
}

wait_for_certificate() {
  local name="$1"
  local namespace="$2"
  log_info "waiting for Certificate/${name} in ${namespace}..."
  retry "${TLS_SECRET_READY_ATTEMPTS}" "${TLS_SECRET_READY_DELAY}" certificate_is_ready "${name}" "${namespace}"
}

krakend_tls_secret_exists() {
  kubectl_cmd -n "${GATEWAY_NAMESPACE}" get secret "${KRAKEND_TLS_SECRET}" >/dev/null 2>&1
}

wait_for_krakend_tls_secret() {
  log_info "waiting for TLS secret ${KRAKEND_TLS_SECRET} in ${GATEWAY_NAMESPACE}..."
  retry "${TLS_SECRET_READY_ATTEMPTS}" "${TLS_SECRET_READY_DELAY}" krakend_tls_secret_exists
}

deploy_cert_manager_stack() {
  deploy_cert_manager_helm
  apply_cert_manager_manifests
  wait_for_certificate "fluxo-caixa-ca" "${CERT_MANAGER_NAMESPACE}"
  wait_for_certificate "krakend-tls" "${GATEWAY_NAMESPACE}"
  wait_for_krakend_tls_secret
  log_info "KrakenD TLS secret ${KRAKEND_TLS_SECRET} is present in ${GATEWAY_NAMESPACE}"
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

wait_for_nats() {
  log_info "waiting for NATS pods in ${NATS_NAMESPACE}..."
  retry "${NATS_READY_ATTEMPTS}" "${NATS_READY_DELAY}" nats_pods_ready
  log_info "NATS is ready"
}

deploy_nats_helm() {
  ensure_helm
  ensure_namespace "${NATS_NAMESPACE}"

  if [[ ! -f "${NATS_VALUES}" ]]; then
    log_error "NATS values not found: ${NATS_VALUES}"
    exit 1
  fi

  log_info "helm upgrade --install ${NATS_RELEASE} nats/nats (chart ${NATS_CHART_VERSION})"
  helm repo add nats https://nats-io.github.io/k8s/helm/charts/ >/dev/null 2>&1 || true
  helm repo update nats >/dev/null

  helm upgrade --install "${NATS_RELEASE}" nats/nats \
    --namespace "${NATS_NAMESPACE}" \
    --version "${NATS_CHART_VERSION}" \
    --values "${NATS_VALUES}" \
    --wait \
    --timeout 10m

  wait_for_nats
}

nats_bootstrap_job_complete() {
  local status
  status="$(kubectl_cmd -n "${NATS_NAMESPACE}" get job nats-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

wait_for_nats_bootstrap() {
  log_info "waiting for Job/nats-bootstrap in ${NATS_NAMESPACE}..."
  retry "${NATS_BOOTSTRAP_ATTEMPTS}" "${NATS_BOOTSTRAP_DELAY}" nats_bootstrap_job_complete
  log_info "nats-bootstrap job completed"
}

run_nats_bootstrap() {
  if [[ ! -d "${NATS_BOOTSTRAP_MANIFESTS}" ]]; then
    log_error "NATS bootstrap manifests not found: ${NATS_BOOTSTRAP_MANIFESTS}"
    exit 1
  fi

  log_info "applying nats-bootstrap manifests from ${NATS_BOOTSTRAP_MANIFESTS}"
  kubectl_cmd delete job nats-bootstrap -n "${NATS_NAMESPACE}" --ignore-not-found
  kubectl_cmd apply -k "${NATS_BOOTSTRAP_MANIFESTS}"
  wait_for_nats_bootstrap
}

deploy_nats_stack() {
  deploy_nats_helm
  run_nats_bootstrap
  log_info "JetStream streams/consumers provisioned (lancamentos.events, lancamentos.dlq, consolidado-workers)"
}

main() {
  log_info "deploy-platform.sh — CLUSTER_TYPE=${CLUSTER_TYPE}"
  configure_kubeconfig
  deploy_cert_manager_stack
  deploy_nats_stack
  log_info "deploy-platform.sh — complete"
}

main "$@"
