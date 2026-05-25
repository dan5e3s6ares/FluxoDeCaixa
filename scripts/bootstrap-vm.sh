#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

MIN_CPUS="${MIN_CPUS:-8}"
MIN_RAM_MB="${MIN_RAM_MB:-16384}"
MIN_DISK_GB="${MIN_DISK_GB:-100}"

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
  else
    log_info "installing podman..."
    run_as_root apt-get update -qq
    run_as_root apt-get install -y -qq podman
  fi
  ensure_podman_nodocker
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
  ensure_k3s_port_available

  if command -v k3s >/dev/null 2>&1; then
    log_info "k3s already installed"
  else
    log_info "installing k3s..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
  fi

  if command -v systemctl >/dev/null 2>&1 \
    && ! run_as_root systemctl is-active --quiet k3s 2>/dev/null; then
    ensure_k3s_port_available
    log_info "starting k3s service..."
    run_as_root systemctl enable --now k3s
  fi
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

  resolve_harbor_config
  log_info "Harbor config: mode=${HARBOR_MODE} registry=${HARBOR_REGISTRY} image_ref=${HARBOR_IMAGE_REGISTRY}"

  ensure_harbor_hosts_entry
  configure_k3s_registries
  configure_podman_registries
  write_registry_env_file

  install_make
  install_podman
  install_uv
  install_k3s

  if [[ -f "${HARBOR_CA_CERT}" ]]; then
    install_system_harbor_ca "${HARBOR_CA_CERT}"
    configure_k3s_registries
  elif [[ "${HARBOR_MODE}" == "external" ]]; then
    configure_harbor_trust
  else
    log_info "in-VM Harbor CA not yet published — configure_harbor_trust will finalize trust when Harbor is available"
  fi

  verify_commands
  log_info "bootstrap-vm.sh — complete (registry env: ${REGISTRY_ENV_FILE})"
}

main "$@"
