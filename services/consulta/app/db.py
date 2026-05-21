from __future__ import annotations

from functools import lru_cache

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from sqlalchemy.orm.session import Session

from fcx_shared import get_settings


class Base(DeclarativeBase):
    """Read-only SQLAlchemy base for cross-schema reads (consolidado, lancamentos)."""

    pass


@lru_cache
def get_engine():
    settings = get_settings()
    return create_engine(settings.database_url, pool_pre_ping=True)


@lru_cache
def get_session_factory() -> sessionmaker[Session]:
    return sessionmaker(bind=get_engine(), autoflush=False, expire_on_commit=False)
