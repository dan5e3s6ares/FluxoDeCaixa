"""Security, RLS session, and observability (doc 05)."""

from __future__ import annotations

import logging
import uuid
from datetime import date
from decimal import Decimal
from unittest.mock import MagicMock

import jwt
import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_clock, get_lancamentos_service, get_merchant_db_session
from app.auth.jwt import extract_merchant_id
from app.domain import LancamentoAccepted
from app.errors import ProblemDetail
from app.domain import LancamentoAccepted
from app.main import app
from app.repository.lancamentos import LancamentosRepository
from app.services.lancamentos_service import LancamentosService
from fcx_shared.tracing import traceparent_from_correlation_id
from tests.helpers.jwt import AUDIENCE, ISSUER, JWT_SECRET, MERCHANT_ID, auth_header

FIXED_TODAY = date(2026, 5, 20)


def test_correlation_id_equals_lancamento_id_in_outbox_payload() -> None:
    session = MagicMock()
    repo = LancamentosRepository()

    repo.create_with_outbox(
        session,
        merchant_id=MERCHANT_ID,
        valor=Decimal("10.00"),
        tipo="CREDITO",
        data_competencia=FIXED_TODAY,
        descricao="Test",
        categoria_id=None,
        idempotency_key=None,
    )

    outbox = session.add.call_args_list[1].args[0]
    lancamento = session.add.call_args_list[0].args[0]
    assert outbox.payload["correlation_id"] == str(lancamento.id)


def test_bind_merchant_rls_sets_app_merchant_id() -> None:
    session = MagicMock()
    merchant_id = uuid.uuid4()

    LancamentosRepository.bind_merchant_rls(session, merchant_id)

    session.execute.assert_called_once()
    stmt, params = session.execute.call_args.args
    assert "set_app_merchant_id" in str(stmt)
    assert params == {"merchant_id": merchant_id}


@pytest.fixture
def client() -> TestClient:
    mock_repo = MagicMock()
    mock_repo.create_with_outbox.return_value = LancamentoAccepted(
        id=uuid.UUID("11111111-1111-4111-8111-111111111111"),
        status="ACCEPTED",
        replay=False,
    )
    service = LancamentosService(repo=mock_repo)
    session = MagicMock()

    app.dependency_overrides[get_clock] = lambda: FIXED_TODAY
    app.dependency_overrides[get_lancamentos_service] = lambda: service
    app.dependency_overrides[get_merchant_db_session] = lambda: session
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_post_sets_x_correlation_id_header(client: TestClient) -> None:
    response = client.post(
        "/v1/lancamentos",
        json={
            "valor": "10.00",
            "tipo": "CREDITO",
            "data_competencia": FIXED_TODAY.isoformat(),
        },
        headers=auth_header(),
    )
    assert response.status_code == 201
    assert response.headers["X-Correlation-Id"] == "11111111-1111-4111-8111-111111111111"


def test_jwt_rejects_expired_token() -> None:
    token = jwt.encode(
        {
            "sub": "user",
            "merchant_id": str(MERCHANT_ID),
            "roles": ["merchant"],
            "iss": ISSUER,
            "aud": AUDIENCE,
            "exp": 1,
        },
        JWT_SECRET,
        algorithm="HS256",
    )
    with pytest.raises(ProblemDetail) as exc_info:
        extract_merchant_id(authorization=f"Bearer {token}")
    assert exc_info.value.status == 401


def test_traceparent_from_correlation_id() -> None:
    correlation_id = "22222222-2222-4222-8222-222222222222"
    tp = traceparent_from_correlation_id(correlation_id)
    assert tp == "00-22222222222242228222222222222222-2222222222224222-01"


def test_post_logs_structured_correlation_fields(
    client: TestClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO)
    client.post(
        "/v1/lancamentos",
        json={
            "valor": "10.00",
            "tipo": "CREDITO",
            "data_competencia": FIXED_TODAY.isoformat(),
        },
        headers=auth_header(),
    )
    records = [r for r in caplog.records if r.getMessage() == "lancamento accepted"]
    assert len(records) == 1
    record = records[0]
    assert record.merchant_id == str(MERCHANT_ID)
    assert record.lancamento_id == "11111111-1111-4111-8111-111111111111"
    assert record.correlation_id == "11111111-1111-4111-8111-111111111111"
