from __future__ import annotations

import uuid
from collections.abc import Generator
from typing import Annotated

from fastapi import Depends, Request
from redis.asyncio import Redis
from sqlalchemy.orm import Session

from app.auth.jwt import extract_merchant_id
from app.db import get_session_factory
from app.repository.read_model import ConsolidadoReadRepository
from app.repository.lancamentos_read import LancamentosReadRepository
from app.services.consolidado_read_service import ConsolidadoReadService
from app.services.lancamentos_read_service import LancamentosReadService


def get_redis(request: Request) -> Redis:
    return request.app.state.redis


def get_db_session() -> Generator[Session, None, None]:
    session = get_session_factory()()
    try:
        yield session
    finally:
        session.close()


def get_merchant_db_session(
    merchant_id: Annotated[uuid.UUID, Depends(extract_merchant_id)],
) -> Generator[Session, None, None]:
    session = get_session_factory()()
    try:
        ConsolidadoReadRepository.bind_merchant_rls(session, merchant_id)
        yield session
    finally:
        session.close()


def get_read_repository() -> ConsolidadoReadRepository:
    return ConsolidadoReadRepository()


def get_consolidado_read_service() -> ConsolidadoReadService:
    return ConsolidadoReadService()


def get_lancamentos_read_repository() -> LancamentosReadRepository:
    return LancamentosReadRepository()


def get_lancamentos_read_service() -> LancamentosReadService:
    return LancamentosReadService()
