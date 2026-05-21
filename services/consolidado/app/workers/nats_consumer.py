"""JetStream pull consumer for LancamentoRegistrado (doc 03)."""

from __future__ import annotations

import asyncio
import json
import logging
import signal
from typing import Any, Protocol

import nats
from nats.aio.msg import Msg
from nats.js import JetStreamContext

from app.consumer.config import (
    CONSUMER_NAME,
    FETCH_BATCH,
    FETCH_TIMEOUT_SECONDS,
    FILTER_SUBJECT,
    POLL_IDLE_SECONDS,
    STREAM_NAME,
)
from app.consumer.processor import ProjectionEventProcessor
from fcx_shared import configure_logging, get_settings

logger = logging.getLogger(__name__)


class EventProcessor(Protocol):
    async def handle(
        self,
        envelope: dict[str, Any],
        *,
        headers: dict[str, str] | None = None,
    ) -> None: ...


class NatsConsumerWorker:
    def __init__(
        self,
        *,
        processor: EventProcessor | None = None,
        fetch_batch: int = FETCH_BATCH,
        fetch_timeout: float = FETCH_TIMEOUT_SECONDS,
        poll_idle: float = POLL_IDLE_SECONDS,
    ) -> None:
        self._processor = processor or ProjectionEventProcessor()
        self._fetch_batch = fetch_batch
        self._fetch_timeout = fetch_timeout
        self._poll_idle = poll_idle
        self._stop = asyncio.Event()
        self._nc: nats.NATS | None = None
        self._js: JetStreamContext | None = None
        self._subscription: Any = None

    async def run(self) -> None:
        settings = get_settings()
        configure_logging(settings)
        self._nc = await nats.connect(settings.nats_url)
        self._js = self._nc.jetstream()
        self._subscription = await self._js.pull_subscribe(
            FILTER_SUBJECT,
            durable=CONSUMER_NAME,
            stream=STREAM_NAME,
        )

        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, self._stop.set)

        logger.info(
            "nats consumer started",
            extra={
                "stream": STREAM_NAME,
                "consumer": CONSUMER_NAME,
                "subject": FILTER_SUBJECT,
            },
        )

        try:
            while not self._stop.is_set():
                await self._poll_once()
                try:
                    await asyncio.wait_for(self._stop.wait(), timeout=self._poll_idle)
                except asyncio.TimeoutError:
                    pass
        finally:
            if self._nc is not None:
                await self._nc.close()

    async def _poll_once(self) -> None:
        if self._subscription is None:
            return
        try:
            messages = await self._subscription.fetch(
                self._fetch_batch,
                timeout=self._fetch_timeout,
            )
        except asyncio.TimeoutError:
            return
        except nats.errors.TimeoutError:
            return

        for msg in messages:
            await self._handle_message(msg)

    async def _handle_message(self, msg: Msg) -> None:
        try:
            envelope = json.loads(msg.data.decode("utf-8"))
            if not isinstance(envelope, dict):
                raise ValueError("event envelope must be a JSON object")
            headers = _normalize_headers(msg.headers)
            await self._processor.handle(envelope, headers=headers)
            await msg.ack()
        except Exception:
            logger.exception("consumer message handling failed")
            await msg.nak()


def _normalize_headers(headers: Any) -> dict[str, str] | None:
    if not headers:
        return None
    if isinstance(headers, dict):
        return {str(key): str(value) for key, value in headers.items()}
    return {str(key): str(value) for key, value in headers.items()}  # type: ignore[union-attr]


async def main() -> None:
    worker = NatsConsumerWorker()
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
