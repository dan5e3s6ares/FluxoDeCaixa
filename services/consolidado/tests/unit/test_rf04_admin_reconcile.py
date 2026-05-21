"""RF04 admin — recompute, reconcile, outbox DLQ replay (doc 02)."""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_db_session, get_reconciliation_service
from app.auth.admin import ROLES_HEADER
from app.domain import DayTotals, RecomputeResult, ReconciliationCheck
from app.main import app
from app.services.reconciliation_service import ReconciliationService

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
DATA = date(2026, 5, 20)
_TOTALS = DayTotals(
    total_creditos=Decimal("100.00"),
    total_debitos=Decimal("25.00"),
    saldo_final=Decimal("75.00"),
    lancamento_count=2,
)


def _admin_headers() -> dict[str, str]:
    return {ROLES_HEADER: "admin"}


@pytest.fixture
def mock_service() -> MagicMock:
    return MagicMock(spec=ReconciliationService)


@pytest.fixture
def client(mock_service: MagicMock) -> TestClient:
    session = MagicMock()
    app.dependency_overrides[get_reconciliation_service] = lambda: mock_service
    app.dependency_overrides[get_db_session] = lambda: session
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_admin_recompute_requires_admin_role(client: TestClient) -> None:
    response = client.post(
        "/internal/v1/admin/recompute",
        json={"merchant_id": str(MERCHANT_ID), "data": DATA.isoformat()},
    )
    assert response.status_code == 403


def test_admin_recompute_returns_corrected_totals(
    client: TestClient, mock_service: MagicMock
) -> None:
    mock_service.recompute_day.return_value = RecomputeResult(
        merchant_id=MERCHANT_ID,
        data=DATA,
        totals=_TOTALS,
        corrected=True,
    )

    response = client.post(
        "/internal/v1/admin/recompute",
        headers=_admin_headers(),
        json={"merchant_id": str(MERCHANT_ID), "data": DATA.isoformat()},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["corrected"] is True
    assert body["totals"]["saldo_final"] == "75.00"
    assert body["totals"]["lancamento_count"] == 2


def test_admin_reconcile_compare_only(
    client: TestClient, mock_service: MagicMock
) -> None:
    mock_service.check_day.return_value = ReconciliationCheck(
        merchant_id=MERCHANT_ID,
        data=DATA,
        source=_TOTALS,
        projection=_TOTALS,
        matched=True,
    )

    response = client.post(
        "/internal/v1/admin/reconcile",
        headers=_admin_headers(),
        json={"merchant_id": str(MERCHANT_ID), "data": DATA.isoformat()},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["matched"] is True
    assert body["source"]["total_creditos"] == "100.00"


def test_admin_outbox_replay_returns_ids(
    client: TestClient, mock_service: MagicMock
) -> None:
    mock_service.replay_outbox.return_value = [10, 11]

    response = client.post(
        "/internal/v1/admin/outbox/replay",
        headers=_admin_headers(),
        json={"merchant_id": str(MERCHANT_ID)},
    )

    assert response.status_code == 200
    assert response.json() == {"replayed_ids": [10, 11]}
