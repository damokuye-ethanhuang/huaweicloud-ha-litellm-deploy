#!/usr/bin/env python3
"""Check which CCE Kubernetes versions are actually available, and update the preset.

Two sources, because they answer different questions:

  API (authoritative, needs AK/SK)
      ShowClusterSupportConfiguration returns what this region will accept right
      now, including deprecation state. This is what `deploy.sh` uses to resolve
      an empty `cce_cluster_version`.

  Vendor docs (no credentials)
      The support site's "Kubernetes版本发布记录" page is static HTML with a table
      of cluster versions. It tells you a new minor exists even before you have
      credentials for the target region.

Usage:
    ./scripts/check-cce-versions.py                # SDK if creds exist, else docs
    ./scripts/check-cce-versions.py --sdk
    ./scripts/check-cce-versions.py --doc <url>    # repeatable
    ./scripts/check-cce-versions.py --write        # update version-presets.yaml

Exit codes: 0 up to date, 1 preset is behind the live list, 2 could not check.
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
PRESETS = REPO / "version-presets.yaml"
INPUTS = REPO / "deploy-inputs.yaml"

VERSION_RE = re.compile(r"\bv1\.(\d{1,2})(?:\.(\d{1,3}))?\b")


def die(msg: str, code: int = 2) -> None:
    print(f"[fail] {msg}", file=sys.stderr)
    sys.exit(code)


def minor_key(minor: str) -> tuple[int, int]:
    cleaned = minor.removeprefix("v")
    major, _, rest = cleaned.partition(".")
    return int(major), int(rest or 0)


def credentials() -> tuple[str, str, str]:
    import os

    ak, sk, project = os.environ.get("HW_ACCESS_KEY", ""), os.environ.get("HW_SECRET_KEY", ""), os.environ.get("HW_PROJECT_ID", "")
    env_file = REPO / "secrets" / "hw.env"
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            value = value.strip().strip('"').strip("'")
            if key == "HW_ACCESS_KEY":
                ak = ak or value
            elif key == "HW_SECRET_KEY":
                sk = sk or value
            elif key == "HW_PROJECT_ID":
                project = project or value
    return ak, sk, project


def region() -> str:
    doc = yaml.safe_load(INPUTS.read_text(encoding="utf-8")) or {}
    for section in doc.values():
        for item in section if isinstance(section, list) else []:
            if isinstance(item, dict) and item.get("key") == "region":
                return str(item.get("value"))
    return "cn-southwest-2"


def from_sdk() -> list[str] | None:
    ak, sk, project = credentials()
    if not (ak and sk):
        return None
    try:
        from huaweicloudsdkcore.auth.credentials import BasicCredentials
        from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest
    except ImportError:
        print("[warn] huaweicloudsdkcce not installed; skipping the API check", file=sys.stderr)
        return None

    client = (
        CceClient.new_builder()
        .with_credentials(BasicCredentials(ak, sk, project))
        .with_region(region())
        .build()
    )
    request = ShowClusterSupportConfigurationRequest(cluster_type="VirtualMachine", network_mode="vpc-router")
    try:
        response = client.show_cluster_support_configuration(request)
    except Exception as exc:  # noqa: BLE001 - SDK raises per-service errors
        print(f"[warn] API call failed: {exc}", file=sys.stderr)
        return None

    versions: list[str] = []
    for item in getattr(response, "versions", None) or []:
        text = str(item)
        found = VERSION_RE.findall(text)
        for major, patch in found:
            versions.append(f"v1.{major}" + (f".{patch}" if patch else ""))
    return sorted(set(versions)) or None


def from_docs(urls: list[str]) -> list[str] | None:
    found: set[str] = set()
    for url in urls:
        try:
            with urllib.request.urlopen(url, timeout=20) as response:  # noqa: S310 - operator-supplied URL
                html = response.read().decode("utf-8", errors="ignore")
        except Exception as exc:  # noqa: BLE001 - network is best effort
            print(f"[warn] {url}: {exc}", file=sys.stderr)
            continue
        for major, patch in VERSION_RE.findall(html):
            if int(major) < 20:
                continue
            found.add(f"v1.{major}" + (f".{patch}" if patch else ""))
        print(f"[info] {url}: {len(found)} distinct versions so far", file=sys.stderr)
    return sorted(found) or None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sdk", action="store_true", help="query the CCE API (needs AK/SK)")
    ap.add_argument("--doc", action="append", default=[], metavar="URL", help="parse a vendor doc page")
    ap.add_argument("--write", action="store_true", help="update version-presets.yaml when a newer minor exists")
    args = ap.parse_args()

    presets = yaml.safe_load(PRESETS.read_text(encoding="utf-8")) or {}
    cce = presets.get("cce") or {}
    known_max = str(cce.get("max_minor") or "0.0")

    live: list[str] = []
    if args.sdk or (not args.doc and not cce.get("doc_sources")):
        sdk = from_sdk()
        if sdk:
            print(f"API ({region()}): {', '.join(sdk)}")
            live.extend(sdk)
        elif args.sdk:
            die("--sdk requested but no credentials/SDK; run ./scripts/creds.sh set")

    doc_urls = args.doc or list(cce.get("doc_sources") or [])
    if doc_urls:
        docs = from_docs(doc_urls)
        if docs:
            print(f"docs: {', '.join(docs)}")
            live.extend(docs)

    if not live:
        die("nothing to check: add --doc URL, or configure credentials and use --sdk")

    minors = sorted({f"v1.{m}" for m, _ in (VERSION_RE.match(v).groups() for v in live)}, key=minor_key)
    newest = minors[-1].removeprefix("v")
    print(f"preset max_minor: {known_max}   live newest: {newest}   range: {minors[0]}..{minors[-1]}")

    if minor_key(newest) <= minor_key(known_max):
        print("up to date")
        return 0

    print(f"[action] {newest} is newer than the preset {known_max}")
    print("        1. bump the chart/README only after a test on a scratch cluster")
    print("        2. record the verification in docs/upgrade-procedure.md")
    if args.write:
        text = PRESETS.read_text(encoding="utf-8")
        text = re.sub(r'(?m)^(\s*max_minor:\s*).*$', rf'\g<1>"{newest}"', text, count=1)
        text = re.sub(r'(?m)^(\s*last_checked:\s*).*$', rf'\g<1>"{__import__("datetime").date.today().isoformat()}"', text, count=1)
        PRESETS.write_text(text, encoding="utf-8")
        print(f"        wrote max_minor={newest} to {PRESETS.name}")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
