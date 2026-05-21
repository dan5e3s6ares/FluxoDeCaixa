from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

from app.models import ConsolidadoDiario, ProcessedEvent


def _load_migration_module():
    migration_path = (
        Path(__file__).resolve().parents[2]
        / "migrations"
        / "versions"
        / "20260520_001_consolidado_read_model.py"
    )
    spec = spec_from_file_location("migration_20260520_001", migration_path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_initial_migration_revision_metadata() -> None:
    module = _load_migration_module()
    assert module.revision == "20260520_001"
    assert module.down_revision is None


def test_initial_migration_defines_upgrade_and_downgrade() -> None:
    module = _load_migration_module()
    assert callable(module.upgrade)
    assert callable(module.downgrade)


def test_initial_migration_creates_read_model_tables() -> None:
    source = (
        Path(__file__).resolve().parents[2]
        / "migrations"
        / "versions"
        / "20260520_001_consolidado_read_model.py"
    ).read_text(encoding="utf-8")
    assert "processed_events" in source
    assert "consolidado_diario" in source
    assert "CREATE SCHEMA IF NOT EXISTS" in source
    assert "event_id UUID PRIMARY KEY" in source
    assert "PRIMARY KEY (merchant_id, data)" in source
    assert "apply_rls_stubs()" in source
    assert "def downgrade()" in source
    assert "DROP TABLE IF EXISTS {_DAILY}" in source
    assert "DROP TABLE IF EXISTS {_PROCESSED}" in source


def test_orm_models_match_read_model_schema() -> None:
    processed_pk = ProcessedEvent.__table__.primary_key.columns  # type: ignore[attr-defined]
    assert list(processed_pk.keys()) == ["event_id"]

    daily_pk = ConsolidadoDiario.__table__.primary_key.columns  # type: ignore[attr-defined]
    assert list(daily_pk.keys()) == ["merchant_id", "data"]
    assert ConsolidadoDiario.__table__.schema == "consolidado"  # type: ignore[attr-defined]
    assert ProcessedEvent.__table__.schema == "consolidado"  # type: ignore[attr-defined]
