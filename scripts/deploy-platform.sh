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

ORY_NAMESPACE="${ORY_NAMESPACE:-security}"
KRATOS_RELEASE="${KRATOS_RELEASE:-kratos}"
HYDRA_RELEASE="${HYDRA_RELEASE:-hydra}"
KRATOS_CHART_VERSION="${KRATOS_CHART_VERSION:-0.58.0}"
HYDRA_CHART_VERSION="${HYDRA_CHART_VERSION:-0.58.0}"
KRATOS_VALUES="${REPO_ROOT}/deploy/ory/kratos-values.yaml"
HYDRA_VALUES="${REPO_ROOT}/deploy/ory/hydra-values.yaml"
ORY_MANIFESTS="${REPO_ROOT}/deploy/ory"
HYDRA_PUBLIC_URL="${HYDRA_PUBLIC_URL:-http://hydra-public.security.svc.cluster.local:4444}"
HYDRA_ADMIN_URL="${HYDRA_ADMIN_URL:-http://hydra-admin.security.svc.cluster.local:4445}"
KRATOS_PUBLIC_URL="${KRATOS_PUBLIC_URL:-http://kratos-public.security.svc.cluster.local:4433}"
KRATOS_ADMIN_URL="${KRATOS_ADMIN_URL:-http://kratos-admin.security.svc.cluster.local:4434}"
ORY_READY_ATTEMPTS="${ORY_READY_ATTEMPTS:-90}"
ORY_READY_DELAY="${ORY_READY_DELAY:-5}"
# 360 × 5s = 1800s — matches Job activeDeadlineSeconds (avoid polling a dead Job).
ORY_BOOTSTRAP_ATTEMPTS="${ORY_BOOTSTRAP_ATTEMPTS:-360}"
ORY_BOOTSTRAP_DELAY="${ORY_BOOTSTRAP_DELAY:-5}"
ORY_HELM_TIMEOUT="${ORY_HELM_TIMEOUT:-20m}"
ORY_HELM_PROGRESS_INTERVAL="${ORY_HELM_PROGRESS_INTERVAL:-30}"
ORY_PG_HOST="${ORY_PG_HOST:-fluxo-pg-rw.database.svc.cluster.local}"
KRATOS_PG_NAME="${KRATOS_PG_NAME:-kratos}"
HYDRA_PG_NAME="${HYDRA_PG_NAME:-hydra}"
ORY_PG_PORT="${ORY_PG_PORT:-5432}"

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

ory_pg_secret_ready() {
  kubectl_cmd -n "${ORY_NAMESPACE}" get secret fluxo-ory-pg >/dev/null 2>&1
}

kratos_secret_ready() {
  kubectl_cmd -n "${ORY_NAMESPACE}" get secret fluxo-kratos >/dev/null 2>&1
}

hydra_secret_ready() {
  kubectl_cmd -n "${ORY_NAMESPACE}" get secret fluxo-hydra >/dev/null 2>&1
}

read_fluxo_pg_app_credentials() {
  FLUXO_PG_APP_USER="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get secret fluxo-pg-app \
    -o jsonpath='{.data.username}' | base64 -d)"
  FLUXO_PG_APP_PASSWORD="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get secret fluxo-pg-app \
    -o jsonpath='{.data.password}' | base64 -d)"
}

ory_postgres_dsn() {
  local db_name="$1"
  local user encoded_user encoded_password
  user="${FLUXO_PG_APP_USER}"
  encoded_user="$(urlencode_component "${user}")"
  encoded_password="$(urlencode_component "${FLUXO_PG_APP_PASSWORD}")"
  printf 'postgres://%s:%s@%s:%s/%s?sslmode=disable' \
    "${encoded_user}" "${encoded_password}" "${ORY_PG_HOST}" "${ORY_PG_PORT}" "${db_name}"
}

read_ory_secret_literal() {
  local secret_name="$1"
  local key="$2"
  local fallback="$3"
  local value=""
  value="$(kubectl_cmd -n "${ORY_NAMESPACE}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    printf '%s' "${fallback}"
  fi
}

apply_ory_secret() {
  local secret_name="$1"
  shift
  log_info "applying secret ${secret_name} in ${ORY_NAMESPACE}"
  # shellcheck disable=SC2068
  kubectl_cmd -n "${ORY_NAMESPACE}" create secret generic "${secret_name}" \
    "$@" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -
}

ensure_ory_pg_secret() {
  log_info "waiting for CNPG app secret fluxo-pg-app in ${POSTGRES_NAMESPACE}..."
  retry "${POSTGRES_READY_ATTEMPTS}" "${POSTGRES_READY_DELAY}" fluxo_pg_app_secret_ready
  read_fluxo_pg_app_credentials

  if ory_pg_secret_ready; then
    log_info "secret exists: fluxo-ory-pg (${ORY_NAMESPACE})"
    return 0
  fi

  log_info "creating secret fluxo-ory-pg in ${ORY_NAMESPACE}"
  kubectl_cmd -n "${ORY_NAMESPACE}" create secret generic fluxo-ory-pg \
    --from-literal=username="${FLUXO_PG_APP_USER}" \
    --from-literal=password="${FLUXO_PG_APP_PASSWORD}"
}

ensure_kratos_secret() {
  local dsn secrets_default secrets_cookie secrets_cipher smtp_connection_uri
  local default_smtp_uri="smtps://unused:unused@127.0.0.1:65534/?skip_ssl_verify=true"
  dsn="$(ory_postgres_dsn "${KRATOS_PG_NAME}")"

  if kratos_secret_ready; then
    secrets_default="$(read_ory_secret_literal fluxo-kratos secretsDefault \
      "${KRATOS_SECRETS_DEFAULT:-$(openssl rand -base64 32),$(openssl rand -base64 32)}")"
    secrets_cookie="$(read_ory_secret_literal fluxo-kratos secretsCookie \
      "${KRATOS_SECRETS_COOKIE:-$(openssl rand -base64 32)}")"
    secrets_cipher="$(read_ory_secret_literal fluxo-kratos secretsCipher \
      "${KRATOS_SECRETS_CIPHER:-$(openssl rand -base64 32)}")"
    smtp_connection_uri="$(read_ory_secret_literal fluxo-kratos smtpConnectionURI \
      "${KRATOS_SMTP_CONNECTION_URI:-${default_smtp_uri}}")"
  else
    secrets_default="${KRATOS_SECRETS_DEFAULT:-$(openssl rand -base64 32),$(openssl rand -base64 32)}"
    secrets_cookie="${KRATOS_SECRETS_COOKIE:-$(openssl rand -base64 32)}"
    secrets_cipher="${KRATOS_SECRETS_CIPHER:-$(openssl rand -base64 32)}"
    smtp_connection_uri="${KRATOS_SMTP_CONNECTION_URI:-${default_smtp_uri}}"
  fi

  apply_ory_secret fluxo-kratos \
    --from-literal=dsn="${dsn}" \
    --from-literal=secretsDefault="${secrets_default}" \
    --from-literal=secretsCookie="${secrets_cookie}" \
    --from-literal=secretsCipher="${secrets_cipher}" \
    --from-literal=smtpConnectionURI="${smtp_connection_uri}"
}

ensure_hydra_secret() {
  local dsn secrets_system secrets_cookie
  dsn="$(ory_postgres_dsn "${HYDRA_PG_NAME}")"

  if hydra_secret_ready; then
    secrets_system="$(read_ory_secret_literal fluxo-hydra secretsSystem \
      "${HYDRA_SECRETS_SYSTEM:-$(openssl rand -base64 32)}")"
    secrets_cookie="$(read_ory_secret_literal fluxo-hydra secretsCookie \
      "${HYDRA_SECRETS_COOKIE:-$(openssl rand -base64 32)}")"
  else
    secrets_system="${HYDRA_SECRETS_SYSTEM:-$(openssl rand -base64 32)}"
    secrets_cookie="${HYDRA_SECRETS_COOKIE:-$(openssl rand -base64 32)}"
  fi

  apply_ory_secret fluxo-hydra \
    --from-literal=dsn="${dsn}" \
    --from-literal=secretsSystem="${secrets_system}" \
    --from-literal=secretsCookie="${secrets_cookie}"
}

token_hook_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=ory-token-hook" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=ory-token-hook" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

token_hook_health_ok() {
  kubectl_cmd -n "${ORY_NAMESPACE}" delete pod ory-token-hook-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${ORY_NAMESPACE}" run ory-token-hook-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://ory-token-hook.${ORY_NAMESPACE}.svc.cluster.local:8080/health" >/dev/null 2>&1
}

deploy_token_hook() {
  if [[ ! -f "${ORY_MANIFESTS}/token-hook.yaml" ]]; then
    log_error "Ory token hook manifest not found: ${ORY_MANIFESTS}/token-hook.yaml"
    exit 1
  fi

  log_info "applying Ory token hook from ${ORY_MANIFESTS}/token-hook.yaml"
  kubectl_cmd apply -f "${ORY_MANIFESTS}/token-hook.yaml" -n "${ORY_NAMESPACE}"
  log_info "waiting for ory-token-hook in ${ORY_NAMESPACE}..."
  retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" token_hook_pods_ready
  retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" token_hook_health_ok
  log_info "ory-token-hook is ready"
}

kratos_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=kratos,app.kubernetes.io/instance=${KRATOS_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=kratos,app.kubernetes.io/instance=${KRATOS_RELEASE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

hydra_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=hydra,app.kubernetes.io/instance=${HYDRA_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=hydra,app.kubernetes.io/instance=${HYDRA_RELEASE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

kratos_health_ready() {
  kubectl_cmd -n "${ORY_NAMESPACE}" delete pod kratos-health-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${ORY_NAMESPACE}" run kratos-health-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${KRATOS_ADMIN_URL}/health/ready" >/dev/null 2>&1
}

hydra_health_ready() {
  kubectl_cmd -n "${ORY_NAMESPACE}" delete pod hydra-health-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${ORY_NAMESPACE}" run hydra-health-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${HYDRA_ADMIN_URL}/health/ready" >/dev/null 2>&1
}

log_ory_helm_progress() {
  local release="$1"
  local interval="${ORY_HELM_PROGRESS_INTERVAL}"
  while sleep "${interval}"; do
    kubectl_cmd -n "${ORY_NAMESPACE}" get pods,jobs \
      -l "app.kubernetes.io/instance=${release}" \
      --no-headers 2>/dev/null || true
  done
}

cleanup_ory_helm_progress() {
  local progress_pid="${1:-}"
  [[ -z "${progress_pid}" ]] && return 0
  kill "${progress_pid}" 2>/dev/null || true
  wait "${progress_pid}" 2>/dev/null || true
}

wait_for_ory_idp() {
  log_info "waiting for Ory Kratos pods in ${ORY_NAMESPACE}..."
  retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" kratos_pods_ready
  log_info "waiting for Ory Hydra pods in ${ORY_NAMESPACE}..."
  retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" hydra_pods_ready
  log_info "waiting for Kratos /health/ready..."
  retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" kratos_health_ready
  log_info "waiting for Hydra /health/ready..."
  retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" hydra_health_ready
  log_info "Ory Kratos + Hydra are ready"
}

deploy_ory_helm() {
  ensure_helm
  ensure_namespace "${ORY_NAMESPACE}"

  if [[ ! -f "${KRATOS_VALUES}" ]] || [[ ! -f "${HYDRA_VALUES}" ]]; then
    log_error "Ory values not found under ${ORY_MANIFESTS}"
    exit 1
  fi

  ensure_ory_pg_secret
  ensure_kratos_secret
  ensure_hydra_secret
  deploy_token_hook

  log_info "helm upgrade --install ${KRATOS_RELEASE} ory/kratos (chart ${KRATOS_CHART_VERSION}, timeout ${ORY_HELM_TIMEOUT})"
  log_info "Ory first install: image pull + SQL migrations can take several minutes; pod/job status logged every ${ORY_HELM_PROGRESS_INTERVAL}s"
  helm repo add ory https://k8s.ory.sh/helm/charts >/dev/null 2>&1 || true
  helm repo update ory >/dev/null

  local progress_pid=""
  log_ory_helm_progress "${KRATOS_RELEASE}" &
  progress_pid=$!
  trap 'cleanup_ory_helm_progress "${progress_pid}"' EXIT

  if ! helm upgrade --install "${KRATOS_RELEASE}" ory/kratos \
    --namespace "${ORY_NAMESPACE}" \
    --version "${KRATOS_CHART_VERSION}" \
    --values "${KRATOS_VALUES}" \
    --wait \
    --timeout "${ORY_HELM_TIMEOUT}"; then
    cleanup_ory_helm_progress "${progress_pid}"
    trap - EXIT
    log_error "Kratos Helm release failed — inspect: kubectl -n ${ORY_NAMESPACE} get pods,jobs -l app.kubernetes.io/instance=${KRATOS_RELEASE}"
    return 1
  fi

  cleanup_ory_helm_progress "${progress_pid}"
  trap - EXIT

  log_info "helm upgrade --install ${HYDRA_RELEASE} ory/hydra (chart ${HYDRA_CHART_VERSION}, timeout ${ORY_HELM_TIMEOUT})"
  log_ory_helm_progress "${HYDRA_RELEASE}" &
  progress_pid=$!
  trap 'cleanup_ory_helm_progress "${progress_pid}"' EXIT

  if ! helm upgrade --install "${HYDRA_RELEASE}" ory/hydra \
    --namespace "${ORY_NAMESPACE}" \
    --version "${HYDRA_CHART_VERSION}" \
    --values "${HYDRA_VALUES}" \
    --wait \
    --timeout "${ORY_HELM_TIMEOUT}"; then
    cleanup_ory_helm_progress "${progress_pid}"
    trap - EXIT
    log_error "Hydra Helm release failed — inspect: kubectl -n ${ORY_NAMESPACE} get pods,jobs -l app.kubernetes.io/instance=${HYDRA_RELEASE}"
    return 1
  fi

  cleanup_ory_helm_progress "${progress_pid}"
  trap - EXIT

  wait_for_ory_idp
}

ory_bootstrap_job_complete() {
  local status
  status="$(kubectl_cmd -n "${ORY_NAMESPACE}" get job ory-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

ory_bootstrap_job_failed() {
  local status
  status="$(kubectl_cmd -n "${ORY_NAMESPACE}" get job ory-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

ory_bootstrap_pod_failed() {
  local pod phase reason exit_code
  pod="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "job-name=ory-bootstrap" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
  [[ -z "${pod}" ]] && return 1

  phase="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Failed" ]] && return 0

  reason="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  case "${reason}" in
    CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError)
      return 0
      ;;
  esac

  exit_code="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pod "${pod}" \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
  [[ -n "${exit_code}" && "${exit_code}" != "0" ]]
}

log_ory_bootstrap_job_failure() {
  local pod status
  status="$(kubectl_cmd -n "${ORY_NAMESPACE}" get job ory-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Failed")].message}' 2>/dev/null || true)"
  pod="$(kubectl_cmd -n "${ORY_NAMESPACE}" get pods \
    -l "job-name=ory-bootstrap" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
  log_error "Job/ory-bootstrap did not complete in ${ORY_NAMESPACE}"
  [[ -n "${status}" ]] && log_error "job status: ${status}"
  if [[ -n "${pod}" ]]; then
    log_error "latest pod logs (${pod}):"
    kubectl_cmd -n "${ORY_NAMESPACE}" logs "${pod}" --tail=80 2>/dev/null || true
  fi
}

wait_for_ory_bootstrap() {
  local i=1
  log_info "waiting for Job/ory-bootstrap in ${ORY_NAMESPACE}..."
  while (( i <= ORY_BOOTSTRAP_ATTEMPTS )); do
    if ory_bootstrap_job_complete; then
      log_info "ory-bootstrap job completed"
      return 0
    fi
    if ory_bootstrap_job_failed || ory_bootstrap_pod_failed; then
      log_error "Job/ory-bootstrap failed (not waiting for timeout — inspect pod logs)"
      log_ory_bootstrap_job_failure
      return 1
    fi
    if (( i >= ORY_BOOTSTRAP_ATTEMPTS )); then
      break
    fi
    log_warn "Attempt ${i}/${ORY_BOOTSTRAP_ATTEMPTS} failed; retrying in ${ORY_BOOTSTRAP_DELAY}s..."
    sleep "${ORY_BOOTSTRAP_DELAY}"
    i=$((i + 1))
  done
  log_ory_bootstrap_job_failure
  return 1
}

run_ory_bootstrap() {
  if [[ ! -d "${ORY_MANIFESTS}" ]]; then
    log_error "Ory bootstrap manifests not found: ${ORY_MANIFESTS}"
    exit 1
  fi

  log_info "applying ory-bootstrap manifests from ${ORY_MANIFESTS}"
  kubectl_cmd delete job ory-bootstrap -n "${ORY_NAMESPACE}" --ignore-not-found
  kubectl_cmd delete configmap ory-bootstrap -n "${ORY_NAMESPACE}" --ignore-not-found
  kubectl_apply_k "${ORY_MANIFESTS}"
  wait_for_ory_bootstrap
}

ory_oidc_discovery_url() {
  echo "${HYDRA_PUBLIC_URL}/.well-known/openid-configuration"
}

ory_oidc_discovery_ok() {
  local url
  url="$(ory_oidc_discovery_url)"
  kubectl_cmd -n "${ORY_NAMESPACE}" delete pod ory-oidc-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${ORY_NAMESPACE}" run ory-oidc-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "${url}" | grep -q '"issuer"' >/dev/null 2>&1
}

wait_for_ory_oidc() {
  local url
  url="$(ory_oidc_discovery_url)"
  log_info "waiting for Ory Hydra OIDC discovery at ${url}..."
  if ! retry "${ORY_READY_ATTEMPTS}" "${ORY_READY_DELAY}" ory_oidc_discovery_ok; then
    log_error "Ory Hydra OIDC discovery unreachable at ${url}"
    return 1
  fi
  log_info "Ory Hydra OIDC discovery OK — issuer present"
}

deploy_ory_stack() {
  deploy_ory_helm
  run_ory_bootstrap
  wait_for_ory_oidc
  log_info "Ory Kratos + Hydra ready — OIDC configured (CNPG DBs kratos/hydra on ${POSTGRES_CLUSTER})"
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
  log_info "KrakenD ready — NodePort 30443, GET /__health OK (JWT JWKS Ory Hydra OIDC, routes stubbed)"
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
  deploy_ory_stack
  deploy_krakend_stack
  deploy_observability_stack
  log_info "deploy-platform.sh — complete"
}

main "$@"
