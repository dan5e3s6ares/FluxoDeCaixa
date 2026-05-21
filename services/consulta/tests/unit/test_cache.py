from __future__ import annotations

import asyncio
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal
from unittest.mock import AsyncMock

from redis.exceptions import ConnectionError

from app.cache import (
    CACHE_TTL_SECONDS,
    consolidado_cache_key,
    get_cached_view,
    set_cached_view,
)
from app.domain import ConsolidadoDiarioView

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


def test_consolidado_cache_key() -> None:
    key = consolidado_cache_key(MERCHANT_ID, DATA)
    assert key == "consolidado:00000000-0000-4000-8000-000000000001:2026-05-20"


def test_cache_ttl_is_24h() -> None:
    assert CACHE_TTL_SECONDS == 86_400


def test_get_cached_view_returns_none_on_miss() -> None:
    async def _run() -> None:
        redis = AsyncMock()
        redis.get.return_value = None

        result = await get_cached_view(redis, merchant_id=MERCHANT_ID, data=DATA)

        assert result is None
        redis.get.assert_awaited_once_with(consolidado_cache_key(MERCHANT_ID, DATA))

    asyncio.run(_run())


def test_get_cached_view_deserializes_hit() -> None:
    async def _run() -> None:
        redis = AsyncMock()
        redis.get.return_value = (
            '{"data":"2026-05-20","total_creditos":"100.00","total_debitos":"25.00",'
            '"saldo_final":"75.00","versao":2,"ultima_atualizacao":"2026-05-20T14:00:00Z"}'
        )

        result = await get_cached_view(redis, merchant_id=MERCHANT_ID, data=DATA)

        assert result is not None
        assert result.saldo_final == Decimal("75.00")
        assert result.ultima_atualizacao == UPDATED_AT

    asyncio.run(_run())


def test_get_cached_view_returns_none_when_redis_fails() -> None:
    async def _run() -> None:
        redis = AsyncMock()
        redis.get.side_effect = ConnectionError("redis down")

        result = await get_cached_view(redis, merchant_id=MERCHANT_ID, data=DATA)

        assert result is None

    asyncio.run(_run())


def test_set_cached_view_writes_with_ttl() -> None:
    async def _run() -> None:
        redis = AsyncMock()
        view = _view()

        await set_cached_view(redis, view)

        redis.set.assert_awaited_once()
        key, payload = redis.set.await_args.args[0], redis.set.await_args.args[1]
        assert key == consolidado_cache_key(MERCHANT_ID, DATA)
        assert redis.set.await_args.kwargs["ex"] == CACHE_TTL_SECONDS
        assert '"saldo_final":"75.00"' in payload

    asyncio.run(_run())


def test_set_cached_view_swallows_redis_write_errors() -> None:
    async def _run() -> None:
        redis = AsyncMock()
        redis.set.side_effect = ConnectionError("redis down")

        await set_cached_view(redis, _view())

        redis.set.assert_awaited_once()

    asyncio.run(_run())
