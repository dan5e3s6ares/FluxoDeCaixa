"""Idempotency semantics — INSERT+constraint, 24h TTL, 200/409 (doc 05)."""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from unittest.mock import MagicMock

import pytest
from sqlalchemy.exc import IntegrityError

from app.domain import LancamentoAccepted, LancamentoConflict
from app.repository.lancamentos import (
    IDEMPOTENCY_TTL,
    LancamentosRepository,
    _within_idempotency_ttl,
)

MERCHANT_ID = uuid.UUID("00000000-0000-4000-8000-000000000001")
DATA_COMP = date(2026, 5, 20)


def _integrity_error() -> IntegrityError:
    return IntegrityError("stmt", {}, Exception("uq_lancamentos_merchant_idempotency"))


def _existing_lancamento(**overrides) -> MagicMock:
    row = MagicMock()
    row.id = overrides.get("id", uuid.uuid4())
    row.merchant_id = MERCHANT_ID
    row.valor = Decimal("150.50")
    row.tipo = "CREDITO"
    row.data_competencia = DATA_COMP
    row.descricao = "Venda balcão"
    row.categoria_id = None
    row.idempotency_key = "same-key"
    row.created_at = overrides.get(
        "created_at", datetime.now(timezone.utc) - timedelta(hours=1)
    )
    for key, value in overrides.items():
        setattr(row, key, value)
    return row


@pytest.mark.parametrize(
    "created_at,expected",
    [
        (datetime.now(timezone.utc) - timedelta(hours=1), True),
        (datetime.now(timezone.utc) - timedelta(hours=25), False),
    ],
)
def test_within_idempotency_ttl(created_at: datetime, expected: bool) -> None:
    assert _within_idempotency_ttl(created_at) is expected


def test_idempotency_ttl_is_24_hours() -> None:
    assert IDEMPOTENCY_TTL == timedelta(hours=24)


def test_insert_without_idempotency_key_skips_conflict_path() -> None:
    session = MagicMock()
    repo = LancamentosRepository()

    result = repo.create_with_outbox(
        session,
        merchant_id=MERCHANT_ID,
        valor=Decimal("10.00"),
        tipo="DEBITO",
        data_competencia=DATA_COMP,
        descricao=None,
        categoria_id=None,
        idempotency_key=None,
    )

    assert result.replay is False
    assert session.add.call_count == 2
    session.flush.assert_called_once()


def test_integrity_error_replay_returns_200() -> None:
    session = MagicMock()
    existing = _existing_lancamento()
    session.execute.return_value.scalar_one_or_none.return_value = existing
    session.flush.side_effect = [_integrity_error(), None]

    repo = LancamentosRepository()
    result = repo.create_with_outbox(
        session,
        merchant_id=MERCHANT_ID,
        valor=Decimal("150.50"),
        tipo="CREDITO",
        data_competencia=DATA_COMP,
        descricao="Venda balcão",
        categoria_id=None,
        idempotency_key="same-key",
    )

    session.rollback.assert_called_once()
    assert result == LancamentoAccepted(
        id=existing.id, status="ACCEPTED", replay=True
    )


def test_integrity_error_different_payload_raises_409() -> None:
    session = MagicMock()
    existing = _existing_lancamento(valor=Decimal("99.00"))
    session.execute.return_value.scalar_one_or_none.return_value = existing
    session.flush.side_effect = _integrity_error()

    repo = LancamentosRepository()
    with pytest.raises(LancamentoConflict, match="different payload"):
        repo.create_with_outbox(
            session,
            merchant_id=MERCHANT_ID,
            valor=Decimal("150.50"),
            tipo="CREDITO",
            data_competencia=DATA_COMP,
            descricao="Venda balcão",
            categoria_id=None,
            idempotency_key="same-key",
        )


def test_integrity_error_expired_ttl_clears_key_and_retries_insert() -> None:
    session = MagicMock()
    existing = _existing_lancamento(
        created_at=datetime.now(timezone.utc) - timedelta(hours=25)
    )
    session.execute.return_value.scalar_one_or_none.return_value = existing
    session.flush.side_effect = [_integrity_error(), None, None]

    repo = LancamentosRepository()
    result = repo.create_with_outbox(
        session,
        merchant_id=MERCHANT_ID,
        valor=Decimal("150.50"),
        tipo="CREDITO",
        data_competencia=DATA_COMP,
        descricao="Venda balcão",
        categoria_id=None,
        idempotency_key="same-key",
    )

    assert existing.idempotency_key is None
    assert session.flush.call_count == 3
    assert result.replay is False
    assert session.add.call_count == 4
