import os

import pytest
from pydantic import ValidationError

from fcx_shared.settings import ServiceSettings, get_settings


@pytest.fixture(autouse=True)
def clear_settings_cache() -> None:
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_settings_loads_required_env(required_env: None) -> None:
    settings = ServiceSettings()

    assert settings.database_url.startswith("postgresql://")
    assert settings.redis_url.startswith("redis://")
    assert settings.nats_url.startswith("nats://")
    assert settings.keycloak_realm == "fluxo-caixa"
    assert settings.otel_service_name == "svc-test"
    assert settings.log_level == "INFO"
    assert settings.environment == "dev"


def test_settings_normalizes_log_level(required_env: None, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LOG_LEVEL", "debug")
    settings = ServiceSettings()
    assert settings.log_level == "DEBUG"


def test_settings_fails_when_required_env_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for key in list(os.environ):
        if key.startswith(
            (
                "DATABASE_",
                "REDIS_",
                "NATS_",
                "KEYCLOAK_",
                "OTEL_",
            )
        ):
            monkeypatch.delenv(key, raising=False)

    with pytest.raises(ValidationError):
        ServiceSettings()
