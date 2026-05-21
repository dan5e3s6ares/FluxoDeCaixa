"""NATS JetStream consumer settings (doc 03/07)."""

from __future__ import annotations

STREAM_NAME = "lancamentos.events"
CONSUMER_NAME = "consolidado-workers"
FILTER_SUBJECT = "lancamentos.lancamento_registrado.v1"
FETCH_BATCH = 10
FETCH_TIMEOUT_SECONDS = 5.0
POLL_IDLE_SECONDS = 1.0
