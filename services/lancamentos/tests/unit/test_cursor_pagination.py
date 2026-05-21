"""Opaque cursor encode/decode for RF02 pagination."""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest

from app.errors import ProblemDetail
from app.pagination.cursor import decode_cursor, encode_cursor


def test_encode_decode_cursor_roundtrip() -> None:
    created_at = datetime(2026, 5, 20, 15, 30, 0, tzinfo=timezone.utc)
    lancamento_id = uuid.UUID("11111111-1111-4111-8111-111111111111")

    cursor = encode_cursor(created_at=created_at, lancamento_id=lancamento_id)
    decoded_created_at, decoded_id = decode_cursor(cursor)

    assert decoded_id == lancamento_id
    assert decoded_created_at == created_at


def test_decode_cursor_rejects_invalid_payload() -> None:
    with pytest.raises(ProblemDetail) as exc_info:
        decode_cursor("not-a-valid-cursor")
    assert exc_info.value.status == 422
