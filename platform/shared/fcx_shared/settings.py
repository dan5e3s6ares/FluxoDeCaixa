from functools import lru_cache
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

LogLevel = Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
Environment = Literal["dev", "staging", "prod", "test"]


class ServiceSettings(BaseSettings):
    """Platform env vars validated at startup (doc 07)."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        populate_by_name=True,
    )

    database_url: str = Field(..., alias="DATABASE_URL", min_length=1)
    redis_url: str = Field(..., alias="REDIS_URL", min_length=1)
    nats_url: str = Field(..., alias="NATS_URL", min_length=1)
    keycloak_url: str = Field(..., alias="KEYCLOAK_URL", min_length=1)
    keycloak_realm: str = Field(..., alias="KEYCLOAK_REALM", min_length=1)
    keycloak_client_id: str = Field(..., alias="KEYCLOAK_CLIENT_ID", min_length=1)
    otel_exporter_otlp_endpoint: str = Field(
        ..., alias="OTEL_EXPORTER_OTLP_ENDPOINT", min_length=1
    )
    otel_service_name: str = Field(..., alias="OTEL_SERVICE_NAME", min_length=1)
    log_level: LogLevel = Field(default="INFO", alias="LOG_LEVEL")
    environment: Environment = Field(default="dev", alias="ENVIRONMENT")

    @field_validator("log_level", mode="before")
    @classmethod
    def normalize_log_level(cls, value: object) -> object:
        if isinstance(value, str):
            return value.upper()
        return value

    @field_validator("environment", mode="before")
    @classmethod
    def normalize_environment(cls, value: object) -> object:
        if isinstance(value, str):
            return value.lower()
        return value


@lru_cache
def get_settings() -> ServiceSettings:
    return ServiceSettings()
