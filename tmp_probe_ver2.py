#!/usr/bin/env python3
"""List CCE supported cluster versions for the configured region."""
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
from huaweicloudsdkcce.v3 import CceClient, ShowVersionRequest

client = (
    CceClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, pid))
    .with_region(Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com"))
    .build()
)
r = client.show_version(ShowVersionRequest())
print(f"region={region} project={pid}")
print(f"versions returned: {len(r.versions or [])}")
for v in r.versions or []:
    print(" ", json.dumps(v if isinstance(v, (dict, str)) else v.to_dict(), ensure_ascii=False)[:200])
