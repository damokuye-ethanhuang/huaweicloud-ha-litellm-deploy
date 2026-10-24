#!/usr/bin/env python3
"""Print deploy-inputs.yaml as a fill-in table (Markdown or CSV).

    python3 scripts/inputs-table.py              # Markdown table
    python3 scripts/inputs-table.py --format csv # CSV (opens in Excel)

The YAML file remains the single source of truth; this view exists so people can
read the whole parameter set at a glance and fill it in one pass. Values shown
are the current defaults.
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import yaml

INPUTS = Path(__file__).resolve().parent.parent / "deploy-inputs.yaml"

COLUMNS = ["分组", "参数", "当前值", "必填", "可选值", "说明", "映射到"]


def row_for(section: str, item: dict) -> list[str]:
    value = item.get("value")
    if isinstance(value, list):
        shown = ", ".join(str(v) for v in value) if value else "(空)"
    elif value in (None, ""):
        shown = "(空)"
    else:
        shown = str(value)

    if item.get("required") is True:
        required = "是"
    elif item.get("required_if"):
        required = f"条件：{item['required_if']}"
    else:
        required = "否"

    allowed = ""
    if item.get("allowed"):
        allowed = " | ".join(str(a) for a in item["allowed"])
    elif item.get("allowed_int_range"):
        lo, hi = item["allowed_int_range"]
        allowed = f"{lo}..{hi}"
    elif item.get("format"):
        allowed = f"格式 {item['format']}"

    help_text = " ".join(str(item.get("help", "")).split())
    return [section, item["key"], shown, required, allowed, help_text, item.get("map_to", "")]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["markdown", "csv"], default="markdown")
    ap.add_argument("--inputs", default=str(INPUTS))
    args = ap.parse_args()

    doc = yaml.safe_load(Path(args.inputs).read_text(encoding="utf-8")) or {}
    rows: list[list[str]] = []
    for section, items in doc.items():
        if not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict) and "key" in item:
                rows.append(row_for(section, item))

    if args.format == "csv":
        writer = csv.writer(sys.stdout)
        writer.writerow(COLUMNS)
        writer.writerows(rows)
        return 0

    print("| " + " | ".join(COLUMNS) + " |")
    print("|" + "|".join(["---"] * len(COLUMNS)) + "|")
    for row in rows:
        cells = [c.replace("|", "\\|") for c in row]
        print("| " + " | ".join(cells) + " |")
    print(f"\n共 {len(rows)} 个参数，其中必填 {sum(1 for r in rows if r[3] == '是')} 个。")
    print("填写入口：deploy-inputs.yaml；校验：./scripts/deploy.sh preflight")
    return 0


if __name__ == "__main__":
    sys.exit(main())
