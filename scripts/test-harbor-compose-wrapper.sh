#!/usr/bin/env bash
# Validate Harbor docker-compose wrapper patches syslog blocks before compose up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

test_compose_wrapper_patches_before_up() {
  local tmp shim_dir real_compose compose removed
  tmp="$(mktemp -d)"
  shim_dir="${tmp}/bin"
  real_compose="${shim_dir}/real-docker-compose"
  compose="${tmp}/docker-compose.yml"
  mkdir -p "${shim_dir}"

  cat >"${real_compose}" <<'EOF'
#!/usr/bin/env bash
echo "real-compose $*"
EOF
  chmod +x "${real_compose}"

  cat >"${compose}" <<'EOF'
services:
  registry:
    image: goharbor/registry-photon:v2.10.2
    logging:
      driver: "syslog"
      options:
        syslog-address: "tcp://localhost:1514"
EOF

  cat >"${shim_dir}/docker-compose" <<EOF
#!/usr/bin/env bash
set -euo pipefail
HARBOR_COMPOSE='${compose}'
PATCH_SCRIPT='${SCRIPT_DIR}/lib/patch-harbor-compose.py'
REAL_COMPOSE='${real_compose}'

patch_compose_if_needed() {
  [[ -f "\${HARBOR_COMPOSE}" ]] || return 0
  python3 "\${PATCH_SCRIPT}" "\${HARBOR_COMPOSE}" >/dev/null 2>&1 || true
}

case "\${1:-}" in
  up|create|run|start)
    patch_compose_if_needed
    ;;
esac
exec "\${REAL_COMPOSE}" "\$@"
EOF
  chmod +x "${shim_dir}/docker-compose"

  PATH="${shim_dir}:${PATH}" docker-compose up -d >/dev/null

  if grep -q 'logging:' "${compose}" || grep -q 'syslog' "${compose}"; then
    log_error "compose wrapper did not strip syslog logging before up"
    failures=$((failures + 1))
  else
    log_info "OK compose wrapper strips syslog logging before up"
  fi
  rm -rf "${tmp}"
}

main() {
  log_info "test-harbor-compose-wrapper.sh — Harbor docker-compose wrapper"
  test_compose_wrapper_patches_before_up
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-compose-wrapper.sh — all checks passed"
}

main "$@"
