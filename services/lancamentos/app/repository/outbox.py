from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from sqlalchemy import func, select, text, update
from sqlalchemy.orm import Session

from app.models import OutboxEvent
from app.outbox.backoff import next_retry_at
from app.outbox.config import CLAIM_BATCH_SIZE, DLQ_MAX_FAILURES

_CLAIM_SQL = text(
    """
    SELECT id, aggregate_id, event_type, payload, failure_count
    FROM lancamentos.outbox_events
    WHERE published_at IS NULL
      AND dlq_at IS NULL
      AND (next_retry_at IS NULL OR next_retry_at <= now())
    ORDER BY id
    LIMIT :batch_size
    FOR UPDATE SKIP LOCKED
    """
)


class OutboxRepository:
    def count_pending(self, session: Session) -> int:
        stmt = select(func.count()).select_from(OutboxEvent).where(
            OutboxEvent.published_at.is_(None),
            OutboxEvent.dlq_at.is_(None),
        )
        return int(session.execute(stmt).scalar_one())

    def claim_batch(self, session: Session, *, batch_size: int = CLAIM_BATCH_SIZE) -> list[dict[str, Any]]:
        rows = session.execute(_CLAIM_SQL, {"batch_size": batch_size}).mappings().all()
        return [dict(row) for row in rows]

    def mark_published(self, session: Session, *, outbox_id: int) -> None:
        now = datetime.now(timezone.utc)
        session.execute(
            update(OutboxEvent)
            .where(OutboxEvent.id == outbox_id)
            .values(published_at=now, next_retry_at=None)
        )

    def record_failure(
        self,
        session: Session,
        *,
        outbox_id: int,
        current_failure_count: int,
    ) -> int:
        new_count = current_failure_count + 1
        session.execute(
            update(OutboxEvent)
            .where(OutboxEvent.id == outbox_id)
            .values(
                failure_count=new_count,
                next_retry_at=next_retry_at(failure_count=new_count),
            )
        )
        return new_count

    def mark_dlq(self, session: Session, *, outbox_id: int) -> None:
        now = datetime.now(timezone.utc)
        session.execute(
            update(OutboxEvent)
            .where(OutboxEvent.id == outbox_id)
            .values(dlq_at=now, next_retry_at=None)
        )

    def schedule_dlq_retry(self, session: Session, *, outbox_id: int) -> None:
        session.execute(
            update(OutboxEvent)
            .where(OutboxEvent.id == outbox_id)
            .values(next_retry_at=next_retry_at(failure_count=DLQ_MAX_FAILURES))
        )
