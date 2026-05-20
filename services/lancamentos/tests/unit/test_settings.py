from fcx_shared import ServiceSettings, get_settings


def test_shared_settings_importable() -> None:
    settings = get_settings()
    assert isinstance(settings, ServiceSettings)
    assert settings.otel_service_name == "svc-lancamentos"
