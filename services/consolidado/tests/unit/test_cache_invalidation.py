"""Redis cache invalidation for consolidado projection updates."""

from __future__ import annotations

import uuid
from datetime import date
from unittest.mock import MagicMock, patch

import pytest
import redis

from app.cache import (
    CACHE_TTL_SECONDS,
    consolidado_cache_key,
    invalidate_consolidado_cache,
    reset_redis_client_cache,
)


@pytest.fixture(autouse=True)
def clear_redis_client_cache() -> None:
    reset_redis_client_cache()
    yield
    reset_redis_client_cache()


def test_consolidado_cache_key_format() -> None:
    merchant_id = uuid.UUID("44444444-4444-4444-8444-444444444444")
    key = consolidado_cache_key(merchant_id, date(2026, 5, 20))

    assert key == "consolidado:44444444-4444-4444-8444-444444444444:2026-05-20"


def test_cache_ttl_is_24h() -> None:
    assert CACHE_TTL_SECONDS == 86_400


@patch("app.cache._redis_client")
def test_invalidate_consolidado_cache_deletes_key(mock_client_factory: MagicMock) -> None:
    client = MagicMock()
    client.delete.return_value = 1
    mock_client_factory.return_value = client
    merchant_id = uuid.UUID("44444444-4444-4444-8444-444444444444")

    deleted = invalidate_consolidado_cache(merchant_id, date(2026, 5, 20))

    assert deleted == 1
    client.delete.assert_called_once_with(
        "consolidado:44444444-4444-4444-8444-444444444444:2026-05-20"
    )


@patch("app.cache._redis_client")
def test_invalidate_consolidado_cache_returns_zero_when_key_missing(
    mock_client_factory: MagicMock,
) -> None:
    client = MagicMock()
    client.delete.return_value = 0
    mock_client_factory.return_value = client

    deleted = invalidate_consolidado_cache(
        uuid.UUID("44444444-4444-4444-8444-444444444444"),
        date(2026, 5, 20),
    )

    assert deleted == 0
    client.delete.assert_called_once()


@patch("app.cache._redis_client")
def test_invalidate_consolidado_cache_logs_and_returns_zero_on_redis_error(
    mock_client_factory: MagicMock,
) -> None:
    client = MagicMock()
    client.delete.side_effect = redis.RedisError("connection refused")
    mock_client_factory.return_value = client

    deleted = invalidate_consolidado_cache("44444444-4444-4444-8444-444444444444", "2026-05-20")

    assert deleted == 0


def test_consolidado_cache_key_with_string_inputs() -> None:
    key = consolidado_cache_key(
        "44444444-4444-4444-8444-444444444444",
        "2026-05-20",
    )
    assert key == "consolidado:44444444-4444-4444-8444-444444444444:2026-05-20"


@patch("app.cache._redis_client")
def test_invalidate_consolidado_cache_returns_int_deleted_count(
    mock_client_factory: MagicMock,
) -> None:
    """delete() returns an int count; verify it's forwarded correctly."""
    client = MagicMock()
    client.delete.return_value = 2
    mock_client_factory.return_value = client
    merchant_id = uuid.UUID("44444444-4444-4444-8444-444444444444")

    deleted = invalidate_consolidado_cache(merchant_id, date(2026, 5, 20))

    assert deleted == 2
