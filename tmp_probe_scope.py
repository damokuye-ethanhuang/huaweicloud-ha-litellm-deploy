#!/usr/bin/env python3
"""Check which regions this AK/SK can see, and whether cn-southwest-2 exists."""
import json
import os
import urllib.request
from datetime import datetime, timezone

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

def token(scope=None):
    payload = {"auth": {"identity": {"methods": ["hw_ak_sk"],
                                     "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}}}}
    if scope:
        payload["auth"]["scope"] = scope
    req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens",
                                 data=json.dumps(payload).encode(), method="POST")
    req.add_header("Content-Type", "application/json;charset=utf8")
    req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.headers["X-Subject-Token"], json.load(resp)

# Unscoped: what does this identity see?
tok, data = token()
t = data["token"]
print("user:", t.get("user", {}).get("name"), "| domain:", t.get("user", {}).get("domain", {}).get("name"))
catalog = t.get("catalog", [])
print(f"catalog services: {len(catalog)}")
regions = set()
for svc in catalog:
    for ep in svc.get("endpoints", []):
        regions.add(ep.get("region"))
regions.discard(None)
hits = sorted(r for r in regions if "sw" in r or "southwest" in r or "cn-" in r)
print("cn-ish regions visible:", hits[:20])
print("total regions visible:", len(regions))

# Can we scope to cn-southwest-2 specifically?
for name in ("cn-southwest-2", "cn-north-4", "ap-southeast-1", "ap-southeast-3"):
    try:
        _, d = token({"project": {"name": name}})
        p = d["token"].get("project", {})
        print(f"scope {name}: OK project_id={p.get('id')}")
    except Exception as exc:  # noqa: BLE001
        print(f"scope {name}: FAIL {str(exc)[:90]}")
