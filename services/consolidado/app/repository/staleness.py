from __future__ import annotations

import uuid

from sqlalchemy import text
from sqlalchemy.orm import Session

_OUTBOX = "lancamentos.outbox_events"
_PENDING_FOR_MERCHANT = text(
    f"""
    SELECT EXISTS (
        SELECT 1
        FROM {_OUTBOX}
        WHERE published_at IS NULL
          AND dlq_at IS NULL
          AND payload->'payload'->>'merchant_id' = :merchant_id
    )
    """
)


class StalenessRepository:
    """Detects pending outbox rows for a merchant (doc 02 RF03 staleness)."""

    def has_pending_outbox(self, session: Session, *, merchant_id: uuid.UUID) -> bool:
        return bool(
            session.execute(
                _PENDING_FOR_MERCHANT,
                {"merchant_id": str(merchant_id)},
            ).scalar_one()
        )
