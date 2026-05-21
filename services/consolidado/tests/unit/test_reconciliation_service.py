"""Reconciliation service unit tests (doc 02 RF04)."""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from unittest.mock import MagicMock, patch

from app.domain import DayTotals, ReconciliationCheck
from app.services.reconciliation_service import ReconciliationService

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
DATA = date(2026, 5, 20)

_SOURCE = DayTotals(
    total_creditos=Decimal("100.00"),
    total_debitos=Decimal("25.00"),
    saldo_final=Decimal("75.00"),
    lancamento_count=2,
)
_PROJECTION = DayTotals(
    total_creditos=Decimal("100.00"),
    total_debitos=Decimal("25.00"),
    saldo_final=Decimal("75.00"),
    lancamento_count=0,
)
_MISMATCH = DayTotals(
    total_creditos=Decimal("90.00"),
    total_debitos=Decimal("25.00"),
    saldo_final=Decimal("65.00"),
    lancamento_count=0,
)


def test_check_day_matched() -> None:
    repo = MagicMock()
    repo.aggregate_lancamentos.return_value = _SOURCE
    repo.get_projection_totals.return_value = _PROJECTION
    service = ReconciliationService(repo=repo)
    session = MagicMock()

    check = service.check_day(session, merchant_id=MERCHANT_ID, data=DATA)

    assert check.matched is True
    assert check.source == _SOURCE
    assert check.projection == _PROJECTION


def test_check_day_drift_when_projection_missing_with_lancamentos() -> None:
    repo = MagicMock()
    repo.aggregate_lancamentos.return_value = _SOURCE
    repo.get_projection_totals.return_value = None
    service = ReconciliationService(repo=repo)

    check = service.check_day(MagicMock(), merchant_id=MERCHANT_ID, data=DATA)

    assert check.matched is False


def test_check_day_matched_when_no_lancamentos_and_no_projection() -> None:
    empty = DayTotals(
        total_creditos=Decimal("0"),
        total_debitos=Decimal("0"),
        saldo_final=Decimal("0"),
        lancamento_count=0,
    )
    repo = MagicMock()
    repo.aggregate_lancamentos.return_value = empty
    repo.get_projection_totals.return_value = None
    service = ReconciliationService(repo=repo)

    check = service.check_day(MagicMock(), merchant_id=MERCHANT_ID, data=DATA)

    assert check.matched is True


@patch("app.services.reconciliation_service.invalidate_consolidado_cache")
def test_recompute_day_corrects_drift(mock_invalidate: MagicMock) -> None:
    repo = MagicMock()
    repo.aggregate_lancamentos.return_value = _SOURCE
    repo.get_projection_totals.return_value = _MISMATCH
    service = ReconciliationService(repo=repo)
    session = MagicMock()

    result = service.recompute_day(session, merchant_id=MERCHANT_ID, data=DATA)

    assert result.corrected is True
    repo.snapshot_recompute.assert_called_once_with(
        session,
        merchant_id=MERCHANT_ID,
        data=DATA,
        totals=_SOURCE,
    )
    mock_invalidate.assert_called_once_with(MERCHANT_ID, DATA)


@patch("app.services.reconciliation_service.invalidate_consolidado_cache")
def test_recompute_day_skips_when_matched(mock_invalidate: MagicMock) -> None:
    repo = MagicMock()
    repo.aggregate_lancamentos.return_value = _SOURCE
    repo.get_projection_totals.return_value = _PROJECTION
    service = ReconciliationService(repo=repo)

    result = service.recompute_day(MagicMock(), merchant_id=MERCHANT_ID, data=DATA)

    assert result.corrected is False
    repo.snapshot_recompute.assert_not_called()
    mock_invalidate.assert_not_called()


def test_run_daily_recomputes_drift_days() -> None:
    repo = MagicMock()
    repo.list_merchant_days.return_value = [(MERCHANT_ID, DATA)]
    service = ReconciliationService(repo=repo)
    service.check_day = MagicMock(  # type: ignore[method-assign]
        return_value=ReconciliationCheck(
            merchant_id=MERCHANT_ID,
            data=DATA,
            source=_SOURCE,
            projection=_MISMATCH,
            matched=False,
        )
    )
    service.recompute_day = MagicMock()  # type: ignore[method-assign]
    session = MagicMock()

    results = service.run_daily(session, lookback_days=7)

    assert len(results) == 1
    service.recompute_day.assert_called_once_with(
        session, merchant_id=MERCHANT_ID, data=DATA
    )


def test_replay_outbox_by_ids() -> None:
    outbox_repo = MagicMock()
    outbox_repo.replay_by_ids.return_value = [1, 2]
    service = ReconciliationService(outbox_repo=outbox_repo)
    session = MagicMock()

    replayed = service.replay_outbox(session, outbox_ids=[1, 2])

    assert replayed == [1, 2]
    outbox_repo.replay_by_ids.assert_called_once_with(session, outbox_ids=[1, 2])
