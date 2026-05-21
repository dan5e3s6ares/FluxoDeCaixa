from __future__ import annotations

import logging
import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response, status
from sqlalchemy.orm import Session

from app.api.deps import get_clock, get_lancamentos_service, get_merchant_db_session
from app.auth.jwt import extract_merchant_id
from app.domain import LancamentoConflict
from app.errors import ProblemDetail
from app.schemas.lancamentos import (
    LancamentoCreateRequest,
    LancamentoCreateResponse,
    LancamentoListItemResponse,
    LancamentoListResponse,
)
from app.services.lancamentos_service import LancamentosService

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1", tags=["lancamentos"])


@router.get("/lancamentos", response_model=LancamentoListResponse)
def list_lancamentos(
    merchant_id: Annotated[uuid.UUID, Depends(extract_merchant_id)],
    session: Annotated[Session, Depends(get_merchant_db_session)],
    service: Annotated[LancamentosService, Depends(get_lancamentos_service)],
    data_inicio: Annotated[date | None, Query()] = None,
    data_fim: Annotated[date | None, Query()] = None,
    tipo: Annotated[str | None, Query()] = None,
    cursor: Annotated[str | None, Query()] = None,
    limit: Annotated[int | None, Query(ge=1, le=200)] = None,
) -> LancamentoListResponse:
    page = service.list(
        session=session,
        merchant_id=merchant_id,
        data_inicio=data_inicio,
        data_fim=data_fim,
        tipo=tipo,
        cursor=cursor,
        limit=limit,
    )
    return LancamentoListResponse(
        items=[LancamentoListItemResponse.model_validate(item) for item in page.items],
        next_cursor=page.next_cursor,
    )


@router.post(
    "/lancamentos",
    response_model=LancamentoCreateResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_lancamento(
    body: LancamentoCreateRequest,
    response: Response,
    merchant_id: Annotated[uuid.UUID, Depends(extract_merchant_id)],
    session: Annotated[Session, Depends(get_merchant_db_session)],
    service: Annotated[LancamentosService, Depends(get_lancamentos_service)],
    today: Annotated[date, Depends(get_clock)],
    idempotency_key: Annotated[str | None, Header(alias="Idempotency-Key")] = None,
) -> LancamentoCreateResponse:
    try:
        accepted = service.create(
            session=session,
            merchant_id=merchant_id,
            valor=body.valor,
            tipo=body.tipo,
            data_competencia=body.data_competencia,
            descricao=body.descricao,
            categoria_id=body.categoria_id,
            idempotency_key=idempotency_key,
            today=today,
        )
        # Commit after service flush so lancamento + outbox share one transaction.
        session.commit()
    except LancamentoConflict as exc:
        session.rollback()
        raise ProblemDetail(
            status=409,
            title="Conflict",
            detail=str(exc),
            type_="https://fluxo-caixa/errors/idempotency-conflict",
        ) from exc
    except ProblemDetail:
        session.rollback()
        raise
    except Exception:
        session.rollback()
        raise

    if accepted.replay:
        response.status_code = status.HTTP_200_OK

    response.headers["X-Correlation-Id"] = str(accepted.id)
    logger.info(
        "lancamento accepted",
        extra={
            "merchant_id": str(merchant_id),
            "lancamento_id": str(accepted.id),
            "correlation_id": str(accepted.id),
        },
    )

    return LancamentoCreateResponse(id=accepted.id, status="ACCEPTED")
