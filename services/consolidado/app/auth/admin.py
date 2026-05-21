from __future__ import annotations

from typing import Annotated

from fastapi import Header

from app.errors import ProblemDetail

ROLES_HEADER = "X-Roles"
ADMIN_ROLE = "admin"


def require_admin_role(
    x_roles: Annotated[str | None, Header(alias=ROLES_HEADER)] = None,
) -> None:
    """Operational admin endpoints (doc 05 RBAC — reprocess/reconcile)."""
    if not x_roles:
        raise ProblemDetail(
            status=403,
            title="Forbidden",
            detail=f"Missing {ROLES_HEADER} header with role {ADMIN_ROLE}",
            type_="https://fluxo-caixa/errors/forbidden",
        )
    roles = {part.strip().lower() for part in x_roles.split(",") if part.strip()}
    if ADMIN_ROLE not in roles:
        raise ProblemDetail(
            status=403,
            title="Forbidden",
            detail=f"Role {ADMIN_ROLE} required",
            type_="https://fluxo-caixa/errors/forbidden",
        )
