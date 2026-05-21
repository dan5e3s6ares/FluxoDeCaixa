"""Projection event processor unit tests."""

from __future__ import annotations

import asyncio
from typing import Any
from unittest.mock import MagicMock

from app.consumer.processor import ProjectionEventProcessor, _producer_link
from fcx_shared.tracing import traceparent_from_correlation_id


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


def test_producer_link_uses_traceparent_header() -> None:
    correlation_id = "22222222-2222-4222-8222-222222222222"
    headers = {"traceparent": traceparent_from_correlation_id(correlation_id)}

    link = _producer_link(headers, correlation_id)

    assert link is not None
    assert link.context.is_valid


def test_producer_link_falls_back_to_correlation_id() -> None:
    correlation_id = "22222222-2222-4222-8222-222222222222"

    link = _producer_link(None, correlation_id)

    assert link is not None
    assert link.context.is_valid


def test_handle_commits_projection() -> None:
    repo = MagicMock()
    repo.apply_lancamento_registrado.return_value = True
    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session
    cache_invalidator = MagicMock(return_value=1)
    processor = ProjectionEventProcessor(
        repo=repo,
        session_factory=session_factory,
        cache_invalidator=cache_invalidator,
    )

    asyncio.run(
        processor.handle(
            sample_envelope(),
            headers={"traceparent": traceparent_from_correlation_id("22222222-2222-4222-8222-222222222222")},
        )
    )

    repo.apply_lancamento_registrado.assert_called_once()
    session.commit.assert_called_once()
    cache_invalidator.assert_called_once_with(
        "44444444-4444-4444-8444-444444444444",
        "2026-05-20",
    )


def test_producer_link_returns_none_without_trace_context() -> None:
    assert _producer_link(None, "") is None
    assert _producer_link({}, "") is None


def test_handle_with_otel_disabled_applies_projection(monkeypatch) -> None:
    monkeypatch.setenv("OTEL_SDK_DISABLED", "true")
    repo = MagicMock()
    repo.apply_lancamento_registrado.return_value = True
    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session
    cache_invalidator = MagicMock(return_value=1)
    processor = ProjectionEventProcessor(
        repo=repo,
        session_factory=session_factory,
        cache_invalidator=cache_invalidator,
    )

    asyncio.run(processor.handle(sample_envelope()))

    repo.apply_lancamento_registrado.assert_called_once()
    session.commit.assert_called_once()
    cache_invalidator.assert_called_once()


def test_handle_skips_cache_invalidation_when_duplicate() -> None:
    repo = MagicMock()
    repo.apply_lancamento_registrado.return_value = False
    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session
    cache_invalidator = MagicMock()
    processor = ProjectionEventProcessor(
        repo=repo,
        session_factory=session_factory,
        cache_invalidator=cache_invalidator,
    )

    asyncio.run(processor.handle(sample_envelope()))

    session.commit.assert_called_once()
    cache_invalidator.assert_not_called()


def test_handle_skips_cache_invalidation_when_merchant_id_missing() -> None:
    repo = MagicMock()
    repo.apply_lancamento_registrado.return_value = True
    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session
    cache_invalidator = MagicMock()
    processor = ProjectionEventProcessor(
        repo=repo,
        session_factory=session_factory,
        cache_invalidator=cache_invalidator,
    )
    envelope = sample_envelope()
    del envelope["payload"]["merchant_id"]

    asyncio.run(processor.handle(envelope))

    repo.apply_lancamento_registrado.assert_called_once()
    session.commit.assert_called_once()
    cache_invalidator.assert_not_called()


def test_handle_skips_cache_invalidation_when_data_competencia_missing() -> None:
    repo = MagicMock()
    repo.apply_lancamento_registrado.return_value = True
    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session
    cache_invalidator = MagicMock()
    processor = ProjectionEventProcessor(
        repo=repo,
        session_factory=session_factory,
        cache_invalidator=cache_invalidator,
    )
    envelope = sample_envelope()
    del envelope["payload"]["data_competencia"]

    asyncio.run(processor.handle(envelope))

    repo.apply_lancamento_registrado.assert_called_once()
    session.commit.assert_called_once()
    cache_invalidator.assert_not_called()


def test_handle_debito_event_invalidates_cache() -> None:
    repo = MagicMock()
    repo.apply_lancamento_registrado.return_value = True
    session = MagicMock()
    session_factory = MagicMock()
    session_factory.return_value.__enter__.return_value = session
    cache_invalidator = MagicMock(return_value=1)
    processor = ProjectionEventProcessor(
        repo=repo,
        session_factory=session_factory,
        cache_invalidator=cache_invalidator,
    )
    envelope = sample_envelope()
    envelope["payload"]["tipo"] = "DEBITO"
    envelope["payload"]["valor"] = "50.00"

    asyncio.run(processor.handle(envelope))

    cache_invalidator.assert_called_once_with(
        "44444444-4444-4444-8444-444444444444",
        "2026-05-20",
    )


def test_producer_link_with_empty_correlation_id() -> None:
    link = _producer_link(None, "")
    assert link is None
