#!/usr/bin/env python3
"""Print the literal JSON returned by the CCE support-configuration endpoint."""
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
print("body keys:", list(r.body))
print(json.dumps(r.body, ensure_ascii=False, default=str)[:3000])
