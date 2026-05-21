from __future__ import annotations

import uuid
from datetime import date

from sqlalchemy.orm import Session

from app.domain import ConsolidadoDiarioView, ConsolidadoReadResult
from app.repository.read_model import ConsolidadoReadRepository
from app.repository.staleness import StalenessRepository

STALE_HEADER = "X-Consolidado-Stale"


class ConsolidadoReadService:
    def __init__(
        self,
        *,
        read_repo: ConsolidadoReadRepository | None = None,
        staleness_repo: StalenessRepository | None = None,
    ) -> None:
        self._read_repo = read_repo or ConsolidadoReadRepository()
        self._staleness_repo = staleness_repo or StalenessRepository()

    def get_daily(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> ConsolidadoReadResult:
        row = self._read_repo.get_daily(session, merchant_id=merchant_id, data=data)
        consolidado = row or self._read_repo.empty_daily(merchant_id=merchant_id, data=data)
        stale = self._staleness_repo.has_pending_outbox(session, merchant_id=merchant_id)
        return ConsolidadoReadResult(consolidado=consolidado, stale=stale)

    @staticmethod
    def to_response(view: ConsolidadoDiarioView) -> dict[str, object]:
        return {
            "data": view.data,
            "total_creditos": view.total_creditos,
            "total_debitos": view.total_debitos,
            "saldo_final": view.saldo_final,
            "ultima_atualizacao": view.ultima_atualizacao,
        }
