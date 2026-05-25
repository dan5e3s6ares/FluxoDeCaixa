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

CNPG_OPERATOR_NAMESPACE="${CNPG_OPERATOR_NAMESPACE:-cnpg-system}"
CNPG_OPERATOR_RELEASE="${CNPG_OPERATOR_RELEASE:-cnpg}"
CNPG_OPERATOR_CHART_VERSION="${CNPG_OPERATOR_CHART_VERSION:-0.22.1}"
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-database}"
POSTGRES_CLUSTER="${POSTGRES_CLUSTER:-fluxo-pg}"
POSTGRES_MANIFESTS="${REPO_ROOT}/deploy/postgres"
POSTGRES_READY_ATTEMPTS="${POSTGRES_READY_ATTEMPTS:-60}"
POSTGRES_READY_DELAY="${POSTGRES_READY_DELAY:-5}"
POSTGRES_BOOTSTRAP_ATTEMPTS="${POSTGRES_BOOTSTRAP_ATTEMPTS:-60}"
POSTGRES_BOOTSTRAP_DELAY="${POSTGRES_BOOTSTRAP_DELAY:-5}"

REDIS_NAMESPACE="${REDIS_NAMESPACE:-cache}"
REDIS_RELEASE="${REDIS_RELEASE:-redis}"
REDIS_CHART_VERSION="${REDIS_CHART_VERSION:-20.6.2}"
REDIS_VALUES="${REPO_ROOT}/deploy/redis/values.yaml"
REDIS_MANIFESTS="${REPO_ROOT}/deploy/redis"
REDIS_READY_ATTEMPTS="${REDIS_READY_ATTEMPTS:-60}"
REDIS_READY_DELAY="${REDIS_READY_DELAY:-5}"

AUTHENTIK_NAMESPACE="${AUTHENTIK_NAMESPACE:-security}"
AUTHENTIK_RELEASE="${AUTHENTIK_RELEASE:-authentik}"
AUTHENTIK_CHART_VERSION="${AUTHENTIK_CHART_VERSION:-2025.12.4}"
AUTHENTIK_VALUES="${REPO_ROOT}/deploy/authentik/values.yaml"
AUTHENTIK_MANIFESTS="${REPO_ROOT}/deploy/authentik"
AUTHENTIK_SERVER_URL="${AUTHENTIK_SERVER_URL:-http://authentik-server.security.svc.cluster.local:9000}"
AUTHENTIK_OIDC_APP_SLUG="${AUTHENTIK_OIDC_APP_SLUG:-fluxo-caixa}"
AUTHENTIK_READY_ATTEMPTS="${AUTHENTIK_READY_ATTEMPTS:-90}"
AUTHENTIK_READY_DELAY="${AUTHENTIK_READY_DELAY:-5}"
# 360 × 5s = 1800s — matches Job activeDeadlineSeconds (avoid polling a dead Job).
AUTHENTIK_BOOTSTRAP_ATTEMPTS="${AUTHENTIK_BOOTSTRAP_ATTEMPTS:-360}"
AUTHENTIK_BOOTSTRAP_DELAY="${AUTHENTIK_BOOTSTRAP_DELAY:-5}"
# Tuned for first Authentik install (image pull + DB migrations); upgrades are usually faster.
AUTHENTIK_HELM_TIMEOUT="${AUTHENTIK_HELM_TIMEOUT:-20m}"
AUTHENTIK_PG_HOST="${AUTHENTIK_PG_HOST:-fluxo-pg-rw.database.svc.cluster.local}"
AUTHENTIK_PG_NAME="${AUTHENTIK_PG_NAME:-authentik}"
AUTHENTIK_PG_PORT="${AUTHENTIK_PG_PORT:-5432}"

OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
OBSERVABILITY_MANIFESTS="${REPO_ROOT}/deploy/observability"
PROMETHEUS_RELEASE="${PROMETHEUS_RELEASE:-prometheus}"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-27.16.0}"
PROMETHEUS_VALUES="${REPO_ROOT}/deploy/observability/prometheus-values.yaml"
TEMPO_RELEASE="${TEMPO_RELEASE:-tempo}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-1.16.0}"
TEMPO_VALUES="${REPO_ROOT}/deploy/observability/tempo-values.yaml"
LOKI_RELEASE="${LOKI_RELEASE:-loki}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-6.16.0}"
LOKI_VALUES="${REPO_ROOT}/deploy/observability/loki-values.yaml"
OTEL_RELEASE="${OTEL_RELEASE:-otel-collector}"
OTEL_CHART_VERSION="${OTEL_CHART_VERSION:-0.108.0}"
OTEL_VALUES="${REPO_ROOT}/deploy/observability/otel-collector-values.yaml"
GRAFANA_RELEASE="${GRAFANA_RELEASE:-grafana}"
GRAFANA_CHART_VERSION="${GRAFANA_CHART_VERSION:-8.8.0}"
GRAFANA_VALUES="${REPO_ROOT}/deploy/observability/grafana-values.yaml"
OBSERVABILITY_READY_ATTEMPTS="${OBSERVABILITY_READY_ATTEMPTS:-90}"
OBSERVABILITY_READY_DELAY="${OBSERVABILITY_READY_DELAY:-5}"

KRAKEND_MANIFESTS="${REPO_ROOT}/deploy/krakend"
KRAKEND_READY_ATTEMPTS="${KRAKEND_READY_ATTEMPTS:-60}"
KRAKEND_READY_DELAY="${KRAKEND_READY_DELAY:-5}"

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
  kubectl_apply_k "${CERT_MANAGER_MANIFESTS}"
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
  kubectl_apply_k "${NATS_BOOTSTRAP_MANIFESTS}"
  wait_for_nats_bootstrap
}

deploy_nats_stack() {
  deploy_nats_helm
  run_nats_bootstrap
  log_info "JetStream streams/consumers provisioned (lancamentos_events, lancamentos_dlq, consolidado-workers)"
}

deploy_cnpg_operator() {
  ensure_helm
  ensure_namespace "${CNPG_OPERATOR_NAMESPACE}"

  log_info "helm upgrade --install ${CNPG_OPERATOR_RELEASE} cloudnative-pg (chart ${CNPG_OPERATOR_CHART_VERSION})"
  helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
  helm repo update cnpg >/dev/null

  helm upgrade --install "${CNPG_OPERATOR_RELEASE}" cnpg/cloudnative-pg \
    --namespace "${CNPG_OPERATOR_NAMESPACE}" \
    --version "${CNPG_OPERATOR_CHART_VERSION}" \
    --wait \
    --timeout 10m
}

cnpg_operator_ready() {
  local ready desired
  ready="$(kubectl_cmd -n "${CNPG_OPERATOR_NAMESPACE}" get deploy \
    -l app.kubernetes.io/name=cloudnative-pg \
    -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  desired="$(kubectl_cmd -n "${CNPG_OPERATOR_NAMESPACE}" get deploy \
    -l app.kubernetes.io/name=cloudnative-pg \
    -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  [[ "${desired}" -ge 1 && "${ready}" -ge "${desired}" ]]
}

wait_for_cnpg_operator() {
  log_info "waiting for CloudNativePG operator in ${CNPG_OPERATOR_NAMESPACE}..."
  retry "${POSTGRES_READY_ATTEMPTS}" "${POSTGRES_READY_DELAY}" cnpg_operator_ready
  log_info "CloudNativePG operator is ready"
}

postgres_cluster_healthy() {
  local phase
  phase="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get cluster "${POSTGRES_CLUSTER}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Cluster in healthy state" ]]
}

wait_for_postgres_cluster() {
  log_info "waiting for Cluster/${POSTGRES_CLUSTER} in ${POSTGRES_NAMESPACE}..."
  retry "${POSTGRES_READY_ATTEMPTS}" "${POSTGRES_READY_DELAY}" postgres_cluster_healthy
  log_info "PostgreSQL cluster ${POSTGRES_CLUSTER} is healthy"
}

apply_postgres_cluster() {
  if [[ ! -f "${POSTGRES_MANIFESTS}/cluster.yaml" ]]; then
    log_error "PostgreSQL cluster manifest not found: ${POSTGRES_MANIFESTS}/cluster.yaml"
    exit 1
  fi

  ensure_namespace "${POSTGRES_NAMESPACE}"
  log_info "applying Cluster/${POSTGRES_CLUSTER} in ${POSTGRES_NAMESPACE}"
  kubectl_cmd apply -f "${POSTGRES_MANIFESTS}/cluster.yaml" -n "${POSTGRES_NAMESPACE}"
  wait_for_postgres_cluster
}

postgres_bootstrap_job_complete() {
  local status
  status="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get job pg-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

wait_for_postgres_bootstrap() {
  log_info "waiting for Job/pg-bootstrap in ${POSTGRES_NAMESPACE}..."
  retry "${POSTGRES_BOOTSTRAP_ATTEMPTS}" "${POSTGRES_BOOTSTRAP_DELAY}" postgres_bootstrap_job_complete
  log_info "pg-bootstrap job completed"
}

run_postgres_bootstrap() {
  log_info "running pg-bootstrap job"
  wait_for_postgres_secrets
  kubectl_cmd delete job pg-bootstrap -n "${POSTGRES_NAMESPACE}" --ignore-not-found
  kubectl_apply_k "${POSTGRES_MANIFESTS}"
  wait_for_postgres_bootstrap
}

deploy_postgres_stack() {
  deploy_cnpg_operator
  wait_for_cnpg_operator
  apply_postgres_cluster
  run_postgres_bootstrap
  log_info "PostgreSQL ready — schemas lancamentos/consolidado (RLS stubs via apply_rls_stubs)"
}

redis_auth_secret_ready() {
  kubectl_cmd -n "${REDIS_NAMESPACE}" get secret fluxo-redis >/dev/null 2>&1
}

ensure_redis_auth_secret() {
  if redis_auth_secret_ready; then
    log_info "secret exists: fluxo-redis (${REDIS_NAMESPACE})"
    return 0
  fi

  local password url
  password="${REDIS_PASSWORD:-$(openssl rand -base64 24)}"
  url="redis://:${password}@redis-master.${REDIS_NAMESPACE}.svc.cluster.local:6379/0"

  log_info "creating secret fluxo-redis in ${REDIS_NAMESPACE}"
  kubectl_cmd -n "${REDIS_NAMESPACE}" create secret generic fluxo-redis \
    --from-literal=redis-password="${password}" \
    --from-literal=redis-url="${url}"
}

redis_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${REDIS_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=redis,app.kubernetes.io/instance=${REDIS_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${REDIS_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=redis,app.kubernetes.io/instance=${REDIS_RELEASE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

wait_for_redis() {
  log_info "waiting for Redis pods in ${REDIS_NAMESPACE}..."
  retry "${REDIS_READY_ATTEMPTS}" "${REDIS_READY_DELAY}" redis_pods_ready
  log_info "Redis is ready"
}

deploy_redis_helm() {
  ensure_helm
  ensure_namespace "${REDIS_NAMESPACE}"

  if [[ ! -f "${REDIS_VALUES}" ]]; then
    log_error "Redis values not found: ${REDIS_VALUES}"
    exit 1
  fi

  ensure_redis_auth_secret

  log_info "helm upgrade --install ${REDIS_RELEASE} bitnami/redis (chart ${REDIS_CHART_VERSION})"
  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  helm repo update bitnami >/dev/null

  helm upgrade --install "${REDIS_RELEASE}" bitnami/redis \
    --namespace "${REDIS_NAMESPACE}" \
    --version "${REDIS_CHART_VERSION}" \
    --values "${REDIS_VALUES}" \
    --wait \
    --timeout 10m

  wait_for_redis
}

apply_redis_connection_config() {
  if [[ ! -d "${REDIS_MANIFESTS}" ]]; then
    log_error "Redis manifests not found: ${REDIS_MANIFESTS}"
    exit 1
  fi

  log_info "applying redis-connection ConfigMap from ${REDIS_MANIFESTS}"
  kubectl_apply_k "${REDIS_MANIFESTS}"
}

deploy_redis_stack() {
  deploy_redis_helm
  apply_redis_connection_config
  log_info "Redis ready — standalone cache (256MB allkeys-lru, no persistence)"
}

authentik_auth_secret_ready() {
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get secret fluxo-authentik >/dev/null 2>&1
}

authentik_pg_secret_ready() {
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get secret fluxo-authentik-pg >/dev/null 2>&1
}

read_fluxo_pg_app_credentials() {
  FLUXO_PG_APP_USER="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get secret fluxo-pg-app \
    -o jsonpath='{.data.username}' | base64 -d)"
  FLUXO_PG_APP_PASSWORD="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get secret fluxo-pg-app \
    -o jsonpath='{.data.password}' | base64 -d)"
}

ensure_authentik_pg_secret() {
  log_info "waiting for CNPG app secret fluxo-pg-app in ${POSTGRES_NAMESPACE}..."
  retry "${POSTGRES_READY_ATTEMPTS}" "${POSTGRES_READY_DELAY}" fluxo_pg_app_secret_ready
  read_fluxo_pg_app_credentials

  if authentik_pg_secret_ready; then
    log_info "secret exists: fluxo-authentik-pg (${AUTHENTIK_NAMESPACE})"
    return 0
  fi

  log_info "creating secret fluxo-authentik-pg in ${AUTHENTIK_NAMESPACE}"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" create secret generic fluxo-authentik-pg \
    --from-literal=username="${FLUXO_PG_APP_USER}" \
    --from-literal=password="${FLUXO_PG_APP_PASSWORD}"
}

authentik_secret_has_postgres_config() {
  local raw host name user password port
  raw="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get secret fluxo-authentik \
    -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__HOST},{.data.AUTHENTIK_POSTGRESQL__NAME},{.data.AUTHENTIK_POSTGRESQL__USER},{.data.AUTHENTIK_POSTGRESQL__PASSWORD},{.data.AUTHENTIK_POSTGRESQL__PORT}' 2>/dev/null || true)"
  IFS=',' read -r host name user password port <<< "${raw}"
  host="$(printf '%s' "${host}" | base64 -d 2>/dev/null || true)"
  name="$(printf '%s' "${name}" | base64 -d 2>/dev/null || true)"
  user="$(printf '%s' "${user}" | base64 -d 2>/dev/null || true)"
  password="$(printf '%s' "${password}" | base64 -d 2>/dev/null || true)"
  port="$(printf '%s' "${port}" | base64 -d 2>/dev/null || true)"
  [[ -n "${host}" && -n "${name}" && -n "${user}" && -n "${password}" && -n "${port}" ]]
}

patch_authentik_postgres_secret_keys() {
  local encoded_host encoded_name encoded_user encoded_password encoded_port
  encoded_host="$(printf '%s' "${AUTHENTIK_PG_HOST}" | base64 -w 0 2>/dev/null || printf '%s' "${AUTHENTIK_PG_HOST}" | base64)"
  encoded_name="$(printf '%s' "${AUTHENTIK_PG_NAME}" | base64 -w 0 2>/dev/null || printf '%s' "${AUTHENTIK_PG_NAME}" | base64)"
  encoded_user="$(printf '%s' "file:///pg-creds/username" | base64 -w 0 2>/dev/null || printf '%s' "file:///pg-creds/username" | base64)"
  encoded_password="$(printf '%s' "file:///pg-creds/password" | base64 -w 0 2>/dev/null || printf '%s' "file:///pg-creds/password" | base64)"
  encoded_port="$(printf '%s' "${AUTHENTIK_PG_PORT}" | base64 -w 0 2>/dev/null || printf '%s' "${AUTHENTIK_PG_PORT}" | base64)"

  log_info "patching fluxo-authentik with CNPG PostgreSQL env (existingSecret mode ignores values.yaml authentik.postgresql)"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" patch secret fluxo-authentik --type merge \
    -p "{\"data\":{\"AUTHENTIK_POSTGRESQL__HOST\":\"${encoded_host}\",\"AUTHENTIK_POSTGRESQL__NAME\":\"${encoded_name}\",\"AUTHENTIK_POSTGRESQL__USER\":\"${encoded_user}\",\"AUTHENTIK_POSTGRESQL__PASSWORD\":\"${encoded_password}\",\"AUTHENTIK_POSTGRESQL__PORT\":\"${encoded_port}\"}}"
}

ensure_authentik_auth_secret() {
  if authentik_auth_secret_ready; then
    log_info "secret exists: fluxo-authentik (${AUTHENTIK_NAMESPACE})"
    if authentik_secret_has_postgres_config; then
      return 0
    fi
    patch_authentik_postgres_secret_keys
    return 0
  fi

  local secret_key bootstrap_password bootstrap_token
  secret_key="${AUTHENTIK_SECRET_KEY:-$(openssl rand -base64 48)}"
  bootstrap_password="${AUTHENTIK_BOOTSTRAP_PASSWORD:-$(openssl rand -base64 24)}"
  bootstrap_token="${AUTHENTIK_BOOTSTRAP_TOKEN:-$(openssl rand -hex 32)}"

  log_info "creating secret fluxo-authentik in ${AUTHENTIK_NAMESPACE}"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" create secret generic fluxo-authentik \
    --from-literal=AUTHENTIK_SECRET_KEY="${secret_key}" \
    --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="${bootstrap_password}" \
    --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="${bootstrap_token}" \
    --from-literal=AUTHENTIK_POSTGRESQL__HOST="${AUTHENTIK_PG_HOST}" \
    --from-literal=AUTHENTIK_POSTGRESQL__NAME="${AUTHENTIK_PG_NAME}" \
    --from-literal=AUTHENTIK_POSTGRESQL__USER="file:///pg-creds/username" \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="file:///pg-creds/password" \
    --from-literal=AUTHENTIK_POSTGRESQL__PORT="${AUTHENTIK_PG_PORT}"
}

log_authentik_helm_progress() {
  local interval="${AUTHENTIK_HELM_PROGRESS_INTERVAL:-30}"
  while sleep "${interval}"; do
    kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get pods \
      -l "app.kubernetes.io/name=authentik,app.kubernetes.io/instance=${AUTHENTIK_RELEASE}" \
      --no-headers 2>/dev/null || true
  done
}

authentik_server_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=authentik,app.kubernetes.io/component=server,app.kubernetes.io/instance=${AUTHENTIK_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=authentik,app.kubernetes.io/component=server,app.kubernetes.io/instance=${AUTHENTIK_RELEASE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

authentik_health_ready() {
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" delete pod authentik-health-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" run authentik-health-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${AUTHENTIK_SERVER_URL}/-/health/ready/" >/dev/null 2>&1
}

wait_for_authentik() {
  log_info "waiting for Authentik server pods in ${AUTHENTIK_NAMESPACE}..."
  retry "${AUTHENTIK_READY_ATTEMPTS}" "${AUTHENTIK_READY_DELAY}" authentik_server_pods_ready
  log_info "waiting for Authentik /-/health/ready/..."
  retry "${AUTHENTIK_READY_ATTEMPTS}" "${AUTHENTIK_READY_DELAY}" authentik_health_ready
  log_info "Authentik is ready"
}

deploy_authentik_helm() {
  ensure_helm
  ensure_namespace "${AUTHENTIK_NAMESPACE}"

  if [[ ! -f "${AUTHENTIK_VALUES}" ]]; then
    log_error "Authentik values not found: ${AUTHENTIK_VALUES}"
    exit 1
  fi

  ensure_authentik_pg_secret
  ensure_authentik_auth_secret

  log_info "helm upgrade --install ${AUTHENTIK_RELEASE} authentik/authentik (chart ${AUTHENTIK_CHART_VERSION}, timeout ${AUTHENTIK_HELM_TIMEOUT})"
  log_info "Authentik first install: image pull + DB migrations can take several minutes; pod status logged every ${AUTHENTIK_HELM_PROGRESS_INTERVAL:-30}s"
  helm repo add authentik https://charts.goauthentik.io >/dev/null 2>&1 || true
  helm repo update authentik >/dev/null

  local progress_pid=""
  cleanup_authentik_helm_progress() {
    if [[ -n "${progress_pid}" ]]; then
      kill "${progress_pid}" 2>/dev/null || true
      wait "${progress_pid}" 2>/dev/null || true
      progress_pid=""
    fi
  }
  trap cleanup_authentik_helm_progress EXIT

  log_authentik_helm_progress &
  progress_pid=$!

  if ! helm upgrade --install "${AUTHENTIK_RELEASE}" authentik/authentik \
    --namespace "${AUTHENTIK_NAMESPACE}" \
    --version "${AUTHENTIK_CHART_VERSION}" \
    --values "${AUTHENTIK_VALUES}" \
    --wait \
    --timeout "${AUTHENTIK_HELM_TIMEOUT}"; then
    cleanup_authentik_helm_progress
    trap - EXIT
    log_error "Authentik Helm release failed — inspect: kubectl -n ${AUTHENTIK_NAMESPACE} get pods,logs deploy/authentik-server"
    return 1
  fi

  cleanup_authentik_helm_progress
  trap - EXIT

  wait_for_authentik
}

authentik_bootstrap_token_valid() {
  local token
  token="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get secret fluxo-authentik \
    -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "${token}" ]] || return 1

  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" delete pod authentik-token-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" run authentik-token-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf -H "Authorization: Bearer ${token}" \
    "${AUTHENTIK_SERVER_URL}/api/v3/core/users/me/" >/dev/null 2>&1
}

authentik_server_pod() {
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=authentik,app.kubernetes.io/component=server,app.kubernetes.io/instance=${AUTHENTIK_RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

ensure_authentik_bootstrap_token() {
  if authentik_bootstrap_token_valid; then
    log_info "Authentik bootstrap API token is valid"
    return 0
  fi

  local pod token encoded_token
  pod="$(authentik_server_pod)"
  if [[ -z "${pod}" ]]; then
    log_error "Authentik server pod not found in ${AUTHENTIK_NAMESPACE}"
    return 1
  fi

  log_info "creating Authentik bootstrap API token via ak shell in ${pod}"
  token="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" exec "${pod}" -- ak shell -c "
from authentik.core.models import Token, User
user = User.objects.filter(username='akadmin').first()
if user is None:
    raise SystemExit('akadmin user not found')
api_token, _ = Token.objects.get_or_create(
    identifier='fluxo-bootstrap',
    defaults={'user': user, 'intent': Token.INTENT_API},
)
print(api_token.key)
" 2>/dev/null | tail -n 1)"
  [[ -n "${token}" ]] || {
    log_error "failed to create Authentik bootstrap API token"
    return 1
  }

  encoded_token="$(printf '%s' "${token}" | base64 -w 0 2>/dev/null || printf '%s' "${token}" | base64)"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" patch secret fluxo-authentik --type merge \
    -p "{\"data\":{\"AUTHENTIK_BOOTSTRAP_TOKEN\":\"${encoded_token}\"}}"
  log_info "patched fluxo-authentik with bootstrap API token"
}

authentik_bootstrap_job_complete() {
  local status
  status="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get job authentik-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

log_authentik_bootstrap_job_failure() {
  local pod status
  status="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get job authentik-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].message}' 2>/dev/null || true)"
  pod="$(kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" get pods \
    -l "job-name=authentik-bootstrap" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
  log_error "Job/authentik-bootstrap did not complete in ${AUTHENTIK_NAMESPACE}"
  [[ -n "${status}" ]] && log_error "job status: ${status}"
  if [[ -n "${pod}" ]]; then
    log_error "latest pod logs (${pod}):"
    kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" logs "${pod}" --tail=80 2>/dev/null || true
  fi
}

wait_for_authentik_bootstrap() {
  log_info "waiting for Job/authentik-bootstrap in ${AUTHENTIK_NAMESPACE}..."
  if ! retry "${AUTHENTIK_BOOTSTRAP_ATTEMPTS}" "${AUTHENTIK_BOOTSTRAP_DELAY}" authentik_bootstrap_job_complete; then
    log_authentik_bootstrap_job_failure
    return 1
  fi
  log_info "authentik-bootstrap job completed"
}

run_authentik_bootstrap() {
  if [[ ! -d "${AUTHENTIK_MANIFESTS}" ]]; then
    log_error "Authentik bootstrap manifests not found: ${AUTHENTIK_MANIFESTS}"
    exit 1
  fi

  ensure_authentik_bootstrap_token

  log_info "applying authentik-bootstrap manifests from ${AUTHENTIK_MANIFESTS}"
  kubectl_cmd delete job authentik-bootstrap -n "${AUTHENTIK_NAMESPACE}" --ignore-not-found
  kubectl_cmd delete configmap authentik-bootstrap -n "${AUTHENTIK_NAMESPACE}" --ignore-not-found
  kubectl_apply_k "${AUTHENTIK_MANIFESTS}"
  wait_for_authentik_bootstrap
}

authentik_oidc_discovery_url() {
  echo "${AUTHENTIK_SERVER_URL}/application/o/${AUTHENTIK_OIDC_APP_SLUG}/.well-known/openid-configuration"
}

authentik_oidc_discovery_ok() {
  local url
  url="$(authentik_oidc_discovery_url)"
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" delete pod authentik-oidc-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${AUTHENTIK_NAMESPACE}" run authentik-oidc-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${url}" | grep -q '"issuer"' >/dev/null 2>&1
}

wait_for_authentik_oidc() {
  local url
  url="$(authentik_oidc_discovery_url)"
  log_info "waiting for Authentik OIDC discovery at ${url}..."
  if ! retry "${AUTHENTIK_READY_ATTEMPTS}" "${AUTHENTIK_READY_DELAY}" authentik_oidc_discovery_ok; then
    log_error "Authentik OIDC discovery unreachable at ${url} (application ${AUTHENTIK_OIDC_APP_SLUG})"
    return 1
  fi
  log_info "Authentik OIDC discovery OK — issuer present for ${AUTHENTIK_OIDC_APP_SLUG}"
}

deploy_authentik_stack() {
  deploy_authentik_helm
  run_authentik_bootstrap
  wait_for_authentik_oidc
  log_info "Authentik ready — application ${AUTHENTIK_OIDC_APP_SLUG} OIDC configured (CNPG DB authentik on ${POSTGRES_CLUSTER})"
}

fluxo_pg_app_secret_ready() {
  kubectl_cmd -n "${POSTGRES_NAMESPACE}" get secret fluxo-pg-app >/dev/null 2>&1
}

fluxo_pg_superuser_secret_ready() {
  kubectl_cmd -n "${POSTGRES_NAMESPACE}" get secret fluxo-pg-superuser >/dev/null 2>&1
}

wait_for_postgres_secrets() {
  log_info "waiting for CNPG secrets fluxo-pg-app and fluxo-pg-superuser in ${POSTGRES_NAMESPACE}..."
  retry "${POSTGRES_READY_ATTEMPTS}" "${POSTGRES_READY_DELAY}" fluxo_pg_app_secret_ready
  retry "${POSTGRES_READY_ATTEMPTS}" "${POSTGRES_READY_DELAY}" fluxo_pg_superuser_secret_ready
}

krakend_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${GATEWAY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=krakend" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${GATEWAY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=krakend" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

wait_for_krakend_pods() {
  log_info "waiting for KrakenD pods in ${GATEWAY_NAMESPACE}..."
  retry "${KRAKEND_READY_ATTEMPTS}" "${KRAKEND_READY_DELAY}" krakend_pods_ready
  log_info "KrakenD pods are ready"
}

krakend_health_ok() {
  kubectl_cmd -n "${GATEWAY_NAMESPACE}" delete pod krakend-health-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${GATEWAY_NAMESPACE}" run krakend-health-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -skf "https://krakend.${GATEWAY_NAMESPACE}.svc.cluster.local:8080/__health" >/dev/null 2>&1
}

wait_for_krakend_health() {
  log_info "waiting for KrakenD GET /__health..."
  retry "${KRAKEND_READY_ATTEMPTS}" "${KRAKEND_READY_DELAY}" krakend_health_ok
  log_info "KrakenD /__health OK"
}

apply_krakend_manifests() {
  if [[ ! -d "${KRAKEND_MANIFESTS}" ]]; then
    log_error "KrakenD manifests not found: ${KRAKEND_MANIFESTS}"
    exit 1
  fi

  if ! krakend_tls_secret_exists; then
    log_error "TLS secret ${KRAKEND_TLS_SECRET} missing in ${GATEWAY_NAMESPACE} (run deploy_cert_manager_stack first)"
    exit 1
  fi

  log_info "applying KrakenD manifests from ${KRAKEND_MANIFESTS}"
  kubectl_apply_k "${KRAKEND_MANIFESTS}"
}

deploy_krakend_stack() {
  apply_krakend_manifests
  wait_for_krakend_pods
  wait_for_krakend_health
  log_info "KrakenD ready — NodePort 30443, GET /__health OK (JWT JWKS Authentik OIDC, routes stubbed)"
}

observability_workloads_ready() {
  local ready desired
  ready="$(kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" get deploy,statefulset \
    -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  desired="$(kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" get deploy,statefulset \
    -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  [[ "${desired}" -ge 4 && "${ready}" -ge "${desired}" ]]
}

wait_for_observability_workloads() {
  log_info "waiting for observability workloads in ${OBSERVABILITY_NAMESPACE}..."
  retry "${OBSERVABILITY_READY_ATTEMPTS}" "${OBSERVABILITY_READY_DELAY}" observability_workloads_ready
  log_info "observability workloads are ready"
}

prometheus_ready() {
  kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" delete pod prom-ready-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" run prom-ready-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://prometheus-server.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:80/-/ready" >/dev/null 2>&1
}

grafana_ready() {
  kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" delete pod grafana-ready-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" run grafana-ready-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://grafana.${OBSERVABILITY_NAMESPACE}.svc.cluster.local/api/health" >/dev/null 2>&1
}

otel_collector_ready() {
  kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" delete pod otel-ready-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${OBSERVABILITY_NAMESPACE}" run otel-ready-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://otel-collector.${OBSERVABILITY_NAMESPACE}.svc.cluster.local:13133/" >/dev/null 2>&1
}

wait_for_observability_endpoints() {
  log_info "waiting for Prometheus /-/ready..."
  retry "${OBSERVABILITY_READY_ATTEMPTS}" "${OBSERVABILITY_READY_DELAY}" prometheus_ready
  log_info "waiting for Grafana /api/health..."
  retry "${OBSERVABILITY_READY_ATTEMPTS}" "${OBSERVABILITY_READY_DELAY}" grafana_ready
  log_info "waiting for OTel Collector health..."
  retry "${OBSERVABILITY_READY_ATTEMPTS}" "${OBSERVABILITY_READY_DELAY}" otel_collector_ready
  log_info "observability endpoints healthy"
}

deploy_loki_helm() {
  ensure_helm
  ensure_namespace "${OBSERVABILITY_NAMESPACE}"

  if [[ ! -f "${LOKI_VALUES}" ]]; then
    log_error "Loki values not found: ${LOKI_VALUES}"
    exit 1
  fi

  log_info "helm upgrade --install ${LOKI_RELEASE} grafana/loki (chart ${LOKI_CHART_VERSION})"
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null

  helm upgrade --install "${LOKI_RELEASE}" grafana/loki \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    --version "${LOKI_CHART_VERSION}" \
    --values "${LOKI_VALUES}" \
    --wait \
    --timeout 10m
}

deploy_tempo_helm() {
  ensure_helm
  ensure_namespace "${OBSERVABILITY_NAMESPACE}"

  if [[ ! -f "${TEMPO_VALUES}" ]]; then
    log_error "Tempo values not found: ${TEMPO_VALUES}"
    exit 1
  fi

  log_info "helm upgrade --install ${TEMPO_RELEASE} grafana/tempo (chart ${TEMPO_CHART_VERSION})"
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null

  helm upgrade --install "${TEMPO_RELEASE}" grafana/tempo \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    --version "${TEMPO_CHART_VERSION}" \
    --values "${TEMPO_VALUES}" \
    --wait \
    --timeout 10m
}

deploy_prometheus_helm() {
  ensure_helm
  ensure_namespace "${OBSERVABILITY_NAMESPACE}"

  if [[ ! -f "${PROMETHEUS_VALUES}" ]]; then
    log_error "Prometheus values not found: ${PROMETHEUS_VALUES}"
    exit 1
  fi

  log_info "helm upgrade --install ${PROMETHEUS_RELEASE} prometheus-community/prometheus (chart ${PROMETHEUS_CHART_VERSION})"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null

  helm upgrade --install "${PROMETHEUS_RELEASE}" prometheus-community/prometheus \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    --version "${PROMETHEUS_CHART_VERSION}" \
    --values "${PROMETHEUS_VALUES}" \
    --wait \
    --timeout 10m
}

deploy_otel_collector_helm() {
  ensure_helm
  ensure_namespace "${OBSERVABILITY_NAMESPACE}"

  if [[ ! -f "${OTEL_VALUES}" ]]; then
    log_error "OTel Collector values not found: ${OTEL_VALUES}"
    exit 1
  fi

  log_info "helm upgrade --install ${OTEL_RELEASE} open-telemetry/opentelemetry-collector (chart ${OTEL_CHART_VERSION})"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update open-telemetry >/dev/null

  helm upgrade --install "${OTEL_RELEASE}" open-telemetry/opentelemetry-collector \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    --version "${OTEL_CHART_VERSION}" \
    --values "${OTEL_VALUES}" \
    --wait \
    --timeout 10m
}

deploy_grafana_helm() {
  ensure_helm
  ensure_namespace "${OBSERVABILITY_NAMESPACE}"

  if [[ ! -f "${GRAFANA_VALUES}" ]]; then
    log_error "Grafana values not found: ${GRAFANA_VALUES}"
    exit 1
  fi

  log_info "helm upgrade --install ${GRAFANA_RELEASE} grafana/grafana (chart ${GRAFANA_CHART_VERSION})"
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null

  helm upgrade --install "${GRAFANA_RELEASE}" grafana/grafana \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    --version "${GRAFANA_CHART_VERSION}" \
    --values "${GRAFANA_VALUES}" \
    --wait \
    --timeout 10m
}

apply_observability_connection_config() {
  if [[ ! -d "${OBSERVABILITY_MANIFESTS}" ]]; then
    log_error "Observability manifests not found: ${OBSERVABILITY_MANIFESTS}"
    exit 1
  fi

  log_info "applying otel-connection ConfigMap from ${OBSERVABILITY_MANIFESTS}"
  kubectl_apply_k "${OBSERVABILITY_MANIFESTS}"
}

deploy_observability_stack() {
  deploy_loki_helm
  deploy_tempo_helm
  deploy_prometheus_helm
  deploy_otel_collector_helm
  deploy_grafana_helm
  wait_for_observability_workloads
  wait_for_observability_endpoints
  apply_observability_connection_config
  log_info "Observability ready — OTel Collector, Prometheus, Grafana, Tempo, Loki (namespace ${OBSERVABILITY_NAMESPACE})"
}

main() {
  log_info "deploy-platform.sh — CLUSTER_TYPE=${CLUSTER_TYPE}"
  configure_kubeconfig
  deploy_cert_manager_stack
  deploy_nats_stack
  deploy_postgres_stack
  deploy_redis_stack
  deploy_authentik_stack
  deploy_krakend_stack
  deploy_observability_stack
  log_info "deploy-platform.sh — complete"
}

main "$@"
