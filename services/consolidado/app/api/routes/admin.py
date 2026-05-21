from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.deps import get_db_session, get_reconciliation_service
from app.auth.admin import require_admin_role
from app.domain import DayTotals
from app.schemas.reconciliation import (
    DayTotalsResponse,
    OutboxReplayRequest,
    OutboxReplayResponse,
    RecomputeRequest,
    RecomputeResponse,
    ReconcileResponse,
)
from app.services.reconciliation_service import ReconciliationService

router = APIRouter(prefix="/internal/v1/admin", tags=["admin"])


def _totals_response(totals: DayTotals) -> DayTotalsResponse:
    return DayTotalsResponse(
        total_creditos=totals.total_creditos,
        total_debitos=totals.total_debitos,
        saldo_final=totals.saldo_final,
        lancamento_count=totals.lancamento_count,
    )


@router.post(
    "/recompute",
    response_model=RecomputeResponse,
    dependencies=[Depends(require_admin_role)],
)
def admin_recompute(
    body: RecomputeRequest,
    session: Annotated[Session, Depends(get_db_session)],
    service: Annotated[ReconciliationService, Depends(get_reconciliation_service)],
) -> RecomputeResponse:
    """Snapshot recompute for merchant+day (doc 02 RF04)."""
    result = service.recompute_day(
        session, merchant_id=body.merchant_id, data=body.data
    )
    session.commit()
    return RecomputeResponse(
        merchant_id=result.merchant_id,
        data=result.data,
        totals=_totals_response(result.totals),
        corrected=result.corrected,
    )


@router.post(
    "/reconcile",
    response_model=ReconcileResponse,
    dependencies=[Depends(require_admin_role)],
)
def admin_reconcile(
    body: RecomputeRequest,
    session: Annotated[Session, Depends(get_db_session)],
    service: Annotated[ReconciliationService, Depends(get_reconciliation_service)],
) -> ReconcileResponse:
    """Compare lancamentos sums vs read model without mutating (doc 02 RF04)."""
    check = service.check_day(
        session, merchant_id=body.merchant_id, data=body.data
    )
    return ReconcileResponse(
        merchant_id=check.merchant_id,
        data=check.data,
        source=_totals_response(check.source),
        projection=_totals_response(check.projection) if check.projection else None,
        matched=check.matched,
    )


@router.post(
    "/outbox/replay",
    response_model=OutboxReplayResponse,
    dependencies=[Depends(require_admin_role)],
)
def admin_outbox_replay(
    body: OutboxReplayRequest,
    session: Annotated[Session, Depends(get_db_session)],
    service: Annotated[ReconciliationService, Depends(get_reconciliation_service)],
) -> OutboxReplayResponse:
    """Reset DLQ outbox rows for manual replay (doc 02/03)."""
    replayed = service.replay_outbox(
        session,
        merchant_id=body.merchant_id,
        outbox_ids=body.outbox_ids or None,
    )
    session.commit()
    return OutboxReplayResponse(replayed_ids=replayed)
