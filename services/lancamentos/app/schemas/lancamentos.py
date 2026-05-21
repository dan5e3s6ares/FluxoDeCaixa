from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

MAX_VALOR = Decimal("9999999.99")
TIPO_LITERAL = Literal["CREDITO", "DEBITO"]


class LancamentoCreateRequest(BaseModel):
    valor: Decimal = Field(..., gt=0, le=MAX_VALOR, decimal_places=2)
    tipo: TIPO_LITERAL
    data_competencia: date | None = None
    descricao: str | None = Field(default=None, max_length=500)
    categoria_id: uuid.UUID | None = None

    @field_validator("valor", mode="before")
    @classmethod
    def parse_valor(cls, value: object) -> object:
        if isinstance(value, str):
            return Decimal(value)
        return value


class LancamentoCreateResponse(BaseModel):
    id: uuid.UUID
    status: Literal["ACCEPTED"] = "ACCEPTED"


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
