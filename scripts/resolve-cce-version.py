#!/usr/bin/env python3
"""Resolve the Kubernetes versions the Huawei Cloud region currently supports
for CCE, then write the newest one into deploy-inputs.yaml.

Uses the official Huawei Cloud SDK (huaweicloudsdkcce) - no hand-rolled signing.
Credentials come from the standard SDK chain: HW_ACCESS_KEY / HW_SECRET_KEY, or
~/.huaweicloud/credentials.

Why resolve at run time: CCE retires minor versions and expects an exact patch
string (for example v1.31.1-r0). A version pinned in a repository goes stale, so
the deployment resolves it per run and records it in the inputs file.

  scripts/resolve-cce-version.py             # query and write
  scripts/resolve-cce-version.py --json      # query only
  scripts/resolve-cce-version.py --dry-run   # query, show what would change

Exit codes: 0 ok, 2 could not resolve, 3 SDK or credentials unavailable.
Install the SDK into a venv first:
  python3 -m venv .venv-sdk && .venv-sdk/bin/pip install huaweicloudsdkcce
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INPUTS = REPO / "deploy-inputs.yaml"


def die(msg: str, code: int) -> None:
    print(f"[fail] {msg}", file=sys.stderr)
    sys.exit(code)


def input_value(key: str) -> str:
    m = re.search(rf'  - key: {key}\n    value: "?([^"\n]+)"?', INPUTS.read_text(encoding="utf-8"))
    return m.group(1) if m else ""


def version_key(v: str) -> tuple:
    m = re.match(r"v(\d+)\.(\d+)\.(\d+)(?:-r(\d+))?", v)
    return tuple(int(x) if x else 0 for x in m.groups()) if m else (0, 0, 0, 0)


def extract_versions(obj: object) -> list[str]:
    """Collect every Kubernetes version string from the SDK response object."""
    found: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, str):
            if re.fullmatch(r"v1\.\d+\.\d+(?:-r\d+)?", node):
                found.add(node)
        elif isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, (list, tuple)):
            for item in node:
                walk(item)
        elif hasattr(node, "to_dict"):
            walk(node.to_dict())
        elif hasattr(node, "__dict__"):
            walk({k: v for k, v in vars(node).items() if not k.startswith("_")})

    walk(obj)
    return sorted(found, key=version_key)


def resolve(region: str) -> list[str]:
    try:
        from huaweicloudsdkcore.auth.credentials import BasicCredentials
        from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest
    except ImportError:
        die("huaweicloudsdkcce is not installed: python3 -m venv .venv-sdk && "
            ".venv-sdk/bin/pip install huaweicloudsdkcce", 3)

    ak = os.environ.get("HW_ACCESS_KEY", "")
    sk = os.environ.get("HW_SECRET_KEY", "")
    project = os.environ.get("HW_PROJECT_ID", "")
    if not (ak and sk):
        cred = Path(os.path.expanduser("~/.huaweicloud/credentials"))
        if not cred.is_file():
            die("no credentials: export HW_ACCESS_KEY / HW_SECRET_KEY (or create ~/.huaweicloud/credentials)", 3)

    credentials = BasicCredentials(ak, sk, project) if ak and sk else None
    builder = CceClient.new_builder()
    if credentials is not None:
        builder = builder.with_credentials(credentials)
    client = builder.with_region(region).build()

    request = ShowClusterSupportConfigurationRequest(cluster_type="VirtualMachine", network_mode="vpc-router")
    try:
        response = client.show_cluster_support_configuration(request)
    except Exception as exc:  # noqa: BLE001 - SDK raises per-service errors
        die(f"CCE API call failed: {exc}", 2)
    return extract_versions(response)


def write_version(version: str) -> bool:
    text = INPUTS.read_text(encoding="utf-8")
    new, n = re.subn(r'(  - key: cce_cluster_version\n    value: )"?[^"\n]+"?', rf'\1"{version}"', text, count=1)
    if n == 0:
        return False
    INPUTS.write_text(new, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    region = args.region or input_value("region")
    if not region:
        die("region not found in deploy-inputs.yaml", 2)

    versions = resolve(region)
    if not versions:
        die(f"no CCE versions returned for {region}; check CCE read permission", 2)

    latest = versions[-1]
    current = input_value("cce_cluster_version")
    payload = {"region": region, "supported": versions, "latest": latest, "current": current}

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    print(f"region     {region}")
    print(f"latest     {latest}")
    print(f"current    {current}")
    print("supported  " + ", ".join(versions[-8:]))

    if args.dry_run:
        return 0
    if current != latest and write_version(latest):
        print(f"\nwrote cce_cluster_version = {latest} to deploy-inputs.yaml")
    else:
        print("\nalready up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
