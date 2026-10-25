#!/usr/bin/env python3
"""Resolve the real project id from IAM, then retry the CCE call with it."""
import json
import os
import urllib.request
from datetime import datetime, timezone

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()
region = "cn-southwest-2"

# 1. IAM token with the region name scope (this worked earlier)
body = json.dumps({"auth": {"identity": {"methods": ["hw_ak_sk"],
                                         "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
                            "scope": {"project": {"name": region}}}})
req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens", data=body.encode(), method="POST")
req.add_header("Content-Type", "application/json;charset=utf8")
req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
with urllib.request.urlopen(req, timeout=20) as resp:
    token = resp.headers["X-Subject-Token"]
    payload = json.load(resp)

pid = payload["token"]["project"]["id"]
print(f"project.name={region} -> project.id={pid}")

# 2. Retry CCE with the real project id
from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest

client = (
    CceClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, pid))
    .with_region(Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com"))
    .build()
)
try:
    r = client.show_cluster_support_configuration(
        ShowClusterSupportConfigurationRequest(cluster_type="VirtualMachine", network_mode="vpc-router")
    )
    d = r.to_dict()
    vers = d.get("versions") or []
    print(f"CCE OK versions={len(vers)}")
    for v in vers:
        if isinstance(v, dict):
            print("  ", v.get("version") or v.get("kubernetesVersion") or v)
        else:
            print("  ", v)
except Exception as exc:  # noqa: BLE001
    print("CCE FAIL", str(exc)[:220])
