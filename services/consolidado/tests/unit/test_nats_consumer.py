"""NATS consumer loop unit tests (mocked JetStream)."""

from __future__ import annotations

import asyncio
import json
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

from app.workers.nats_consumer import NatsConsumerWorker


class FakeMsg:
    def __init__(
        self,
        payload: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.data = json.dumps(payload).encode("utf-8")
        self.headers = headers
        self.ack = AsyncMock()
        self.nak = AsyncMock()


def sample_envelope() -> dict[str, Any]:
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


def test_handle_message_acks_on_success() -> None:
    processor = AsyncMock()
    worker = NatsConsumerWorker(processor=processor)
    envelope = sample_envelope()
    msg = FakeMsg(envelope, headers={"traceparent": "00-abc-01"})

    asyncio.run(worker._handle_message(msg))  # type: ignore[arg-type]

    processor.handle.assert_awaited_once_with(
        envelope,
        headers={"traceparent": "00-abc-01"},
    )
    msg.ack.assert_awaited_once()
    msg.nak.assert_not_awaited()


def test_handle_message_acks_on_duplicate_event_idempotency() -> None:
    processor = AsyncMock()
    worker = NatsConsumerWorker(processor=processor)
    msg = FakeMsg(sample_envelope())

    asyncio.run(worker._handle_message(msg))  # type: ignore[arg-type]

    processor.handle.assert_awaited_once()
    msg.ack.assert_awaited_once()
    msg.nak.assert_not_awaited()


def test_handle_message_naks_on_invalid_envelope() -> None:
    processor = AsyncMock()
    worker = NatsConsumerWorker(processor=processor)

    class BadMsg:
        data = json.dumps(["not", "an", "object"]).encode("utf-8")
        headers = None
        ack = AsyncMock()
        nak = AsyncMock()

    msg = BadMsg()
    asyncio.run(worker._handle_message(msg))  # type: ignore[arg-type]

    processor.handle.assert_not_awaited()
    msg.nak.assert_awaited_once()
    msg.ack.assert_not_awaited()


def test_handle_message_naks_on_processor_error() -> None:
    processor = AsyncMock()
    processor.handle.side_effect = RuntimeError("db down")
    worker = NatsConsumerWorker(processor=processor)
    msg = FakeMsg(sample_envelope())

    asyncio.run(worker._handle_message(msg))  # type: ignore[arg-type]

    msg.nak.assert_awaited_once()
    msg.ack.assert_not_awaited()


def test_poll_once_fetches_and_handles_messages() -> None:
    processor = AsyncMock()
    worker = NatsConsumerWorker(processor=processor)
    subscription = MagicMock()
    subscription.fetch = AsyncMock(return_value=[FakeMsg(sample_envelope())])
    worker._subscription = subscription

    asyncio.run(worker._poll_once())

    subscription.fetch.assert_awaited_once()


def test_run_closes_connection_on_stop() -> None:
    async def _run() -> None:
        worker = NatsConsumerWorker(poll_idle=0.01, fetch_timeout=0.01)
        nc = MagicMock()
        nc.close = AsyncMock()
        js = MagicMock()
        js.pull_subscribe = AsyncMock(
            return_value=MagicMock(fetch=AsyncMock(side_effect=asyncio.TimeoutError))
        )
        worker._nc = nc
        worker._js = js
        worker._subscription = await js.pull_subscribe()

        with patch("app.workers.nats_consumer.nats.connect", AsyncMock(return_value=nc)):
            with patch.object(nc, "jetstream", return_value=js):
                task = asyncio.create_task(worker.run())
                await asyncio.sleep(0.05)
                worker._stop.set()
                await asyncio.wait_for(task, timeout=2)

        nc.close.assert_awaited_once()

    asyncio.run(_run())


def test_normalize_headers_converts_dict() -> None:
    from app.workers.nats_consumer import _normalize_headers

    result = _normalize_headers({"traceparent": "00-abc-01", "x-custom": "val"})
    assert result == {"traceparent": "00-abc-01", "x-custom": "val"}


def test_normalize_headers_returns_none_for_none() -> None:
    from app.workers.nats_consumer import _normalize_headers

    assert _normalize_headers(None) is None


def test_normalize_handles_empty_headers() -> None:
    from app.workers.nats_consumer import _normalize_headers

    assert _normalize_headers({}) is None
