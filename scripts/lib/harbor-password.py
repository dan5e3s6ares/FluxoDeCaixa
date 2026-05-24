#!/usr/bin/env python3
"""Generate Harbor registry DB password hash (PBKDF2-SHA256, Harbor 2.x)."""
from __future__ import annotations

import hashlib
import secrets
import string
import sys


def harbor_password_hash(password: str, salt: str | None = None) -> tuple[str, str]:
    if salt is None:
        alphabet = string.ascii_letters + string.digits
        salt = "".join(secrets.choice(alphabet) for _ in range(32))
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode(),
        salt.encode(),
        4096,
        dklen=16,
    ).hex()
    return salt, digest


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: harbor-password.py <password>", file=sys.stderr)
        return 2
    salt, digest = harbor_password_hash(sys.argv[1])
    print(f"{salt}\t{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
