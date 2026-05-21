from pathlib import Path

from app.schemas.health import HealthResponse


def test_health_response_model() -> None:
    response = HealthResponse(status="ok", service="consolidado")
    assert response.model_dump() == {"status": "ok", "service": "consolidado"}


def test_alembic_layout() -> None:
    service_root = Path(__file__).resolve().parents[2]
    assert (service_root / "alembic.ini").is_file()
    assert (service_root / "migrations" / "env.py").is_file()
    assert (service_root / "migrations" / "script.py.mako").is_file()
    assert (service_root / "migrations" / "versions").is_dir()


def test_dockerfile_exists() -> None:
    service_root = Path(__file__).resolve().parents[2]
    assert (service_root / "Dockerfile").is_file()
