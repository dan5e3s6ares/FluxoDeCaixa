from __future__ import annotations

from prometheus_client import Gauge, start_http_server

outbox_pending_gauge = Gauge(
    "outbox_pending_gauge",
    "Count of outbox rows awaiting NATS publish (unpublished, not in DLQ).",
)


def start_metrics_server(port: int) -> None:
    start_http_server(port)
