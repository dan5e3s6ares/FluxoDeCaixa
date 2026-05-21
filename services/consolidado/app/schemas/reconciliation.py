from __future__ import annotations

import uuid
from datetime import date
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.consolidado import Money


class DayTotalsResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    total_creditos: Money
    total_debitos: Money
    saldo_final: Money
    lancamento_count: int = 0


class RecomputeRequest(BaseModel):
    merchant_id: uuid.UUID
    data: date


class RecomputeResponse(BaseModel):
    merchant_id: uuid.UUID
    data: date
    totals: DayTotalsResponse
    corrected: bool


class ReconcileResponse(BaseModel):
    merchant_id: uuid.UUID
    data: date
    source: DayTotalsResponse
    projection: DayTotalsResponse | None
    matched: bool


class OutboxReplayRequest(BaseModel):
    merchant_id: uuid.UUID | None = None
    outbox_ids: list[int] = Field(default_factory=list)


class OutboxReplayResponse(BaseModel):
    replayed_ids: list[int]
