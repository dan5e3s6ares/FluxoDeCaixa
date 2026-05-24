#!/usr/bin/env bash
# Validate Harbor docker shim patches syslog blocks before `docker compose up`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

test_docker_shim_patches_compose_up() {
  local tmp shim_dir real_docker compose
  tmp="$(mktemp -d)"
  shim_dir="${tmp}/bin"
  real_docker="${shim_dir}/real-docker"
  compose="${tmp}/docker-compose.yml"
  mkdir -p "${shim_dir}"

  cat >"${real_docker}" <<'EOF'
#!/usr/bin/env bash
echo "real-docker $*"
EOF
  chmod +x "${real_docker}"

  cat >"${compose}" <<'EOF'
services:
  redis:
    image: goharbor/redis-photon:v2.10.2
    logging:
      driver: "syslog"
      options:
        syslog-address: "tcp://localhost:1514"
EOF

  cat >"${shim_dir}/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
REAL_DOCKER='${real_docker}'
HARBOR_COMPOSE='${compose}'
PATCH_SCRIPT='${SCRIPT_DIR}/lib/patch-harbor-compose.py'
SPOOF_VERSION='0'
PATCH_COMPOSE='1'

patch_compose_if_needed() {
  [[ "\${PATCH_COMPOSE}" == "1" ]] || return 0
  [[ -f "\${HARBOR_COMPOSE}" ]] || return 0
  python3 "\${PATCH_SCRIPT}" "\${HARBOR_COMPOSE}" >/dev/null 2>&1 || true
}

case "\${1:-}" in
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
  chmod +x "${shim_dir}/docker"

  PATH="${shim_dir}:${PATH}" docker compose up -d >/dev/null

  if grep -q 'logging:' "${compose}" || grep -q 'syslog' "${compose}"; then
    log_error "docker shim did not strip syslog logging before compose up"
    failures=$((failures + 1))
  else
    log_info "OK docker shim strips syslog logging before compose up"
  fi
  rm -rf "${tmp}"
}

main() {
  log_info "test-harbor-docker-shim.sh — Harbor docker compose shim"
  test_docker_shim_patches_compose_up
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-docker-shim.sh — all checks passed"
}

main "$@"
