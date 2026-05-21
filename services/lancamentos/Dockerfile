# Build from repository root: podman build -f services/lancamentos/Dockerfile .
FROM python:3.12-slim-bookworm

WORKDIR /app

COPY --from=ghcr.io/astral-sh/uv:0.6.14 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1

COPY platform/shared /platform/shared
COPY services/lancamentos/pyproject.toml services/lancamentos/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY services/lancamentos/app ./app
COPY services/lancamentos/migrations ./migrations
COPY services/lancamentos/alembic.ini ./

RUN uv sync --frozen --no-dev

EXPOSE 8000

CMD ["uv", "run", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
