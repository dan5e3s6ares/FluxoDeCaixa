from __future__ import annotations

import base64
import json
import uuid
from datetime import datetime, timezone

from app.errors import ProblemDetail

_CURSOR_VERSION = 1


def encode_cursor(*, created_at: datetime, lancamento_id: uuid.UUID) -> str:
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    payload = {
        "v": _CURSOR_VERSION,
        "created_at": created_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "id": str(lancamento_id),
    }
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        padding = "=" * (-len(cursor) % 4)
        raw = base64.urlsafe_b64decode(cursor + padding)
        payload = json.loads(raw.decode("utf-8"))
        if payload.get("v") != _CURSOR_VERSION:
            raise ValueError("unsupported cursor version")
        created_at = datetime.fromisoformat(
            str(payload["created_at"]).replace("Z", "+00:00")
        )
        lancamento_id = uuid.UUID(str(payload["id"]))
    except (ValueError, KeyError, json.JSONDecodeError, TypeError) as exc:
        raise ProblemDetail(
            status=422,
            title="Unprocessable Entity",
            detail="Invalid cursor",
            type_="https://fluxo-caixa/errors/validation",
        ) from exc

    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    return created_at, lancamento_id
