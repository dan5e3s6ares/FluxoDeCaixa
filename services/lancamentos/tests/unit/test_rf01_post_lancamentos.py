"""RF01 — POST /v1/lancamentos (persist + outbox, 201 ACCEPTED)."""

from __future__ import annotations

import uuid
from datetime import date, timedelta
from decimal import Decimal
from typing import Any
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_clock, get_lancamentos_service, get_merchant_db_session
from app.domain import LancamentoAccepted, LancamentoConflict
from app.main import app
from app.services.lancamentos_service import LancamentosService
from tests.helpers.jwt import MERCHANT_ID, auth_header as _auth_header

FIXED_TODAY = date(2026, 5, 20)


def _payload(**overrides: Any) -> dict[str, Any]:
    base = {
        "valor": "150.50",
        "tipo": "CREDITO",
        "data_competencia": FIXED_TODAY.isoformat(),
        "descricao": "Venda balcão",
    }
    base.update(overrides)
    return base


@pytest.fixture
def mock_repo() -> MagicMock:
    repo = MagicMock()
    repo.create_with_outbox.return_value = LancamentoAccepted(
        id=uuid.uuid4(),
        status="ACCEPTED",
        replay=False,
    )
    return repo


@pytest.fixture
def client(mock_repo: MagicMock) -> TestClient:
    service = LancamentosService(repo=mock_repo)
    session = MagicMock()

    app.dependency_overrides[get_clock] = lambda: FIXED_TODAY
    app.dependency_overrides[get_lancamentos_service] = lambda: service
    app.dependency_overrides[get_merchant_db_session] = lambda: session
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_post_lancamentos_201_accepted(client: TestClient, mock_repo: MagicMock) -> None:
    response = client.post(
        "/v1/lancamentos",
        json=_payload(),
        headers={**_auth_header(), "Idempotency-Key": str(uuid.uuid4())},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["status"] == "ACCEPTED"
    assert uuid.UUID(body["id"])
    mock_repo.create_with_outbox.assert_called_once()


def test_post_lancamentos_default_data_competencia_today(
    client: TestClient, mock_repo: MagicMock
) -> None:
    body = _payload()
    del body["data_competencia"]
    client.post(
        "/v1/lancamentos",
        json=body,
        headers=_auth_header(),
    )
    call_kwargs = mock_repo.create_with_outbox.call_args.kwargs
    assert call_kwargs["data_competencia"] == FIXED_TODAY


@pytest.mark.parametrize(
    "valor",
    ["0", "0.00", "-10", "10000000", "10000000.00"],
)
def test_post_lancamentos_rejects_invalid_valor(
    client: TestClient, valor: str
) -> None:
    response = client.post(
        "/v1/lancamentos",
        json=_payload(valor=valor),
        headers=_auth_header(),
    )
    assert response.status_code == 422
    assert response.headers["content-type"].startswith("application/problem+json")


@pytest.mark.parametrize("tipo", ["credito", "DEB", "", "TRANSFER"])
def test_post_lancamentos_rejects_invalid_tipo(client: TestClient, tipo: str) -> None:
    response = client.post(
        "/v1/lancamentos",
        json=_payload(tipo=tipo),
        headers=_auth_header(),
    )
    assert response.status_code == 422


def test_post_lancamentos_rejects_data_competencia_beyond_retroativo_7d(
    client: TestClient,
) -> None:
    too_old = (FIXED_TODAY - timedelta(days=8)).isoformat()
    response = client.post(
        "/v1/lancamentos",
        json=_payload(data_competencia=too_old),
        headers=_auth_header(),
    )
    assert response.status_code == 422
    problem = response.json()
    assert problem["status"] == 422


def test_post_lancamentos_rejects_future_data_competencia(client: TestClient) -> None:
    future = (FIXED_TODAY + timedelta(days=1)).isoformat()
    response = client.post(
        "/v1/lancamentos",
        json=_payload(data_competencia=future),
        headers=_auth_header(),
    )
    assert response.status_code == 422


def test_post_lancamentos_requires_authorization(client: TestClient) -> None:
    response = client.post("/v1/lancamentos", json=_payload())
    assert response.status_code == 401


def test_post_lancamentos_extracts_merchant_id_from_jwt(
    client: TestClient, mock_repo: MagicMock
) -> None:
    merchant = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    client.post(
        "/v1/lancamentos",
        json=_payload(),
        headers=_auth_header(merchant),
    )
    assert mock_repo.create_with_outbox.call_args.kwargs["merchant_id"] == merchant


def test_post_lancamentos_idempotency_replay_returns_200(
    client: TestClient, mock_repo: MagicMock
) -> None:
    lancamento_id = uuid.uuid4()
    mock_repo.create_with_outbox.return_value = LancamentoAccepted(
        id=lancamento_id,
        status="ACCEPTED",
        replay=True,
    )
    response = client.post(
        "/v1/lancamentos",
        json=_payload(),
        headers={**_auth_header(), "Idempotency-Key": "same-key"},
    )
    assert response.status_code == 200
    assert response.json()["id"] == str(lancamento_id)


def test_post_lancamentos_idempotency_conflict_returns_409(
    client: TestClient,
    mock_repo: MagicMock,
) -> None:
    mock_repo.create_with_outbox.side_effect = LancamentoConflict(
        "Idempotency-Key reused with different payload"
    )
    response = client.post(
        "/v1/lancamentos",
        json=_payload(),
        headers={**_auth_header(), "Idempotency-Key": "conflict-key"},
    )
    assert response.status_code == 409


def test_service_persists_lancamento_and_outbox_in_one_transaction() -> None:
    """Repository must insert lancamento + outbox before commit (no NATS)."""
    session = MagicMock()
    session.begin.return_value.__enter__ = MagicMock(return_value=None)
    session.begin.return_value.__exit__ = MagicMock(return_value=False)

    with patch("app.services.lancamentos_service.LancamentosRepository") as repo_cls:
        repo = repo_cls.return_value
        repo.create_with_outbox.return_value = LancamentoAccepted(
            id=uuid.uuid4(),
            status="ACCEPTED",
            replay=False,
        )
        service = LancamentosService(repo=repo)
        result = service.create(
            session=session,
            merchant_id=MERCHANT_ID,
            valor=Decimal("10.00"),
            tipo="DEBITO",
            data_competencia=FIXED_TODAY,
            descricao=None,
            categoria_id=None,
            idempotency_key=None,
            today=FIXED_TODAY,
        )

    assert result.status == "ACCEPTED"
    repo.create_with_outbox.assert_called_once()
    session.rollback.assert_not_called()
