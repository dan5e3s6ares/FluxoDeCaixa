# Build from repository root: podman build -f services/consolidado/Dockerfile .
FROM python:3.12-slim-bookworm

COPY --from=ghcr.io/astral-sh/uv:0.6.14 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1

WORKDIR /workspace

COPY platform/shared platform/shared
COPY services/consolidado/pyproject.toml services/consolidado/uv.lock services/consolidado/

WORKDIR /workspace/services/consolidado
RUN uv sync --frozen --no-dev --no-install-project

COPY services/consolidado/app ./app
COPY services/consolidado/migrations ./migrations
COPY services/consolidado/alembic.ini ./

RUN uv sync --frozen --no-dev

EXPOSE 8000

CMD ["uv", "run", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
