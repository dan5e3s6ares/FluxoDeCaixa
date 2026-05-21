from __future__ import annotations

import uuid
from unittest.mock import MagicMock

import jwt
import pytest

from app.auth.jwt import extract_merchant_id
from app.errors import ProblemDetail
from app.repository.read_model import ConsolidadoReadRepository

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
ISSUER = "http://keycloak.local:8080/realms/fluxo-caixa"
AUDIENCE = "svc-consulta"
JWT_SECRET = "test-secret-with-32-bytes-minimum!!"


def _token(**overrides: object) -> str:
    claims: dict[str, object] = {
        "sub": "test-user",
        "merchant_id": str(MERCHANT_ID),
        "roles": ["merchant"],
        "iss": ISSUER,
        "aud": AUDIENCE,
        "exp": 4_102_444_800,
    }
    claims.update(overrides)
    return jwt.encode(claims, JWT_SECRET, algorithm="HS256")


def test_extract_merchant_id_from_jwt() -> None:
    merchant_id = extract_merchant_id(authorization=f"Bearer {_token()}")
    assert merchant_id == MERCHANT_ID


def test_extract_merchant_id_rejects_missing_header() -> None:
    with pytest.raises(ProblemDetail) as exc_info:
        extract_merchant_id(authorization=None)
    assert exc_info.value.status == 401


def test_bind_merchant_rls_sets_app_merchant_id() -> None:
    session = MagicMock()
    merchant_id = uuid.uuid4()

    ConsolidadoReadRepository.bind_merchant_rls(session, merchant_id)

    session.execute.assert_called_once()
    stmt, params = session.execute.call_args.args
    assert "set_app_merchant_id" in str(stmt)
    assert params == {"merchant_id": merchant_id}
