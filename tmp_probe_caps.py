#!/usr/bin/env python3
"""Read-only capability probe in cn-southwest-2: what can this AK actually do?"""
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
    data = json.load(resp)
pid = data["token"]["project"]["id"]
print(f"project={pid}")

CHECKS = [
    ("VPC  list", f"https://vpc.{region}.myhuaweicloud.com/v1/{pid}/vpcs"),
    ("EIP  list", f"https://vpc.{region}.myhuaweicloud.com/v1/{pid}/publicips"),
    ("ECS  list", f"https://ecs.{region}.myhuaweicloud.com/v1/{pid}/cloudservers/detail?limit=1"),
    ("CCE  list", f"https://cce.{region}.myhuaweicloud.com/api/v3/projects/{pid}/clusters"),
    ("RDS  list", f"https://rds.{region}.myhuaweicloud.com/v3/{pid}/instances?limit=1"),
    ("DCS  list", f"https://dcs.{region}.myhuaweicloud.com/v2/{pid}/instances?limit=1"),
    ("ELB  list", f"https://elb.{region}.myhuaweicloud.com/v3/{pid}/elb/loadbalancers?limit=1"),
    ("NAT  list", f"https://nat.{region}.myhuaweicloud.com/v2/{pid}/nat_gateways?limit=1"),
]

for name, url in CHECKS:
    r = urllib.request.Request(url, method="GET")
    r.add_header("X-Auth-Token", tok)
    try:
        with urllib.request.urlopen(r, timeout=25) as resp:
            body_txt = resp.read()[:160].decode("utf-8", "replace")
            print(f"  {name}: HTTP {resp.status}  {body_txt[:110]}")
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:180].decode("utf-8", "replace")
        print(f"  {name}: HTTP {exc.code}  {detail[:150]}")
    except Exception as exc:  # noqa: BLE001
        print(f"  {name}: ERR {type(exc).__name__} {str(exc)[:80]}")
