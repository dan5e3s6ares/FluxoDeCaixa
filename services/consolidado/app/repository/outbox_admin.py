from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import text
from sqlalchemy.orm import Session

_OUTBOX = "lancamentos.outbox_events"

_REPLAY_BY_IDS = text(
    f"""
    UPDATE {_OUTBOX}
    SET dlq_at = NULL,
        failure_count = 0,
        next_retry_at = now(),
        published_at = NULL
    WHERE id = ANY(:outbox_ids)
      AND dlq_at IS NOT NULL
    RETURNING id
    """
)

_REPLAY_BY_MERCHANT = text(
    f"""
    UPDATE {_OUTBOX}
    SET dlq_at = NULL,
        failure_count = 0,
        next_retry_at = now(),
        published_at = NULL
    WHERE dlq_at IS NOT NULL
      AND payload->'payload'->>'merchant_id' = :merchant_id
    RETURNING id
    """
)


class OutboxAdminRepository:
    """Admin replay of outbox DLQ rows (doc 02/03 — manual DLQ replay)."""

    def replay_by_ids(self, session: Session, *, outbox_ids: list[int]) -> list[int]:
        if not outbox_ids:
            return []
        rows = session.execute(
            _REPLAY_BY_IDS,
            {"outbox_ids": outbox_ids},
        ).all()
        return [int(row.id) for row in rows]

    def replay_for_merchant(self, session: Session, *, merchant_id: uuid.UUID) -> list[int]:
        rows = session.execute(
            _REPLAY_BY_MERCHANT,
            {"merchant_id": str(merchant_id)},
        ).all()
        return [int(row.id) for row in rows]

    def replay_all_dlq(self, session: Session) -> list[int]:
        rows = session.execute(
            text(
                f"""
                UPDATE {_OUTBOX}
                SET dlq_at = NULL,
                    failure_count = 0,
                    next_retry_at = :now,
                    published_at = NULL
                WHERE dlq_at IS NOT NULL
                RETURNING id
                """
            ),
            {"now": datetime.now(timezone.utc)},
        ).all()
        return [int(row.id) for row in rows]
