from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Protocol
from uuid import UUID

import nats
from nats.aio.client import Client as NatsClient
from nats.js import JetStreamContext

from app.outbox.config import DLQ_SUBJECT, EVENT_SUBJECT
from fcx_shared import get_settings, traceparent_from_correlation_id

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class PublishResult:
    subject: str


class OutboxPublisher(Protocol):
    async def publish_event(self, payload: dict[str, Any]) -> PublishResult: ...

    async def publish_dlq(self, payload: dict[str, Any]) -> PublishResult: ...


class NatsJetStreamPublisher:
    def __init__(self, *, nc: NatsClient, js: JetStreamContext) -> None:
        self._nc = nc
        self._js = js

    @classmethod
    async def connect(cls) -> NatsJetStreamPublisher:
        settings = get_settings()
        nc = await nats.connect(settings.nats_url)
        js = nc.jetstream()
        return cls(nc=nc, js=js)

    async def close(self) -> None:
        await self._nc.close()

    async def publish_event(self, payload: dict[str, Any]) -> PublishResult:
        return await self._publish(EVENT_SUBJECT, payload)

    async def publish_dlq(self, payload: dict[str, Any]) -> PublishResult:
        return await self._publish(DLQ_SUBJECT, payload)

    async def _publish(self, subject: str, payload: dict[str, Any]) -> PublishResult:
        correlation_id = str(payload.get("correlation_id", ""))
        headers: dict[str, str] = {}
        if correlation_id:
            try:
                UUID(correlation_id)
                headers["traceparent"] = traceparent_from_correlation_id(correlation_id)
            except ValueError:
                pass
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        await self._js.publish(subject, body, headers=headers or None)
        logger.info(
            "published outbox event",
            extra={"subject": subject, "event_id": payload.get("event_id")},
        )
        return PublishResult(subject=subject)
