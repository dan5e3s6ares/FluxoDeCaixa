"""RF03 public — GET /v1/consolidado/{data} via cache-aside (doc 02/05)."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_consolidado_read_service, get_merchant_db_session, get_redis
from app.domain import ConsolidadoDiarioView, ConsolidadoReadResult
from app.main import app
from app.services.consolidado_read_service import STALE_HEADER, ConsolidadoReadService
from tests.helpers.jwt import MERCHANT_ID, auth_header

DATA = date(2026, 5, 20)
UPDATED_AT = datetime(2026, 5, 20, 14, 0, 0, tzinfo=timezone.utc)


def _view(**overrides: object) -> ConsolidadoDiarioView:
    defaults = {
        "merchant_id": MERCHANT_ID,
        "data": DATA,
        "total_creditos": Decimal("100.00"),
        "total_debitos": Decimal("25.00"),
        "saldo_final": Decimal("75.00"),
        "versao": 3,
        "ultima_atualizacao": UPDATED_AT,
    }
    defaults.update(overrides)
    return ConsolidadoDiarioView(**defaults)  # type: ignore[arg-type]


@pytest.fixture
def mock_service() -> MagicMock:
    return MagicMock(spec=ConsolidadoReadService)


@pytest.fixture
def client(mock_service: MagicMock) -> TestClient:
    session = MagicMock()
    redis = AsyncMock()
    mock_service.get_daily = AsyncMock()
    app.dependency_overrides[get_consolidado_read_service] = lambda: mock_service
    app.dependency_overrides[get_merchant_db_session] = lambda: session
    app.dependency_overrides[get_redis] = lambda: redis
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_get_consolidado_returns_materialized_fields(
    client: TestClient, mock_service: MagicMock
) -> None:
    mock_service.get_daily.return_value = ConsolidadoReadResult(
        consolidado=_view(),
        stale=False,
    )

    response = client.get(f"/v1/consolidado/{DATA.isoformat()}", headers=auth_header())

    assert response.status_code == 200
    body = response.json()
    assert body == {
        "data": DATA.isoformat(),
        "total_creditos": "100.00",
        "total_debitos": "25.00",
        "saldo_final": "75.00",
        "ultima_atualizacao": UPDATED_AT.isoformat().replace("+00:00", "Z"),
    }
    assert STALE_HEADER not in response.headers


def test_get_consolidado_sets_stale_header_when_outbox_pending(
    client: TestClient, mock_service: MagicMock
) -> None:
    mock_service.get_daily.return_value = ConsolidadoReadResult(
        consolidado=_view(),
        stale=True,
    )

    response = client.get(f"/v1/consolidado/{DATA.isoformat()}", headers=auth_header())

    assert response.status_code == 200
    assert response.headers.get(STALE_HEADER) == "true"


def test_get_consolidado_empty_day_without_stale_header(
    client: TestClient, mock_service: MagicMock
) -> None:
    mock_service.get_daily.return_value = ConsolidadoReadResult(
        consolidado=_view(
            total_creditos=Decimal("0"),
            total_debitos=Decimal("0"),
            saldo_final=Decimal("0"),
            versao=0,
            ultima_atualizacao=None,
        ),
        stale=False,
    )

    response = client.get(f"/v1/consolidado/{DATA.isoformat()}", headers=auth_header())

    assert response.status_code == 200
    body = response.json()
    assert body["saldo_final"] == "0.00"
    assert body["ultima_atualizacao"] is None
    assert STALE_HEADER not in response.headers


def test_get_consolidado_requires_jwt(client: TestClient) -> None:
    response = client.get(f"/v1/consolidado/{DATA.isoformat()}")
    assert response.status_code == 401


def test_get_consolidado_uses_merchant_from_jwt_only(
    client: TestClient, mock_service: MagicMock
) -> None:
    other_merchant = uuid.UUID("00000000-0000-4000-8000-000000000099")
    mock_service.get_daily.return_value = ConsolidadoReadResult(
        consolidado=_view(merchant_id=other_merchant),
        stale=False,
    )

    response = client.get(
        f"/v1/consolidado/{DATA.isoformat()}",
        headers=auth_header(merchant_id=MERCHANT_ID),
    )

    assert response.status_code == 200
    mock_service.get_daily.assert_awaited_once()
    call_kwargs = mock_service.get_daily.await_args.kwargs
    assert call_kwargs["merchant_id"] == MERCHANT_ID
