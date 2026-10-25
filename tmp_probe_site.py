#!/usr/bin/env python3
"""Determine which Huawei Cloud site this account belongs to."""
import json
import os
import urllib.request
from datetime import datetime, timezone

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

body = json.dumps({"auth": {"identity": {"methods": ["hw_ak_sk"],
                                         "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
                            "scope": {"project": {"name": "cn-southwest-2"}}}})
req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens", data=body.encode(), method="POST")
req.add_header("Content-Type", "application/json;charset=utf8")
req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
with urllib.request.urlopen(req, timeout=20) as resp:
    data = json.load(resp)

t = data["token"]
u = t.get("user", {})
print("user.name      :", u.get("name"))
print("user.id        :", u.get("id"))
print("domain.name    :", u.get("domain", {}).get("name"), "| id:", u.get("domain", {}).get("id"))
print("project.name   :", t.get("project", {}).get("name"))
print("project.id     :", t.get("project", {}).get("id"))
print("token.issued_at:", t.get("issued_at"))
print("roles          :", [r.get("name") for r in t.get("roles", [])][:12] or "(none at project scope)")

# Account-level flags that reveal site/account type.
for k in ("xdomain_type", "account_type", "is_fedration", "catalog"):
    if k in t:
        print(f"{k:15}:", str(t[k])[:120])

# Who am I at the account (domain) scope?
body2 = json.dumps({"auth": {"identity": {"methods": ["hw_ak_sk"],
                                          "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
                             "scope": {"domain": {"name": u.get("domain", {}).get("name")}}}})
req2 = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens", data=body2.encode(), method="POST")
req2.add_header("Content-Type", "application/json;charset=utf8")
req2.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
try:
    with urllib.request.urlopen(req2, timeout=20) as resp2:
        d2 = json.load(resp2)
    print("domain scope   : OK, roles:", [r.get("name") for r in d2["token"].get("roles", [])][:12])
except Exception as exc:  # noqa: BLE001
    print("domain scope   : FAIL", str(exc)[:120])
