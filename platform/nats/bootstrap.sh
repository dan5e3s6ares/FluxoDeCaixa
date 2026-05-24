#!/usr/bin/env sh
# Idempotent JetStream bootstrap per docs 03/07.
set -eu

NATS_URL="${NATS_URL:-nats://nats.messaging.svc.cluster.local:4222}"
export NATS_URL

# JetStream stream names must not contain '.' (NATS naming rules); subjects keep dots.
EVENTS_STREAM="${EVENTS_STREAM:-lancamentos_events}"
DLQ_STREAM="${DLQ_STREAM:-lancamentos_dlq}"
EVENT_SUBJECT="${EVENT_SUBJECT:-lancamentos.lancamento_registrado.v1}"
CONSUMER_NAME="${CONSUMER_NAME:-consolidado-workers}"

log() {
  echo "[nats-bootstrap] $*"
}

wait_for_nats() {
  local attempt=1
  local max="${NATS_WAIT_ATTEMPTS:-60}"
  local delay="${NATS_WAIT_DELAY:-2}"
  while [ "${attempt}" -le "${max}" ]; do
    if nats server check connection 2>/dev/null \
      && nats server check jetstream 2>/dev/null; then
      log "connected to ${NATS_URL} (JetStream ready)"
      return 0
    fi
    log "waiting for NATS (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
  log "NATS/JetStream not reachable at ${NATS_URL}"
  return 1
}

stream_exists() {
  nats stream info "$1" >/dev/null 2>&1
}

consumer_exists() {
  nats consumer info "$1" "$2" >/dev/null 2>&1
}

ensure_stream_lancamentos_events() {
  if stream_exists "${EVENTS_STREAM}"; then
    log "stream ${EVENTS_STREAM} already exists"
    return 0
  fi
  log "creating stream ${EVENTS_STREAM}"
  nats stream add "${EVENTS_STREAM}" \
    --subjects "${EVENT_SUBJECT}" \
    --retention limits \
    --max-age 168h \
    --storage file \
    --replicas 1 \
    --discard old \
    --defaults
}

ensure_stream_dlq() {
  # Business DLQ (lancamentos.dlq.>) plus JetStream advisories when consolidado-workers
  # exhausts max-deliver (doc 03: 3 retries → DLQ lancamentos.dlq).
  local dlq_subjects
  dlq_subjects="lancamentos.dlq.>,\$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.${EVENTS_STREAM}.${CONSUMER_NAME},\$JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.${EVENTS_STREAM}.${CONSUMER_NAME}"
  if stream_exists "${DLQ_STREAM}"; then
    log "stream ${DLQ_STREAM} already exists"
    return 0
  fi
  log "creating stream ${DLQ_STREAM}"
  nats stream add "${DLQ_STREAM}" \
    --subjects "${dlq_subjects}" \
    --retention limits \
    --max-age 720h \
    --storage file \
    --replicas 1 \
    --discard old \
    --defaults
}

ensure_consumer_consolidado_workers() {
  if consumer_exists "${EVENTS_STREAM}" "${CONSUMER_NAME}"; then
    log "consumer ${CONSUMER_NAME} already exists"
    return 0
  fi
  log "creating durable consumer ${CONSUMER_NAME}"
  # Backoff 1s, 5s, 30s per doc 03; max-deliver 3 routes failures to lancamentos.dlq advisories.
  nats consumer add "${EVENTS_STREAM}" "${CONSUMER_NAME}" \
    --pull \
    --ack explicit \
    --deliver all \
    --max-deliver 3 \
    --replay instant \
    --wait 1s \
    --filter "${EVENT_SUBJECT}" \
    --defaults
}

main() {
  wait_for_nats
  ensure_stream_lancamentos_events
  ensure_stream_dlq
  ensure_consumer_consolidado_workers
  log "bootstrap complete"
  nats stream ls
  nats consumer ls "${EVENTS_STREAM}"
}

main "$@"
