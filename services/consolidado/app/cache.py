from __future__ import annotations

import logging
import uuid
from datetime import date
from functools import lru_cache
from typing import Any

import redis

from fcx_shared import get_settings

logger = logging.getLogger(__name__)

# 24h safety net for cache-aside reads in svc-consulta (doc 04).
CACHE_TTL_SECONDS = 86_400


def consolidado_cache_key(merchant_id: uuid.UUID | str, data: date | str) -> str:
    merchant = str(merchant_id)
    day = data.isoformat() if isinstance(data, date) else str(data)
    return f"consolidado:{merchant}:{day}"


@lru_cache
def _redis_client() -> redis.Redis:
    return redis.Redis.from_url(get_settings().redis_url, decode_responses=True)


def invalidate_consolidado_cache(merchant_id: uuid.UUID | str, data: date | str) -> int:
    """Delete cached consolidado entry after projection update."""
    key = consolidado_cache_key(merchant_id, data)
    try:
        deleted = int(_redis_client().delete(key))
    except redis.RedisError:
        logger.exception(
            "redis cache invalidation failed",
            extra={
                "cache_key": key,
                "merchant_id": str(merchant_id),
                "data": data.isoformat() if isinstance(data, date) else str(data),
            },
        )
        return 0

    logger.info(
        "redis cache invalidated",
        extra={
            "cache_key": key,
            "merchant_id": str(merchant_id),
            "data": data.isoformat() if isinstance(data, date) else str(data),
            "deleted": deleted,
        },
    )
    return deleted


def reset_redis_client_cache() -> None:
    """Clear cached Redis client (tests)."""
    _redis_client.cache_clear()
