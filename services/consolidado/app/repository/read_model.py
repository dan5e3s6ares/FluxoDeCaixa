from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import select, text
from sqlalchemy.orm import Session

from app.domain import ConsolidadoDiarioView
from app.models import ConsolidadoDiario

_SCHEMA = "consolidado"


class ConsolidadoReadRepository:
    """Reads materialized consolidado_diario rows (RF03 internal)."""

    @staticmethod
    def bind_merchant_rls(session: Session, merchant_id: uuid.UUID) -> None:
        session.execute(
            text("SELECT public.set_app_merchant_id(:merchant_id)"),
            {"merchant_id": merchant_id},
        )

    def get_daily(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> ConsolidadoDiarioView | None:
        self.bind_merchant_rls(session, merchant_id)
        row = session.execute(
            select(ConsolidadoDiario).where(
                ConsolidadoDiario.merchant_id == merchant_id,
                ConsolidadoDiario.data == data,
            )
        ).scalar_one_or_none()
        if row is None:
            return None
        return ConsolidadoDiarioView(
            merchant_id=row.merchant_id,
            data=row.data,
            total_creditos=row.total_creditos,
            total_debitos=row.total_debitos,
            saldo_final=row.saldo_final,
            versao=int(row.versao),
            ultima_atualizacao=row.ultima_atualizacao,
        )

    def empty_daily(self, *, merchant_id: uuid.UUID, data: date) -> ConsolidadoDiarioView:
        return ConsolidadoDiarioView(
            merchant_id=merchant_id,
            data=data,
            total_creditos=Decimal("0"),
            total_debitos=Decimal("0"),
            saldo_final=Decimal("0"),
            versao=0,
            ultima_atualizacao=None,
        )
