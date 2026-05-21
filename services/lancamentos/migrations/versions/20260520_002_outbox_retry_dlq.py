"""outbox retry columns and DLQ tracking (doc 03/05).

Revision ID: 20260520_002
Revises: 20260520_001
Create Date: 2026-05-20

"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260520_002"
down_revision: str | None = "20260520_001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_SCHEMA = "lancamentos"
_OUTBOX = f"{_SCHEMA}.outbox_events"


def upgrade() -> None:
    op.execute(
        f"""
        ALTER TABLE {_OUTBOX}
            ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0,
            ADD COLUMN next_retry_at TIMESTAMPTZ,
            ADD COLUMN dlq_at TIMESTAMPTZ
        """
    )
    op.execute(f"DROP INDEX IF EXISTS {_SCHEMA}.idx_outbox_pending")
    op.execute(
        f"""
        CREATE INDEX idx_outbox_pending
            ON {_OUTBOX} (id)
            WHERE published_at IS NULL AND dlq_at IS NULL
        """
    )


def downgrade() -> None:
    op.execute(f"DROP INDEX IF EXISTS {_SCHEMA}.idx_outbox_pending")
    op.execute(
        f"""
        CREATE INDEX idx_outbox_pending
            ON {_OUTBOX} (id)
            WHERE published_at IS NULL
        """
    )
    op.execute(
        f"""
        ALTER TABLE {_OUTBOX}
            DROP COLUMN IF EXISTS dlq_at,
            DROP COLUMN IF EXISTS next_retry_at,
            DROP COLUMN IF EXISTS failure_count
        """
    )
