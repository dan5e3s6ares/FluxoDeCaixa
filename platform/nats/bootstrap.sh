#!/usr/bin/env sh
# Idempotent JetStream bootstrap per docs 03/07.
set -eu

NATS_URL="${NATS_URL:-nats://nats.messaging.svc.cluster.local:4222}"
export NATS_URL

log() {
  echo "[nats-bootstrap] $*"
}

wait_for_nats() {
  local attempt=1
  local max="${NATS_WAIT_ATTEMPTS:-60}"
  local delay="${NATS_WAIT_DELAY:-2}"
  while [ "${attempt}" -le "${max}" ]; do
    if nats server check connection 2>/dev/null; then
      log "connected to ${NATS_URL}"
      return 0
    fi
    log "waiting for NATS (${attempt}/${max})..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
  log "NATS not reachable at ${NATS_URL}"
  return 1
}

stream_exists() {
  nats stream info "$1" >/dev/null 2>&1
}

consumer_exists() {
  nats consumer info "$1" "$2" >/dev/null 2>&1
}

ensure_stream_lancamentos_events() {
  if stream_exists lancamentos.events; then
    log "stream lancamentos.events already exists"
    return 0
  fi
  log "creating stream lancamentos.events"
  nats stream add lancamentos.events \
    --subjects "lancamentos.lancamento_registrado.v1" \
    --retention limits \
    --max-age 168h \
    --storage file \
    --replicas 1 \
    --discard old \
    --defaults
}

ensure_stream_dlq() {
  if stream_exists lancamentos.dlq; then
    log "stream lancamentos.dlq already exists"
    return 0
  fi
  log "creating stream lancamentos.dlq"
  nats stream add lancamentos.dlq \
    --subjects "lancamentos.dlq.>" \
    --retention limits \
    --max-age 720h \
    --storage file \
    --replicas 1 \
    --discard old \
    --defaults
}

ensure_consumer_consolidado_workers() {
  if consumer_exists lancamentos.events consolidado-workers; then
    log "consumer consolidado-workers already exists"
    return 0
  fi
  log "creating durable consumer consolidado-workers"
  nats consumer add lancamentos.events consolidado-workers \
    --pull \
    --ack explicit \
    --deliver all \
    --max-deliver 3 \
    --replay instant \
    --defaults
}

main() {
  wait_for_nats
  ensure_stream_lancamentos_events
  ensure_stream_dlq
  ensure_consumer_consolidado_workers
  log "bootstrap complete"
  nats stream ls
  nats consumer ls lancamentos.events
}

main "$@"
