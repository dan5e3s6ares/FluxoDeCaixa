from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


def _load(name: str):
    path = Path(__file__).resolve().parents[2] / "migrations" / "versions" / name
    spec = spec_from_file_location(name, path)
    assert spec and spec.loader
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_retry_migration_metadata() -> None:
    module = _load("20260520_002_outbox_retry_dlq.py")
    assert module.revision == "20260520_002"
    assert module.down_revision == "20260520_001"


def test_retry_migration_adds_columns() -> None:
    source = (
        Path(__file__).resolve().parents[2]
        / "migrations"
        / "versions"
        / "20260520_002_outbox_retry_dlq.py"
    ).read_text(encoding="utf-8")
    assert "failure_count" in source
    assert "next_retry_at" in source
    assert "dlq_at" in source
    assert "dlq_at IS NULL" in source
