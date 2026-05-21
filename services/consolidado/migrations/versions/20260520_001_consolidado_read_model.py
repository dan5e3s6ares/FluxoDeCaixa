"""consolidado read model tables (doc 04).

Revision ID: 20260520_001
Revises:
Create Date: 2026-05-20

Upsert read model (consolidado_diario) and idempotency ledger (processed_events).
"""

from collections.abc import Sequence

from alembic import op

revision: str = "20260520_001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_SCHEMA = "consolidado"
_PROCESSED = f"{_SCHEMA}.processed_events"
_DAILY = f"{_SCHEMA}.consolidado_diario"


def upgrade() -> None:
    op.execute(f"CREATE SCHEMA IF NOT EXISTS {_SCHEMA}")

    op.execute(
        f"""
        CREATE TABLE {_PROCESSED} (
            event_id UUID PRIMARY KEY,
            processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )

    op.execute(
        f"""
        CREATE TABLE {_DAILY} (
            merchant_id UUID NOT NULL,
            data DATE NOT NULL,
            total_creditos NUMERIC(18, 2) NOT NULL DEFAULT 0,
            total_debitos NUMERIC(18, 2) NOT NULL DEFAULT 0,
            saldo_final NUMERIC(18, 2) NOT NULL DEFAULT 0,
            versao BIGINT NOT NULL DEFAULT 0,
            ultima_atualizacao TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (merchant_id, data)
        )
        """
    )

    op.execute("SELECT public.apply_rls_stubs()")


def downgrade() -> None:
    op.execute(f"DROP TABLE IF EXISTS {_DAILY}")
    op.execute(f"DROP TABLE IF EXISTS {_PROCESSED}")
    op.execute(f"DROP SCHEMA IF EXISTS {_SCHEMA} CASCADE")
