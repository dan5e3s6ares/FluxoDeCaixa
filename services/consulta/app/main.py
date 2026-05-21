import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fcx_shared import configure_logging, configure_otel, get_settings
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from app.api.routes import consolidado as consolidado_routes
from app.api.routes import lancamentos as lancamentos_routes
from app.cache import close_redis_client, create_redis_client
from app.errors import ProblemDetail, problem_detail_handler
from app.schemas.health import HealthResponse

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    configure_logging(settings)
    configure_otel(settings)
    app.state.redis = await create_redis_client(settings.redis_url)
    logger.info("service started", extra={"service": "consulta"})
    try:
        yield
    finally:
        await close_redis_client(app.state.redis)
        logger.info("service stopped", extra={"service": "consulta"})


app = FastAPI(title="svc-consulta", version="0.1.0", lifespan=lifespan)

FastAPIInstrumentor.instrument_app(app, excluded_urls="/health")

app.add_exception_handler(ProblemDetail, problem_detail_handler)
app.include_router(consolidado_routes.router)
app.include_router(lancamentos_routes.router)


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", service="consulta")
