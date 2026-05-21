from __future__ import annotations

from typing import Any

from fastapi import Request
from fastapi.responses import JSONResponse

PROBLEM_JSON = "application/problem+json"


class ProblemDetail(Exception):
    def __init__(
        self,
        *,
        status: int,
        title: str,
        detail: str,
        type_: str = "about:blank",
        extra: dict[str, Any] | None = None,
    ) -> None:
        self.status = status
        self.title = title
        self.detail = detail
        self.type_ = type_
        self.extra = extra or {}

    def to_dict(self) -> dict[str, Any]:
        body: dict[str, Any] = {
            "type": self.type_,
            "title": self.title,
            "status": self.status,
            "detail": self.detail,
        }
        body.update(self.extra)
        return body


def problem_response(exc: ProblemDetail) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status,
        content=exc.to_dict(),
        media_type=PROBLEM_JSON,
    )


async def problem_detail_handler(_request: Request, exc: ProblemDetail) -> JSONResponse:
    return problem_response(exc)
