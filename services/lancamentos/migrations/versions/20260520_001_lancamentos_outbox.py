"""lancamentos partitioned table and outbox_events (doc 04).

Revision ID: 20260520_001
Revises:
Create Date: 2026-05-20

"""

from collections.abc import Sequence
from datetime import date

from alembic import op

revision: str = "20260520_001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_SCHEMA = "lancamentos"
_PARENT = f"{_SCHEMA}.lancamentos"
_OUTBOX = f"{_SCHEMA}.outbox_events"

# Monthly partitions: one year back through two years forward (doc 01 retroactive window).
_PARTITION_START = date(2025, 1, 1)
_PARTITION_END = date(2028, 1, 1)


def _month_start(year: int, month: int) -> date:
    return date(year, month, 1)


def _next_month(value: date) -> date:
    if value.month == 12:
        return date(value.year + 1, 1, 1)
    return date(value.year, value.month + 1, 1)


def _partition_name(period_start: date) -> str:
    return f"lancamentos_{period_start.year:04d}_{period_start.month:02d}"


def _iter_monthly_partitions() -> list[tuple[str, date, date]]:
    partitions: list[tuple[str, date, date]] = []
    cursor = _PARTITION_START
    while cursor < _PARTITION_END:
        nxt = _next_month(cursor)
        partitions.append((_partition_name(cursor), cursor, nxt))
        cursor = nxt
    return partitions


def upgrade() -> None:
    op.execute(f"CREATE SCHEMA IF NOT EXISTS {_SCHEMA}")

    op.execute(
        f"""
        CREATE TABLE {_PARENT} (
            id UUID NOT NULL DEFAULT gen_random_uuid(),
            merchant_id UUID NOT NULL,
            data_competencia DATE NOT NULL,
            tipo VARCHAR(10) NOT NULL CHECK (tipo IN ('CREDITO', 'DEBITO')),
            valor NUMERIC(18, 2) NOT NULL CHECK (valor > 0),
            descricao VARCHAR(500) NOT NULL,
            categoria_id UUID,
            status VARCHAR(20) NOT NULL DEFAULT 'ATIVO',
            idempotency_key VARCHAR(128),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (id, data_competencia),
            CONSTRAINT uq_lancamentos_merchant_idempotency
                UNIQUE (merchant_id, idempotency_key)
        ) PARTITION BY RANGE (data_competencia)
        """
    )

    for name, period_start, period_end in _iter_monthly_partitions():
        op.execute(
            f"""
            CREATE TABLE {_SCHEMA}.{name} PARTITION OF {_PARENT}
            FOR VALUES FROM ('{period_start.isoformat()}')
            TO ('{period_end.isoformat()}')
            """
        )

    op.execute(
        f"""
        CREATE INDEX idx_lancamentos_merchant_competencia
            ON {_PARENT} (merchant_id, data_competencia)
        """
    )
    op.execute(
        f"""
        CREATE INDEX idx_lancamentos_merchant_created
            ON {_PARENT} (merchant_id, created_at DESC, id DESC)
        """
    )
    op.execute(
        f"""
        CREATE INDEX idx_lancamentos_merchant_id
            ON {_PARENT} (merchant_id)
        """
    )

    op.execute(
        f"""
        CREATE TABLE {_OUTBOX} (
            id BIGSERIAL PRIMARY KEY,
            aggregate_id UUID NOT NULL,
            event_type VARCHAR(100) NOT NULL,
            payload JSONB NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            published_at TIMESTAMPTZ
        )
        """
    )
    op.execute(
        f"""
        CREATE INDEX idx_outbox_pending
            ON {_OUTBOX} (id)
            WHERE published_at IS NULL
        """
    )
    op.execute(
        f"""
        CREATE INDEX idx_outbox_aggregate_id
            ON {_OUTBOX} (aggregate_id)
        """
    )

    op.execute("SELECT public.apply_rls_stubs()")


def downgrade() -> None:
    op.execute(f"DROP TABLE IF EXISTS {_OUTBOX} CASCADE")

    for name, _, _ in reversed(_iter_monthly_partitions()):
        op.execute(f"DROP TABLE IF EXISTS {_SCHEMA}.{name}")

    op.execute(f"DROP TABLE IF EXISTS {_PARENT} CASCADE")
