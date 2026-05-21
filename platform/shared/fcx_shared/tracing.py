from __future__ import annotations


def traceparent_from_correlation_id(correlation_id: str) -> str:
    """Build W3C traceparent from a UUID correlation id (doc 05)."""
    trace_id = correlation_id.replace("-", "").lower().zfill(32)[:32]
    span_id = correlation_id.replace("-", "").lower().zfill(16)[:16]
    return f"00-{trace_id}-{span_id}-01"
