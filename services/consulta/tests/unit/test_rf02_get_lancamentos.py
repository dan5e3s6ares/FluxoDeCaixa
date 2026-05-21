"""RF02 — GET /v1/lancamentos read proxy (doc 04 cross-schema read)."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Any
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_lancamentos_read_service, get_merchant_db_session
from app.domain import LancamentoListItem, LancamentoListPage
from app.main import app
from app.pagination.cursor import encode_cursor
from app.services.lancamentos_read_service import LancamentosReadService
from tests.helpers.jwt import MERCHANT_ID, auth_header as _auth_header

OTHER_MERCHANT = uuid.UUID("00000000-0000-4000-8000-000000000099")
FIXED_TODAY = date(2026, 5, 20)


def _item(
    *,
    item_id: uuid.UUID | None = None,
    created_at: datetime | None = None,
    tipo: str = "CREDITO",
    data_competencia: date = FIXED_TODAY,
) -> LancamentoListItem:
    return LancamentoListItem(
        id=item_id or uuid.uuid4(),
        valor=Decimal("100.00"),
        tipo=tipo,
        data_competencia=data_competencia,
        descricao="Test item",
        categoria_id=None,
        status="ATIVO",
        created_at=created_at
        or datetime(2026, 5, 20, 12, 0, 0, tzinfo=timezone.utc),
    )


@pytest.fixture
def mock_repo() -> MagicMock:
    return MagicMock()


@pytest.fixture
def client(mock_repo: MagicMock) -> TestClient:
    service = LancamentosReadService(repo=mock_repo)
    session = MagicMock()

    app.dependency_overrides[get_lancamentos_read_service] = lambda: service
    app.dependency_overrides[get_merchant_db_session] = lambda: session
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_get_lancamentos_returns_items_and_next_cursor(
    client: TestClient, mock_repo: MagicMock
) -> None:
    first_id = uuid.uuid4()
    second_id = uuid.uuid4()
    created_first = datetime(2026, 5, 20, 13, 0, 0, tzinfo=timezone.utc)
    created_second = datetime(2026, 5, 20, 12, 0, 0, tzinfo=timezone.utc)
    mock_repo.list_by_merchant.return_value = LancamentoListPage(
        items=[
            _item(item_id=first_id, created_at=created_first),
            _item(item_id=second_id, created_at=created_second),
        ],
        next_cursor=encode_cursor(created_at=created_second, lancamento_id=second_id),
    )

    response = client.get("/v1/lancamentos", headers=_auth_header())

    assert response.status_code == 200
    body = response.json()
    assert len(body["items"]) == 2
    assert body["items"][0]["id"] == str(first_id)
    assert body["items"][0]["status"] == "ATIVO"
    assert body["next_cursor"] is not None
    mock_repo.bind_merchant_rls.assert_called_once()
    call_kwargs = mock_repo.list_by_merchant.call_args.kwargs
    assert call_kwargs["merchant_id"] == MERCHANT_ID
    assert call_kwargs["limit"] == 50


def test_get_lancamentos_passes_filters_and_limit(
    client: TestClient, mock_repo: MagicMock
) -> None:
    mock_repo.list_by_merchant.return_value = LancamentoListPage(items=[], next_cursor=None)

    response = client.get(
        "/v1/lancamentos",
        params={
            "data_inicio": "2026-05-01",
            "data_fim": "2026-05-20",
            "tipo": "DEBITO",
            "cursor": "opaque-cursor",
            "limit": 25,
        },
        headers=_auth_header(),
    )

    assert response.status_code == 200
    call_kwargs = mock_repo.list_by_merchant.call_args.kwargs
    assert call_kwargs["data_inicio"] == date(2026, 5, 1)
    assert call_kwargs["data_fim"] == date(2026, 5, 20)
    assert call_kwargs["tipo"] == "DEBITO"
    assert call_kwargs["cursor"] == "opaque-cursor"
    assert call_kwargs["limit"] == 25


def test_get_lancamentos_requires_authorization(client: TestClient) -> None:
    response = client.get("/v1/lancamentos")
    assert response.status_code == 401


def test_get_lancamentos_extracts_merchant_id_from_jwt(
    client: TestClient, mock_repo: MagicMock
) -> None:
    mock_repo.list_by_merchant.return_value = LancamentoListPage(items=[], next_cursor=None)

    client.get("/v1/lancamentos", headers=_auth_header(OTHER_MERCHANT))

    assert mock_repo.list_by_merchant.call_args.kwargs["merchant_id"] == OTHER_MERCHANT


@pytest.mark.parametrize("limit", [0, 201])
def test_get_lancamentos_rejects_invalid_limit(client: TestClient, limit: int) -> None:
    response = client.get(
        "/v1/lancamentos",
        params={"limit": limit},
        headers=_auth_header(),
    )
    assert response.status_code == 422


def test_get_lancamentos_rejects_invalid_date_range(
    client: TestClient, mock_repo: MagicMock
) -> None:
    response = client.get(
        "/v1/lancamentos",
        params={"data_inicio": "2026-05-20", "data_fim": "2026-05-01"},
        headers=_auth_header(),
    )
    assert response.status_code == 422
    mock_repo.list_by_merchant.assert_not_called()


def test_get_lancamentos_rejects_invalid_tipo(
    client: TestClient, mock_repo: MagicMock
) -> None:
    response = client.get(
        "/v1/lancamentos",
        params={"tipo": "INVALID"},
        headers=_auth_header(),
    )
    assert response.status_code == 422
    mock_repo.list_by_merchant.assert_not_called()


def test_service_list_applies_default_limit(mock_repo: MagicMock) -> None:
    mock_repo.list_by_merchant.return_value = LancamentoListPage(items=[], next_cursor=None)
    service = LancamentosReadService(repo=mock_repo)
    session = MagicMock()

    service.list(session=session, merchant_id=MERCHANT_ID)

    assert mock_repo.list_by_merchant.call_args.kwargs["limit"] == 50
