from __future__ import annotations

import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.api.deps import get_lancamentos_read_service, get_merchant_db_session
from app.auth.jwt import extract_merchant_id
from app.schemas.lancamentos import LancamentoListItemResponse, LancamentoListResponse
from app.services.lancamentos_read_service import LancamentosReadService

router = APIRouter(prefix="/v1", tags=["lancamentos"])


@router.get("/lancamentos", response_model=LancamentoListResponse)
def list_lancamentos(
    merchant_id: Annotated[uuid.UUID, Depends(extract_merchant_id)],
    session: Annotated[Session, Depends(get_merchant_db_session)],
    service: Annotated[LancamentosReadService, Depends(get_lancamentos_read_service)],
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
