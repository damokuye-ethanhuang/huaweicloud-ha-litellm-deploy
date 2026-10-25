#!/usr/bin/env python3
"""List CCE releases (the supported Kubernetes cluster versions) for a region.

CCE does not expose 'supported cluster versions' via a version-discovery endpoint;
cluster versions are carried by ListReleases (v3). Each release has a
cluster_version / version string such as 'v1.30'.
"""
import json
import os
import urllib.request
from datetime import datetime, timezone

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()
region = os.environ.get("HW_REGION_NAME", "cn-southwest-2")

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
from huaweicloudsdkcce.v3 import CceClient, ListReleasesRequest

client = (
    CceClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, pid))
    .with_region(Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com"))
    .build()
)
r = client.list_releases(ListReleasesRequest())
items = r.items or r.releases or []
print(f"region={region} releases={len(items)}")
for it in items[:30]:
    d = it.to_dict() if hasattr(it, "to_dict") else it
    print(" ", json.dumps(d, ensure_ascii=False)[:220])
