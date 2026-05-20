import os

os.environ.setdefault("DATABASE_URL", "postgresql://user:pass@localhost:5432/consolidado")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("NATS_URL", "nats://localhost:4222")
os.environ.setdefault("KEYCLOAK_URL", "http://keycloak.local:8080")
os.environ.setdefault("KEYCLOAK_REALM", "fluxo-caixa")
os.environ.setdefault("KEYCLOAK_CLIENT_ID", "svc-consulta")
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
os.environ.setdefault("OTEL_SERVICE_NAME", "svc-consulta")
os.environ.setdefault("LOG_LEVEL", "INFO")
os.environ.setdefault("ENVIRONMENT", "test")
