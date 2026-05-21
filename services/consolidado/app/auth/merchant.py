from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import Header

from app.errors import ProblemDetail

MERCHANT_HEADER = "X-Merchant-Id"


def extract_merchant_id(
    x_merchant_id: Annotated[str | None, Header(alias=MERCHANT_HEADER)] = None,
) -> uuid.UUID:
    if not x_merchant_id:
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail=f"Missing {MERCHANT_HEADER} header",
            type_="https://fluxo-caixa/errors/unauthorized",
        )
    try:
        return uuid.UUID(x_merchant_id)
    except ValueError as exc:
        raise ProblemDetail(
            status=401,
            title="Unauthorized",
            detail=f"Invalid {MERCHANT_HEADER} header",
            type_="https://fluxo-caixa/errors/unauthorized",
        ) from exc
