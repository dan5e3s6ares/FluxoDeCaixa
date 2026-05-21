"""Transactional outbox worker — publishes LancamentoRegistrado to NATS JetStream."""

from __future__ import annotations

import asyncio
import logging
import os
import signal
from typing import Any

from fcx_shared import configure_logging, get_settings

from app.db import get_session_factory
from app.metrics import outbox_pending_gauge, start_metrics_server
from app.outbox.config import DLQ_MAX_FAILURES, POLL_INTERVAL_SECONDS
from app.repository.outbox import OutboxRepository
from app.services.nats_publisher import NatsJetStreamPublisher, OutboxPublisher

logger = logging.getLogger(__name__)


class OutboxWorker:
    def __init__(
        self,
        *,
        repo: OutboxRepository | None = None,
        publisher: OutboxPublisher | None = None,
        poll_interval: float = POLL_INTERVAL_SECONDS,
    ) -> None:
        self._repo = repo or OutboxRepository()
        self._publisher = publisher
        self._poll_interval = poll_interval
        self._session_factory = get_session_factory()
        self._stop = asyncio.Event()

    async def run(self) -> None:
        if self._publisher is None:
            nats_pub = await NatsJetStreamPublisher.connect()
            self._publisher = nats_pub
        assert self._publisher is not None

        metrics_port = int(os.environ.get("OUTBOX_METRICS_PORT", "9090"))
        start_metrics_server(metrics_port)
        logger.info("outbox worker started", extra={"poll_interval_s": self._poll_interval})

        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, self._stop.set)

        try:
            while not self._stop.is_set():
                await self._poll_once()
                try:
                    await asyncio.wait_for(self._stop.wait(), timeout=self._poll_interval)
                except asyncio.TimeoutError:
                    pass
        finally:
            if isinstance(self._publisher, NatsJetStreamPublisher):
                await self._publisher.close()

    async def _poll_once(self) -> None:
        with self._session_factory() as session:
            pending = self._repo.count_pending(session)
            outbox_pending_gauge.set(pending)

            rows = self._repo.claim_batch(session)
            if not rows:
                return

            for row in rows:
                await self._process_row(session, row)

            session.commit()

    async def _process_row(self, session: Any, row: dict[str, Any]) -> None:
        outbox_id = row["id"]
        payload = row["payload"]
        failure_count = int(row["failure_count"])

        if failure_count >= DLQ_MAX_FAILURES:
            await self._publish_to_dlq(session, outbox_id=outbox_id, payload=payload)
            return

        try:
            await self._publisher.publish_event(payload)
            self._repo.mark_published(session, outbox_id=outbox_id)
        except Exception:
            logger.exception(
                "outbox publish failed",
                extra={"outbox_id": outbox_id, "failure_count": failure_count},
            )
            new_count = self._repo.record_failure(
                session,
                outbox_id=outbox_id,
                current_failure_count=failure_count,
            )
            if new_count >= DLQ_MAX_FAILURES:
                await self._publish_to_dlq(session, outbox_id=outbox_id, payload=payload)

    async def _publish_to_dlq(
        self,
        session: Any,
        *,
        outbox_id: int,
        payload: dict[str, Any],
    ) -> None:
        try:
            await self._publisher.publish_dlq(payload)
            self._repo.mark_dlq(session, outbox_id=outbox_id)
        except Exception:
            logger.exception(
                "outbox DLQ publish failed",
                extra={"outbox_id": outbox_id},
            )
            self._repo.schedule_dlq_retry(session, outbox_id=outbox_id)


async def main() -> None:
    settings = get_settings()
    configure_logging(settings)
    worker = OutboxWorker()
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
