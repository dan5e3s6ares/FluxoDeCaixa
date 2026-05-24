#!/usr/bin/env bash
# Validate Harbor docker-compose syslog patch for podman-docker (no root / Harbor required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

failures=0

patch_compose_sample() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    lines = fh.readlines()

out = []
skip = False
removed = 0
for line in lines:
    if re.match(r"^    logging:\s*$", line):
        skip = True
        removed += 1
        continue
    if skip:
        if re.match(r"^      ", line):
            continue
        skip = False
    out.append(line)

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
print(removed)
PY
}

test_removes_syslog_logging_blocks() {
  local tmp compose removed
  tmp="$(mktemp -d)"
  compose="${tmp}/docker-compose.yml"
  cat >"${compose}" <<'EOF'
services:
  registry:
    image: goharbor/registry-photon:v2.10.2
    depends_on:
      - log
    logging:
      driver: "syslog"
      options:
        syslog-address: "tcp://localhost:1514"
        tag: "registry"
    networks:
      - harbor
  portal:
    image: goharbor/harbor-portal:v2.10.2
    logging:
      driver: "syslog"
      options:
        syslog-address: "tcp://localhost:1514"
        tag: "portal"
    networks:
      - harbor
EOF

  removed="$(patch_compose_sample "${compose}")"
  if [[ "${removed}" != "2" ]]; then
    log_error "expected 2 logging blocks removed, got ${removed}"
    failures=$((failures + 1))
    return
  fi
  if grep -q 'logging:' "${compose}" || grep -q 'syslog' "${compose}"; then
    log_error "syslog logging blocks still present after patch"
    failures=$((failures + 1))
    return
  fi
  if ! grep -q 'depends_on:' "${compose}" || ! grep -q 'networks:' "${compose}"; then
    log_error "non-logging service keys were removed"
    failures=$((failures + 1))
    return
  fi
  log_info "OK removes syslog logging blocks from Harbor compose"
  rm -rf "${tmp}"
}

test_noop_without_logging_blocks() {
  local tmp compose removed
  tmp="$(mktemp -d)"
  compose="${tmp}/docker-compose.yml"
  cat >"${compose}" <<'EOF'
services:
  log:
    image: goharbor/harbor-log:v2.10.2
    networks:
      - harbor
EOF

  removed="$(patch_compose_sample "${compose}")"
  if [[ "${removed}" != "0" ]]; then
    log_error "expected 0 logging blocks removed, got ${removed}"
    failures=$((failures + 1))
  else
    log_info "OK compose without logging blocks unchanged"
  fi
  rm -rf "${tmp}"
}

main() {
  log_info "test-harbor-compose-patch.sh — Harbor podman syslog compose patch"
  test_removes_syslog_logging_blocks
  test_noop_without_logging_blocks
  if (( failures > 0 )); then
    log_error "${failures} assertion(s) failed"
    exit 1
  fi
  log_info "test-harbor-compose-patch.sh — all checks passed"
}

main "$@"
