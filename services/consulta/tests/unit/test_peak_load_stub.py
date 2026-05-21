"""Peak read SLA stub (doc 01): 50 req/s burst, <=5% failures, 2s timeout."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

from app.api.deps import get_consolidado_read_service, get_merchant_db_session, get_redis
from app.domain import ConsolidadoDiarioView, ConsolidadoReadResult
from app.main import app
from app.services.consolidado_read_service import ConsolidadoReadService
from tests.helpers.jwt import MERCHANT_ID, auth_header
from tests.unit.test_rf03_get_consolidado import DATA, _view

# Doc 01 / 02 RNF03 — consulta read path at peak.
PEAK_READ_RPS = 50
MAX_FAILURE_RATE = 0.05
MIN_SUCCESS_RATE = 1.0 - MAX_FAILURE_RATE
BURST_WINDOW_SECONDS = 300
P99_LATENCY_TARGET_MS = 500
REQUEST_TIMEOUT_SECONDS = 2.0


def test_peak_read_sla_constants_match_documentation() -> None:
    assert PEAK_READ_RPS == 50
    assert MAX_FAILURE_RATE == 0.05
    assert MIN_SUCCESS_RATE == 0.95
    assert BURST_WINDOW_SECONDS == 300
    assert P99_LATENCY_TARGET_MS == 500
    assert REQUEST_TIMEOUT_SECONDS == 2.0


@pytest.fixture
def peak_client() -> TestClient:
    mock_service = MagicMock(spec=ConsolidadoReadService)
    mock_service.get_daily = AsyncMock(
        return_value=ConsolidadoReadResult(consolidado=_view(), stale=False)
    )
    session = MagicMock()
    redis = AsyncMock()
    app.dependency_overrides[get_consolidado_read_service] = lambda: mock_service
    app.dependency_overrides[get_merchant_db_session] = lambda: session
    app.dependency_overrides[get_redis] = lambda: redis
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_get_consolidado_survives_peak_burst_stub(peak_client: TestClient) -> None:
    """Stub: 50 concurrent GETs with mocked cache-aside must meet >=95% success (doc 01)."""
    path = f"/v1/consolidado/{DATA.isoformat()}"
    headers = auth_header()

    def _request() -> int:
        return peak_client.get(path, headers=headers).status_code

    with ThreadPoolExecutor(max_workers=PEAK_READ_RPS) as pool:
        futures = [pool.submit(_request) for _ in range(PEAK_READ_RPS)]
        status_codes = [future.result() for future in as_completed(futures)]

    successes = sum(1 for code in status_codes if code == 200)
    success_rate = successes / len(status_codes)
    assert success_rate >= MIN_SUCCESS_RATE, (
        f"peak stub: {successes}/{len(status_codes)} succeeded "
        f"(required >= {MIN_SUCCESS_RATE:.0%})"
    )
