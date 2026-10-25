#!/usr/bin/env python3
"""Inspect the CCE support-configuration response structure."""
import json
import os
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
    pid = json.load(resp)["token"]["project"]["id"]

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest

client = (
    CceClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, pid))
    .with_region(Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com"))
    .build()
)
r = client.show_cluster_support_configuration(
    ShowClusterSupportConfigurationRequest(cluster_type="VirtualMachine", network_mode="vpc-router")
)
b = r.body
print("body type:", type(b).__name__)
print("body attrs:", [a for a in dir(b) if not a.startswith("_")])

vers = getattr(b, "versions", None) or []
print(f"versions={len(vers)}")
for v in vers[:40]:
    name = getattr(v, "version", None)
    print("  version=", name, "| type=", getattr(v, "type", None),
          "| platform=", getattr(v, "platform_version", None))

print("\n--- other body fields ---")
for attr in ("kubernetes_versions", "support_versions", "cluster_versions"):
    val = getattr(b, attr, None)
    if val:
        print(attr, val)

print("\n--- raw to_dict (trimmed) ---")
d = b.to_dict()
print(json.dumps(d, ensure_ascii=False, default=str)[:1500])
