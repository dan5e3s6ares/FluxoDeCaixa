#!/usr/bin/env bash
# Build app images locally and load them into k3s containerd (no registry).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SVC="${SVC:-}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
ALL_SERVICES=(lancamentos consolidado consulta)

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

image_ref_for_service() {
  local svc="$1"
  printf 'fluxo-caixa/%s:%s' "${svc}" "${IMAGE_TAG}"
}

resolve_services() {
  local -n _out="$1"
  _out=()

  if [[ -z "${SVC}" ]]; then
    _out=("${ALL_SERVICES[@]}")
    return 0
  fi

  local svc
  for svc in "${ALL_SERVICES[@]}"; do
    if [[ "${svc}" == "${SVC}" ]]; then
      _out=("${svc}")
      return 0
    fi
  done

  log_error "Unknown SVC='${SVC}'. Valid: ${ALL_SERVICES[*]}"
  exit 1
}

build_service_image() {
  local svc="$1"
  local dockerfile image_ref

  dockerfile="${REPO_ROOT}/services/${svc}/Dockerfile"
  image_ref="$(image_ref_for_service "${svc}")"

  if [[ ! -f "${dockerfile}" ]]; then
    log_error "Dockerfile not found: ${dockerfile}"
    exit 1
  fi

  log_info "building ${image_ref} (context=${REPO_ROOT}, dockerfile=services/${svc}/Dockerfile)..."
  podman build -f "${dockerfile}" -t "${image_ref}" "${REPO_ROOT}"
}

import_image_to_k3s() {
  local image_ref="$1"

  log_info "importing ${image_ref} into k3s containerd..."
  podman save "${image_ref}" | run_as_root k3s ctr images import -
}

main() {
  local services=()
  local svc image_ref

  require_cmd podman
  require_cmd k3s

  resolve_services services

  log_info "build-images.sh — services=${services[*]} tag=${IMAGE_TAG}"

  for svc in "${services[@]}"; do
    build_service_image "${svc}"
    image_ref="$(image_ref_for_service "${svc}")"
    import_image_to_k3s "${image_ref}"
  done

  log_info "build-images.sh — complete (${#services[@]} image(s) @ :${IMAGE_TAG})"
}

main "$@"
