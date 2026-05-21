from __future__ import annotations

import uuid
from typing import Annotated, Any

import jwt
from fastapi import Header
from fcx_shared import get_settings

from app.errors import ProblemDetail

MERCHANT_CLAIM = "merchant_id"
ROLES_CLAIM = "roles"


def _expected_issuer() -> str:
    settings = get_settings()
    return f"{settings.keycloak_url.rstrip('/')}/realms/{settings.keycloak_realm}"


def _decode_claims(token: str) -> dict[str, Any]:
    settings = get_settings()
    try:
        return jwt.decode(
            token,
            options={
                "verify_signature": False,
                "verify_exp": True,
                "verify_aud": True,
                "verify_iss": True,
                "require": ["exp", "sub", MERCHANT_CLAIM, ROLES_CLAIM],
            },
            audience=settings.keycloak_client_id,
            issuer=_expected_issuer(),
        )
    except jwt.ExpiredSignatureError as exc:
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail="JWT expired",
            type_="https://fluxo-caixa/errors/unauthorized",
        ) from exc
    except jwt.PyJWTError as exc:
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail="Invalid JWT",
            type_="https://fluxo-caixa/errors/unauthorized",
        ) from exc


def extract_merchant_id(authorization: Annotated[str | None, Header()] = None) -> uuid.UUID:
    if not authorization or not authorization.startswith("Bearer "):
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail="Missing or invalid Authorization header",
            type_="https://fluxo-caixa/errors/unauthorized",
        )
    token = authorization.removeprefix("Bearer ").strip()
    # Signature is verified by KrakenD upstream; services revalidate claims + tenant scope.
    claims = _decode_claims(token)

    raw = claims.get(MERCHANT_CLAIM)
    if not raw:
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail="JWT missing merchant_id claim",
            type_="https://fluxo-caixa/errors/unauthorized",
        )
    try:
        return uuid.UUID(str(raw))
    except ValueError as exc:
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail="Invalid merchant_id claim",
            type_="https://fluxo-caixa/errors/unauthorized",
        ) from exc
