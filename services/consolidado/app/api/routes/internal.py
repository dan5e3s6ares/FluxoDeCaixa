from __future__ import annotations

import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Response
from sqlalchemy.orm import Session

from app.api.deps import get_consolidado_read_service, get_merchant_db_session
from app.auth.merchant import extract_merchant_id
from app.schemas.consolidado import ConsolidadoDiarioResponse
from app.services.consolidado_read_service import (
    STALE_HEADER,
    ConsolidadoReadService,
)

router = APIRouter(prefix="/internal/v1", tags=["internal"])


@router.get("/consolidado/{data}", response_model=ConsolidadoDiarioResponse)
def get_consolidado_diario(
    data: date,
    response: Response,
    merchant_id: Annotated[uuid.UUID, Depends(extract_merchant_id)],
    session: Annotated[Session, Depends(get_merchant_db_session)],
    service: Annotated[ConsolidadoReadService, Depends(get_consolidado_read_service)],
) -> ConsolidadoDiarioResponse:
    result = service.get_daily(session, merchant_id=merchant_id, data=data)
    if result.stale:
        response.headers[STALE_HEADER] = "true"
    view = result.consolidado
    return ConsolidadoDiarioResponse(
        data=view.data,
        total_creditos=view.total_creditos,
        total_debitos=view.total_debitos,
        saldo_final=view.saldo_final,
        ultima_atualizacao=view.ultima_atualizacao,
    )
