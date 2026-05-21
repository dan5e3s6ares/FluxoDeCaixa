"""Projection repository unit tests."""

from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from typing import Any
from unittest.mock import MagicMock

from app.repository.projection import ProjectionRepository


def sample_envelope() -> dict[str, Any]:
    return {
        "event_id": "11111111-1111-4111-8111-111111111111",
        "event_type": "LancamentoRegistrado",
        "event_version": 1,
        "occurred_at": "2026-05-20T10:00:00Z",
        "correlation_id": "33333333-3333-4333-8333-333333333333",
        "payload": {
            "lancamento_id": "33333333-3333-4333-8333-333333333333",
            "merchant_id": "44444444-4444-4444-8444-444444444444",
            "valor": "10.00",
            "tipo": "CREDITO",
            "data_competencia": "2026-05-20",
            "descricao": None,
        },
    }


def test_apply_lancamento_registrado_upserts_on_new_event() -> None:
    session = MagicMock()
    session.execute.side_effect = [
        MagicMock(),  # RLS bind
        MagicMock(
            scalar_one_or_none=MagicMock(
                return_value=uuid.UUID("11111111-1111-4111-8111-111111111111")
            )
        ),
        MagicMock(),  # upsert
    ]
    repo = ProjectionRepository()

    applied = repo.apply_lancamento_registrado(session, sample_envelope())

    assert applied is True
    assert session.execute.call_count == 3
    rls_call = session.execute.call_args_list[0]
    assert "set_app_merchant_id" in str(rls_call.args[0])
    assert rls_call.args[1] == {
        "merchant_id": uuid.UUID("44444444-4444-4444-8444-444444444444")
    }
    upsert_call = session.execute.call_args_list[2]
    assert "INSERT INTO consolidado.consolidado_diario" in str(upsert_call.args[0])
    assert upsert_call.args[1] == {
        "merchant_id": uuid.UUID("44444444-4444-4444-8444-444444444444"),
        "data": date(2026, 5, 20),
        "creditos": Decimal("10.00"),
        "debitos": Decimal("0"),
        "saldo_delta": Decimal("10.00"),
    }


def test_apply_lancamento_registrado_debito_uses_negative_saldo_delta() -> None:
    session = MagicMock()
    session.execute.side_effect = [
        MagicMock(),  # RLS bind
        MagicMock(
            scalar_one_or_none=MagicMock(
                return_value=uuid.UUID("11111111-1111-4111-8111-111111111111")
            )
        ),
        MagicMock(),  # upsert
    ]
    envelope = sample_envelope()
    envelope["payload"]["tipo"] = "DEBITO"
    envelope["payload"]["valor"] = "25.50"

    repo = ProjectionRepository()
    repo.apply_lancamento_registrado(session, envelope)

    upsert_call = session.execute.call_args_list[2]
    assert upsert_call.args[1]["creditos"] == Decimal("0")
    assert upsert_call.args[1]["debitos"] == Decimal("25.50")
    assert upsert_call.args[1]["saldo_delta"] == Decimal("-25.50")


def test_apply_lancamento_registrado_normalizes_tipo_case() -> None:
    session = MagicMock()
    session.execute.side_effect = [
        MagicMock(),  # RLS bind
        MagicMock(
            scalar_one_or_none=MagicMock(
                return_value=uuid.UUID("11111111-1111-4111-8111-111111111111")
            )
        ),
        MagicMock(),  # upsert
    ]
    envelope = sample_envelope()
    envelope["payload"]["tipo"] = "credito"
    envelope["payload"]["valor"] = "15.75"

    repo = ProjectionRepository()
    repo.apply_lancamento_registrado(session, envelope)

    upsert_call = session.execute.call_args_list[2]
    assert upsert_call.args[1]["creditos"] == Decimal("15.75")
    assert upsert_call.args[1]["debitos"] == Decimal("0")
    assert upsert_call.args[1]["saldo_delta"] == Decimal("15.75")


def test_apply_lancamento_registrado_skips_duplicate_event_id() -> None:
    session = MagicMock()
    session.execute.side_effect = [
        MagicMock(),  # RLS bind
        MagicMock(scalar_one_or_none=MagicMock(return_value=None)),
    ]
    repo = ProjectionRepository()

    applied = repo.apply_lancamento_registrado(session, sample_envelope())

    assert applied is False
    assert session.execute.call_count == 2
    assert "INSERT INTO consolidado.consolidado_diario" not in str(
        session.execute.call_args_list[1]
    )
