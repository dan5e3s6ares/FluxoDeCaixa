from __future__ import annotations

import os

from fcx_shared.settings import ServiceSettings


def configure_otel(settings: ServiceSettings) -> None:
    """Initialize OpenTelemetry tracing for HTTP and structured log correlation."""
    if os.getenv("OTEL_SDK_DISABLED", "").lower() in {"1", "true", "yes"}:
        return
    if settings.environment == "test":
        return

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create(
        {
            "service.name": settings.otel_service_name,
            "deployment.environment": settings.environment,
        }
    )
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=settings.otel_exporter_otlp_endpoint,
        insecure=True,
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    LoggingInstrumentor().instrument(set_logging_format=False)
