#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ENV="${ENV:-dev}"

SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-kube-system}"
SEALED_SECRETS_RELEASE="${SEALED_SECRETS_RELEASE:-sealed-secrets}"
SEALED_SECRETS_CHART_VERSION="${SEALED_SECRETS_CHART_VERSION:-2.16.5}"

KUSTOMIZE_OVERLAY_PATH="deploy/k8s/overlays/${ENV}"
SEALED_BOOTSTRAP="${REPO_ROOT}/platform/sealed-secrets/bootstrap.sh"

deploy_sealed_secrets_controller() {
  ensure_helm
  log_info "helm upgrade --install ${SEALED_SECRETS_RELEASE} (chart ${SEALED_SECRETS_CHART_VERSION})"
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
  helm repo update sealed-secrets >/dev/null

  helm upgrade --install "${SEALED_SECRETS_RELEASE}" sealed-secrets/sealed-secrets \
    --namespace "${SEALED_SECRETS_NAMESPACE}" \
    --version "${SEALED_SECRETS_CHART_VERSION}" \
    --set fullnameOverride="${SEALED_SECRETS_RELEASE}" \
    --wait \
    --timeout 10m
}

run_sealed_secrets_bootstrap() {
  if [[ ! -x "${SEALED_BOOTSTRAP}" ]]; then
    chmod +x "${SEALED_BOOTSTRAP}"
  fi
  log_info "running sealed-secrets bootstrap (ENV=${ENV})"
  ENV="${ENV}" "${SEALED_BOOTSTRAP}"
}

apply_apps_overlay() {
  local overlay_path="${REPO_ROOT}/${KUSTOMIZE_OVERLAY_PATH}"
  if [[ ! -d "${overlay_path}" ]]; then
    log_error "kustomize overlay not found: ${overlay_path}"
    exit 1
  fi
  log_info "kubectl apply -k ${overlay_path}"
  kubectl_apply_k "${overlay_path}"
}

main() {
  log_info "deploy-apps.sh — CLUSTER_TYPE=${CLUSTER_TYPE} ENV=${ENV}"
  configure_kubeconfig
  deploy_sealed_secrets_controller
  run_sealed_secrets_bootstrap
  apply_apps_overlay
  log_info "deploy-apps.sh — complete (overlay=${KUSTOMIZE_OVERLAY_PATH}, local :dev images via build-images.sh)"
}

main "$@"
