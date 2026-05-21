from __future__ import annotations

import logging
import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy.orm import Session

from app.cache import invalidate_consolidado_cache
from app.domain import DayTotals, RecomputeResult, ReconciliationCheck
from app.reconciliation.config import RECONCILIATION_LOOKBACK_DAYS
from app.repository.outbox_admin import OutboxAdminRepository
from app.repository.reconciliation import ReconciliationRepository

logger = logging.getLogger(__name__)

_MONEY_FIELDS = ("total_creditos", "total_debitos", "saldo_final")


def _totals_match(source: DayTotals, projection: DayTotals | None) -> bool:
    if projection is None:
        return source.lancamento_count == 0
    return (
        source.total_creditos == projection.total_creditos
        and source.total_debitos == projection.total_debitos
        and source.saldo_final == projection.saldo_final
    )


class ReconciliationService:
    def __init__(
        self,
        *,
        repo: ReconciliationRepository | None = None,
        outbox_repo: OutboxAdminRepository | None = None,
    ) -> None:
        self._repo = repo or ReconciliationRepository()
        self._outbox_repo = outbox_repo or OutboxAdminRepository()

    def check_day(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> ReconciliationCheck:
        source = self._repo.aggregate_lancamentos(
            session, merchant_id=merchant_id, data=data
        )
        projection = self._repo.get_projection_totals(
            session, merchant_id=merchant_id, data=data
        )
        return ReconciliationCheck(
            merchant_id=merchant_id,
            data=data,
            source=source,
            projection=projection,
            matched=_totals_match(source, projection),
        )

    def recompute_day(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> RecomputeResult:
        check = self.check_day(session, merchant_id=merchant_id, data=data)
        corrected = not check.matched
        if corrected:
            self._repo.snapshot_recompute(
                session,
                merchant_id=merchant_id,
                data=data,
                totals=check.source,
            )
            invalidate_consolidado_cache(merchant_id, data)
            logger.warning(
                "reconciliation drift corrected",
                extra={
                    "merchant_id": str(merchant_id),
                    "data": data.isoformat(),
                    "source_creditos": str(check.source.total_creditos),
                    "projection_creditos": str(
                        check.projection.total_creditos if check.projection else Decimal(0)
                    ),
                },
            )
        return RecomputeResult(
            merchant_id=merchant_id,
            data=data,
            totals=check.source,
            corrected=corrected,
        )

    def run_daily(
        self,
        session: Session,
        *,
        lookback_days: int = RECONCILIATION_LOOKBACK_DAYS,
    ) -> list[ReconciliationCheck]:
        results: list[ReconciliationCheck] = []
        for merchant_id, data in self._repo.list_merchant_days(
            session, lookback_days=lookback_days
        ):
            check = self.check_day(session, merchant_id=merchant_id, data=data)
            if not check.matched:
                self.recompute_day(session, merchant_id=merchant_id, data=data)
                logger.warning(
                    "daily reconciliation corrected drift",
                    extra={
                        "merchant_id": str(merchant_id),
                        "data": data.isoformat(),
                    },
                )
            results.append(check)
        return results

    def replay_outbox(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID | None = None,
        outbox_ids: list[int] | None = None,
    ) -> list[int]:
        if outbox_ids:
            return self._outbox_repo.replay_by_ids(session, outbox_ids=outbox_ids)
        if merchant_id is not None:
            return self._outbox_repo.replay_for_merchant(session, merchant_id=merchant_id)
        return self._outbox_repo.replay_all_dlq(session)
