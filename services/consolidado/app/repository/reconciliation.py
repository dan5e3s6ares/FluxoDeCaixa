from __future__ import annotations

import uuid
from datetime import date, timedelta
from decimal import Decimal

from sqlalchemy import text
from sqlalchemy.orm import Session

from app.domain import DayTotals
from app.repository.read_model import ConsolidadoReadRepository

_LANCAMENTOS = "lancamentos.lancamentos"
_DAILY = "consolidado.consolidado_diario"

_AGGREGATE_DAY = text(
    f"""
    SELECT
        COALESCE(SUM(CASE WHEN tipo = 'CREDITO' THEN valor ELSE 0 END), 0) AS total_creditos,
        COALESCE(SUM(CASE WHEN tipo = 'DEBITO' THEN valor ELSE 0 END), 0) AS total_debitos,
        COALESCE(
            SUM(CASE WHEN tipo = 'CREDITO' THEN valor ELSE -valor END),
            0
        ) AS saldo_final,
        COUNT(*)::int AS lancamento_count
    FROM {_LANCAMENTOS}
    WHERE merchant_id = :merchant_id
      AND data_competencia = :data
      AND status = 'ATIVO'
    """
)

_LIST_DAYS = text(
    f"""
    SELECT DISTINCT merchant_id, data_competencia AS data
    FROM {_LANCAMENTOS}
    WHERE status = 'ATIVO'
      AND data_competencia >= :since
    UNION
    SELECT merchant_id, data
    FROM {_DAILY}
    WHERE data >= :since
    """
)

_SNAPSHOT_UPSERT = text(
    f"""
    INSERT INTO {_DAILY} (
        merchant_id,
        data,
        total_creditos,
        total_debitos,
        saldo_final,
        versao,
        ultima_atualizacao
    )
    VALUES (
        :merchant_id,
        :data,
        :total_creditos,
        :total_debitos,
        :saldo_final,
        1,
        now()
    )
    ON CONFLICT (merchant_id, data) DO UPDATE SET
        total_creditos = EXCLUDED.total_creditos,
        total_debitos = EXCLUDED.total_debitos,
        saldo_final = EXCLUDED.saldo_final,
        versao = {_DAILY}.versao + 1,
        ultima_atualizacao = now()
    """
)


def _row_to_totals(row: object) -> DayTotals:
    mapping = row._mapping  # type: ignore[attr-defined]
    return DayTotals(
        total_creditos=Decimal(str(mapping["total_creditos"])),
        total_debitos=Decimal(str(mapping["total_debitos"])),
        saldo_final=Decimal(str(mapping["saldo_final"])),
        lancamento_count=int(mapping["lancamento_count"]),
    )


class ReconciliationRepository:
    """Compares lancamentos source sums vs consolidado read model (doc 02 RF04)."""

    @staticmethod
    def bind_merchant_rls(session: Session, merchant_id: uuid.UUID) -> None:
        ConsolidadoReadRepository.bind_merchant_rls(session, merchant_id)

    def aggregate_lancamentos(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> DayTotals:
        self.bind_merchant_rls(session, merchant_id)
        row = session.execute(
            _AGGREGATE_DAY,
            {"merchant_id": merchant_id, "data": data},
        ).one()
        return _row_to_totals(row)

    def get_projection_totals(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> DayTotals | None:
        self.bind_merchant_rls(session, merchant_id)
        row = session.execute(
            text(
                f"""
                SELECT
                    total_creditos,
                    total_debitos,
                    saldo_final,
                    0 AS lancamento_count
                FROM {_DAILY}
                WHERE merchant_id = :merchant_id
                  AND data = :data
                """
            ),
            {"merchant_id": merchant_id, "data": data},
        ).one_or_none()
        if row is None:
            return None
        return DayTotals(
            total_creditos=Decimal(str(row.total_creditos)),
            total_debitos=Decimal(str(row.total_debitos)),
            saldo_final=Decimal(str(row.saldo_final)),
            lancamento_count=0,
        )

    def list_merchant_days(
        self,
        session: Session,
        *,
        lookback_days: int,
    ) -> list[tuple[uuid.UUID, date]]:
        since = date.today() - timedelta(days=lookback_days)
        rows = session.execute(_LIST_DAYS, {"since": since}).all()
        return [(uuid.UUID(str(row.merchant_id)), row.data) for row in rows]

    def snapshot_recompute(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
        totals: DayTotals,
    ) -> None:
        self.bind_merchant_rls(session, merchant_id)
        session.execute(
            _SNAPSHOT_UPSERT,
            {
                "merchant_id": merchant_id,
                "data": data,
                "total_creditos": totals.total_creditos,
                "total_debitos": totals.total_debitos,
                "saldo_final": totals.saldo_final,
            },
        )
