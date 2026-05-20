import pytest


@pytest.fixture
def required_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@localhost:5432/fluxo")
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")
    monkeypatch.setenv("NATS_URL", "nats://localhost:4222")
    monkeypatch.setenv("KEYCLOAK_URL", "http://keycloak.local:8080")
    monkeypatch.setenv("KEYCLOAK_REALM", "fluxo-caixa")
    monkeypatch.setenv("KEYCLOAK_CLIENT_ID", "svc-test")
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
    monkeypatch.setenv("OTEL_SERVICE_NAME", "svc-test")
