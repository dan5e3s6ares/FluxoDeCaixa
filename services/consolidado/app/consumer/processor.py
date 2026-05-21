from __future__ import annotations

import logging
import os
from datetime import date
from typing import Any, Callable

from fcx_shared import traceparent_from_correlation_id
from opentelemetry import trace
from opentelemetry.trace import Link, SpanKind
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

from app.cache import invalidate_consolidado_cache
from app.db import get_session_factory
from app.repository.projection import ProjectionRepository

logger = logging.getLogger(__name__)
_tracer = trace.get_tracer(__name__)
_propagator = TraceContextTextMapPropagator()


def _producer_link(headers: dict[str, str] | None, correlation_id: str) -> Link | None:
    carrier = dict(headers or {})
    if "traceparent" not in carrier and correlation_id:
        carrier["traceparent"] = traceparent_from_correlation_id(correlation_id)

    if "traceparent" not in carrier:
        return None

    producer_context = _propagator.extract(carrier)
    producer_span = trace.get_current_span(producer_context)
    producer_span_context = producer_span.get_span_context()
    if not producer_span_context.is_valid:
        return None
    return Link(producer_span_context)


class ProjectionEventProcessor:
    """Consumes LancamentoRegistrado envelopes and upserts consolidado_diario."""

    def __init__(
        self,
        *,
        repo: ProjectionRepository | None = None,
        session_factory=None,
        cache_invalidator: Callable[[Any, date | str], int] | None = None,
    ) -> None:
        self._repo = repo or ProjectionRepository()
        self._session_factory = session_factory or get_session_factory()
        self._cache_invalidator = cache_invalidator or invalidate_consolidado_cache

    async def handle(
        self,
        envelope: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        payload = envelope.get("payload", {})
        correlation_id = str(envelope.get("correlation_id", ""))
        event_id = envelope.get("event_id")
        merchant_id = payload.get("merchant_id")
        lancamento_id = payload.get("lancamento_id")
        data_competencia = payload.get("data_competencia")

        links = []
        producer_link = _producer_link(headers, correlation_id)
        if producer_link is not None:
            links.append(producer_link)

        span_attributes = {
            "messaging.system": "nats",
            "messaging.operation": "process",
            "messaging.destination.name": "lancamentos.lancamento_registrado.v1",
            "event_id": str(event_id or ""),
            "correlation_id": correlation_id,
            "merchant_id": str(merchant_id or ""),
            "lancamento_id": str(lancamento_id or ""),
        }

        if os.getenv("OTEL_SDK_DISABLED", "").lower() in {"1", "true", "yes"}:
            await self._apply(envelope, payload, correlation_id, data_competencia, event_id, merchant_id, lancamento_id)
            return

        with _tracer.start_as_current_span(
            "LancamentoRegistrado consume",
            kind=SpanKind.CONSUMER,
            links=links,
            attributes=span_attributes,
        ):
            await self._apply(
                envelope,
                payload,
                correlation_id,
                data_competencia,
                event_id,
                merchant_id,
                lancamento_id,
            )

    async def _apply(
        self,
        envelope: dict[str, Any],
        payload: dict[str, Any],
        correlation_id: str,
        data_competencia: Any,
        event_id: Any,
        merchant_id: Any,
        lancamento_id: Any,
    ) -> None:
        with self._session_factory() as session:
            applied = self._repo.apply_lancamento_registrado(session, envelope)
            session.commit()

        if applied and merchant_id is not None and data_competencia is not None:
            self._cache_invalidator(merchant_id, data_competencia)

        logger.info(
            "projection applied" if applied else "projection skipped duplicate event",
            extra={
                "event_id": event_id,
                "event_type": envelope.get("event_type"),
                "correlation_id": correlation_id,
                "lancamento_id": lancamento_id,
                "merchant_id": merchant_id,
                "data_competencia": data_competencia,
                "applied": applied,
            },
        )
