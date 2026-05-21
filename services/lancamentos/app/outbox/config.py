"""Outbox worker constants (doc 03/05, task 6a0d8c9fbac06030d516c09b)."""

from __future__ import annotations

EVENT_SUBJECT = "lancamentos.lancamento_registrado.v1"
DLQ_SUBJECT = "lancamentos.dlq.lancamento_registrado.v1"
POLL_INTERVAL_SECONDS = 2
DLQ_MAX_FAILURES = 10
CLAIM_BATCH_SIZE = 50
