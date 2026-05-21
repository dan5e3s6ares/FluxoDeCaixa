from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import BigInteger, Date, DateTime, Numeric, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

SCHEMA = "consolidado"


class ProcessedEvent(Base):
    """Idempotency ledger for consumed NATS events (doc 04)."""

    __tablename__ = "processed_events"
    __table_args__ = {"schema": SCHEMA}

    event_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    processed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class ConsolidadoDiario(Base):
    """Daily balance read model; composite PK enables upsert by merchant+date (doc 04)."""

    __tablename__ = "consolidado_diario"
    __table_args__ = {"schema": SCHEMA}

    merchant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True)
    data: Mapped[date] = mapped_column(Date, primary_key=True)
    total_creditos: Mapped[Decimal] = mapped_column(
        Numeric(18, 2), nullable=False, server_default="0"
    )
    total_debitos: Mapped[Decimal] = mapped_column(
        Numeric(18, 2), nullable=False, server_default="0"
    )
    saldo_final: Mapped[Decimal] = mapped_column(
        Numeric(18, 2), nullable=False, server_default="0"
    )
    versao: Mapped[int] = mapped_column(BigInteger, nullable=False, server_default="0")
    ultima_atualizacao: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
