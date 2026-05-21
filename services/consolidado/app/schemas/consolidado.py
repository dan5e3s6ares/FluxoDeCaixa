from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, PlainSerializer  # noqa: TC002
from typing import Annotated

def _money_json(value: Decimal) -> str:
    return format(value.quantize(Decimal("0.01")), "f")


Money = Annotated[Decimal, PlainSerializer(_money_json, return_type=str)]


class ConsolidadoDiarioResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    data: date
    total_creditos: Money
    total_debitos: Money
    saldo_final: Money
    ultima_atualizacao: datetime | None = None
