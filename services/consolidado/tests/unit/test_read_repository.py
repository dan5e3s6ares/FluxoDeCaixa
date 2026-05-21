"""Consolidado read repository and staleness unit tests."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock

from app.models import ConsolidadoDiario
from app.repository.read_model import ConsolidadoReadRepository
from app.repository.staleness import StalenessRepository
from app.services.consolidado_read_service import ConsolidadoReadService

MERCHANT_ID = uuid.UUID("44444444-4444-4444-8444-444444444444")
DATA = date(2026, 5, 20)


def test_get_daily_maps_row_fields() -> None:
    session = MagicMock()
    row = ConsolidadoDiario(
        merchant_id=MERCHANT_ID,
        data=DATA,
        total_creditos=Decimal("10.00"),
        total_debitos=Decimal("2.50"),
        saldo_final=Decimal("7.50"),
        versao=2,
        ultima_atualizacao=datetime(2026, 5, 20, 12, 0, 0, tzinfo=timezone.utc),
    )
    session.execute.return_value = MagicMock(scalar_one_or_none=MagicMock(return_value=row))
    repo = ConsolidadoReadRepository()

    view = repo.get_daily(session, merchant_id=MERCHANT_ID, data=DATA)

    assert view is not None
    assert view.saldo_final == Decimal("7.50")
    assert view.ultima_atualizacao == row.ultima_atualizacao
    assert view.versao == 2


def test_staleness_detects_pending_outbox() -> None:
    session = MagicMock()
    session.execute.return_value = MagicMock(scalar_one=MagicMock(return_value=True))
    repo = StalenessRepository()

    assert repo.has_pending_outbox(session, merchant_id=MERCHANT_ID) is True
    sql = str(session.execute.call_args.args[0])
    assert "lancamentos.outbox_events" in sql
    assert "published_at IS NULL" in sql


def test_read_service_returns_empty_day_when_no_projection() -> None:
    session = MagicMock()
    read_repo = ConsolidadoReadRepository()
    staleness_repo = MagicMock()
    read_repo.get_daily = MagicMock(return_value=None)  # type: ignore[method-assign]
    staleness_repo.has_pending_outbox.return_value = False
    service = ConsolidadoReadService(read_repo=read_repo, staleness_repo=staleness_repo)

    result = service.get_daily(session, merchant_id=MERCHANT_ID, data=DATA)

    assert result.consolidado.saldo_final == Decimal("0")
    assert result.consolidado.ultima_atualizacao is None
    assert result.stale is False


def test_read_service_marks_stale_when_outbox_pending() -> None:
    session = MagicMock()
    read_repo = MagicMock()
    staleness_repo = MagicMock()
    read_repo.get_daily.return_value = read_repo.empty_daily(merchant_id=MERCHANT_ID, data=DATA)
    staleness_repo.has_pending_outbox.return_value = True
    service = ConsolidadoReadService(read_repo=read_repo, staleness_repo=staleness_repo)

    result = service.get_daily(session, merchant_id=MERCHANT_ID, data=DATA)

    assert result.stale is True
