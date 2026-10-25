#!/usr/bin/env python3
"""Patch the Archify source (docs/diagrams/*.json) for the ops-subnet topology.

Idempotent: run it as often as you like. The drawio diagram is generated from
deploy-inputs.yaml by scripts/draw-architecture.py; this keeps the interactive
one in step without hand-editing JSON.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "docs" / "diagrams" / "architecture-litellmtest01.json"
INPUTS = REPO / "deploy-inputs.yaml"


def value(flat: dict, key: str, default: str) -> str:
    item = flat.get(key) or {}
    v = item.get("value")
    return str(v) if v not in (None, "") else default


def main() -> int:
    doc = yaml.safe_load(INPUTS.read_text(encoding="utf-8")) or {}
    flat: dict[str, dict] = {}
    for section in doc.values():
        for item in section if isinstance(section, list) else []:
            if isinstance(item, dict) and "key" in item:
                flat[item["key"]] = item

    project = value(flat, "project_name", "litellm")
    vpc = value(flat, "vpc_cidr", "10.0.0.0/21")
    ops_cidr = value(flat, "subnet_ops_cidr", "10.0.3.0/24")
    client = value(flat, "client_cidrs", ops_cidr).strip("[]'\"")
    admin = value(flat, "admin_cidrs", ops_cidr).strip("[]'\"")
    ssh_count = len((flat.get("bastion_ssh_cidrs") or {}).get("value") or [])

    data = json.loads(SRC.read_text(encoding="utf-8"))

    for boundary in data.get("boundaries", []):
        label = boundary.get("label", "")
        if label.startswith("VPC "):
            boundary["label"] = f"VPC {project}-maas-vpc · {vpc} · 唯一公网入口是堡垒机 EIP"
        elif "data-subnet" in label:
            boundary["label"] = f"{project}-maas-data-subnet · 5432/6379 来自应用子网与运维子网"

    for comp in data.get("components", []):
        cid = comp.get("id")
        if cid == "callers":
            comp["sublabel"] = client
        elif cid == "ops":
            # the Admin UI is reached from the bastion, not from a separate hop
            comp["sublabel"] = admin
        elif cid == "laptop":
            comp["label"] = "运维 PC"
            comp["sublabel"] = f"普通电脑 · SSH 白名单 {ssh_count} 条" if ssh_count else "普通电脑 · 仅控制台"
        elif cid == "bastion":
            comp["sublabel"] = "运维子网 · 按需 EIP · kubectl/helm/冒烟"
            comp["tag"] = "operator"
        elif cid == "vpce" and "vpce" in comp.get("label", ""):
            pass

    # Add the ops subnet as its own boundary wrapping the bastion, once.
    names = {b.get("label", "") for b in data.get("boundaries", [])}
    if not any("ops-subnet" in n for n in names):
        data["boundaries"].append(
            {
                "kind": "security-group",
                "label": f"{project}-maas-ops-subnet · {ops_cidr} · 可达 ELB/RDS/DCS/CCE API",
                "wraps": ["bastion"],
                "pad": 14,
            }
        )

    # The prose cards are part of the diagram; keep the wording on the ops model.
    for card in data.get("cards", []):
        lines = card.get("items") or card.get("lines") or []
        updated = [
            line.replace("唯一公网 IP 是跳板机的按需 EIP", "唯一公网 IP 是运维子网里堡垒机的按需 EIP")
            .replace("CCE 无公网端点，helm 从跳板机执行", "CCE 无公网端点，helm 在堡垒机执行")
            .replace("跳板机", "堡垒机")
            for line in lines
        ]
        if card.get("items") is not None:
            card["items"] = updated
        elif card.get("lines") is not None:
            card["lines"] = updated

    SRC.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"patched {SRC.relative_to(REPO)}: vpc={vpc} ops={ops_cidr} client={client}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
