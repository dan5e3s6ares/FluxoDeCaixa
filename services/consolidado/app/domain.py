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
class DayTotals:
    total_creditos: Decimal
    total_debitos: Decimal
    saldo_final: Decimal
    lancamento_count: int


@dataclass(frozen=True, slots=True)
class ReconciliationCheck:
    merchant_id: uuid.UUID
    data: date
    source: DayTotals
    projection: DayTotals | None
    matched: bool


@dataclass(frozen=True, slots=True)
class RecomputeResult:
    merchant_id: uuid.UUID
    data: date
    totals: DayTotals
    corrected: bool
