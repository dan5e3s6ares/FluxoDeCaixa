from __future__ import annotations

import asyncio
import uuid
from datetime import date

from redis.asyncio import Redis
from sqlalchemy.orm import Session

from app.cache import get_cached_view, set_cached_view
from app.domain import ConsolidadoDiarioView, ConsolidadoReadResult
from app.repository.read_model import ConsolidadoReadRepository
from app.repository.staleness import StalenessRepository

STALE_HEADER = "X-Consolidado-Stale"


class ConsolidadoReadService:
    def __init__(
        self,
        *,
        read_repo: ConsolidadoReadRepository | None = None,
        staleness_repo: StalenessRepository | None = None,
    ) -> None:
        self._read_repo = read_repo or ConsolidadoReadRepository()
        self._staleness_repo = staleness_repo or StalenessRepository()

    async def get_daily(
        self,
        session: Session,
        redis: Redis,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> ConsolidadoReadResult:
        view = await get_cached_view(redis, merchant_id=merchant_id, data=data)
        if view is None:
            view = await asyncio.to_thread(
                self._load_from_postgres,
                session,
                merchant_id=merchant_id,
                data=data,
            )
            await set_cached_view(redis, view)
        stale = await asyncio.to_thread(
            self._staleness_repo.has_pending_outbox,
            session,
            merchant_id=merchant_id,
        )
        return ConsolidadoReadResult(consolidado=view, stale=stale)

    def _load_from_postgres(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data: date,
    ) -> ConsolidadoDiarioView:
        row = self._read_repo.get_daily(session, merchant_id=merchant_id, data=data)
        return row or self._read_repo.empty_daily(merchant_id=merchant_id, data=data)
