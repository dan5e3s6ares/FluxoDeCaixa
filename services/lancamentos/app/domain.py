from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal


class LancamentoConflict(Exception):
    pass


@dataclass(frozen=True)
class LancamentoAccepted:
    id: uuid.UUID
    status: str
    replay: bool


@dataclass(frozen=True)
class LancamentoListItem:
    id: uuid.UUID
    valor: Decimal
    tipo: str
    data_competencia: date
    descricao: str
    categoria_id: uuid.UUID | None
    status: str
    created_at: datetime


@dataclass(frozen=True)
class LancamentoListPage:
    items: list[LancamentoListItem]
    next_cursor: str | None
