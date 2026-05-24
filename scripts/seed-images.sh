#!/usr/bin/env bash
# Build and push app images into Harbor after deploy-platform, before deploy-apps (first make start without CI).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/registry.sh
source "${SCRIPT_DIR}/lib/registry.sh"

HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
SEED_FORCE="${SEED_FORCE:-0}"
SEED_READY_ATTEMPTS="${SEED_READY_ATTEMPTS:-60}"
SEED_READY_DELAY="${SEED_READY_DELAY:-5}"

# service_dir -> Harbor image name (matches .gitea/workflows/ci.yaml)
declare -A SEED_IMAGE_NAMES=(
  [lancamentos]=svc-lancamentos
  [consolidado]=consolidado
  [consulta]=consulta
)

load_seed_env() {
  if source_registry_env; then
    log_info "loaded registry env (HARBOR_IMAGE_REGISTRY=${HARBOR_IMAGE_REGISTRY:-<unset>})"
  else
    resolve_harbor_config
    log_info "registry env missing — resolved mode=${HARBOR_MODE} images=${HARBOR_IMAGE_REGISTRY}"
  fi
}

harbor_auth_header() {
  printf 'Authorization: Basic %s' \
    "$(printf '%s:%s' "${HARBOR_ADMIN_USER}" "${HARBOR_ADMIN_PASSWORD}" | base64 -w0 2>/dev/null \
      || printf '%s:%s' "${HARBOR_ADMIN_USER}" "${HARBOR_ADMIN_PASSWORD}" | base64)"
}

ensure_harbor_project() {
  local project_id auth api_url
  auth="$(harbor_auth_header)"
  api_url="$(harbor_api_url "/api/v2.0/projects?project_name=${HARBOR_PROJECT}")"

  project_id="$(curl -fsS -H "${auth}" "${api_url}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['project_id'] if d else '')" 2>/dev/null || true)"

  if [[ -n "${project_id}" ]]; then
    log_info "Harbor project exists: ${HARBOR_PROJECT} (id=${project_id})"
    return 0
  fi

  log_info "creating Harbor project: ${HARBOR_PROJECT}"
  curl -fsS -H "${auth}" \
    -X POST "$(harbor_api_url "/api/v2.0/projects")" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":false,\"metadata\":{\"public\":\"false\"}}"
  log_info "Harbor project created: ${HARBOR_PROJECT}"
}

wait_for_harbor() {
  log_info "waiting for Harbor API (${HARBOR_ALIAS}:${HARBOR_PORT})..."
  retry "${SEED_READY_ATTEMPTS}" "${SEED_READY_DELAY}" resolve_harbor_api_base
  log_info "Harbor API is ready at ${HARBOR_API_BASE}"
}

detect_seed_tag() {
  if [[ -n "${SEED_IMAGE_TAG:-}" ]]; then
    echo "${SEED_IMAGE_TAG}"
    return 0
  fi

  local tag
  tag="$(
    grep -rhoE 'harbor\.local:[0-9]+/fluxo-caixa/[^:]+:main-[a-f0-9]+' \
      "${REPO_ROOT}/deploy/k8s/base" 2>/dev/null \
      | sed -E 's/.*:(main-[a-f0-9]+)$/\1/' \
      | sort -u
  )"

  if [[ -z "${tag}" ]]; then
    log_error "could not detect image tag from deploy/k8s/base manifests; set SEED_IMAGE_TAG"
    exit 1
  fi

  if [[ "$(printf '%s\n' "${tag}" | wc -l)" -gt 1 ]]; then
    log_error "multiple image tags in manifests — set SEED_IMAGE_TAG explicitly: ${tag}"
    exit 1
  fi

  echo "${tag}"
}

harbor_image_exists() {
  local image_name="$1"
  local tag="$2"
  local auth code

  auth="$(harbor_auth_header)"
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "${auth}" \
    "$(harbor_api_url "/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${image_name}/artifacts/${tag}")" \
    || echo "000")"
  [[ "${code}" == "200" ]]
}

podman_login_harbor() {
  local login_registry="${HARBOR_IMAGE_REGISTRY}"
  log_info "logging into Harbor (${login_registry})..."
  printf '%s\n' "${HARBOR_ADMIN_PASSWORD}" | podman login "${login_registry}" \
    -u "${HARBOR_ADMIN_USER}" --password-stdin
}

build_and_push() {
  local service_dir="$1"
  local image_name="$2"
  local tag="$3"
  local dockerfile image_ref

  dockerfile="${REPO_ROOT}/services/${service_dir}/Dockerfile"
  image_ref="${HARBOR_IMAGE_REGISTRY}/${HARBOR_PROJECT}/${image_name}:${tag}"

  if [[ ! -f "${dockerfile}" ]]; then
    log_error "Dockerfile not found: ${dockerfile}"
    exit 1
  fi

  if [[ "${SEED_FORCE}" != "1" ]] && harbor_image_exists "${image_name}" "${tag}"; then
    log_info "skip ${image_name}:${tag} — already in Harbor"
    return 0
  fi

  log_info "building ${image_ref}..."
  podman build -f "${dockerfile}" -t "${image_ref}" "${REPO_ROOT}"

  log_info "pushing ${image_ref}..."
  podman push "${image_ref}"
}

verify_seeded_images() {
  local service_dir image_name tag missing=0
  for service_dir in lancamentos consolidado consulta; do
    image_name="${SEED_IMAGE_NAMES[${service_dir}]}"
    tag="${SEED_TAG}"
    if harbor_image_exists "${image_name}" "${tag}"; then
      log_info "verified ${image_name}:${tag} in Harbor"
    else
      log_error "missing in Harbor: ${image_name}:${tag}"
      missing=1
    fi
  done
  if (( missing )); then
    exit 1
  fi
}

main() {
  if [[ "${SELF_CONTAINED:-1}" == "0" ]] || [[ -n "${HARBOR_EXTERNAL:-}" ]]; then
    log_info "seed-images.sh — skipped (SELF_CONTAINED=${SELF_CONTAINED:-1}, HARBOR_EXTERNAL=${HARBOR_EXTERNAL:-<unset>})"
    exit 0
  fi

  require_cmd podman
  require_cmd curl
  require_cmd git
  require_cmd python3

  log_info "seed-images.sh — seeding app images into in-VM Harbor"
  load_seed_env

  SEED_TAG="$(detect_seed_tag)"
  log_info "image tag=${SEED_TAG} registry=${HARBOR_IMAGE_REGISTRY}/${HARBOR_PROJECT}"

  wait_for_harbor
  podman_login_harbor
  ensure_harbor_project

  local service_dir image_name
  for service_dir in lancamentos consolidado consulta; do
    image_name="${SEED_IMAGE_NAMES[${service_dir}]}"
    build_and_push "${service_dir}" "${image_name}" "${SEED_TAG}"
  done

  podman logout "${HARBOR_IMAGE_REGISTRY}" >/dev/null 2>&1 || true
  verify_seeded_images

  log_info "seed-images.sh — complete (${#SEED_IMAGE_NAMES[@]} images @ ${SEED_TAG})"
}

main "$@"
