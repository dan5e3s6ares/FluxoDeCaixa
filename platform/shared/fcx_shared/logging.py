import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

from fcx_shared.settings import ServiceSettings

CORRELATION_FIELDS = ("trace_id", "correlation_id", "merchant_id", "lancamento_id")


class JsonLogFormatter(logging.Formatter):
    def __init__(self, service_name: str, environment: str) -> None:
        super().__init__()
        self.service_name = service_name
        self.environment = environment

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self.service_name,
            "environment": self.environment,
        }

        for field in CORRELATION_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, ensure_ascii=False)


def configure_logging(settings: ServiceSettings) -> None:
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(settings.log_level)

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        JsonLogFormatter(
            service_name=settings.otel_service_name,
            environment=settings.environment,
        )
    )
    root.addHandler(handler)
