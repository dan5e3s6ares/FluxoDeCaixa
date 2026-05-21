"""Shared JWT helpers for lancamentos API tests (doc 05 claims)."""

from __future__ import annotations

import time
import uuid

import jwt

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
JWT_SECRET = "test-secret-with-32-bytes-minimum!!"
ISSUER = "http://keycloak.local:8080/realms/fluxo-caixa"
AUDIENCE = "svc-lancamentos"


def auth_header(
    merchant_id: uuid.UUID = MERCHANT_ID,
    *,
    exp_offset: int = 3600,
    include_roles: bool = True,
) -> dict[str, str]:
    claims: dict[str, object] = {
        "sub": "test-user",
        "merchant_id": str(merchant_id),
        "iss": ISSUER,
        "aud": AUDIENCE,
        "exp": int(time.time()) + exp_offset,
    }
    if include_roles:
        claims["roles"] = ["merchant"]
    token = jwt.encode(claims, JWT_SECRET, algorithm="HS256")
    return {"Authorization": f"Bearer {token}"}
