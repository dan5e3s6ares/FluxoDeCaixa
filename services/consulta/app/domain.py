from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal


@dataclass(frozen=True, slots=True)
class ConsolidadoDiarioView:
    merchant_id: uuid.UUID
    data: date
    total_creditos: Decimal
    total_debitos: Decimal
    saldo_final: Decimal
    versao: int
    ultima_atualizacao: datetime | None


@dataclass(frozen=True, slots=True)
class ConsolidadoReadResult:
    consolidado: ConsolidadoDiarioView
    stale: bool


@dataclass(frozen=True, slots=True)
class LancamentoListItem:
    id: uuid.UUID
    valor: Decimal
    tipo: str
    data_competencia: date
    descricao: str
    categoria_id: uuid.UUID | None
    status: str
    created_at: datetime


@dataclass(frozen=True, slots=True)
class LancamentoListPage:
    items: list[LancamentoListItem]
    next_cursor: str | None
