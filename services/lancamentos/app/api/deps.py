from __future__ import annotations

import uuid
from collections.abc import Generator
from datetime import date
from typing import Annotated

from fastapi import Depends
from sqlalchemy.orm import Session

from app.auth.jwt import extract_merchant_id
from app.db import get_session_factory
from app.repository.lancamentos import LancamentosRepository
from app.services.lancamentos_service import LancamentosService


def get_clock() -> date:
    return date.today()


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
        LancamentosRepository.bind_merchant_rls(session, merchant_id)
        yield session
    finally:
        session.close()


def get_lancamentos_service() -> LancamentosService:
    return LancamentosService()
