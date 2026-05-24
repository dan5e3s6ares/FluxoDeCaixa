#!/usr/bin/env python3
"""Remove Harbor docker-compose syslog logging blocks (unsupported on podman-docker)."""
from __future__ import annotations

import re
import sys


def patch_compose(path: str) -> int:
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    out: list[str] = []
    skip = False
    removed = 0
    for line in lines:
        if re.match(r"^    logging:\s*$", line):
            skip = True
            removed += 1
            continue
        if skip:
            if re.match(r"^      ", line):
                continue
            skip = False
        out.append(line)

    if removed == 0:
        return 0

    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)
    print(f"removed {removed} syslog logging block(s) from {path}")
    return removed


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch-harbor-compose.py <docker-compose.yml>", file=sys.stderr)
        sys.exit(2)
    patch_compose(sys.argv[1])
