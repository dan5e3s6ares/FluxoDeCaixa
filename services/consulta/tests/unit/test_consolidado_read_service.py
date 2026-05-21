"""Cache-aside read service — Redis then PG (doc 04)."""

from __future__ import annotations

import asyncio
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock

from redis.exceptions import ConnectionError

from app.cache import CACHE_TTL_SECONDS, consolidado_cache_key
from app.domain import ConsolidadoDiarioView
from app.repository.read_model import ConsolidadoReadRepository
from app.repository.staleness import StalenessRepository
from app.services.consolidado_read_service import ConsolidadoReadService

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
DATA = date(2026, 5, 20)
UPDATED_AT = datetime(2026, 5, 20, 14, 0, 0, tzinfo=timezone.utc)


def _view(**overrides: object) -> ConsolidadoDiarioView:
    defaults = {
        "merchant_id": MERCHANT_ID,
        "data": DATA,
        "total_creditos": Decimal("100.00"),
        "total_debitos": Decimal("25.00"),
        "saldo_final": Decimal("75.00"),
        "versao": 2,
        "ultima_atualizacao": UPDATED_AT,
    }
    defaults.update(overrides)
    return ConsolidadoDiarioView(**defaults)  # type: ignore[arg-type]


def test_get_daily_returns_cache_hit_without_postgres_read() -> None:
    async def _run() -> None:
        session = MagicMock()
        redis = AsyncMock()
        read_repo = MagicMock(spec=ConsolidadoReadRepository)
        staleness_repo = MagicMock(spec=StalenessRepository)
        redis.get.return_value = (
            '{"data":"2026-05-20","total_creditos":"100.00","total_debitos":"25.00",'
            '"saldo_final":"75.00","versao":2,"ultima_atualizacao":"2026-05-20T14:00:00Z"}'
        )
        staleness_repo.has_pending_outbox.return_value = False
        service = ConsolidadoReadService(read_repo=read_repo, staleness_repo=staleness_repo)

        result = await service.get_daily(session, redis, merchant_id=MERCHANT_ID, data=DATA)

        assert result.stale is False
        assert result.consolidado.saldo_final == Decimal("75.00")
        read_repo.get_daily.assert_not_called()
        redis.set.assert_not_called()

    asyncio.run(_run())


def test_get_daily_loads_postgres_on_cache_miss_and_populates_cache() -> None:
    async def _run() -> None:
        session = MagicMock()
        redis = AsyncMock()
        read_repo = MagicMock(spec=ConsolidadoReadRepository)
        staleness_repo = MagicMock(spec=StalenessRepository)
        view = _view()
        redis.get.return_value = None
        read_repo.get_daily.return_value = view
        staleness_repo.has_pending_outbox.return_value = True
        service = ConsolidadoReadService(read_repo=read_repo, staleness_repo=staleness_repo)

        result = await service.get_daily(session, redis, merchant_id=MERCHANT_ID, data=DATA)

        assert result.stale is True
        assert result.consolidado == view
        read_repo.get_daily.assert_called_once_with(session, merchant_id=MERCHANT_ID, data=DATA)
        redis.set.assert_awaited_once()
        key, payload = redis.set.await_args.args[0], redis.set.await_args.args[1]
        assert key == consolidado_cache_key(MERCHANT_ID, DATA)
        assert redis.set.await_args.kwargs["ex"] == CACHE_TTL_SECONDS
        assert '"saldo_final":"75.00"' in payload

    asyncio.run(_run())


def test_get_daily_falls_back_to_postgres_when_redis_read_fails() -> None:
    async def _run() -> None:
        session = MagicMock()
        redis = AsyncMock()
        read_repo = MagicMock(spec=ConsolidadoReadRepository)
        staleness_repo = MagicMock(spec=StalenessRepository)
        redis.get.side_effect = ConnectionError("redis down")
        read_repo.get_daily.return_value = None
        read_repo.empty_daily.return_value = _view(
            total_creditos=Decimal("0"),
            total_debitos=Decimal("0"),
            saldo_final=Decimal("0"),
            versao=0,
            ultima_atualizacao=None,
        )
        staleness_repo.has_pending_outbox.return_value = False
        service = ConsolidadoReadService(read_repo=read_repo, staleness_repo=staleness_repo)

        result = await service.get_daily(session, redis, merchant_id=MERCHANT_ID, data=DATA)

        assert result.consolidado.saldo_final == Decimal("0")
        read_repo.empty_daily.assert_called_once_with(merchant_id=MERCHANT_ID, data=DATA)

    asyncio.run(_run())
