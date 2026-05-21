from __future__ import annotations

import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Response
from redis.asyncio import Redis
from sqlalchemy.orm import Session

from app.api.deps import (
    get_consolidado_read_service,
    get_merchant_db_session,
    get_redis,
)
from app.auth.jwt import extract_merchant_id
from app.schemas.consolidado import ConsolidadoDiarioResponse
from app.services.consolidado_read_service import (
    STALE_HEADER,
    ConsolidadoReadService,
)

router = APIRouter(prefix="/v1", tags=["consolidado"])


@router.get("/consolidado/{data}", response_model=ConsolidadoDiarioResponse)
async def get_consolidado_diario(
    data: date,
    response: Response,
    merchant_id: Annotated[uuid.UUID, Depends(extract_merchant_id)],
    session: Annotated[Session, Depends(get_merchant_db_session)],
    redis: Annotated[Redis, Depends(get_redis)],
    service: Annotated[ConsolidadoReadService, Depends(get_consolidado_read_service)],
) -> ConsolidadoDiarioResponse:
    result = await service.get_daily(
        session,
        redis,
        merchant_id=merchant_id,
        data=data,
    )
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
