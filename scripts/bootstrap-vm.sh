#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HARBOR_HOST="${HARBOR_HOST:-192.168.68.100}"
HARBOR_PORT="${HARBOR_PORT:-8080}"
HARBOR_REGISTRY="${HARBOR_HOST}:${HARBOR_PORT}"
HARBOR_ALIAS="${HARBOR_ALIAS:-harbor.local}"
HARBOR_CA_CERT="${HARBOR_CA_CERT:-${SCRIPT_DIR}/../deploy/certs/harbor-ca.crt}"

MIN_CPUS="${MIN_CPUS:-8}"
MIN_RAM_MB="${MIN_RAM_MB:-16384}"
MIN_DISK_GB="${MIN_DISK_GB:-100}"

K3S_REGISTRIES="/etc/rancher/k3s/registries.yaml"
PODMAN_REGISTRIES="/etc/containers/registries.conf.d/999-harbor.conf"
PODMAN_CERTS_DIR="/etc/containers/certs.d/${HARBOR_REGISTRY}"
SYSTEM_CA="/usr/local/share/ca-certificates/harbor-ca.crt"

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

validate_resources() {
  local cpus ram_mb disk_gb

  cpus="$(nproc)"
  if (( cpus < MIN_CPUS )); then
    log_error "Insufficient CPUs: ${cpus} (required >= ${MIN_CPUS})"
    exit 1
  fi
  log_info "CPU check passed: ${cpus} vCPU"

  ram_mb="$(awk '/MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo)"
  if (( ram_mb < MIN_RAM_MB )); then
    log_error "Insufficient RAM: ${ram_mb} MB (required >= ${MIN_RAM_MB} MB)"
    exit 1
  fi
  log_info "RAM check passed: ${ram_mb} MB"

  disk_gb="$(df -BG / | awk 'NR==2 {gsub(/G/,"",$2); print $2}')"
  if (( disk_gb < MIN_DISK_GB )); then
    log_error "Insufficient disk on /: ${disk_gb} GB (required >= ${MIN_DISK_GB} GB)"
    exit 1
  fi
  log_info "Disk check passed: ${disk_gb} GB on /"
}

ensure_hosts_entry() {
  if grep -qE "[[:space:]]${HARBOR_ALIAS}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    log_info "unchanged: /etc/hosts entry for ${HARBOR_ALIAS}"
    return 0
  fi
  log_info "adding /etc/hosts entry: ${HARBOR_HOST} ${HARBOR_ALIAS}"
  printf '%s %s\n' "${HARBOR_HOST}" "${HARBOR_ALIAS}" | run_as_root tee -a /etc/hosts >/dev/null
}

install_make() {
  if command -v make >/dev/null 2>&1; then
    log_info "make already installed"
    return 0
  fi
  log_info "installing make..."
  run_as_root apt-get update -qq
  run_as_root apt-get install -y -qq make
}

install_podman() {
  if command -v podman >/dev/null 2>&1; then
    log_info "podman already installed"
    return 0
  fi
  log_info "installing podman..."
  run_as_root apt-get update -qq
  run_as_root apt-get install -y -qq podman
}

install_uv() {
  if command -v uv >/dev/null 2>&1; then
    log_info "uv already installed"
    return 0
  fi
  log_info "installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.local/bin:${PATH}"
}

install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    log_info "k3s already installed"
    return 0
  fi
  log_info "installing k3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
}

fetch_harbor_ca() {
  local tmp_ca
  tmp_ca="$(mktemp)"

  if [[ -f "${HARBOR_CA_CERT}" ]]; then
    cp "${HARBOR_CA_CERT}" "${tmp_ca}"
    echo "${tmp_ca}"
    return 0
  fi

  if curl -fsSL "http://${HARBOR_REGISTRY}/api/v2.0/systeminfo/getcert" -o "${tmp_ca}" 2>/dev/null \
    && [[ -s "${tmp_ca}" ]]; then
    echo "${tmp_ca}"
    return 0
  fi

  rm -f "${tmp_ca}"
  return 1
}

configure_harbor_ca() {
  local ca_file tmp_ca=""
  local k3s_ca="/etc/rancher/k3s/harbor-ca.crt"
  local changed=0

  if ! tmp_ca="$(fetch_harbor_ca)"; then
    log_warn "Harbor CA not available; using insecure registry config only"
    return 0
  fi

  ca_file="${tmp_ca}"

  if [[ ! -f "${SYSTEM_CA}" ]] || ! cmp -s "${ca_file}" "${SYSTEM_CA}"; then
    run_as_root install -m 0644 "${ca_file}" "${SYSTEM_CA}"
    run_as_root update-ca-certificates
    log_info "updated system CA trust: ${SYSTEM_CA}"
    changed=1
  else
    log_info "unchanged: ${SYSTEM_CA}"
  fi

  if [[ ! -f "${k3s_ca}" ]] || ! cmp -s "${ca_file}" "${k3s_ca}"; then
    run_as_root install -m 0644 "${ca_file}" "${k3s_ca}"
    log_info "updated k3s CA: ${k3s_ca}"
    changed=1
  else
    log_info "unchanged: ${k3s_ca}"
  fi

  run_as_root mkdir -p "${PODMAN_CERTS_DIR}"
  if [[ ! -f "${PODMAN_CERTS_DIR}/ca.crt" ]] || ! cmp -s "${ca_file}" "${PODMAN_CERTS_DIR}/ca.crt"; then
    run_as_root install -m 0644 "${ca_file}" "${PODMAN_CERTS_DIR}/ca.crt"
    log_info "updated podman CA: ${PODMAN_CERTS_DIR}/ca.crt"
    changed=1
  else
    log_info "unchanged: ${PODMAN_CERTS_DIR}/ca.crt"
  fi

  rm -f "${tmp_ca}"

  if (( changed )) && command -v systemctl >/dev/null 2>&1 \
    && run_as_root systemctl is-active --quiet k3s 2>/dev/null; then
    log_info "restarting k3s to apply CA changes..."
    run_as_root systemctl restart k3s
  fi
}

configure_k3s_registries() {
  local changed=0
  local k3s_ca="/etc/rancher/k3s/harbor-ca.crt"
  local ca_block=""

  if [[ -f "${k3s_ca}" ]]; then
    ca_block="      ca_file: ${k3s_ca}"
  else
    ca_block="      insecure_skip_verify: true"
  fi

  if write_if_changed "${K3S_REGISTRIES}" <<EOF
mirrors:
  "${HARBOR_REGISTRY}":
    endpoint:
      - "http://${HARBOR_REGISTRY}"
  "${HARBOR_ALIAS}":
    endpoint:
      - "http://${HARBOR_REGISTRY}"
configs:
  "${HARBOR_REGISTRY}":
    tls:
${ca_block}
  "${HARBOR_ALIAS}":
    tls:
${ca_block}
EOF
  then
    changed=1
  fi

  if (( changed )) && command -v systemctl >/dev/null 2>&1 \
    && run_as_root systemctl is-active --quiet k3s 2>/dev/null; then
    log_info "restarting k3s to apply registry config..."
    run_as_root systemctl restart k3s
  fi
}

configure_podman_registries() {
  write_if_changed "${PODMAN_REGISTRIES}" <<EOF
[[registry]]
location = "${HARBOR_REGISTRY}"
insecure = true

[[registry]]
location = "${HARBOR_ALIAS}"
insecure = true
EOF
}

verify_commands() {
  export PATH="${HOME}/.local/bin:${PATH}"
  require_cmd make
  require_cmd podman
  require_cmd uv
  require_cmd k3s
  require_cmd kubectl
}

main() {
  log_info "bootstrap-vm.sh — validating VM resources and tooling"
  validate_resources
  ensure_hosts_entry
  configure_k3s_registries
  install_make
  install_podman
  install_uv
  install_k3s
  configure_harbor_ca
  configure_k3s_registries
  configure_podman_registries
  verify_commands
  log_info "bootstrap-vm.sh — complete"
}

main "$@"
