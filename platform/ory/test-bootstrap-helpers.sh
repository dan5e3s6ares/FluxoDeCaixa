#!/usr/bin/env sh
# Unit tests for bootstrap.sh JSON helpers (no cluster required).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(
  sed -n \
    -e '/^json_field_present()/,/^}/p' \
    -e '/^log()/,/^}/p' \
    "${SCRIPT_DIR}/bootstrap.sh"
)"

assert_eq() {
  local name="$1"
  local want="$2"
  local got="$3"
  if [ "${want}" != "${got}" ]; then
    echo "FAIL ${name}: want '${want}' got '${got}'" >&2
    exit 1
  fi
  echo "ok ${name}"
}

assert_match() {
  local name="$1"
  if printf '%s' "$2" | json_field_present "$3" "$4"; then
    echo "ok ${name}"
    return 0
  fi
  echo "FAIL ${name}: field ${3}=${4} not found in ${2}" >&2
  exit 1
}

assert_match "json_field_present client_id" \
  '{"client_id": "svc-lancamentos","metadata":{"merchant_id":"00000000-0000-4000-8000-000000000001"}}' \
  client_id svc-lancamentos

assert_match "json_field_present issuer" \
  '{"issuer":"http://hydra-public.security.svc.cluster.local:4444/"}' \
  issuer "http://hydra-public.security.svc.cluster.local:4444/"

if log_msg="$(log 'stderr-only test' 2>&1 >/dev/null)"; then
  : "log wrote to stderr"
else
  log_msg=""
fi
assert_eq "log writes to stderr" "[ory-bootstrap] stderr-only test" "${log_msg}"

grep -q 'ensure_oauth2_client' "${SCRIPT_DIR}/bootstrap.sh"
echo "ok bootstrap defines ensure_oauth2_client"

grep -q 'ORY_SKIP_READY_WAIT' "${SCRIPT_DIR}/../deploy/ory/bootstrap-job.yaml" 2>/dev/null \
  || grep -q 'ORY_SKIP_READY_WAIT' "${SCRIPT_DIR}/../../deploy/ory/bootstrap-job.yaml"
echo "ok bootstrap job supports ORY_SKIP_READY_WAIT"

grep -q 'alpine:3.20' "${SCRIPT_DIR}/../../deploy/ory/bootstrap-job.yaml"
echo "ok bootstrap job uses alpine shell image"

echo "platform/ory/test-bootstrap-helpers.sh — all tests passed"
