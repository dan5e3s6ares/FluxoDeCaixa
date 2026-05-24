#!/usr/bin/env bash
# Install/configure Gitea + Actions runner on the dev VM (gitea.local) — doc make-start / fcx-deploy-gitea.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Legacy / external Git: skip in-VM install (SELF_CONTAINED=0 or GITEA_EXTERNAL set).
if [[ "${SELF_CONTAINED:-1}" == "0" ]] || [[ -n "${GITEA_EXTERNAL:-}" ]]; then
  log_info "deploy-gitea.sh — skipped (SELF_CONTAINED=${SELF_CONTAINED:-1}, GITEA_EXTERNAL=${GITEA_EXTERNAL:-<unset>})"
  exit 0
fi

detect_gitea_host() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip:-127.0.0.1}"
}

GITEA_HOST="${GITEA_HOST:-$(detect_gitea_host)}"
GITEA_PORT="${GITEA_PORT:-31562}"
GITEA_ALIAS="${GITEA_ALIAS:-gitea.local}"
GITEA_BASE_URL="http://${GITEA_ALIAS}:${GITEA_PORT}"
GITEA_API_URL="${GITEA_BASE_URL}/api/v1"

GITEA_VERSION="${GITEA_VERSION:-1.22.6}"
GITEA_INSTALL_DIR="${GITEA_INSTALL_DIR:-/opt/gitea}"
GITEA_DATA_DIR="${GITEA_DATA_DIR:-/data/gitea}"
GITEA_ENV_FILE="${GITEA_ENV_FILE:-/etc/fluxo-caixa/gitea.env}"
GITEA_COMPOSE_TEMPLATE="${REPO_ROOT}/deploy/gitea/docker-compose.yml.in"
GITEA_COMPOSE_FILE="${GITEA_INSTALL_DIR}/docker-compose.yml"
GITEA_SECRET_FILE="${GITEA_INSTALL_DIR}/config/secret_key"

GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-Gitea12345}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@gitea.local}"
GITEA_REPO_OWNER="${GITEA_REPO_OWNER:-fluxo-caixa}"
GITEA_REPO_NAME="${GITEA_REPO_NAME:-FinTecFluxCX}"
GITEA_REPO_PRIVATE="${GITEA_REPO_PRIVATE:-false}"
GITEA_TOKEN_NAME="${GITEA_TOKEN_NAME:-fluxo-caixa-deploy}"

HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"

GITEA_RUNNER_VERSION="${GITEA_RUNNER_VERSION:-0.2.11}"
GITEA_RUNNER_NAME="${GITEA_RUNNER_NAME:-fluxo-caixa-vm}"
GITEA_RUNNER_DIR="${GITEA_RUNNER_DIR:-/opt/act_runner}"
GITEA_RUNNER_LABELS="${GITEA_RUNNER_LABELS:-self-hosted,linux,x64}"
GITEA_RUNNER_SERVICE="${GITEA_RUNNER_SERVICE:-act-runner.service}"

GITEA_READY_ATTEMPTS="${GITEA_READY_ATTEMPTS:-60}"
GITEA_READY_DELAY="${GITEA_READY_DELAY:-5}"
GITEA_RUNNER_READY_ATTEMPTS="${GITEA_RUNNER_READY_ATTEMPTS:-30}"
GITEA_RUNNER_READY_DELAY="${GITEA_RUNNER_READY_DELAY:-5}"

GIT_REPO_URL="${GIT_REPO_URL:-${GITEA_BASE_URL}/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}.git}"
GITEA_TOKEN=""
GITEA_ADMIN_TOKEN=""

auth_basic_header() {
  printf 'Authorization: Basic %s' \
    "$(printf '%s:%s' "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_PASSWORD}" | base64 -w0 2>/dev/null \
      || printf '%s:%s' "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_PASSWORD}" | base64)"
}

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

write_if_changed() {
  local dest="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}"
  if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
    log_info "unchanged: ${dest}"
    rm -f "${tmp}"
    return 1
  fi
  run_as_root mkdir -p "$(dirname "${dest}")"
  run_as_root install -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
  log_info "updated: ${dest}"
  return 0
}

ensure_hosts_entry() {
  if grep -qE "[[:space:]]${GITEA_ALIAS}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    log_info "unchanged: /etc/hosts entry for ${GITEA_ALIAS}"
    return 0
  fi
  log_info "adding /etc/hosts entry: ${GITEA_HOST} ${GITEA_ALIAS}"
  printf '%s %s\n' "${GITEA_HOST}" "${GITEA_ALIAS}" | run_as_root tee -a /etc/hosts >/dev/null
}

ensure_container_runtime() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log_info "docker runtime available"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    log_info "configuring podman as docker-compatible runtime for Gitea..."
    if ! command -v docker >/dev/null 2>&1; then
      run_as_root apt-get update -qq
      if apt-cache show podman-docker >/dev/null 2>&1; then
        run_as_root apt-get install -y -qq podman-docker
      fi
    fi
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
      run_as_root apt-get update -qq
      if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
        run_as_root apt-get install -y -qq docker-compose-v2
      elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
        run_as_root apt-get install -y -qq docker-compose-plugin
      fi
    fi
    if command -v systemctl >/dev/null 2>&1; then
      run_as_root systemctl enable --now podman.socket 2>/dev/null || true
    fi
    if docker info >/dev/null 2>&1; then
      ensure_podman_nodocker
      log_info "podman-docker runtime ready"
      return 0
    fi
  fi

  log_error "No working container runtime (docker/podman). Run bootstrap-vm.sh first."
  exit 1
}

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    log_error "docker compose not available"
    exit 1
  fi
}

ensure_gitea_secret_key() {
  run_as_root mkdir -p "${GITEA_INSTALL_DIR}/config"
  if [[ -f "${GITEA_SECRET_FILE}" ]]; then
    cat "${GITEA_SECRET_FILE}"
    return 0
  fi
  local key
  key="$(openssl rand -hex 32)"
  printf '%s\n' "${key}" | run_as_root tee "${GITEA_SECRET_FILE}" >/dev/null
  run_as_root chmod 0600 "${GITEA_SECRET_FILE}"
  echo "${key}"
}

render_compose_file() {
  local secret_key
  secret_key="$(ensure_gitea_secret_key)"
  local tmp
  tmp="$(mktemp)"

  sed \
    -e "s|@GITEA_VERSION@|${GITEA_VERSION}|g" \
    -e "s|@GITEA_ALIAS@|${GITEA_ALIAS}|g" \
    -e "s|@GITEA_PORT@|${GITEA_PORT}|g" \
    -e "s|@GITEA_DATA_DIR@|${GITEA_DATA_DIR}|g" \
    -e "s|@GITEA_INSTALL_DIR@|${GITEA_INSTALL_DIR}|g" \
    -e "s|@GITEA_SECRET_KEY@|${secret_key}|g" \
    "${GITEA_COMPOSE_TEMPLATE}" >"${tmp}"

  if [[ -f "${GITEA_COMPOSE_FILE}" ]] && cmp -s "${tmp}" "${GITEA_COMPOSE_FILE}"; then
    log_info "unchanged: ${GITEA_COMPOSE_FILE}"
    rm -f "${tmp}"
    return 1
  fi

  run_as_root mkdir -p "${GITEA_INSTALL_DIR}"
  run_as_root install -m 0644 "${tmp}" "${GITEA_COMPOSE_FILE}"
  rm -f "${tmp}"
  log_info "updated: ${GITEA_COMPOSE_FILE}"
  return 0
}

gitea_api_ready() {
  curl -fsS "${GITEA_BASE_URL}/api/healthz" >/dev/null 2>&1
}

wait_for_gitea() {
  log_info "waiting for Gitea API (${GITEA_BASE_URL})..."
  retry "${GITEA_READY_ATTEMPTS}" "${GITEA_READY_DELAY}" gitea_api_ready
  log_info "Gitea API is ready"
}

install_gitea_stack() {
  render_compose_file || true
  run_as_root mkdir -p "${GITEA_DATA_DIR}"
  log_info "starting Gitea stack (${GITEA_ALIAS}:${GITEA_PORT})..."
  if docker compose version >/dev/null 2>&1; then
    run_as_root bash -c "cd '${GITEA_INSTALL_DIR}' && docker compose up -d"
  else
    run_as_root bash -c "cd '${GITEA_INSTALL_DIR}' && docker-compose up -d"
  fi
}

gitea_auth_header() {
  printf 'Authorization: token %s' "${GITEA_ADMIN_TOKEN}"
}

gitea_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local auth="${4:-yes}"
  local args=(-fsS -X "${method}" "${GITEA_API_URL}${path}")

  if [[ "${auth}" == "yes" ]]; then
    args=(-H "$(gitea_auth_header)" "${args[@]}")
  fi
  if [[ -n "${data}" ]]; then
    args=(-H "Content-Type: application/json" -d "${data}" "${args[@]}")
  fi
  curl "${args[@]}"
}

gitea_docker_exec() {
  # Gitea refuses CLI commands run as root; config lives under /data/gitea/conf (not /etc/gitea).
  run_as_root docker exec -u git gitea gitea -c /data/gitea/conf/app.ini "$@"
}

gitea_admin_auth_ok() {
  curl -fsS -H "$(auth_basic_header)" "${GITEA_API_URL}/user" >/dev/null 2>&1
}

gitea_app_ini_ready() {
  run_as_root docker exec gitea test -f /data/gitea/conf/app.ini 2>/dev/null
}

wait_for_gitea_installed() {
  log_info "waiting for Gitea installation (app.ini)..."
  retry "${GITEA_READY_ATTEMPTS}" "${GITEA_READY_DELAY}" gitea_app_ini_ready
  log_info "Gitea installation config ready"
}

ensure_admin_user() {
  if gitea_admin_auth_ok; then
    log_info "Gitea admin user already configured"
    return 0
  fi

  log_info "creating Gitea admin user (${GITEA_ADMIN_USER})..."
  local attempt err_file max_attempts
  max_attempts="${GITEA_ADMIN_CREATE_ATTEMPTS:-12}"
  err_file="$(mktemp)"
  trap 'rm -f "${err_file}"' RETURN

  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    if gitea_admin_auth_ok; then
      log_info "Gitea admin login OK"
      return 0
    fi

    if gitea_docker_exec admin user create \
      --admin \
      --username "${GITEA_ADMIN_USER}" \
      --password "${GITEA_ADMIN_PASSWORD}" \
      --email "${GITEA_ADMIN_EMAIL}" \
      --must-change-password=false 2>"${err_file}"; then
      log_info "Gitea admin user created"
      continue
    fi
    local err_create
    err_create="$(tr '\n' ' ' <"${err_file}")"

    if gitea_docker_exec admin user change-password \
      --username "${GITEA_ADMIN_USER}" \
      --password "${GITEA_ADMIN_PASSWORD}" 2>"${err_file}"; then
      log_info "Gitea admin password updated"
      continue
    fi
    local err_pw
    err_pw="$(tr '\n' ' ' <"${err_file}")"

    if (( attempt < max_attempts )); then
      log_warn "Gitea admin bootstrap attempt ${attempt}/${max_attempts} failed; retrying in ${GITEA_READY_DELAY}s..."
      [[ -n "${err_create}" ]] && log_warn "  create: ${err_create}"
      [[ -n "${err_pw}" ]] && log_warn "  change-password: ${err_pw}"
      sleep "${GITEA_READY_DELAY}"
    fi
  done

  if ! gitea_admin_auth_ok; then
    log_error "Gitea admin login failed for user ${GITEA_ADMIN_USER}"
    gitea_docker_exec admin user list 2>&1 | head -20 || true
    exit 1
  fi
  log_info "Gitea admin login OK"
}

ensure_admin_token() {
  if [[ -n "${GITEA_TOKEN:-}" ]]; then
    GITEA_ADMIN_TOKEN="${GITEA_TOKEN}"
    return 0
  fi

  if ! gitea_admin_auth_ok; then
    log_error "Gitea admin login failed for user ${GITEA_ADMIN_USER}"
    exit 1
  fi

  local token_name="${GITEA_TOKEN_NAME}-$(date +%s)"
  log_info "creating Gitea API token (${token_name})..."
  GITEA_ADMIN_TOKEN="$(curl -fsS -H "$(auth_basic_header)" -H "Content-Type: application/json" \
    -X POST "${GITEA_API_URL}/users/${GITEA_ADMIN_USER}/tokens" \
    -d "{\"name\":\"${token_name}\",\"scopes\":[\"all\"]}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha1',''))")"

  if [[ -z "${GITEA_ADMIN_TOKEN}" ]]; then
    log_error "failed to create Gitea admin token"
    exit 1
  fi
  GITEA_TOKEN="${GITEA_ADMIN_TOKEN}"
  log_info "Gitea admin token created"
}

ensure_repo_owner() {
  local owner_type
  owner_type="$(gitea_api GET "/users/${GITEA_REPO_OWNER}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('org' if d.get('type')=='Organization' else ('user' if d.get('login') else 'missing'))" 2>/dev/null \
    || echo "missing")"

  if [[ "${owner_type}" != "missing" ]]; then
    log_info "repo owner exists: ${GITEA_REPO_OWNER} (${owner_type})"
    return 0
  fi

  if [[ "${GITEA_REPO_OWNER}" == "${GITEA_ADMIN_USER}" ]]; then
    log_info "repo owner is admin user (${GITEA_ADMIN_USER})"
    return 0
  fi

  log_info "creating Gitea organization: ${GITEA_REPO_OWNER}"
  gitea_api POST "/orgs" \
    "{\"username\":\"${GITEA_REPO_OWNER}\",\"full_name\":\"FinTecFluxCX\",\"visibility\":\"public\"}" >/dev/null
}

ensure_repo() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "$(gitea_auth_header)" \
    "${GITEA_API_URL}/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}" || echo "000")"

  if [[ "${code}" == "200" ]]; then
    log_info "repository exists: ${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}"
    return 0
  fi

  log_info "creating repository: ${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}"
  if [[ "${GITEA_REPO_OWNER}" == "${GITEA_ADMIN_USER}" ]]; then
    gitea_api POST "/user/repos" \
      "{\"name\":\"${GITEA_REPO_NAME}\",\"private\":${GITEA_REPO_PRIVATE},\"auto_init\":false,\"default_branch\":\"main\"}" >/dev/null
  else
    gitea_api POST "/orgs/${GITEA_REPO_OWNER}/repos" \
      "{\"name\":\"${GITEA_REPO_NAME}\",\"private\":${GITEA_REPO_PRIVATE},\"auto_init\":false,\"default_branch\":\"main\"}" >/dev/null
  fi
}

bootstrap_repo_git() {
  local remote_name="gitea-bootstrap"
  local auth_remote="https://oauth2:${GITEA_TOKEN}@${GITEA_ALIAS}:${GITEA_PORT}/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}.git"
  local head_sha remote_head

  require_cmd git

  if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "REPO_ROOT is not a git repository: ${REPO_ROOT}"
    exit 1
  fi

  head_sha="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  remote_head="$(git -C "${REPO_ROOT}" ls-remote "${auth_remote}" refs/heads/main 2>/dev/null | awk '{print $1}' || true)"

  if [[ "${remote_head}" == "${head_sha}" ]]; then
    log_info "remote main already matches local HEAD (${head_sha:0:7})"
    return 0
  fi

  log_info "pushing repository bootstrap to ${GIT_REPO_URL}..."
  git -C "${REPO_ROOT}" remote remove "${remote_name}" 2>/dev/null || true
  git -C "${REPO_ROOT}" remote add "${remote_name}" "${auth_remote}"
  git -C "${REPO_ROOT}" push "${remote_name}" HEAD:main --force
  git -C "${REPO_ROOT}" remote remove "${remote_name}" 2>/dev/null || true
  log_info "git push bootstrap complete"
}

ensure_repo_secret() {
  local name="$1"
  local value="$2"
  local payload b64

  b64="$(printf '%s' "${value}" | base64 -w0 2>/dev/null || printf '%s' "${value}" | base64)"
  payload="{\"data\":\"${b64}\"}"

  log_info "configuring repo secret: ${name}"
  curl -fsS -H "$(gitea_auth_header)" -H "Content-Type: application/json" \
    -X PUT "${GITEA_API_URL}/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/actions/secrets/${name}" \
    -d "${payload}" >/dev/null
}

configure_repo_secrets() {
  ensure_repo_secret "GITEA_TOKEN" "${GITEA_TOKEN}"
  ensure_repo_secret "HARBOR_USERNAME" "${HARBOR_ADMIN_USER}"
  ensure_repo_secret "HARBOR_PASSWORD" "${HARBOR_ADMIN_PASSWORD}"
}

download_act_runner() {
  local arch="linux-amd64"
  local tarball="act_runner-${GITEA_RUNNER_VERSION}-${arch}.tar.gz"
  local url="https://gitea.com/gitea/act_runner/releases/download/v${GITEA_RUNNER_VERSION}/${tarball}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  if [[ -x "${GITEA_RUNNER_DIR}/act_runner" ]]; then
    log_info "act_runner binary already present"
    rm -rf "${tmp}"
    trap - EXIT
    return 0
  fi

  log_info "downloading act_runner v${GITEA_RUNNER_VERSION}..."
  curl -fsSL "${url}" -o "${tmp}/${tarball}"
  run_as_root mkdir -p "${GITEA_RUNNER_DIR}"
  tar -xzf "${tmp}/${tarball}" -C "${tmp}"
  run_as_root install -m 0755 "${tmp}/act_runner" "${GITEA_RUNNER_DIR}/act_runner"
  rm -rf "${tmp}"
  trap - EXIT
  log_info "act_runner installed to ${GITEA_RUNNER_DIR}/act_runner"
}

runner_config_exists() {
  [[ -f "${GITEA_RUNNER_DIR}/.runner" ]]
}

register_act_runner() {
  if runner_config_exists; then
    log_info "act_runner already registered (${GITEA_RUNNER_DIR}/.runner)"
    return 0
  fi

  local token
  token="$(gitea_api POST "/admin/actions/runners/registration-token" '{}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")"
  if [[ -z "${token}" ]]; then
    log_error "failed to obtain act_runner registration token"
    exit 1
  fi

  log_info "registering act_runner (${GITEA_RUNNER_NAME})..."
  run_as_root mkdir -p "${GITEA_RUNNER_DIR}"
  run_as_root bash -c "cd '${GITEA_RUNNER_DIR}' && ./act_runner register \
    --no-interactive \
    --instance '${GITEA_BASE_URL}' \
    --token '${token}' \
    --name '${GITEA_RUNNER_NAME}' \
    --labels '${GITEA_RUNNER_LABELS}'"
}

install_runner_service() {
  local unit="/etc/systemd/system/${GITEA_RUNNER_SERVICE}"
  write_if_changed "${unit}" <<EOF || true
[Unit]
Description=Gitea Actions act_runner (${GITEA_RUNNER_NAME})
After=network-online.target docker.service podman.socket
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${GITEA_RUNNER_DIR}
ExecStart=${GITEA_RUNNER_DIR}/act_runner daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  if command -v systemctl >/dev/null 2>&1; then
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable "${GITEA_RUNNER_SERVICE}" >/dev/null 2>&1 || true
    run_as_root systemctl restart "${GITEA_RUNNER_SERVICE}"
    log_info "systemd service active: ${GITEA_RUNNER_SERVICE}"
  else
    log_warn "systemd unavailable; start act_runner manually: ${GITEA_RUNNER_DIR}/act_runner daemon"
  fi
}

runner_is_online() {
  local count
  count="$(gitea_api GET "/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/actions/runners" \
    | python3 -c "import sys,json; rs=json.load(sys.stdin).get('runners',[]); print(sum(1 for r in rs if r.get('status')=='online'))" 2>/dev/null \
    || echo "0")"
  [[ "${count}" -ge 1 ]]
}

wait_for_runner_online() {
  log_info "waiting for Actions runner online..."
  retry "${GITEA_RUNNER_READY_ATTEMPTS}" "${GITEA_RUNNER_READY_DELAY}" runner_is_online
  log_info "Actions runner is online"
}

trigger_sample_workflow() {
  local workflow_id run_id
  workflow_id="$(gitea_api GET "/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/actions/workflows" \
    | python3 -c "import sys,json; ws=json.load(sys.stdin).get('workflows',[]); print(next((w['id'] for w in ws if w.get('path','').endswith('ping.yaml')), ''))" 2>/dev/null \
    || true)"

  if [[ -z "${workflow_id}" ]]; then
    log_warn "ping workflow not found; skipping workflow_dispatch acceptance"
    return 0
  fi

  log_info "triggering sample workflow (ping.yaml, id=${workflow_id})..."
  gitea_api POST "/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/actions/workflows/${workflow_id}/dispatches" \
    '{"ref":"main"}' >/dev/null

  run_id="$(gitea_api GET "/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}/actions/runs?limit=1" \
    | python3 -c "import sys,json; rs=json.load(sys.stdin).get('workflow_runs',[]); print(rs[0]['id'] if rs else '')" 2>/dev/null \
    || true)"
  if [[ -n "${run_id}" ]]; then
    log_info "sample workflow run created (id=${run_id})"
  fi
}

write_git_env_file() {
  run_as_root mkdir -p "$(dirname "${GITEA_ENV_FILE}")"
  write_if_changed "${GITEA_ENV_FILE}" <<EOF || true
# Generated by scripts/deploy-gitea.sh — source before deploy-apps.sh
GIT_REPO_URL=${GIT_REPO_URL}
GIT_REPO_USERNAME=${GITEA_REPO_OWNER}
GIT_REPO_PASSWORD=${GITEA_TOKEN}
GITEA_TOKEN=${GITEA_TOKEN}
GITEA_BASE_URL=${GITEA_BASE_URL}
GITEA_REPO_OWNER=${GITEA_REPO_OWNER}
GITEA_REPO_NAME=${GITEA_REPO_NAME}
EOF
}

verify_git_push() {
  local auth_remote tmp_dir
  auth_remote="https://oauth2:${GITEA_TOKEN}@${GITEA_ALIAS}:${GITEA_PORT}/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}.git"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  git clone --depth 1 "${auth_remote}" "${tmp_dir}/repo" >/dev/null 2>&1
  printf 'deploy-gitea acceptance %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${tmp_dir}/repo/.gitea-deploy-check"
  git -C "${tmp_dir}/repo" add .gitea-deploy-check
  git -C "${tmp_dir}/repo" -c user.name="deploy-gitea" -c user.email="deploy@gitea.local" \
    commit -m "chore: deploy-gitea acceptance push" >/dev/null
  git -C "${tmp_dir}/repo" push origin main >/dev/null
  rm -rf "${tmp_dir}"
  trap - EXIT
  log_info "git push verification OK"
}

main() {
  log_info "deploy-gitea.sh — in-VM Gitea (${GITEA_ALIAS}:${GITEA_PORT}, host=${GITEA_HOST})"
  require_cmd curl
  require_cmd python3
  require_cmd openssl
  require_cmd git

  ensure_hosts_entry
  ensure_container_runtime
  install_gitea_stack
  wait_for_gitea
  wait_for_gitea_installed
  ensure_admin_user
  ensure_admin_token
  ensure_repo_owner
  ensure_repo
  bootstrap_repo_git
  configure_repo_secrets
  download_act_runner
  register_act_runner
  install_runner_service
  wait_for_runner_online
  verify_git_push
  trigger_sample_workflow
  write_git_env_file

  log_info "deploy-gitea.sh — complete"
  log_info "  GIT_REPO_URL=${GIT_REPO_URL}"
  log_info "  UI:          ${GITEA_BASE_URL}  (${GITEA_ADMIN_USER} / ${GITEA_ADMIN_PASSWORD})"
  log_info "  env file:    ${GITEA_ENV_FILE}"
  log_info "  runner:      ${GITEA_RUNNER_NAME} (${GITEA_RUNNER_LABELS})"
  log_info "  next:        source ${GITEA_ENV_FILE} && ./scripts/deploy-apps.sh"
}

main "$@"
