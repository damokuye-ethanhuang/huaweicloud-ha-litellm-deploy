#!/usr/bin/env python3
"""Validate the monitoring assets and their links.

Alerts are the part of this stack that fails silently: a renamed metric or a
moved heading leaves a rule that never fires and nobody notices until an
incident. This check is cheap and runs in CI.

Checks:
  1. alerting-rules.yaml parses and every rule has the required fields
  2. every runbook link points at a real file and a real heading anchor
  3. grafana-dashboard.json parses, panel ids are unique, panels have targets
  4. metric names used by rules and panels are cross-referenced (warning only)
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = ROOT / "monitoring" / "alerting-rules.yaml"
DASHBOARD = ROOT / "monitoring" / "grafana-dashboard.json"

REQUIRED_RULE_FIELDS = (
    "name",
    "description",
    "severity",
    "metric",
    "aggregation",
    "window",
    "comparison",
    "threshold",
    "for",
    "notify",
    "runbook",
)
SEVERITIES = {"critical", "warning", "info"}


def heading_anchors(path: pathlib.Path) -> set[str]:
    """GitHub-style anchors for every markdown heading in a file."""
    anchors: set[str] = set()
    for line in path.read_text().splitlines():
        match = re.match(r"^#{2,4}\s+(.*)$", line)
        if not match:
            continue
        text = match.group(1).strip().lower()
        text = re.sub(r"[^\w\s-]", "", text)
        anchors.add(re.sub(r"\s+", "-", text))
    return anchors


def check_rules(errors: list[str], warnings: list[str]) -> set[str]:
    if not RULES.exists():
        errors.append(f"{RULES.relative_to(ROOT)}: missing")
        return set()

    doc = yaml.safe_load(RULES.read_text())
    rules = doc.get("rules") or []
    if not rules:
        errors.append("alerting-rules.yaml: no rules defined")
        return set()

    names: set[str] = set()
    metrics: set[str] = set()
    for rule in rules:
        name = rule.get("name", "<unnamed>")
        missing = [f for f in REQUIRED_RULE_FIELDS if f not in rule]
        if missing:
            errors.append(f"rule {name}: missing {', '.join(missing)}")
        if name in names:
            errors.append(f"rule {name}: duplicate name")
        names.add(name)
        if rule.get("severity") not in SEVERITIES:
            errors.append(f"rule {name}: severity {rule.get('severity')!r} not in {SEVERITIES}")
        if rule.get("metric"):
            metrics.add(rule["metric"])

        target = rule.get("runbook", "")
        file_part, _, anchor = target.partition("#")
        target_path = ROOT / file_part
        if not file_part:
            errors.append(f"rule {name}: empty runbook")
        elif not target_path.exists():
            errors.append(f"rule {name}: runbook file {file_part} does not exist")
        elif anchor and anchor not in heading_anchors(target_path):
            errors.append(f"rule {name}: runbook anchor #{anchor} not found in {file_part}")
    return metrics


def check_dashboard(errors: list[str], warnings: list[str]) -> set[str]:
    if not DASHBOARD.exists():
        errors.append(f"{DASHBOARD.relative_to(ROOT)}: missing")
        return set()

    try:
        dash = json.loads(DASHBOARD.read_text())
    except json.JSONDecodeError as exc:
        errors.append(f"grafana-dashboard.json: invalid JSON ({exc})")
        return set()

    for key in ("title", "uid", "panels", "schemaVersion"):
        if key not in dash:
            errors.append(f"grafana-dashboard.json: missing key {key!r}")

    panels = dash.get("panels") or []
    ids = [p.get("id") for p in panels]
    if len(ids) != len(set(ids)):
        errors.append("grafana-dashboard.json: duplicate panel ids")

    metrics: set[str] = set()
    for panel in panels:
        pid = panel.get("id")
        if panel.get("type") == "row":
            continue
        if not panel.get("datasource"):
            errors.append(f"panel {pid}: no datasource")
        targets = panel.get("targets") or []
        if not targets:
            errors.append(f"panel {pid}: no targets")
        for target in targets:
            expr = target.get("expr", "")
            metrics.update(re.findall(r"\b(litellm_[a-z_]+|[a-z]+_[a-z_]+)\b", expr))
    return metrics


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    rule_metrics = check_rules(errors, warnings)
    panel_metrics = check_dashboard(errors, warnings)

    # Cross-reference: a metric an alert relies on should be visible somewhere
    # in the dashboard. Not fatal — an alert may intentionally track something
    # nobody charts — but worth surfacing.
    def normalise(name: str) -> str:
        for suffix in ("_bucket", "_count", "_sum"):
            if name.endswith(suffix):
                return name[: -len(suffix)]
        return name

    covered = {normalise(m) for m in panel_metrics}
    for metric in sorted(rule_metrics - covered):
        warnings.append(f"metric {metric} has an alert rule but no dashboard panel")

    for w in warnings:
        print(f"[warn] {w}")
    for e in errors:
        print(f"[fail] {e}")

    if errors:
        return 1
    print(f"monitoring assets ok: {len(rule_metrics)} alert metrics, dashboard valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
