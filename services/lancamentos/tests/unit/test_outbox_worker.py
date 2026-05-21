"""Outbox worker — publish, backoff, DLQ (doc 03)."""

from __future__ import annotations

import asyncio
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.outbox.config import DLQ_MAX_FAILURES, EVENT_SUBJECT
from app.services.nats_publisher import PublishResult
from app.workers.outbox_worker import OutboxWorker


class FakePublisher:
    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []
        self.dlq: list[dict[str, Any]] = []
        self.failures = 0
        self.fail_until = 0
        self.dlq_fail = False

    async def publish_event(self, payload: dict[str, Any]) -> PublishResult:
        self.events.append(payload)
        self.failures += 1
        if self.failures <= self.fail_until:
            raise ConnectionError("nats unavailable")
        return PublishResult(subject=EVENT_SUBJECT)

    async def publish_dlq(self, payload: dict[str, Any]) -> PublishResult:
        if self.dlq_fail:
            raise ConnectionError("dlq unavailable")
        self.dlq.append(payload)
        return PublishResult(subject="lancamentos.dlq.lancamento_registrado.v1")


@pytest.fixture
def sample_payload() -> dict[str, Any]:
    return {
        "event_id": "11111111-1111-4111-8111-111111111111",
        "event_type": "LancamentoRegistrado",
        "event_version": 1,
        "occurred_at": "2026-05-20T10:00:00Z",
        "correlation_id": "22222222-2222-4222-8222-222222222222",
        "payload": {
            "lancamento_id": "33333333-3333-4333-8333-333333333333",
            "merchant_id": "44444444-4444-4444-8444-444444444444",
            "valor": "10.00",
            "tipo": "CREDITO",
            "data_competencia": "2026-05-20",
            "descricao": None,
        },
    }


def test_process_row_publishes_and_marks_published(sample_payload: dict[str, Any]) -> None:
    publisher = FakePublisher()
    repo = MagicMock()
    session = MagicMock()
    worker = OutboxWorker(repo=repo, publisher=publisher)

    asyncio.run(
        worker._process_row(
            session,
            {
                "id": 1,
                "payload": sample_payload,
                "failure_count": 0,
            },
        )
    )

    assert len(publisher.events) == 1
    repo.mark_published.assert_called_once_with(session, outbox_id=1)


def test_process_row_records_failure_with_backoff(sample_payload: dict[str, Any]) -> None:
    publisher = FakePublisher()
    publisher.fail_until = 99
    repo = MagicMock()
    repo.record_failure.return_value = 1
    session = MagicMock()
    worker = OutboxWorker(repo=repo, publisher=publisher)

    asyncio.run(
        worker._process_row(
            session,
            {"id": 2, "payload": sample_payload, "failure_count": 0},
        )
    )

    repo.record_failure.assert_called_once_with(
        session, outbox_id=2, current_failure_count=0
    )
    repo.mark_published.assert_not_called()


def test_process_row_publishes_dlq_after_max_failures(sample_payload: dict[str, Any]) -> None:
    publisher = FakePublisher()
    publisher.fail_until = 99
    repo = MagicMock()
    repo.record_failure.return_value = DLQ_MAX_FAILURES
    session = MagicMock()
    worker = OutboxWorker(repo=repo, publisher=publisher)

    asyncio.run(
        worker._process_row(
            session,
            {
                "id": 3,
                "payload": sample_payload,
                "failure_count": DLQ_MAX_FAILURES - 1,
            },
        )
    )

    assert len(publisher.dlq) == 1
    repo.record_failure.assert_called_once()
    repo.mark_dlq.assert_called_once_with(session, outbox_id=3)


def test_process_row_at_max_failures_skips_event_publish(sample_payload: dict[str, Any]) -> None:
    publisher = FakePublisher()
    repo = MagicMock()
    session = MagicMock()
    worker = OutboxWorker(repo=repo, publisher=publisher)

    asyncio.run(
        worker._process_row(
            session,
            {
                "id": 4,
                "payload": sample_payload,
                "failure_count": DLQ_MAX_FAILURES,
            },
        )
    )

    assert len(publisher.events) == 0
    assert len(publisher.dlq) == 1
    repo.mark_dlq.assert_called_once_with(session, outbox_id=4)
    repo.record_failure.assert_not_called()


def test_process_row_dlq_publish_failure_schedules_retry(sample_payload: dict[str, Any]) -> None:
    publisher = FakePublisher()
    publisher.dlq_fail = True
    repo = MagicMock()
    session = MagicMock()
    worker = OutboxWorker(repo=repo, publisher=publisher)

    asyncio.run(
        worker._process_row(
            session,
            {
                "id": 5,
                "payload": sample_payload,
                "failure_count": DLQ_MAX_FAILURES,
            },
        )
    )

    repo.mark_dlq.assert_not_called()
    repo.schedule_dlq_retry.assert_called_once_with(session, outbox_id=5)


def test_poll_once_updates_pending_gauge(sample_payload: dict[str, Any]) -> None:
    publisher = FakePublisher()
    repo = MagicMock()
    repo.count_pending.return_value = 5
    repo.claim_batch.return_value = [
        {"id": 1, "payload": sample_payload, "failure_count": 0},
    ]

    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session

    worker = OutboxWorker(repo=repo, publisher=publisher)
    worker._session_factory = session_factory

    with patch("app.workers.outbox_worker.outbox_pending_gauge") as gauge:
        asyncio.run(worker._poll_once())
        gauge.set.assert_called_once_with(5)

    repo.mark_published.assert_called_once()
    session.commit.assert_called_once()


def test_nats_publisher_traceparent_header() -> None:
    from fcx_shared.tracing import traceparent_from_correlation_id

    tp = traceparent_from_correlation_id("22222222-2222-4222-8222-222222222222")
    assert tp.startswith("00-")
    assert tp.endswith("-01")
