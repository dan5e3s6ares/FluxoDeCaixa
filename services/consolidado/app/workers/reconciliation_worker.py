"""Daily reconciliation job — lancamentos sums vs read model (doc 02 RF04)."""

from __future__ import annotations

import asyncio
import logging

from app.db import get_session_factory
from app.reconciliation.config import (
    RECONCILIATION_ENABLED,
    RECONCILIATION_INTERVAL_SECONDS,
    RECONCILIATION_LOOKBACK_DAYS,
)
from app.services.reconciliation_service import ReconciliationService

logger = logging.getLogger(__name__)


class ReconciliationWorker:
    def __init__(
        self,
        *,
        service: ReconciliationService | None = None,
        interval_seconds: int = RECONCILIATION_INTERVAL_SECONDS,
        lookback_days: int = RECONCILIATION_LOOKBACK_DAYS,
        enabled: bool = RECONCILIATION_ENABLED,
    ) -> None:
        self._service = service or ReconciliationService()
        self._interval_seconds = interval_seconds
        self._lookback_days = lookback_days
        self._enabled = enabled
        self._stop = asyncio.Event()

    def stop(self) -> None:
        self._stop.set()

    async def run(self) -> None:
        if not self._enabled:
            logger.info("reconciliation worker disabled")
            return

        logger.info(
            "reconciliation worker started",
            extra={
                "interval_seconds": self._interval_seconds,
                "lookback_days": self._lookback_days,
            },
        )
        while not self._stop.is_set():
            await self._run_once()
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=self._interval_seconds)
            except asyncio.TimeoutError:
                pass

    async def _run_once(self) -> None:
        try:
            with get_session_factory()() as session:
                checks = self._service.run_daily(
                    session, lookback_days=self._lookback_days
                )
                session.commit()
            drift_count = sum(1 for check in checks if not check.matched)
            logger.info(
                "reconciliation cycle complete",
                extra={
                    "days_checked": len(checks),
                    "drift_detected": drift_count,
                },
            )
        except Exception:
            logger.exception("reconciliation cycle failed")
