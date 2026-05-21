from __future__ import annotations

import json
import logging
import uuid
from datetime import date, datetime
from decimal import Decimal

from redis.asyncio import Redis
from redis.exceptions import RedisError

from app.domain import ConsolidadoDiarioView

logger = logging.getLogger(__name__)

# 24h safety net for cache-aside reads (doc 04).
CACHE_TTL_SECONDS = 86_400


def consolidado_cache_key(merchant_id: uuid.UUID | str, data: date | str) -> str:
    merchant = str(merchant_id)
    day = data.isoformat() if isinstance(data, date) else str(data)
    return f"consolidado:{merchant}:{day}"


def _serialize_view(view: ConsolidadoDiarioView) -> str:
    ultima_atualizacao: str | None
    if view.ultima_atualizacao is None:
        ultima_atualizacao = None
    else:
        ultima_atualizacao = (
            view.ultima_atualizacao.isoformat().replace("+00:00", "Z")
        )
    payload = {
        "data": view.data.isoformat(),
        "total_creditos": format(view.total_creditos.quantize(Decimal("0.01")), "f"),
        "total_debitos": format(view.total_debitos.quantize(Decimal("0.01")), "f"),
        "saldo_final": format(view.saldo_final.quantize(Decimal("0.01")), "f"),
        "versao": view.versao,
        "ultima_atualizacao": ultima_atualizacao,
    }
    return json.dumps(payload, separators=(",", ":"))


def _deserialize_view(merchant_id: uuid.UUID, raw: str) -> ConsolidadoDiarioView:
    payload = json.loads(raw)
    ultima_raw = payload.get("ultima_atualizacao")
    ultima_atualizacao = datetime.fromisoformat(ultima_raw.replace("Z", "+00:00")) if ultima_raw else None
    return ConsolidadoDiarioView(
        merchant_id=merchant_id,
        data=date.fromisoformat(str(payload["data"])),
        total_creditos=Decimal(str(payload["total_creditos"])),
        total_debitos=Decimal(str(payload["total_debitos"])),
        saldo_final=Decimal(str(payload["saldo_final"])),
        versao=int(payload.get("versao", 0)),
        ultima_atualizacao=ultima_atualizacao,
    )


async def get_cached_view(
    redis: Redis,
    *,
    merchant_id: uuid.UUID,
    data: date,
) -> ConsolidadoDiarioView | None:
    key = consolidado_cache_key(merchant_id, data)
    try:
        raw = await redis.get(key)
    except RedisError:
        logger.exception("redis cache read failed", extra={"cache_key": key})
        return None
    if raw is None:
        return None
    return _deserialize_view(merchant_id, raw)


async def set_cached_view(redis: Redis, view: ConsolidadoDiarioView) -> None:
    key = consolidado_cache_key(view.merchant_id, view.data)
    try:
        await redis.set(key, _serialize_view(view), ex=CACHE_TTL_SECONDS)
    except RedisError:
        logger.exception("redis cache write failed", extra={"cache_key": key})


async def create_redis_client(redis_url: str) -> Redis:
    """Create an async Redis client (redis-py asyncio)."""
    client: Redis = Redis.from_url(redis_url, decode_responses=True)
    await client.ping()
    return client


async def close_redis_client(client: Redis | None) -> None:
    if client is not None:
        await client.aclose()
