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

resolve_podman_image_ref() {
  local image_ref="$1"

  if podman image exists "${image_ref}" 2>/dev/null; then
    printf '%s' "${image_ref}"
    return 0
  fi
  if podman image exists "localhost/${image_ref}" 2>/dev/null; then
    printf 'localhost/%s' "${image_ref}"
    return 0
  fi

  log_error "Image not found in podman: ${image_ref} (also tried localhost/${image_ref})"
  exit 1
}

ensure_k3s_image_tag() {
  local image_ref="$1"

  if run_as_root k3s ctr images ls -q | grep -Fx "${image_ref}" >/dev/null 2>&1; then
    return 0
  fi
  if run_as_root k3s ctr images ls -q | grep -Fx "localhost/${image_ref}" >/dev/null 2>&1; then
    log_info "tagging localhost/${image_ref} as ${image_ref} for k8s manifests..."
    run_as_root k3s ctr images tag "localhost/${image_ref}" "${image_ref}"
  fi
}

import_image_to_k3s() {
  local image_ref="$1"
  local podman_ref tarball

  log_info "importing ${image_ref} into k3s containerd..."
  podman_ref="$(resolve_podman_image_ref "${image_ref}")"
  tarball="$(mktemp /tmp/fluxo-caixa-image-XXXXXX.tar)"

  # Save to a tarball first; piping podman save into `k3s ctr images import -`
  # often fails with "progress stream failed to recv" / EOF under sudo.
  podman save -o "${tarball}" "${podman_ref}"

  if ! retry 3 5 run_as_root k3s ctr images import "${tarball}"; then
    rm -f "${tarball}"
    log_error "failed to import ${image_ref} into k3s containerd"
    exit 1
  fi
  rm -f "${tarball}"

  ensure_k3s_image_tag "${image_ref}"
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
