from __future__ import annotations

from datetime import datetime, timedelta, timezone

_MAX_BACKOFF_SECONDS = 300


def backoff_seconds(failure_count: int) -> int:
    """Exponential backoff: 1s, 2s, 4s, … capped at 300s."""
    if failure_count <= 0:
        return 0
    return min(2 ** (failure_count - 1), _MAX_BACKOFF_SECONDS)


def next_retry_at(*, failure_count: int, now: datetime | None = None) -> datetime:
    base = now or datetime.now(timezone.utc)
    delay = backoff_seconds(failure_count)
    if delay <= 0:
        return base
    return base + timedelta(seconds=delay)
