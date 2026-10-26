#!/usr/bin/env python3
"""Show what `models --apply` would change, before anything touches the cluster.

    ./scripts/models-diff.py --current ~/.litellm-deploy/state/models.applied.yaml \
                             --next models.yaml

Exit codes: 0 = diff printed (with or without changes), 2 = models.yaml invalid
or unreadable. This never talks to Kubernetes, so it is safe to run anywhere.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

FIELDS = ("model", "api_base", "api_key_env", "mode", "max_tokens", "rpm", "tpm")


def load(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as exc:
        sys.exit(f"{path}: {exc}")


def index(doc: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for entry in doc.get("models") or []:
        name = str(entry.get("name") or "").strip()
        if name:
            out[name] = entry
    return out


def pairs(doc: dict) -> set[frozenset[str]]:
    result: set[frozenset[str]] = set()
    for pair in (doc.get("fallbacks") or {}).get("pairs") or []:
        if isinstance(pair, list) and len(pair) >= 2:
            result.add(frozenset(str(p) for p in pair))
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--current", required=True, help="last applied snapshot")
    ap.add_argument("--next", required=True, help="models.yaml as it is now")
    args = ap.parse_args()

    current_path, next_path = Path(args.current), Path(args.next)
    if not next_path.is_file():
        sys.exit(f"{next_path} does not exist")
    before, after = load(current_path), load(next_path)
    old, new = index(before), index(after)
    if not new:
        print("models: [] - nothing to apply; add at least one entry to models.yaml")
        return 0

    added = [n for n in new if n not in old]
    removed = [n for n in old if n not in new]
    changed = [
        n for n in new
        if n in old and any(old[n].get(f) != new[n].get(f) for f in FIELDS)
    ]

    if not current_path.is_file():
        print(f"no snapshot at {current_path}: this is the first apply")
    print(f"models: {len(old)} applied -> {len(new)} in models.yaml")
    for n in added:
        print(f"  + {n:<24} {new[n].get('model')}")
    for n in removed:
        print(f"  - {n:<24} removed")
    for n in changed:
        details = ", ".join(
            f"{f}: {old[n].get(f) or '-'} -> {new[n].get(f) or '-'}"
            for f in FIELDS if old[n].get(f) != new[n].get(f)
        )
        print(f"  ~ {n:<24} {details}")

    # A rename looks like "one removed, one added". If the payload is identical,
    # say it out loud: every client calling the old name breaks at once.
    for gone in removed:
        for came in added:
            if all((old[gone].get(f) or "") == (new[came].get(f) or "") for f in ("model", "api_base")):
                print(
                    f"  !! {gone} -> {came} looks like a rename of the same endpoint.\n"
                    f"     `name` is the tenant-facing contract: existing clients call "
                    f"{gone!r} and will start failing with model-not-found."
                )

    fb_before, fb_after = pairs(before), pairs(after)
    if fb_before != fb_after:
        for p in sorted(fb_after - fb_before, key=sorted):
            print(f"  fallback + {' <-> '.join(sorted(p))}")
        for p in sorted(fb_before - fb_after, key=sorted):
            print(f"  fallback - {' <-> '.join(sorted(p))}")

    if not (added or removed or changed or fb_before != fb_after):
        print("  no changes: an apply would roll the pods for nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
