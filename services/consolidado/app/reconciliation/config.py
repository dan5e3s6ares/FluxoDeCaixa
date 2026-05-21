import os

# Daily reconciliation job (doc 02 RF04 / doc 03).
RECONCILIATION_INTERVAL_SECONDS = int(
    os.getenv("RECONCILIATION_INTERVAL_SECONDS", str(24 * 3600))
)
RECONCILIATION_LOOKBACK_DAYS = int(os.getenv("RECONCILIATION_LOOKBACK_DAYS", "30"))
RECONCILIATION_ENABLED = os.getenv("RECONCILIATION_ENABLED", "true").lower() in {
    "1",
    "true",
    "yes",
}
