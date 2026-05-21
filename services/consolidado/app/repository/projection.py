from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal
from typing import Any

from sqlalchemy import text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.models import ProcessedEvent

_SCHEMA = "consolidado"
_DAILY = f"{_SCHEMA}.consolidado_diario"


class ProjectionRepository:
    """Upserts consolidado_diario and records processed_events for idempotency."""

    @staticmethod
    def bind_merchant_rls(session: Session, merchant_id: uuid.UUID) -> None:
        session.execute(
            text("SELECT public.set_app_merchant_id(:merchant_id)"),
            {"merchant_id": merchant_id},
        )

    def apply_lancamento_registrado(
        self,
        session: Session,
        envelope: dict[str, Any],
    ) -> bool:
        """Apply projection for one event. Returns False if event_id was already processed."""
        event_id = uuid.UUID(str(envelope["event_id"]))
        payload = envelope["payload"]
        merchant_id = uuid.UUID(str(payload["merchant_id"]))
        data_competencia = date.fromisoformat(str(payload["data_competencia"]))
        valor = Decimal(str(payload["valor"]))
        tipo = str(payload["tipo"]).upper()

        creditos = valor if tipo == "CREDITO" else Decimal("0")
        debitos = valor if tipo == "DEBITO" else Decimal("0")
        saldo_delta = valor if tipo == "CREDITO" else -valor

        self.bind_merchant_rls(session, merchant_id)

        inserted = session.execute(
            insert(ProcessedEvent)
            .values(event_id=event_id)
            .on_conflict_do_nothing(index_elements=["event_id"])
            .returning(ProcessedEvent.event_id)
        ).scalar_one_or_none()
        if inserted is None:
            return False

        session.execute(
            text(
                f"""
                INSERT INTO {_DAILY} (
                    merchant_id,
                    data,
                    total_creditos,
                    total_debitos,
                    saldo_final,
                    versao,
                    ultima_atualizacao
                )
                VALUES (
                    :merchant_id,
                    :data,
                    :creditos,
                    :debitos,
                    :saldo_delta,
                    1,
                    now()
                )
                ON CONFLICT (merchant_id, data) DO UPDATE SET
                    total_creditos = {_DAILY}.total_creditos + EXCLUDED.total_creditos,
                    total_debitos = {_DAILY}.total_debitos + EXCLUDED.total_debitos,
                    saldo_final = {_DAILY}.saldo_final + EXCLUDED.saldo_final,
                    versao = {_DAILY}.versao + 1,
                    ultima_atualizacao = now()
                """
            ),
            {
                "merchant_id": merchant_id,
                "data": data_competencia,
                "creditos": creditos,
                "debitos": debitos,
                "saldo_delta": saldo_delta,
            },
        )
        return True
