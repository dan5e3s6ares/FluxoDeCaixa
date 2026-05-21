"""ReconciliationWorker background job tests."""

from __future__ import annotations

import asyncio
from unittest.mock import MagicMock, patch

from app.workers.reconciliation_worker import ReconciliationWorker


def test_worker_disabled_exits_immediately() -> None:
    worker = ReconciliationWorker(enabled=False)
    asyncio.run(worker.run())


def test_worker_runs_cycle_and_stops() -> None:
    service = MagicMock()
    service.run_daily.return_value = []
    worker = ReconciliationWorker(
        service=service,
        interval_seconds=3600,
        enabled=True,
    )

    async def _run() -> None:
        async def stop_after_delay() -> None:
            await asyncio.sleep(0.05)
            worker.stop()

        with patch("app.workers.reconciliation_worker.get_session_factory") as mock_factory:
            session = MagicMock()
            session_cm = MagicMock()
            session_cm.__enter__.return_value = session
            session_cm.__exit__.return_value = None
            mock_factory.return_value = MagicMock(return_value=session_cm)
            task = asyncio.create_task(worker.run())
            await stop_after_delay()
            await asyncio.wait_for(task, timeout=2)

        service.run_daily.assert_called()
        session.commit.assert_called_once()

    asyncio.run(_run())
