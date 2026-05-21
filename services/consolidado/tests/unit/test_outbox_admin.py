"""Outbox admin repository unit tests (DLQ replay)."""

from __future__ import annotations

import uuid
from unittest.mock import MagicMock

from app.repository.outbox_admin import OutboxAdminRepository

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")


def test_replay_by_ids_returns_empty_for_empty_list() -> None:
    repo = OutboxAdminRepository()
    session = MagicMock()

    result = repo.replay_by_ids(session, outbox_ids=[])

    assert result == []
    session.execute.assert_not_called()


def test_replay_by_ids_executes_replay_sql() -> None:
    repo = OutboxAdminRepository()
    session = MagicMock()
    row1 = MagicMock()
    row1.id = 10
    row2 = MagicMock()
    row2.id = 20
    session.execute.return_value = MagicMock(all=MagicMock(return_value=[row1, row2]))

    result = repo.replay_by_ids(session, outbox_ids=[10, 20])

    assert result == [10, 20]
    session.execute.assert_called_once()
    sql = str(session.execute.call_args.args[0])
    assert "dlq_at IS NOT NULL" in sql
    assert "next_retry_at" in sql


def test_replay_for_merchant_executes_sql() -> None:
    repo = OutboxAdminRepository()
    session = MagicMock()
    row = MagicMock()
    row.id = 5
    session.execute.return_value = MagicMock(all=MagicMock(return_value=[row]))

    result = repo.replay_for_merchant(session, merchant_id=MERCHANT_ID)

    assert result == [5]
    session.execute.assert_called_once()
    call_args = session.execute.call_args
    assert call_args.args[1]["merchant_id"] == str(MERCHANT_ID)


def test_replay_all_dlq_executes_sql() -> None:
    repo = OutboxAdminRepository()
    session = MagicMock()
    row = MagicMock()
    row.id = 1
    session.execute.return_value = MagicMock(all=MagicMock(return_value=[row]))

    result = repo.replay_all_dlq(session)

    assert result == [1]
    session.execute.assert_called_once()
    sql = str(session.execute.call_args.args[0])
    assert "dlq_at IS NOT NULL" in sql