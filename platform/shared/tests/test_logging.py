import json
import logging

from fcx_shared.logging import configure_logging
from fcx_shared.settings import ServiceSettings


def test_configure_logging_emits_json(required_env: None, capsys) -> None:  # noqa: ANN001
    settings = ServiceSettings()
    configure_logging(settings)

    logger = logging.getLogger("fcx.test")
    logger.info(
        "startup complete",
        extra={
            "trace_id": "abc123",
            "correlation_id": "corr-1",
            "merchant_id": "m-42",
        },
    )

    output = capsys.readouterr().out.strip()
    payload = json.loads(output)

    assert payload["level"] == "INFO"
    assert payload["message"] == "startup complete"
    assert payload["service"] == settings.otel_service_name
    assert payload["trace_id"] == "abc123"
    assert payload["correlation_id"] == "corr-1"
    assert payload["merchant_id"] == "m-42"
