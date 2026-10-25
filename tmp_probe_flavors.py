#!/usr/bin/env python3
"""Check availability of cluster flavors and node flavors in cn-southwest-2."""
import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()
region = "cn-southwest-2"

body = json.dumps({"auth": {"identity": {"methods": ["hw_ak_sk"],
                                         "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
                            "scope": {"project": {"name": region}}}})
req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens", data=body.encode(), method="POST")
req.add_header("Content-Type", "application/json;charset=utf8")
req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
with urllib.request.urlopen(req, timeout=20) as resp:
    tok = resp.headers["X-Subject-Token"]
    pid = json.load(resp)["token"]["project"]["id"]

def get(url, label):
    r = urllib.request.Request(url, method="GET")
    r.add_header("X-Auth-Token", tok)
    try:
        with urllib.request.urlopen(r, timeout=25) as resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        print(f"{label}: HTTP {exc.code} {exc.read()[:160].decode('utf-8','replace')}")
        return None

# 1. ECS flavors available in each AZ
avail = get(f"https://ecs.{region}.myhuaweicloud.com/v2/{pid}/os-availability-zone", "AZ list")
if avail:
    d = json.loads(avail)
    azs = [z["zoneName"] for z in d.get("availabilityZoneInfo", [])]
    print("AZs:", azs)

for az in ("cn-southwest-2d", "cn-southwest-2e", "cn-southwest-2f"):
    raw = get(f"https://ecs.{region}.myhuaweicloud.com/v2/{pid}/cloudservers/flavors"
              f"?availability_zone={az}&limit=2000", f"flavors {az}")
    if not raw:
        continue
    fl = json.loads(raw).get("flavors", [])
    want = [f for f in fl if f.get("name", "").startswith("c7.")]
    print(f"\n{az}: total={len(fl)} c7={len(want)}")
    for f in sorted(want, key=lambda x: x["name"]):
        print(f"   {f['name']:<14} vcpu={f['vcpus']:<3} ram={f['ram']//1024}GiB status={f.get('os_extra_specs',{}).get('ecs:performancetype','?')}")
