from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, Numeric, String, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

SCHEMA = "lancamentos"


class Lancamento(Base):
    """Read-only mapping of lancamentos.lancamentos (doc 04 cross-schema read)."""

    __tablename__ = "lancamentos"
    __table_args__ = {"schema": SCHEMA}

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    merchant_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    data_competencia: Mapped[date] = mapped_column(Date, primary_key=True)
    tipo: Mapped[str] = mapped_column(String(10), nullable=False)
    valor: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    descricao: Mapped[str] = mapped_column(String(500), nullable=False, default="")
    categoria_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="ATIVO")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
