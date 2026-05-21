"""Domain dataclass unit tests."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone
from decimal import Decimal

from app.domain import (
    ConsolidadoDiarioView,
    ConsolidadoReadResult,
    DayTotals,
    ReconciliationCheck,
    RecomputeResult,
)

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
DATA = date(2026, 5, 20)


def test_consolidado_diario_view_is_frozen() -> None:
    view = ConsolidadoDiarioView(
        merchant_id=MERCHANT_ID,
        data=DATA,
        total_creditos=Decimal("100.00"),
        total_debitos=Decimal("25.00"),
        saldo_final=Decimal("75.00"),
        versao=1,
        ultima_atualizacao=None,
    )
    import pytest

    with pytest.raises(AttributeError):
        view.versao = 2  # type: ignore[mutable]


def test_day_totals_is_frozen() -> None:
    totals = DayTotals(
        total_creditos=Decimal("10.00"),
        total_debitos=Decimal("0"),
        saldo_final=Decimal("10.00"),
        lancamento_count=1,
    )
    import pytest

    with pytest.raises(AttributeError):
        totals.lancamento_count = 5  # type: ignore[mutable]


def test_reconciliation_check_matched() -> None:
    source = DayTotals(Decimal("10"), Decimal("0"), Decimal("10"), 1)
    check = ReconciliationCheck(
        merchant_id=MERCHANT_ID,
        data=DATA,
        source=source,
        projection=source,
        matched=True,
    )
    assert check.matched is True


def test_recompute_result_corrected() -> None:
    totals = DayTotals(Decimal("10"), Decimal("0"), Decimal("10"), 1)
    result = RecomputeResult(
        merchant_id=MERCHANT_ID,
        data=DATA,
        totals=totals,
        corrected=True,
    )
    assert result.corrected is True