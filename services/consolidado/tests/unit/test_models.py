from decimal import Decimal

from app.models import ConsolidadoDiario, ProcessedEvent


def test_consolidado_diario_columns() -> None:
    table = ConsolidadoDiario.__table__  # type: ignore[attr-defined]
    column_names = {column.name for column in table.columns}
    assert column_names == {
        "merchant_id",
        "data",
        "total_creditos",
        "total_debitos",
        "saldo_final",
        "versao",
        "ultima_atualizacao",
    }
    assert table.c.total_creditos.type.precision == 18  # type: ignore[union-attr]
    assert table.c.saldo_final.type.scale == 2  # type: ignore[union-attr]
    assert Decimal(table.c.total_creditos.server_default.arg) == Decimal("0")  # type: ignore[union-attr]


def test_processed_event_idempotency_key() -> None:
    table = ProcessedEvent.__table__  # type: ignore[attr-defined]
    assert list(table.primary_key.columns.keys()) == ["event_id"]
    assert table.c.processed_at.nullable is False  # type: ignore[union-attr]
