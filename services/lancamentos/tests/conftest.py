import os

# Required platform env vars (doc 07) — set before app imports in unit tests.
os.environ.setdefault("DATABASE_URL", "postgresql://user:pass@localhost:5432/lancamentos")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("NATS_URL", "nats://localhost:4222")
os.environ.setdefault("KEYCLOAK_URL", "http://keycloak.local:8080")
os.environ.setdefault("KEYCLOAK_REALM", "fluxo-caixa")
os.environ.setdefault("KEYCLOAK_CLIENT_ID", "svc-lancamentos")
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
os.environ.setdefault("OTEL_SERVICE_NAME", "svc-lancamentos")
os.environ.setdefault("LOG_LEVEL", "INFO")
os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("OTEL_SDK_DISABLED", "true")
