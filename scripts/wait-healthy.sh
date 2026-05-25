#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CHECK_ONLY=false
NATS_NAMESPACE="${NATS_NAMESPACE:-messaging}"
NATS_RELEASE="${NATS_RELEASE:-nats}"
POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-database}"
POSTGRES_CLUSTER="${POSTGRES_CLUSTER:-fluxo-pg}"
REDIS_NAMESPACE="${REDIS_NAMESPACE:-cache}"
REDIS_RELEASE="${REDIS_RELEASE:-redis}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-security}"
KEYCLOAK_RELEASE="${KEYCLOAK_RELEASE:-keycloak}"
OBSERVABILITY_NAMESPACE="${OBSERVABILITY_NAMESPACE:-observability}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-gateway}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_RELEASE="${CERT_MANAGER_RELEASE:-cert-manager}"
FLUXO_NAMESPACE="${FLUXO_NAMESPACE:-fluxo-caixa}"
READY_ATTEMPTS="${READY_ATTEMPTS:-${HEALTH_RETRY_ATTEMPTS}}"
READY_DELAY="${READY_DELAY:-${HEALTH_RETRY_DELAY}}"

if [[ "${1:-}" == "--check-only" ]]; then
  CHECK_ONLY=true
fi

cluster_nodes_ready() {
  local ready
  ready="$(kubectl_cmd get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  [[ "${ready}" -ge 1 ]]
}

check_cluster() {
  log_info "checking Kubernetes nodes..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" cluster_nodes_ready
  log_info "Kubernetes nodes Ready"
}

cert_manager_deployments_ready() {
  local ready desired
  ready="$(kubectl_cmd -n "${CERT_MANAGER_NAMESPACE}" get deploy \
    -l "app.kubernetes.io/instance=${CERT_MANAGER_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  desired="$(kubectl_cmd -n "${CERT_MANAGER_NAMESPACE}" get deploy \
    -l "app.kubernetes.io/instance=${CERT_MANAGER_RELEASE}" \
    -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}' 2>/dev/null \
    | awk 'NF {sum += $1} END {print sum+0}')"
  [[ "${desired}" -ge 1 && "${ready}" -ge "${desired}" ]]
}

check_cert_manager() {
  log_info "checking cert-manager (${CERT_MANAGER_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" cert_manager_deployments_ready
  log_info "cert-manager healthy"
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

nats_healthz_ok() {
  kubectl_cmd -n "${NATS_NAMESPACE}" delete pod nats-healthz-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${NATS_NAMESPACE}" run nats-healthz-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://nats.${NATS_NAMESPACE}.svc.cluster.local:8222/healthz" >/dev/null 2>&1
}

nats_stream_lancamentos_events_exists() {
  kubectl_cmd -n "${NATS_NAMESPACE}" delete pod nats-stream-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${NATS_NAMESPACE}" run nats-stream-check --rm -i --restart=Never \
    --image=natsio/nats-box:0.14.3 \
    --env="NATS_URL=nats://nats.${NATS_NAMESPACE}.svc.cluster.local:4222" \
    --command -- nats stream info lancamentos_events >/dev/null 2>&1
}

check_nats() {
  log_info "checking NATS JetStream (${NATS_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_pods_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_healthz_ok
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_bootstrap_complete
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" nats_stream_lancamentos_events_exists
  log_info "NATS healthy — :8222/healthz OK, stream lancamentos_events present"
}

postgres_cluster_healthy() {
  local phase
  phase="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get cluster "${POSTGRES_CLUSTER}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${phase}" == "Cluster in healthy state" ]]
}

postgres_bootstrap_complete() {
  local status
  status="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" get job pg-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

postgres_primary_pod() {
  kubectl_cmd -n "${POSTGRES_NAMESPACE}" get pods \
    -l "cnpg.io/cluster=${POSTGRES_CLUSTER},role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

postgres_pg_isready() {
  local pod
  pod="$(postgres_primary_pod)"
  [[ -n "${pod}" ]] || return 1
  kubectl_cmd -n "${POSTGRES_NAMESPACE}" exec "${pod}" -- \
    pg_isready -h localhost -p 5432 -U fluxo -d fluxo >/dev/null 2>&1
}

postgres_schemas_exist() {
  local pod count
  pod="$(postgres_primary_pod)"
  [[ -n "${pod}" ]] || return 1
  count="$(kubectl_cmd -n "${POSTGRES_NAMESPACE}" exec "${pod}" -- \
    psql -U fluxo -d fluxo -tAc \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name IN ('lancamentos','consolidado')")"
  [[ "${count}" == "2" ]]
}

check_postgres() {
  log_info "checking PostgreSQL (${POSTGRES_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" postgres_cluster_healthy
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" postgres_bootstrap_complete
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" postgres_pg_isready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" postgres_schemas_exist
  log_info "PostgreSQL healthy — pg_isready OK, schemas lancamentos/consolidado present"
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

redis_ping_ok() {
  local password
  password="$(kubectl_cmd -n "${REDIS_NAMESPACE}" get secret fluxo-redis \
    -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "${password}" ]] || return 1

  kubectl_cmd -n "${REDIS_NAMESPACE}" delete pod redis-ping-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${REDIS_NAMESPACE}" run redis-ping-check --rm -i --restart=Never \
    --image=redis:7.4-alpine \
    --command -- redis-cli \
    -h "redis-master.${REDIS_NAMESPACE}.svc.cluster.local" \
    -a "${password}" \
    --no-auth-warning \
    PING >/dev/null 2>&1
}

check_redis() {
  log_info "checking Redis (${REDIS_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" redis_pods_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" redis_ping_ok
  log_info "Redis healthy — PING OK"
}

keycloak_pods_ready() {
  local ready total
  ready="$(kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=keycloak,app.kubernetes.io/instance=${KEYCLOAK_RELEASE}" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c '^True$' || true)"
  total="$(kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" get pods \
    -l "app.kubernetes.io/name=keycloak,app.kubernetes.io/instance=${KEYCLOAK_RELEASE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${total}" -ge 1 && "${ready}" -ge "${total}" ]]
}

keycloak_health_ready() {
  kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" delete pod keycloak-health-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" run keycloak-health-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080/health/ready" >/dev/null 2>&1
}

keycloak_bootstrap_complete() {
  local status
  status="$(kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" get job keycloak-bootstrap \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
  [[ "${status}" == "True" ]]
}

keycloak_realm_imported() {
  kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" delete pod keycloak-realm-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${KEYCLOAK_NAMESPACE}" run keycloak-realm-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf \
    "http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080/realms/fluxo-caixa/.well-known/openid-configuration" \
    | grep -q '"issuer"' >/dev/null 2>&1
}

check_keycloak() {
  log_info "checking Keycloak (${KEYCLOAK_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" keycloak_pods_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" keycloak_health_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" keycloak_bootstrap_complete
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" keycloak_realm_imported
  log_info "Keycloak healthy — /health/ready OK, realm fluxo-caixa imported"
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

check_observability() {
  log_info "checking observability stack (${OBSERVABILITY_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" observability_workloads_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" prometheus_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" grafana_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" otel_collector_ready
  log_info "Observability healthy — Prometheus, Grafana, OTel Collector ready"
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

krakend_health_ok() {
  kubectl_cmd -n "${GATEWAY_NAMESPACE}" delete pod krakend-health-check --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${GATEWAY_NAMESPACE}" run krakend-health-check --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -skf "https://krakend.${GATEWAY_NAMESPACE}.svc.cluster.local:8080/__health" >/dev/null 2>&1
}

check_krakend() {
  log_info "checking KrakenD (${GATEWAY_NAMESPACE})..."
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" krakend_pods_ready
  retry "${READY_ATTEMPTS}" "${READY_DELAY}" krakend_health_ok
  log_info "KrakenD healthy — GET /__health OK (NodePort 30443)"
}

app_deployment_ready() {
  local name="$1"
  local ready desired
  ready="$(kubectl_cmd -n "${FLUXO_NAMESPACE}" get deploy "${name}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(kubectl_cmd -n "${FLUXO_NAMESPACE}" get deploy "${name}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  [[ "${desired}" -ge 1 && "${ready}" -ge "${desired}" ]]
}

app_health_ok() {
  local host="$1"
  kubectl_cmd -n "${FLUXO_NAMESPACE}" delete pod "health-check-${host//./-}" --ignore-not-found >/dev/null 2>&1
  kubectl_cmd -n "${FLUXO_NAMESPACE}" run "health-check-${host//./-}" --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 \
    --command -- curl -sf "http://${host}.${FLUXO_NAMESPACE}.svc.cluster.local:8000/health" >/dev/null 2>&1
}

check_app_service() {
  local deploy="$1"
  local host="$2"
  if ! kubectl_cmd -n "${FLUXO_NAMESPACE}" get deployment "${deploy}" >/dev/null 2>&1; then
    log_error "deployment/${deploy} not found in ${FLUXO_NAMESPACE} (run deploy-apps.sh)"
    return 1
  fi
  log_info "checking ${deploy} (${FLUXO_NAMESPACE})..."
  if ! retry "${READY_ATTEMPTS}" "${READY_DELAY}" app_deployment_ready "${deploy}"; then
    log_error "${deploy} deployment not ready (run build-images.sh and check local :dev images)"
    kubectl_cmd -n "${FLUXO_NAMESPACE}" get pods -l "app=${deploy}" 2>/dev/null || true
    return 1
  fi
  if ! retry "${READY_ATTEMPTS}" "${READY_DELAY}" app_health_ok "${host}"; then
    log_error "${deploy} GET /health not responding"
    return 1
  fi
  log_info "${deploy} healthy — GET /health OK"
}

check_apps() {
  check_app_service "svc-lancamentos" "svc-lancamentos"
  check_app_service "svc-consolidado" "svc-consolidado"
  check_app_service "svc-consulta" "svc-consulta"
}

# Doc 07 health table: K3s, cert-manager, NATS+stream, PG, Redis, Keycloak,
# OTel/Prometheus/Grafana, svc-lancamentos|consolidado|consulta /health,
# KrakenD /__health. Global timeout 15min (180×5s).
run_health_checks() {
  check_cluster
  check_cert_manager
  check_nats
  check_postgres
  check_redis
  check_keycloak
  check_observability
  check_krakend
  check_apps
}

main() {
  configure_kubeconfig

  if [[ "${CHECK_ONLY}" == true ]]; then
    log_info "wait-healthy.sh — check-only (timeout=${HEALTH_TIMEOUT_SECONDS}s, attempts=${READY_ATTEMPTS})"
  else
    log_info "wait-healthy.sh — waiting for platform (timeout=${HEALTH_TIMEOUT_SECONDS}s, attempts=${READY_ATTEMPTS})"
  fi

  if command -v timeout >/dev/null 2>&1; then
    if ! timeout --foreground "${HEALTH_TIMEOUT_SECONDS}" "${BASH_SOURCE[0]}" --run-checks ${CHECK_ONLY:+--check-only}; then
      local exit_code=$?
      if [[ "${exit_code}" -eq 124 ]]; then
        log_error "wait-healthy.sh — global timeout (${HEALTH_TIMEOUT_SECONDS}s) exceeded"
      fi
      exit "${exit_code}"
    fi
  else
    run_health_checks
  fi

  log_info "wait-healthy.sh — all checks passed"
}

if [[ "${1:-}" == "--run-checks" ]]; then
  shift
  if [[ "${1:-}" == "--check-only" ]]; then
    CHECK_ONLY=true
    shift
  fi
  configure_kubeconfig
  run_health_checks
  exit 0
fi

main "$@"
