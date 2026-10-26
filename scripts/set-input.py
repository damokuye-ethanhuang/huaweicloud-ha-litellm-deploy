#!/usr/bin/env python3
"""Set one parameter's value in deploy-inputs.yaml, preserving everything else.

    ./scripts/set-input.py bastion_eip_enabled false

Exists so stages that flip a documented switch (seal / unseal) edit the single
input file instead of passing `-var` on the command line: a `-var` override makes
the file lie, and the next plain `apply` reverts the change.

Exit codes: 0 written (or already that value), 2 key/value not usable.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FILE = Path(__file__).resolve().parent.parent / "deploy-inputs.yaml"


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    key, new_value = sys.argv[1], sys.argv[2]

    lines = FILE.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.strip() != f"- key: {key}":
            continue
        for j in range(i + 1, min(i + 6, len(lines))):
            if not lines[j].lstrip().startswith("value:"):
                continue
            indent = len(lines[j]) - len(lines[j].lstrip())
            old = lines[j].split("value:", 1)[1].strip()
            if old == new_value:
                print(f"{key}: already {new_value}")
                return 0
            lines[j] = " " * indent + f"value: {new_value}"
            FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
            print(f"{key}: {old} -> {new_value}")
            return 0
        sys.exit(f"{key}: found the key but no value line under it")

    available = sorted(re.findall(r"^\s*- key: (.+)$", FILE.read_text(encoding="utf-8"), re.M))
    sys.exit(f"{key}: not in deploy-inputs.yaml (try one of: {', '.join(available[:8])} ...)")


if __name__ == "__main__":
    sys.exit(main())
