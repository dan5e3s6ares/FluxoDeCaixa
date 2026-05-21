"""ProblemDetail error handler unit tests."""

from __future__ import annotations

from app.errors import ProblemDetail, problem_response


def test_problem_detail_to_dict() -> None:
    exc = ProblemDetail(
        status=403,
        title="Forbidden",
        detail="Missing role",
        type_="https://fluxo-caixa/errors/forbidden",
    )
    d = exc.to_dict()
    assert d["status"] == 403
    assert d["title"] == "Forbidden"
    assert d["detail"] == "Missing role"
    assert d["type"] == "https://fluxo-caixa/errors/forbidden"


def test_problem_detail_to_dict_includes_extra_fields() -> None:
    exc = ProblemDetail(
        status=400,
        title="Bad Request",
        detail="Invalid input",
        extra={"field": "merchant_id"},
    )
    d = exc.to_dict()
    assert d["field"] == "merchant_id"


def test_problem_response_returns_json_response() -> None:
    exc = ProblemDetail(
        status=401,
        title="Unauthorized",
        detail="Missing header",
        type_="https://fluxo-caixa/errors/unauthorized",
    )
    response = problem_response(exc)
    assert response.status_code == 401
    assert response.media_type == "application/problem+json"