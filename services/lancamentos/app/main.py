import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fcx_shared import configure_logging, configure_otel, get_settings
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from pydantic import ValidationError

from app.api.routes import lancamentos as lancamentos_routes
from app.errors import (
    ProblemDetail,
    problem_detail_handler,
    pydantic_validation_handler,
    validation_exception_handler,
)
from app.schemas.health import HealthResponse

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    configure_logging(settings)
    configure_otel(settings)
    logger.info("service started", extra={"service": "lancamentos"})
    yield


app = FastAPI(title="svc-lancamentos", version="0.1.0", lifespan=lifespan)

FastAPIInstrumentor.instrument_app(app, excluded_urls="/health")

app.add_exception_handler(ProblemDetail, problem_detail_handler)
app.add_exception_handler(RequestValidationError, validation_exception_handler)
app.add_exception_handler(ValidationError, pydantic_validation_handler)

app.include_router(lancamentos_routes.router)


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", service="lancamentos")
