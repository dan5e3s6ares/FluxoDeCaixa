from __future__ import annotations

import uuid
from datetime import date, datetime

from sqlalchemy import select, text, tuple_
from sqlalchemy.orm import Session

from app.domain import LancamentoListItem, LancamentoListPage
from app.models.lancamento import Lancamento
from app.pagination.cursor import decode_cursor, encode_cursor

DEFAULT_LIST_LIMIT = 50
MAX_LIST_LIMIT = 200


class LancamentosReadRepository:
    """Read-only list of lancamentos.lancamentos (doc 04 direct schema read)."""

    @staticmethod
    def bind_merchant_rls(session: Session, merchant_id: uuid.UUID) -> None:
        session.execute(
            text("SELECT public.set_app_merchant_id(:merchant_id)"),
            {"merchant_id": merchant_id},
        )

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
