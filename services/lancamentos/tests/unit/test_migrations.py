from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


def _load_migration_module():
    migration_path = (
        Path(__file__).resolve().parents[2]
        / "migrations"
        / "versions"
        / "20260520_001_lancamentos_outbox.py"
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


def test_initial_migration_creates_core_objects() -> None:
    source = (
        Path(__file__).resolve().parents[2]
        / "migrations"
        / "versions"
        / "20260520_001_lancamentos_outbox.py"
    ).read_text(encoding="utf-8")
    assert "PARTITION BY RANGE (data_competencia)" in source
    assert "outbox_events" in source
    assert "CREATE TABLE {_OUTBOX}" in source
    assert "uq_lancamentos_merchant_idempotency" in source
    assert "UNIQUE (merchant_id, idempotency_key)" in source
    assert "idempotency_key, data_competencia)" not in source
    assert "idx_outbox_pending" in source
    assert "def downgrade()" in source
    assert "DROP TABLE IF EXISTS {_OUTBOX}" in source
