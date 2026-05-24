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

HARBOR_INSTALL_FLAGS="${HARBOR_INSTALL_FLAGS:---with-trivy false --with-notary false --with-chartmuseum false}"

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

harbor_auth_header() {
  printf 'Authorization: Basic %s' "$(printf '%s:%s' "${HARBOR_ADMIN_USER}" "${HARBOR_ADMIN_PASSWORD}" | base64 -w0 2>/dev/null || printf '%s:%s' "${HARBOR_ADMIN_USER}" "${HARBOR_ADMIN_PASSWORD}" | base64)"
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
      log_info "podman-docker runtime ready"
      return 0
    fi
  fi

  log_error "No working container runtime (docker/podman). Run bootstrap-vm.sh first."
  exit 1
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

run_harbor_install() {
  run_as_root bash -c "cd '${HARBOR_INSTALL_DIR}' && ./prepare && ./install.sh ${HARBOR_INSTALL_FLAGS}"
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

  if harbor_api_ready; then
    log_info "Harbor API already reachable at http://${HARBOR_REGISTRY}"
    if (( config_changed )); then
      log_info "reconfiguring Harbor (harbor.yml changed)..."
      run_harbor_install
    fi
    return 0
  fi

  log_info "installing Harbor (first run)..."
  run_harbor_install
}

harbor_api_ready() {
  curl -fsS "http://${HARBOR_REGISTRY}/api/v2.0/systeminfo" >/dev/null 2>&1 \
    || curl -fsS "http://${HARBOR_ALIAS}:${HARBOR_PORT}/api/v2.0/systeminfo" >/dev/null 2>&1
}

wait_for_harbor() {
  log_info "waiting for Harbor API (http://${HARBOR_REGISTRY})..."
  retry "${HARBOR_READY_ATTEMPTS}" "${HARBOR_READY_DELAY}" harbor_api_ready
  log_info "Harbor API is ready"
}

ensure_harbor_project() {
  local project_id auth
  auth="$(harbor_auth_header)"

  project_id="$(curl -fsS -H "${auth}" \
    "http://${HARBOR_REGISTRY}/api/v2.0/projects?project_name=${HARBOR_PROJECT}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['project_id'] if d else '')" 2>/dev/null || true)"

  if [[ -n "${project_id}" ]]; then
    log_info "Harbor project exists: ${HARBOR_PROJECT} (id=${project_id})"
    return 0
  fi

  log_info "creating Harbor project: ${HARBOR_PROJECT}"
  curl -fsS -H "${auth}" \
    -X POST "http://${HARBOR_REGISTRY}/api/v2.0/projects" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":false,\"metadata\":{\"public\":\"false\"}}"
  log_info "Harbor project created: ${HARBOR_PROJECT}"
}

verify_harbor_ui() {
  local code auth
  auth="$(harbor_auth_header)"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "${auth}" \
    "http://${HARBOR_REGISTRY}/api/v2.0/users/current" || echo "000")"
  if [[ "${code}" == "200" ]]; then
    log_info "Harbor UI/API auth OK (admin user)"
    return 0
  fi
  log_error "Harbor API auth failed (HTTP ${code})"
  return 1
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
  install_harbor
  wait_for_harbor
  ensure_harbor_project
  verify_harbor_ui
  verify_harbor_https
  finalize_registry_trust

  log_info "deploy-registry.sh — complete (mode=${HARBOR_MODE}, registry=${HARBOR_REGISTRY}, images=${HARBOR_IMAGE_REGISTRY}, project=${HARBOR_PROJECT})"
  log_info "  push/pull: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/<image>:<tag>"
  log_info "  UI:        http://${HARBOR_ALIAS}:${HARBOR_PORT}  (admin / ${HARBOR_ADMIN_PASSWORD})"
  log_info "  HTTPS:     https://${HARBOR_ALIAS}:443"
}

main "$@"
