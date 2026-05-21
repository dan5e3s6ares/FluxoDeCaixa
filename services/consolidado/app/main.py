import asyncio
import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fcx_shared import configure_logging, configure_otel, get_settings
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from app.api.routes import admin as admin_routes
from app.api.routes import internal as internal_routes
from app.errors import ProblemDetail, problem_detail_handler
from app.schemas.health import HealthResponse
from app.workers.nats_consumer import NatsConsumerWorker
from app.workers.reconciliation_worker import ReconciliationWorker

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    configure_logging(settings)
    configure_otel(settings)
    consumer = NatsConsumerWorker()
    reconciler = ReconciliationWorker()
    consumer_task = asyncio.create_task(consumer.run())
    reconciler_task = asyncio.create_task(reconciler.run())
    logger.info("service started", extra={"service": "consolidado"})
    try:
        yield
    finally:
        consumer._stop.set()
        reconciler.stop()
        consumer_task.cancel()
        reconciler_task.cancel()
        for task in (consumer_task, reconciler_task):
            try:
                await task
            except asyncio.CancelledError:
                pass
        logger.info("service stopped", extra={"service": "consolidado"})


app = FastAPI(title="svc-consolidado", version="0.1.0", lifespan=lifespan)

FastAPIInstrumentor.instrument_app(app, excluded_urls="/health")

app.add_exception_handler(ProblemDetail, problem_detail_handler)
app.include_router(internal_routes.router)
app.include_router(admin_routes.router)


@app.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", service="consolidado")
