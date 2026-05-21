"""Reconciliation repository SQL contract and method tests."""

from __future__ import annotations

import uuid
from decimal import Decimal
from unittest.mock import MagicMock

from app.domain import DayTotals
from app.repository.reconciliation import (
    _AGGREGATE_DAY,
    _LIST_DAYS,
    _SNAPSHOT_UPSERT,
    ReconciliationRepository,
)

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")


def test_aggregate_sql_targets_lancamentos_schema() -> None:
    sql = str(_AGGREGATE_DAY)
    assert "lancamentos.lancamentos" in sql
    assert "status = 'ATIVO'" in sql
    assert "data_competencia" in sql


def test_snapshot_upsert_replaces_totals() -> None:
    sql = str(_SNAPSHOT_UPSERT)
    assert "consolidado.consolidado_diario" in sql
    assert "ON CONFLICT" in sql
    assert "total_creditos = EXCLUDED.total_creditos" in sql


def test_list_days_unions_lancamentos_and_projection() -> None:
    sql = str(_LIST_DAYS)
    assert "UNION" in sql
    assert "data_competencia" in sql


def test_aggregate_lancamentos_calls_bind_and_returns_totals() -> None:
    session = MagicMock()
    row = MagicMock()
    row._mapping = {
        "total_creditos": Decimal("100.00"),
        "total_debitos": Decimal("25.00"),
        "saldo_final": Decimal("75.00"),
        "lancamento_count": 3,
    }
    session.execute.return_value = MagicMock(one=MagicMock(return_value=row))
    repo = ReconciliationRepository()

    totals = repo.aggregate_lancamentos(session, merchant_id=MERCHANT_ID, data=__import__("datetime").date(2026, 5, 20))

    assert totals.total_creditos == Decimal("100.00")
    assert totals.total_debitos == Decimal("25.00")
    assert totals.saldo_final == Decimal("75.00")
    assert totals.lancamento_count == 3
    # RLS bind should be called
    assert session.execute.call_count >= 2


def test_get_projection_totals_returns_none_when_no_row() -> None:
    session = MagicMock()
    session.execute.return_value = MagicMock(one_or_none=MagicMock(return_value=None))
    repo = ReconciliationRepository()

    result = repo.get_projection_totals(session, merchant_id=MERCHANT_ID, data=__import__("datetime").date(2026, 5, 20))

    assert result is None


def test_get_projection_totals_returns_day_totals_when_row_found() -> None:
    session = MagicMock()
    row = MagicMock()
    row.total_creditos = Decimal("200.00")
    row.total_debitos = Decimal("50.00")
    row.total_saldo_final = Decimal("150.00")
    row.saldo_final = Decimal("150.00")
    session.execute.return_value = MagicMock(one_or_none=MagicMock(return_value=row))
    repo = ReconciliationRepository()

    result = repo.get_projection_totals(session, merchant_id=MERCHANT_ID, data=__import__("datetime").date(2026, 5, 20))

    assert result is not None
    assert result.total_creditos == Decimal("200.00")


def test_snapshot_recompute_executes_upsert() -> None:
    session = MagicMock()
    totals = DayTotals(
        total_creditos=Decimal("100.00"),
        total_debitos=Decimal("25.00"),
        saldo_final=Decimal("75.00"),
        lancamento_count=3,
    )
    repo = ReconciliationRepository()

    repo.snapshot_recompute(
        session,
        merchant_id=MERCHANT_ID,
        data=__import__("datetime").date(2026, 5, 20),
        totals=totals,
    )

    # RLS bind + upsert = at least 2 execute calls
    assert session.execute.call_count >= 2
