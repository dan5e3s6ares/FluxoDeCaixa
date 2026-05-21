from __future__ import annotations

import uuid
from datetime import date

from sqlalchemy.orm import Session

from app.domain import LancamentoListPage
from app.errors import ProblemDetail
from app.repository.lancamentos_read import (
    DEFAULT_LIST_LIMIT,
    LancamentosReadRepository,
    MAX_LIST_LIMIT,
)


class LancamentosReadService:
    def __init__(self, repo: LancamentosReadRepository | None = None) -> None:
        self._repo = repo or LancamentosReadRepository()

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
