from pathlib import Path

from app.schemas.health import HealthResponse


def test_health_response_model() -> None:
    response = HealthResponse(status="ok", service="consulta")
    assert response.model_dump() == {"status": "ok", "service": "consulta"}


def test_dockerfile_exists() -> None:
    service_root = Path(__file__).resolve().parents[2]
    assert (service_root / "Dockerfile").is_file()


def test_no_alembic_migrations() -> None:
    """Consulta reads consolidado schema; migrations live in svc-consolidado."""
    service_root = Path(__file__).resolve().parents[2]
    assert not (service_root / "alembic.ini").exists()
    assert not (service_root / "migrations").exists()


def test_read_only_routes() -> None:
    from app.main import app

    write_methods = {"POST", "PUT", "PATCH", "DELETE"}
    for route in app.routes:
        methods = getattr(route, "methods", set()) or set()
        assert methods.isdisjoint(write_methods), f"Write route not allowed: {route.path} {methods}"
