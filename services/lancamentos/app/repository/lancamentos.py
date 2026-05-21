from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

from sqlalchemy import select, text, tuple_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import Lancamento, OutboxEvent
from app.domain import (
    LancamentoAccepted,
    LancamentoConflict,
    LancamentoListItem,
    LancamentoListPage,
)
from app.pagination.cursor import decode_cursor, encode_cursor

EVENT_TYPE = "LancamentoRegistrado"
EVENT_VERSION = 1
RETROACTIVE_DAYS = 7
IDEMPOTENCY_TTL = timedelta(hours=24)
DEFAULT_LIST_LIMIT = 50
MAX_LIST_LIMIT = 200
_IDEMPOTENCY_CONSTRAINT = "uq_lancamentos_merchant_idempotency"


def _payload_matches(existing: Lancamento, **fields: Any) -> bool:
    return (
        existing.valor == fields["valor"]
        and existing.tipo == fields["tipo"]
        and existing.data_competencia == fields["data_competencia"]
        and (existing.descricao or "") == (fields.get("descricao") or "")
        and existing.categoria_id == fields.get("categoria_id")
    )


def _within_idempotency_ttl(created_at: datetime) -> bool:
    now = datetime.now(timezone.utc)
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    return created_at >= now - IDEMPOTENCY_TTL


def _is_idempotency_violation(exc: IntegrityError) -> bool:
    orig = getattr(exc, "orig", None)
    if orig is None:
        return False
    diag = getattr(orig, "diag", None)
    constraint = getattr(diag, "constraint_name", None) if diag else None
    if constraint == _IDEMPOTENCY_CONSTRAINT:
        return True
    message = str(orig)
    return _IDEMPOTENCY_CONSTRAINT in message


def _build_outbox_payload(
    *,
    lancamento_id: uuid.UUID,
    merchant_id: uuid.UUID,
    valor: Decimal,
    tipo: str,
    data_competencia: date,
    descricao: str | None,
    correlation_id: uuid.UUID,
) -> dict[str, Any]:
    event_id = uuid.uuid4()
    return {
        "event_id": str(event_id),
        "event_type": EVENT_TYPE,
        "event_version": EVENT_VERSION,
        "occurred_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "correlation_id": str(correlation_id),
        "payload": {
            "lancamento_id": str(lancamento_id),
            "merchant_id": str(merchant_id),
            "valor": format(valor, "f"),
            "tipo": tipo,
            "data_competencia": data_competencia.isoformat(),
            "descricao": descricao,
        },
    }


class LancamentosRepository:
    def list_by_merchant(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        data_inicio: date | None = None,
        data_fim: date | None = None,
        tipo: str | None = None,
        cursor: str | None = None,
        limit: int = DEFAULT_LIST_LIMIT,
    ) -> LancamentoListPage:
        stmt = (
            select(Lancamento)
            .where(Lancamento.merchant_id == merchant_id)
            .order_by(Lancamento.created_at.desc(), Lancamento.id.desc())
            .limit(limit + 1)
        )

        if data_inicio is not None:
            stmt = stmt.where(Lancamento.data_competencia >= data_inicio)
        if data_fim is not None:
            stmt = stmt.where(Lancamento.data_competencia <= data_fim)
        if tipo is not None:
            stmt = stmt.where(Lancamento.tipo == tipo)
        if cursor is not None:
            cursor_created_at, cursor_id = decode_cursor(cursor)
            stmt = stmt.where(
                tuple_(Lancamento.created_at, Lancamento.id)
                < tuple_(cursor_created_at, cursor_id)
            )

        rows = list(session.scalars(stmt).all())
        has_more = len(rows) > limit
        page_rows = rows[:limit]

        items = [
            LancamentoListItem(
                id=row.id,
                valor=row.valor,
                tipo=row.tipo,
                data_competencia=row.data_competencia,
                descricao=row.descricao,
                categoria_id=row.categoria_id,
                status=row.status,
                created_at=row.created_at,
            )
            for row in page_rows
        ]

        next_cursor = None
        if has_more and page_rows:
            last = page_rows[-1]
            next_cursor = encode_cursor(created_at=last.created_at, lancamento_id=last.id)

        return LancamentoListPage(items=items, next_cursor=next_cursor)

    @staticmethod
    def bind_merchant_rls(session: Session, merchant_id: uuid.UUID) -> None:
        session.execute(
            text("SELECT public.set_app_merchant_id(:merchant_id)"),
            {"merchant_id": merchant_id},
        )

    def create_with_outbox(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        valor: Decimal,
        tipo: str,
        data_competencia: date,
        descricao: str | None,
        categoria_id: uuid.UUID | None,
        idempotency_key: str | None,
    ) -> LancamentoAccepted:
        fields = {
            "valor": valor,
            "tipo": tipo,
            "data_competencia": data_competencia,
            "descricao": descricao,
            "categoria_id": categoria_id,
        }

        if not idempotency_key:
            return self._insert_new(
                session,
                merchant_id=merchant_id,
                idempotency_key=None,
                **fields,
            )

        try:
            return self._insert_new(
                session,
                merchant_id=merchant_id,
                idempotency_key=idempotency_key,
                **fields,
            )
        except IntegrityError as exc:
            if not _is_idempotency_violation(exc):
                raise
            session.rollback()
            return self._resolve_idempotency_conflict(
                session,
                merchant_id=merchant_id,
                idempotency_key=idempotency_key,
                **fields,
            )

    def _resolve_idempotency_conflict(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        idempotency_key: str,
        valor: Decimal,
        tipo: str,
        data_competencia: date,
        descricao: str | None,
        categoria_id: uuid.UUID | None,
    ) -> LancamentoAccepted:
        existing = self._fetch_by_idempotency_key(
            session, merchant_id=merchant_id, idempotency_key=idempotency_key
        )
        if existing is None:
            raise LancamentoConflict(
                "Idempotency-Key conflict but no existing row found"
            )

        fields = {
            "valor": valor,
            "tipo": tipo,
            "data_competencia": data_competencia,
            "descricao": descricao,
            "categoria_id": categoria_id,
        }

        if not _within_idempotency_ttl(existing.created_at):
            existing.idempotency_key = None
            session.flush()
            return self._insert_new(
                session,
                merchant_id=merchant_id,
                idempotency_key=idempotency_key,
                **fields,
            )

        if _payload_matches(existing, **fields):
            return LancamentoAccepted(
                id=existing.id, status="ACCEPTED", replay=True
            )
        raise LancamentoConflict(
            "Idempotency-Key reused with different payload"
        )

    @staticmethod
    def _fetch_by_idempotency_key(
        session: Session,
        *,
        merchant_id: uuid.UUID,
        idempotency_key: str,
    ) -> Lancamento | None:
        return session.execute(
            select(Lancamento).where(
                Lancamento.merchant_id == merchant_id,
                Lancamento.idempotency_key == idempotency_key,
            )
        ).scalar_one_or_none()

    def _insert_new(
        self,
        session: Session,
        *,
        merchant_id: uuid.UUID,
        valor: Decimal,
        tipo: str,
        data_competencia: date,
        descricao: str | None,
        categoria_id: uuid.UUID | None,
        idempotency_key: str | None,
    ) -> LancamentoAccepted:
        lancamento_id = uuid.uuid4()
        correlation_id = lancamento_id
        descricao_value = descricao or ""

        lancamento = Lancamento(
            id=lancamento_id,
            merchant_id=merchant_id,
            data_competencia=data_competencia,
            tipo=tipo,
            valor=valor,
            descricao=descricao_value,
            categoria_id=categoria_id,
            status="ATIVO",
            idempotency_key=idempotency_key,
        )
        outbox = OutboxEvent(
            aggregate_id=lancamento_id,
            event_type=EVENT_TYPE,
            payload=_build_outbox_payload(
                lancamento_id=lancamento_id,
                merchant_id=merchant_id,
                valor=valor,
                tipo=tipo,
                data_competencia=data_competencia,
                descricao=descricao,
                correlation_id=correlation_id,
            ),
        )
        session.add(lancamento)
        session.add(outbox)
        session.flush()

        return LancamentoAccepted(id=lancamento_id, status="ACCEPTED", replay=False)
