from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

TIPO_LITERAL = Literal["CREDITO", "DEBITO"]


class LancamentoListItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    valor: Decimal
    tipo: TIPO_LITERAL
    data_competencia: date
    descricao: str
    categoria_id: uuid.UUID | None
    status: str
    created_at: datetime

    @field_validator("valor", mode="before")
    @classmethod
    def parse_valor(cls, value: object) -> object:
        if isinstance(value, str):
            return Decimal(value)
        return value


class LancamentoListResponse(BaseModel):
    items: list[LancamentoListItemResponse]
    next_cursor: str | None = None
