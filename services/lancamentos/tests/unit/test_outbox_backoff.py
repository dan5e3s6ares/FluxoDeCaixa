from datetime import datetime, timezone

from app.outbox.backoff import backoff_seconds, next_retry_at


def test_backoff_exponential_capped() -> None:
    assert backoff_seconds(0) == 0
    assert backoff_seconds(1) == 1
    assert backoff_seconds(2) == 2
    assert backoff_seconds(3) == 4
    assert backoff_seconds(10) == 300


def test_next_retry_at_uses_backoff() -> None:
    now = datetime(2026, 5, 20, 12, 0, 0, tzinfo=timezone.utc)
    retry = next_retry_at(failure_count=3, now=now)
    assert retry == datetime(2026, 5, 20, 12, 0, 4, tzinfo=timezone.utc)
