from datetime import datetime, timezone
from unittest.mock import MagicMock

import pytest

from app.outbox.config import DLQ_MAX_FAILURES
from app.repository.outbox import OutboxRepository, _CLAIM_SQL


def test_claim_batch_uses_skip_locked_sql() -> None:
    session = MagicMock()
    session.execute.return_value.mappings.return_value.all.return_value = []

    repo = OutboxRepository()
    repo.claim_batch(session, batch_size=10)

    session.execute.assert_called_once()
    args, _kwargs = session.execute.call_args
    assert args[0] is _CLAIM_SQL
    assert args[1] == {"batch_size": 10}


def test_record_failure_returns_incremented_count() -> None:
    session = MagicMock()
    repo = OutboxRepository()

    count = repo.record_failure(session, outbox_id=42, current_failure_count=2)

    assert count == 3
    session.execute.assert_called_once()


def test_record_failure_at_dlq_threshold_returns_max() -> None:
    session = MagicMock()
    repo = OutboxRepository()

    count = repo.record_failure(
        session,
        outbox_id=7,
        current_failure_count=DLQ_MAX_FAILURES - 1,
    )

    assert count == DLQ_MAX_FAILURES
    session.execute.assert_called_once()


def test_mark_published_sets_timestamp() -> None:
    session = MagicMock()
    repo = OutboxRepository()
    repo.mark_published(session, outbox_id=1)
    session.execute.assert_called_once()
