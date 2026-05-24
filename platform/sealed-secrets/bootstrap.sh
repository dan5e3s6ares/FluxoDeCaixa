#!/usr/bin/env bash
# Generate SealedSecrets for GitOps overlays (doc 07).
# Requires: sealed-secrets controller, kubeseal, kubectl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENV="${ENV:-dev}"
OVERLAY_SEALED_DIR="${REPO_ROOT}/deploy/k8s/overlays/${ENV}/sealed"
SEALED_SECRETS_NAMESPACE="${SEALED_SECRETS_NAMESPACE:-kube-system}"
CONTROLLER_NAME="${SEALED_SECRETS_CONTROLLER:-sealed-secrets}"

REGISTRY_ENV_FILE="${REGISTRY_ENV_FILE:-/etc/fluxo-caixa/registry.env}"
if [[ -f "${REGISTRY_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "${REGISTRY_ENV_FILE}"
  set +a
fi
HARBOR_REGISTRY="${HARBOR_REGISTRY:-${HARBOR_IMAGE_REGISTRY:-harbor.local:8080}}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
HARBOR_PASSWORD="${HARBOR_PASSWORD:-Harbor12345}"

FLUXO_NAMESPACE="${FLUXO_NAMESPACE:-fluxo-caixa}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

GIT_REPO_USERNAME="${GIT_REPO_USERNAME:-}"
GIT_REPO_PASSWORD="${GIT_REPO_PASSWORD:-}"

log() { echo "[sealed-secrets] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[sealed-secrets] ERROR: required command not found: $1" >&2
    exit 1
  }
}

kubectl_cmd() {
  if command -v k3s >/dev/null 2>&1; then
    k3s kubectl "$@"
  else
    kubectl "$@"
  fi
}

wait_for_controller() {
  log "waiting for sealed-secrets controller..."
  local i=1
  while (( i <= 60 )); do
    if kubectl_cmd -n "${SEALED_SECRETS_NAMESPACE}" get deploy \
      -l "app.kubernetes.io/name=sealed-secrets" \
      -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null | grep -q '^1$'; then
      log "sealed-secrets controller is ready"
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  echo "[sealed-secrets] ERROR: controller not ready" >&2
  exit 1
}

seal_from_literal() {
  local name="$1"
  local namespace="$2"
  local out_file="$3"
  shift 3

  kubectl_cmd -n "${namespace}" delete secret "${name}" --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${namespace}" create secret generic "${name}" "$@" --dry-run=client -o yaml \
    | kubeseal \
      --controller-name="${CONTROLLER_NAME}" \
      --controller-namespace="${SEALED_SECRETS_NAMESPACE}" \
      --format yaml \
      --namespace "${namespace}" \
      --name "${name}" \
      >"${out_file}"
  log "wrote ${out_file}"
}

seal_dockerconfig() {
  local name="$1"
  local namespace="$2"
  local registry="$3"
  local username="$4"
  local password="$5"
  local out_file="$6"

  kubectl_cmd -n "${namespace}" delete secret "${name}" --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${namespace}" create secret docker-registry "${name}" \
    --docker-server="${registry}" \
    --docker-username="${username}" \
    --docker-password="${password}" \
    --dry-run=client -o yaml \
    | kubeseal \
      --controller-name="${CONTROLLER_NAME}" \
      --controller-namespace="${SEALED_SECRETS_NAMESPACE}" \
      --format yaml \
      --namespace "${namespace}" \
      --name "${name}" \
      >"${out_file}"
  log "wrote ${out_file}"
}

write_kustomization() {
  local dir="$1"
  shift
  cat >"${dir}/kustomization.yaml" <<'HEADER'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
HEADER
  for f in "$@"; do
    echo "  - ${f}" >>"${dir}/kustomization.yaml"
  done
}

main() {
  require_cmd kubectl
  require_cmd kubeseal

  mkdir -p "${OVERLAY_SEALED_DIR}"
  wait_for_controller

  local -a resources=(harbor-pull-secret.yaml)

  seal_dockerconfig \
    harbor-pull-secret \
    "${FLUXO_NAMESPACE}" \
    "${HARBOR_REGISTRY}" \
    "${HARBOR_USERNAME}" \
    "${HARBOR_PASSWORD}" \
    "${OVERLAY_SEALED_DIR}/harbor-pull-secret.yaml"

  if kubectl_cmd -n cache get secret fluxo-redis >/dev/null 2>&1; then
    local redis_password redis_url
    redis_password="$(kubectl_cmd -n cache get secret fluxo-redis -o jsonpath='{.data.redis-password}' | base64 -d)"
    redis_url="$(kubectl_cmd -n cache get secret fluxo-redis -o jsonpath='{.data.redis-url}' | base64 -d)"
    seal_from_literal fluxo-redis "${FLUXO_NAMESPACE}" "${OVERLAY_SEALED_DIR}/fluxo-redis.yaml" \
      --from-literal=redis-password="${redis_password}" \
      --from-literal=redis-url="${redis_url}"
    resources+=(fluxo-redis.yaml)
  else
    log "skip fluxo-redis (secret not found in cache namespace)"
  fi

  if kubectl_cmd -n security get secret fluxo-keycloak >/dev/null 2>&1; then
    local admin_password postgres_password
    admin_password="$(kubectl_cmd -n security get secret fluxo-keycloak -o jsonpath='{.data.admin-password}' | base64 -d)"
    postgres_password="$(kubectl_cmd -n security get secret fluxo-keycloak -o jsonpath='{.data.postgres-password}' | base64 -d)"
    seal_from_literal fluxo-keycloak "${FLUXO_NAMESPACE}" "${OVERLAY_SEALED_DIR}/fluxo-keycloak.yaml" \
      --from-literal=admin-password="${admin_password}" \
      --from-literal=postgres-password="${postgres_password}"
    resources+=(fluxo-keycloak.yaml)
  else
    log "skip fluxo-keycloak (secret not found in security namespace)"
  fi

  if kubectl_cmd -n database get secret fluxo-pg-app >/dev/null 2>&1; then
    local pg_user pg_pass pg_host
    pg_user="$(kubectl_cmd -n database get secret fluxo-pg-app -o jsonpath='{.data.username}' | base64 -d)"
    pg_pass="$(kubectl_cmd -n database get secret fluxo-pg-app -o jsonpath='{.data.password}' | base64 -d)"
    pg_host="${PGHOST:-fluxo-pg-rw.database.svc.cluster.local}"
    local db_url_lancamentos db_url_consolidado
    db_url_lancamentos="postgresql://${pg_user}:${pg_pass}@${pg_host}:5432/fluxo?options=-csearch_path%3Dlancamentos"
    db_url_consolidado="postgresql://${pg_user}:${pg_pass}@${pg_host}:5432/fluxo?options=-csearch_path%3Dconsolidado"
    seal_from_literal fluxo-pg-app "${FLUXO_NAMESPACE}" "${OVERLAY_SEALED_DIR}/fluxo-pg-app.yaml" \
      --from-literal=username="${pg_user}" \
      --from-literal=password="${pg_pass}" \
      --from-literal=database-url-lancamentos="${db_url_lancamentos}" \
      --from-literal=database-url-consolidado="${db_url_consolidado}"
    resources+=(fluxo-pg-app.yaml)
  else
    log "skip fluxo-pg-app (CNPG app secret not found in database namespace)"
  fi

  if [[ -n "${GIT_REPO_USERNAME}" && -n "${GIT_REPO_PASSWORD}" ]]; then
    seal_from_literal repo-fluxo-caixa "${ARGOCD_NAMESPACE}" "${OVERLAY_SEALED_DIR}/argocd-repo-fluxo-caixa.yaml" \
      --from-literal=username="${GIT_REPO_USERNAME}" \
      --from-literal=password="${GIT_REPO_PASSWORD}"
    resources+=(argocd-repo-fluxo-caixa.yaml)
  else
    log "skip argocd repo credentials (set GIT_REPO_USERNAME and GIT_REPO_PASSWORD)"
  fi

  write_kustomization "${OVERLAY_SEALED_DIR}" "${resources[@]}"
  log "sealed secrets bootstrap complete for overlay=${ENV}"
}

main "$@"
