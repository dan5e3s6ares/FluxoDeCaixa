from __future__ import annotations

import uuid
from datetime import date, timedelta
from decimal import Decimal

from sqlalchemy.orm import Session

from app.errors import ProblemDetail
from app.domain import LancamentoAccepted, LancamentoConflict, LancamentoListPage
from app.repository.lancamentos import (
    DEFAULT_LIST_LIMIT,
    LancamentosRepository,
    MAX_LIST_LIMIT,
    RETROACTIVE_DAYS,
)


class LancamentosService:
    def __init__(self, repo: LancamentosRepository | None = None) -> None:
        self._repo = repo or LancamentosRepository()

    def create(
        self,
        *,
        session: Session,
        merchant_id: uuid.UUID,
        valor: Decimal,
        tipo: str,
        data_competencia: date | None,
        descricao: str | None,
        categoria_id: uuid.UUID | None,
        idempotency_key: str | None,
        today: date,
    ) -> LancamentoAccepted:
        effective_date = data_competencia or today
        self._validate_data_competencia(effective_date, today=today)

        try:
            return self._repo.create_with_outbox(
                session,
                merchant_id=merchant_id,
                valor=valor,
                tipo=tipo,
                data_competencia=effective_date,
                descricao=descricao,
                categoria_id=categoria_id,
                idempotency_key=idempotency_key,
            )
        except LancamentoConflict:
            raise

    def list(
        self,
        *,
        session: Session,
        merchant_id: uuid.UUID,
        data_inicio: date | None = None,
        data_fim: date | None = None,
        tipo: str | None = None,
        cursor: str | None = None,
        limit: int | None = None,
    ) -> LancamentoListPage:
        if data_inicio is not None and data_fim is not None and data_inicio > data_fim:
            raise ProblemDetail(
                status=422,
                title="Unprocessable Entity",
                detail="data_inicio must be on or before data_fim",
                type_="https://fluxo-caixa/errors/validation",
            )

        if tipo is not None and tipo not in {"CREDITO", "DEBITO"}:
            raise ProblemDetail(
                status=422,
                title="Unprocessable Entity",
                detail="tipo must be CREDITO or DEBITO",
                type_="https://fluxo-caixa/errors/validation",
            )

        effective_limit = DEFAULT_LIST_LIMIT if limit is None else limit
        if effective_limit < 1 or effective_limit > MAX_LIST_LIMIT:
            raise ProblemDetail(
                status=422,
                title="Unprocessable Entity",
                detail=f"limit must be between 1 and {MAX_LIST_LIMIT}",
                type_="https://fluxo-caixa/errors/validation",
            )

        self._repo.bind_merchant_rls(session, merchant_id)
        return self._repo.list_by_merchant(
            session,
            merchant_id=merchant_id,
            data_inicio=data_inicio,
            data_fim=data_fim,
            tipo=tipo,
            cursor=cursor,
            limit=effective_limit,
        )

    @staticmethod
    def _validate_data_competencia(data_competencia: date, *, today: date) -> None:
        oldest = today - timedelta(days=RETROACTIVE_DAYS)
        if data_competencia < oldest:
            raise ProblemDetail(
                status=422,
                title="Unprocessable Entity",
                detail=(
                    f"data_competencia must be within the last {RETROACTIVE_DAYS} days "
                    f"(>= {oldest.isoformat()})"
                ),
                type_="https://fluxo-caixa/errors/validation",
            )
        if data_competencia > today:
            raise ProblemDetail(
                status=422,
                title="Unprocessable Entity",
                detail="data_competencia cannot be in the future",
                type_="https://fluxo-caixa/errors/validation",
            )
