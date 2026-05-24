#!/usr/bin/env bash
# Install/configure Harbor on the dev VM (harbor.local) — doc make-start / fcx-deploy-registry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

# Legacy / external registry: skip in-VM install (SELF_CONTAINED=0 or HARBOR_EXTERNAL set).
if [[ "${SELF_CONTAINED:-1}" == "0" ]] || [[ -n "${HARBOR_EXTERNAL:-}" ]]; then
  log_info "deploy-registry.sh — skipped (SELF_CONTAINED=${SELF_CONTAINED:-1}, HARBOR_EXTERNAL=${HARBOR_EXTERNAL:-<unset>})"
  exit 0
fi

resolve_harbor_config
HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
load_harbor_admin_credentials
HARBOR_PROJECT="${HARBOR_PROJECT:-fluxo-caixa}"
HARBOR_VERSION="${HARBOR_VERSION:-2.10.2}"
HARBOR_INSTALL_DIR="${HARBOR_INSTALL_DIR:-/opt/harbor}"
HARBOR_DATA_VOLUME="${HARBOR_DATA_VOLUME:-/data/harbor}"
HARBOR_CERTS_DIR="${HARBOR_CERTS_DIR:-${HARBOR_INSTALL_DIR}/certs}"
HARBOR_CA_CERT="${HARBOR_CA_CERT:-${REPO_ROOT}/deploy/certs/harbor-ca.crt}"
HARBOR_TEMPLATE="${REPO_ROOT}/deploy/harbor/harbor.yml.in"

PODMAN_CERTS_DIR="/etc/containers/certs.d/${HARBOR_REGISTRY}"

HARBOR_READY_ATTEMPTS="${HARBOR_READY_ATTEMPTS:-60}"
HARBOR_READY_DELAY="${HARBOR_READY_DELAY:-5}"

# Harbor v2.10+ install.sh only accepts --with-trivy; notary/chartmuseum were removed.
# Trivy is off by default — set HARBOR_INSTALL_FLAGS=--with-trivy to enable.
HARBOR_INSTALL_FLAGS="${HARBOR_INSTALL_FLAGS:-}"

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

generate_harbor_certs() {
  require_cmd openssl

  run_as_root mkdir -p "${HARBOR_CERTS_DIR}"

  if [[ -f "${HARBOR_CERTS_DIR}/server.crt" ]] \
    && [[ -f "${HARBOR_CERTS_DIR}/server.key" ]] \
    && [[ -f "${HARBOR_CERTS_DIR}/ca.crt" ]]; then
    log_info "Harbor TLS material already present in ${HARBOR_CERTS_DIR}"
  else
    log_info "generating Harbor TLS CA and server certificate (${HARBOR_ALIAS})..."
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT

    openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
      -keyout "${tmp}/ca.key" -out "${tmp}/ca.crt" \
      -subj "/CN=harbor-ca/O=fluxo-caixa/C=BR" 2>/dev/null

    cat >"${tmp}/server.cnf" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = ${HARBOR_ALIAS}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${HARBOR_ALIAS}
DNS.2 = localhost
IP.1 = 127.0.0.1
IP.2 = ${HARBOR_HOST}
EOF

    openssl req -newkey rsa:4096 -nodes -keyout "${tmp}/server.key" \
      -out "${tmp}/server.csr" -config "${tmp}/server.cnf" 2>/dev/null
    openssl x509 -req -days 825 -in "${tmp}/server.csr" \
      -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" -CAcreateserial \
      -out "${tmp}/server.crt" -extensions req_ext -extfile "${tmp}/server.cnf" 2>/dev/null

    run_as_root install -m 0600 "${tmp}/server.key" "${HARBOR_CERTS_DIR}/server.key"
    run_as_root install -m 0644 "${tmp}/server.crt" "${HARBOR_CERTS_DIR}/server.crt"
    run_as_root install -m 0644 "${tmp}/ca.crt" "${HARBOR_CERTS_DIR}/ca.crt"
    rm -rf "${tmp}"
    trap - EXIT
    log_info "Harbor TLS certs written to ${HARBOR_CERTS_DIR}"
  fi

  run_as_root mkdir -p "$(dirname "${HARBOR_CA_CERT}")"
  if [[ ! -f "${HARBOR_CA_CERT}" ]] \
    || ! cmp -s "${HARBOR_CERTS_DIR}/ca.crt" "${HARBOR_CA_CERT}" 2>/dev/null; then
    run_as_root install -m 0644 "${HARBOR_CERTS_DIR}/ca.crt" "${HARBOR_CA_CERT}"
    log_info "published Harbor CA for bootstrap-vm: ${HARBOR_CA_CERT}"
  else
    log_info "unchanged: ${HARBOR_CA_CERT}"
  fi
}

render_harbor_yml() {
  local dest="${HARBOR_INSTALL_DIR}/harbor.yml"
  local tmp
  tmp="$(mktemp)"

  sed \
    -e "s|@HARBOR_ALIAS@|${HARBOR_ALIAS}|g" \
    -e "s|@HARBOR_PORT@|${HARBOR_PORT}|g" \
    -e "s|@HARBOR_ADMIN_PASSWORD@|${HARBOR_ADMIN_PASSWORD}|g" \
    -e "s|@HARBOR_DATA_VOLUME@|${HARBOR_DATA_VOLUME}|g" \
    -e "s|@HARBOR_CERT@|${HARBOR_CERTS_DIR}/server.crt|g" \
    -e "s|@HARBOR_KEY@|${HARBOR_CERTS_DIR}/server.key|g" \
    "${HARBOR_TEMPLATE}" >"${tmp}"

  if [[ -f "${dest}" ]] && cmp -s "${tmp}" "${dest}"; then
    log_info "unchanged: ${dest}"
    rm -f "${tmp}"
    return 1
  fi

  run_as_root mkdir -p "${HARBOR_INSTALL_DIR}"
  run_as_root install -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
  log_info "updated: ${dest}"
  return 0
}

ensure_container_runtime() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log_info "docker runtime available"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    log_info "configuring podman as docker-compatible runtime for Harbor..."
    if ! command -v docker >/dev/null 2>&1; then
      run_as_root apt-get update -qq
      if apt-cache show podman-docker >/dev/null 2>&1; then
        run_as_root apt-get install -y -qq podman-docker
      else
        log_warn "podman-docker package not found; Harbor install may require docker CLI"
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

harbor_compose_search_path() {
  local shim_dir="${HARBOR_INSTALL_DIR}/.bin"
  if [[ "${PATH}" == "${shim_dir}:"* ]]; then
    printf '%s\n' "${PATH#${shim_dir}:}"
    return 0
  fi
  printf '%s\n' "${PATH}"
}

ensure_harbor_prepare_dirs() {
  # Podman (via podman-docker) requires bind-mount sources to exist; Docker auto-creates them.
  run_as_root mkdir -p "${HARBOR_INSTALL_DIR}/common/config" "${HARBOR_DATA_VOLUME}/secret"
}

harbor_needs_docker_version_shim() {
  command -v podman >/dev/null 2>&1 || return 1
  command -v docker >/dev/null 2>&1 || return 1
  local version_line major
  version_line="$(docker --version 2>/dev/null || true)"
  if [[ "${version_line}" =~ ([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    if [[ "${major}" -lt 17 ]]; then
      return 0
    fi
  fi
  return 1
}

harbor_uses_podman_runtime() {
  command -v podman >/dev/null 2>&1 || return 1
  command -v docker >/dev/null 2>&1 || return 1
  if docker info 2>/dev/null | grep -qi podman; then
    return 0
  fi
  local version_line
  version_line="$(docker --version 2>/dev/null || true)"
  [[ "${version_line}" == *[Pp]odman* ]]
}

resolve_harbor_compose() {
  local candidate search_path
  search_path="$(harbor_compose_search_path)"
  if candidate="$(PATH="${search_path}" command -v docker-compose 2>/dev/null)"; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  for candidate in \
    /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/bin/docker-compose \
    /usr/local/bin/docker-compose; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  if PATH="${search_path}" docker-compose version >/dev/null 2>&1; then
    if candidate="$(PATH="${search_path}" command -v docker-compose 2>/dev/null)"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    printf '%s\n' "docker-compose"
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s\n' "docker compose"
    return 0
  fi
  return 1
}

resolve_harbor_compose_absolute() {
  local raw="$1"
  local candidate search_path
  search_path="$(harbor_compose_search_path)"
  case "${raw}" in
    "docker compose")
      printf '%s\n' "${raw}"
      return 0
      ;;
    /*)
      printf '%s\n' "${raw}"
      return 0
      ;;
    "docker-compose")
      if candidate="$(PATH="${search_path}" command -v docker-compose 2>/dev/null)"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
      for candidate in \
        /usr/libexec/docker/cli-plugins/docker-compose \
        /usr/bin/docker-compose \
        /usr/local/bin/docker-compose; do
        if [[ -f "${candidate}" ]]; then
          printf '%s\n' "${candidate}"
          return 0
        fi
      done
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

install_harbor_compose_wrapper() {
  local shim_dir="${HARBOR_INSTALL_DIR}/.bin"
  local real_compose shim_path patch_script compose_backend=path
  real_compose="$(resolve_harbor_compose 2>/dev/null || true)"
  if [[ -z "${real_compose}" ]] && harbor_uses_podman_runtime; then
    for candidate in \
      /usr/libexec/docker/cli-plugins/docker-compose \
      /usr/bin/docker-compose; do
      if [[ -f "${candidate}" ]]; then
        real_compose="${candidate}"
        break
      fi
    done
    if [[ -z "${real_compose}" ]] \
      && PATH="$(harbor_compose_search_path)" docker-compose version >/dev/null 2>&1; then
      real_compose="docker-compose"
    elif [[ -z "${real_compose}" ]] && command -v docker >/dev/null 2>&1; then
      real_compose="docker compose"
    fi
  fi
  if [[ -z "${real_compose}" ]]; then
    log_warn "docker-compose not found; Harbor compose patch wrapper skipped"
    return 0
  fi
  if [[ "${real_compose}" == "docker compose" ]]; then
    compose_backend=plugin
  else
    if ! real_compose="$(resolve_harbor_compose_absolute "${real_compose}")"; then
      log_warn "docker-compose backend not resolved to absolute path; Harbor compose patch wrapper skipped"
      return 0
    fi
    compose_backend=path
  fi
  patch_script="${SCRIPT_DIR}/lib/patch-harbor-compose.py"
  shim_path="${shim_dir}/docker-compose"

  run_as_root mkdir -p "${shim_dir}"
  if [[ "${compose_backend}" == "plugin" ]]; then
    run_as_root tee "${shim_path}" >/dev/null <<EOF
#!/usr/bin/env bash
# fluxo-caixa: strip Harbor syslog logging blocks before compose up (podman unsupported driver).
set -euo pipefail
HARBOR_COMPOSE='${HARBOR_INSTALL_DIR}/docker-compose.yml'
PATCH_SCRIPT='${patch_script}'

patch_compose_if_needed() {
  [[ -f "\${HARBOR_COMPOSE}" ]] || return 0
  python3 "\${PATCH_SCRIPT}" "\${HARBOR_COMPOSE}" >/dev/null 2>&1 || true
}

case "\${1:-}" in
  up|create|run|start|down)
    patch_compose_if_needed
    ;;
esac
exec docker compose "\$@"
EOF
  else
    run_as_root tee "${shim_path}" >/dev/null <<EOF
#!/usr/bin/env bash
# fluxo-caixa: strip Harbor syslog logging blocks before compose up (podman unsupported driver).
set -euo pipefail
HARBOR_COMPOSE='${HARBOR_INSTALL_DIR}/docker-compose.yml'
PATCH_SCRIPT='${patch_script}'
REAL_COMPOSE='${real_compose}'

patch_compose_if_needed() {
  [[ -f "\${HARBOR_COMPOSE}" ]] || return 0
  python3 "\${PATCH_SCRIPT}" "\${HARBOR_COMPOSE}" >/dev/null 2>&1 || true
}

case "\${1:-}" in
  up|create|run|start|down)
    patch_compose_if_needed
    ;;
esac
exec "\${REAL_COMPOSE}" "\$@"
EOF
  fi
  run_as_root chmod 0755 "${shim_path}"
  log_info "installed Harbor docker-compose wrapper: ${shim_path} (backend=${real_compose})"
}

install_harbor_docker_shim() {
  local shim_dir="${HARBOR_INSTALL_DIR}/.bin"
  local real_docker shim_path patch_script spoof_version=0 patch_compose=0
  real_docker="$(command -v docker)"
  shim_path="${shim_dir}/docker"
  patch_script="${SCRIPT_DIR}/lib/patch-harbor-compose.py"
  if harbor_needs_docker_version_shim; then
    spoof_version=1
  fi
  if harbor_uses_podman_runtime; then
    patch_compose=1
  fi

  run_as_root mkdir -p "${shim_dir}"
  run_as_root tee "${shim_path}" >/dev/null <<EOF
#!/usr/bin/env bash
# fluxo-caixa: Harbor podman-docker shims (version check + compose syslog patch).
set -euo pipefail
REAL_DOCKER='${real_docker}'
HARBOR_COMPOSE='${HARBOR_INSTALL_DIR}/docker-compose.yml'
PATCH_SCRIPT='${patch_script}'
SPOOF_VERSION='${spoof_version}'
PATCH_COMPOSE='${patch_compose}'

patch_compose_if_needed() {
  [[ "\${PATCH_COMPOSE}" == "1" ]] || return 0
  [[ -f "\${HARBOR_COMPOSE}" ]] || return 0
  python3 "\${PATCH_SCRIPT}" "\${HARBOR_COMPOSE}" >/dev/null 2>&1 || true
}

case "\${1:-}" in
  --version)
    if [[ "\${SPOOF_VERSION}" == "1" ]]; then
      echo "Docker version 24.0.7, build \$(podman --version 2>/dev/null | awk '{print \$3}' || echo unknown)"
      exit 0
    fi
    ;;
  version)
    if [[ "\${SPOOF_VERSION}" == "1" ]] \
      && { [[ -z "\${2:-}" ]] || [[ "\${2:-}" == --format* ]]; }; then
      echo "Client: Docker Engine - Community"
      echo " Version:           24.0.7"
      echo " API version:       1.43"
      echo " Go version:        go1.20.10"
      echo " Git commit:        fluxo-caixa-podman-shim"
      echo " Built:             $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo " OS/Arch:           linux/amd64"
      echo " Context:           default"
      exit 0
    fi
    ;;
  compose)
    case "\${2:-}" in
      up|create|run|start)
        patch_compose_if_needed
        ;;
    esac
    ;;
esac
exec "\${REAL_DOCKER}" "\$@"
EOF
  run_as_root chmod 0755 "${shim_path}"
  log_info "installed Harbor docker shim: ${shim_path} (spoof_version=${spoof_version}, patch_compose=${patch_compose})"
}

download_harbor_installer() {
  local tarball="harbor-online-installer-v${HARBOR_VERSION}.tgz"
  local url="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/${tarball}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT

  if [[ -x "${HARBOR_INSTALL_DIR}/install.sh" ]] \
    && [[ -f "${HARBOR_INSTALL_DIR}/harbor.yml" ]]; then
    log_info "Harbor installer already present in ${HARBOR_INSTALL_DIR}"
    rm -rf "${tmp}"
    trap - EXIT
    return 0
  fi

  log_info "downloading Harbor v${HARBOR_VERSION} online installer..."
  curl -fsSL "${url}" -o "${tmp}/${tarball}"
  run_as_root mkdir -p "${HARBOR_INSTALL_DIR}"
  run_as_root tar -xzf "${tmp}/${tarball}" -C "${HARBOR_INSTALL_DIR}" --strip-components=1
  rm -rf "${tmp}"
  trap - EXIT
  log_info "Harbor installer extracted to ${HARBOR_INSTALL_DIR}"
}

reset_harbor_admin_password() {
  local db_container="${HARBOR_DB_CONTAINER:-harbor-db}"
  local core_container="${HARBOR_CORE_CONTAINER:-harbor-core}"
  local hash_script="${SCRIPT_DIR}/lib/harbor-password.py"
  local salt digest sql

  load_harbor_admin_credentials
  harbor_container_running "${db_container}" || return 1

  if ! wait_for_harbor_registry_db; then
    log_error "Harbor registry database not ready for admin password reset"
    return 1
  fi

  read -r salt digest < <(python3 "${hash_script}" "${HARBOR_ADMIN_PASSWORD}")
  sql="UPDATE harbor_user SET salt='${salt}', password='${digest}', password_version='sha256' WHERE user_id=1;"

  log_info "resetting Harbor admin password in registry DB to match harbor.yml..."
  if ! run_as_root docker exec -i "${db_container}" psql -U postgres -d registry -v ON_ERROR_STOP=1 \
    -c "${sql}"; then
    log_error "Harbor admin password reset failed (registry DB update)"
    return 1
  fi

  if harbor_container_running "${core_container}"; then
    log_info "restarting ${core_container} after admin password reset..."
    run_as_root docker restart "${core_container}" >/dev/null
    log_info "waiting for Harbor API after ${core_container} restart..."
    retry "${HARBOR_READY_ATTEMPTS}" "${HARBOR_READY_DELAY}" resolve_harbor_api_base
  fi
  return 0
}

run_harbor_install() {
  ensure_harbor_prepare_dirs
  local harbor_path="${PATH}"
  local shim_dir="${HARBOR_INSTALL_DIR}/.bin"
  if harbor_needs_docker_version_shim || harbor_uses_podman_runtime; then
    install_harbor_docker_shim
    harbor_path="${shim_dir}:${harbor_path}"
  fi
  if harbor_uses_podman_runtime; then
    install_harbor_compose_wrapper
    harbor_path="${shim_dir}:${harbor_path}"
  fi
  run_as_root env PATH="${harbor_path}" bash -c "cd '${HARBOR_INSTALL_DIR}' && ./install.sh ${HARBOR_INSTALL_FLAGS}"
}

install_harbor() {
  local config_changed=0
  generate_harbor_certs
  if render_harbor_yml; then
    config_changed=1
  fi

  ensure_container_runtime
  configure_podman_registries
  download_harbor_installer

  run_as_root mkdir -p "${HARBOR_DATA_VOLUME}"

  if resolve_harbor_api_base; then
    log_info "Harbor API already reachable at ${HARBOR_API_BASE}"
    if (( config_changed )); then
      log_info "reconfiguring Harbor (harbor.yml changed)..."
      run_harbor_install
    fi
    return 0
  fi

  log_info "installing Harbor (first run)..."
  run_harbor_install
}

wait_for_harbor() {
  log_info "waiting for Harbor API (${HARBOR_ALIAS}:${HARBOR_PORT})..."
  retry "${HARBOR_READY_ATTEMPTS}" "${HARBOR_READY_DELAY}" resolve_harbor_api_base
  log_info "Harbor API is ready at ${HARBOR_API_BASE}"
}

ensure_harbor_admin_auth() {
  if [[ "${HARBOR_MODE}" == "in-vm" ]] \
    && ! wait_for_harbor_registry_db; then
    log_error "Harbor registry database not ready for admin auth"
    return 1
  fi

  load_harbor_admin_credentials
  if harbor_admin_auth_ok; then
    log_info "Harbor UI/API auth OK (admin user)"
    return 0
  fi

  load_harbor_admin_credentials_from_core || true
  if harbor_admin_auth_ok; then
    log_info "Harbor UI/API auth OK (password from harbor-core env)"
    return 0
  fi

  if [[ "${HARBOR_MODE}" == "in-vm" ]] \
    && reset_harbor_admin_password; then
    resolve_harbor_api_base || true
    retry "${HARBOR_READY_ATTEMPTS}" "${HARBOR_READY_DELAY}" harbor_admin_auth_ok
    if harbor_admin_auth_ok; then
      log_info "Harbor UI/API auth OK after admin password reset"
      return 0
    fi
  fi

  local code auth tls_opt=()
  harbor_curl_ca_opt tls_opt
  auth="$(harbor_auth_header)"
  code="$(curl -s "${tls_opt[@]}" -o /dev/null -w '%{http_code}' \
    -H "${auth}" \
    "$(harbor_api_url "/api/v2.0/users/current")" || echo "000")"
  log_error "Harbor API auth failed (HTTP ${code})"
  return 1
}

verify_harbor_ui() {
  ensure_harbor_admin_auth
}

verify_harbor_https() {
  local ca="${HARBOR_CERTS_DIR}/ca.crt"
  if [[ ! -f "${ca}" ]]; then
    log_warn "Harbor CA missing; skipping HTTPS verification"
    return 0
  fi

  if curl -fsS --cacert "${ca}" "https://${HARBOR_ALIAS}/api/v2.0/systeminfo" >/dev/null 2>&1 \
    || curl -fsS --cacert "${ca}" "https://${HARBOR_ALIAS}:443/api/v2.0/systeminfo" >/dev/null 2>&1; then
    log_info "Harbor HTTPS endpoint OK (${HARBOR_ALIAS}:443)"
    return 0
  fi

  log_error "Harbor HTTPS endpoint not reachable with generated CA"
  return 1
}

finalize_registry_trust() {
  local ca_file="${HARBOR_CERTS_DIR}/ca.crt"
  if [[ -f "${ca_file}" ]]; then
    run_as_root mkdir -p "$(dirname "${HARBOR_CA_CERT}")"
    if [[ ! -f "${HARBOR_CA_CERT}" ]] \
      || ! cmp -s "${ca_file}" "${HARBOR_CA_CERT}" 2>/dev/null; then
      run_as_root install -m 0644 "${ca_file}" "${HARBOR_CA_CERT}"
      log_info "published Harbor CA: ${HARBOR_CA_CERT}"
    fi
    install_system_harbor_ca "${ca_file}"
  fi
  configure_k3s_registries
  configure_podman_registries
  write_registry_env_file
}

main() {
  log_info "deploy-registry.sh — in-VM Harbor (${HARBOR_ALIAS}:${HARBOR_PORT}, host=${HARBOR_HOST})"
  require_cmd curl
  require_cmd python3

  ensure_harbor_hosts_entry
  load_harbor_admin_credentials
  install_harbor
  wait_for_harbor
  ensure_harbor_admin_auth
  ensure_harbor_project
  verify_harbor_https
  finalize_registry_trust

  log_info "deploy-registry.sh — complete (mode=${HARBOR_MODE}, registry=${HARBOR_REGISTRY}, images=${HARBOR_IMAGE_REGISTRY}, project=${HARBOR_PROJECT})"
  log_info "  push/pull: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/<image>:<tag>"
  log_info "  UI:        http://${HARBOR_ALIAS}:${HARBOR_PORT}  (admin / ${HARBOR_ADMIN_PASSWORD})"
  log_info "  HTTPS:     https://${HARBOR_ALIAS}:443"
}

main "$@"
