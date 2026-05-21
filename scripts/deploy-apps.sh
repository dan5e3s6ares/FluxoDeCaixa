#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLUSTER_TYPE="${CLUSTER_TYPE:-k3s}"
K3S_KUBECONFIG="${K3S_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ENV="${ENV:-dev}"

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_RELEASE="${ARGOCD_RELEASE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.10}"
SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-kube-system}"
SEALED_SECRETS_RELEASE="${SEALED_SECRETS_RELEASE:-sealed-secrets}"
SEALED_SECRETS_CHART_VERSION="${SEALED_SECRETS_CHART_VERSION:-2.16.5}"

GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_TARGET_REVISION="${GIT_TARGET_REVISION:-HEAD}"
KUSTOMIZE_OVERLAY_PATH="deploy/k8s/overlays/${ENV}"

ARGOCD_MANIFESTS="${REPO_ROOT}/deploy/argocd"
ROOT_APP_TEMPLATE="${ARGOCD_MANIFESTS}/root-app.yaml.in"
ROOT_APP_RENDERED="${ARGOCD_MANIFESTS}/root-app.yaml"
SEALED_BOOTSTRAP="${REPO_ROOT}/platform/sealed-secrets/bootstrap.sh"

ARGOCD_READY_ATTEMPTS="${ARGOCD_READY_ATTEMPTS:-60}"
ARGOCD_READY_DELAY="${ARGOCD_READY_DELAY:-5}"
ARGOCD_SYNC_ATTEMPTS="${ARGOCD_SYNC_ATTEMPTS:-60}"
ARGOCD_SYNC_DELAY="${ARGOCD_SYNC_DELAY:-5}"

detect_git_repo_url() {
  if [[ -n "${GIT_REPO_URL}" ]]; then
    return 0
  fi
  if git -C "${REPO_ROOT}" remote get-url origin >/dev/null 2>&1; then
    GIT_REPO_URL="$(git -C "${REPO_ROOT}" remote get-url origin)"
    log_info "detected GIT_REPO_URL=${GIT_REPO_URL}"
    return 0
  fi
  log_error "GIT_REPO_URL is not set and git remote origin is unavailable"
  exit 1
}

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

deploy_argocd() {
  ensure_helm
  ensure_namespace "${ARGOCD_NAMESPACE}"

  log_info "helm upgrade --install ${ARGOCD_RELEASE} argo/argo-cd (chart ${ARGOCD_CHART_VERSION})"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update argo >/dev/null

  helm upgrade --install "${ARGOCD_RELEASE}" argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --version "${ARGOCD_CHART_VERSION}" \
    --set server.service.type=ClusterIP \
    --set configs.params."server\.insecure"=true \
    --wait \
    --timeout 15m
}

argocd_server_ready() {
  local ready
  ready="$(kubectl_cmd -n "${ARGOCD_NAMESPACE}" get deploy argocd-server \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [[ "${ready}" == "1" ]]
}

wait_for_argocd() {
  log_info "waiting for ArgoCD server in ${ARGOCD_NAMESPACE}..."
  retry "${ARGOCD_READY_ATTEMPTS}" "${ARGOCD_READY_DELAY}" argocd_server_ready
  log_info "ArgoCD server is ready"
}

run_sealed_secrets_bootstrap() {
  if [[ ! -x "${SEALED_BOOTSTRAP}" ]]; then
    chmod +x "${SEALED_BOOTSTRAP}"
  fi
  log_info "running sealed-secrets bootstrap (ENV=${ENV})"
  ENV="${ENV}" "${SEALED_BOOTSTRAP}"
}

render_root_app() {
  detect_git_repo_url
  if [[ ! -f "${ROOT_APP_TEMPLATE}" ]]; then
    log_error "root app template not found: ${ROOT_APP_TEMPLATE}"
    exit 1
  fi
  sed \
    -e "s|__GIT_REPO_URL__|${GIT_REPO_URL}|g" \
    -e "s|__GIT_TARGET_REVISION__|${GIT_TARGET_REVISION}|g" \
    -e "s|__KUSTOMIZE_OVERLAY_PATH__|${KUSTOMIZE_OVERLAY_PATH}|g" \
    "${ROOT_APP_TEMPLATE}" >"${ROOT_APP_RENDERED}"
  log_info "rendered ${ROOT_APP_RENDERED} (path=${KUSTOMIZE_OVERLAY_PATH})"
}

apply_gitops_overlay() {
  local overlay_path="${REPO_ROOT}/${KUSTOMIZE_OVERLAY_PATH}"
  log_info "applying kustomize overlay ${overlay_path} (bootstrap before ArgoCD git sync)"
  kubectl_cmd apply -k "${overlay_path}"
}

apply_argocd_repo_secret() {
  if [[ -z "${GIT_REPO_USERNAME}" || -z "${GIT_REPO_PASSWORD}" ]]; then
    log_info "skipping ArgoCD repository secret (GIT_REPO_USERNAME/PASSWORD unset)"
    return 0
  fi
  detect_git_repo_url
  log_info "configuring ArgoCD repository credentials"
  kubectl_cmd -n "${ARGOCD_NAMESPACE}" create secret generic repo-fluxo-caixa \
    --from-literal=type=git \
    --from-literal=url="${GIT_REPO_URL}" \
    --from-literal=username="${GIT_REPO_USERNAME}" \
    --from-literal=password="${GIT_REPO_PASSWORD}" \
    --dry-run=client -o yaml \
    | kubectl_cmd apply -f -
  kubectl_cmd -n "${ARGOCD_NAMESPACE}" label secret repo-fluxo-caixa \
    argocd.argoproj.io/secret-type=repository --overwrite
}

apply_root_app() {
  render_root_app
  apply_argocd_repo_secret
  log_info "applying ArgoCD root Application"
  kubectl_cmd apply -f "${ROOT_APP_RENDERED}"
}

argocd_app_synced() {
  local health sync
  health="$(kubectl_cmd -n "${ARGOCD_NAMESPACE}" get application fluxo-caixa \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  sync="$(kubectl_cmd -n "${ARGOCD_NAMESPACE}" get application fluxo-caixa \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [[ "${health}" == "Healthy" && "${sync}" == "Synced" ]]
}

wait_for_root_app_sync() {
  log_info "waiting for Application/fluxo-caixa sync (overlay=${ENV})..."
  if retry "${ARGOCD_SYNC_ATTEMPTS}" "${ARGOCD_SYNC_DELAY}" argocd_app_synced; then
    log_info "fluxo-caixa Application is Synced and Healthy"
    return 0
  fi
  log_warn "Application/fluxo-caixa not Synced/Healthy yet — check ArgoCD UI or repo credentials"
  kubectl_cmd -n "${ARGOCD_NAMESPACE}" get application fluxo-caixa -o wide || true
}

main() {
  log_info "deploy-apps.sh — CLUSTER_TYPE=${CLUSTER_TYPE} ENV=${ENV}"
  configure_kubeconfig
  deploy_sealed_secrets_controller
  deploy_argocd
  wait_for_argocd
  run_sealed_secrets_bootstrap
  apply_gitops_overlay
  apply_root_app
  wait_for_root_app_sync
  log_info "deploy-apps.sh — complete (GitOps overlay=${ENV}, harbor-pull-secret via Sealed Secrets)"
}

main "$@"
