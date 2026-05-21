"""Auth module unit tests — merchant header and admin role extraction."""

from __future__ import annotations

import uuid

import pytest

from app.auth.admin import ADMIN_ROLE, require_admin_role
from app.auth.merchant import MERCHANT_HEADER, extract_merchant_id
from app.errors import ProblemDetail


def test_extract_merchant_id_parses_valid_uuid() -> None:
    uid = uuid.UUID("00000000-0000-4000-8000-000000000001")
    assert extract_merchant_id(str(uid)) == uid


def test_extract_merchant_id_raises_on_missing_header() -> None:
    with pytest.raises(ProblemDetail) as exc_info:
        extract_merchant_id(None)
    assert exc_info.value.status == 401


def test_extract_merchant_id_raises_on_invalid_uuid() -> None:
    with pytest.raises(ProblemDetail) as exc_info:
        extract_merchant_id("not-a-uuid")
    assert exc_info.value.status == 401
    assert "Invalid" in exc_info.value.detail


def test_require_admin_role_passes_with_admin_role() -> None:
    require_admin_role("admin")


def test_require_admin_role_passes_with_mixed_roles() -> None:
    require_admin_role("user, admin, editor")


def test_require_admin_role_raises_on_missing_header() -> None:
    with pytest.raises(ProblemDetail) as exc_info:
        require_admin_role(None)
    assert exc_info.value.status == 403


def test_require_admin_role_raises_on_non_admin_role() -> None:
    with pytest.raises(ProblemDetail) as exc_info:
        require_admin_role("viewer")
    assert exc_info.value.status == 403
    assert ADMIN_ROLE in exc_info.value.detail