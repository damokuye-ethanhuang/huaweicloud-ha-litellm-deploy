#!/usr/bin/env python3
"""Probe the CCE support-configuration API and print the raw shape."""
import json
import os
import sys

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest

region = os.environ.get("HW_REGION_NAME", "cn-southwest-2")
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

client = (
    CceClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, region))
    .with_region(Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com"))
    .build()
)

for params in (
    {"cluster_type": "VirtualMachine", "network_mode": "vpc-router"},
    {"cluster_type": "VirtualMachine"},
    {},
):
    try:
        req = ShowClusterSupportConfigurationRequest(**params)
        resp = client.show_cluster_support_configuration(req)
        d = resp.to_dict()
        print(f"=== params={params or 'none'} -> keys={list(d)}")
        vers = d.get("versions") or []
        print(f"    versions: {len(vers)}")
        if vers:
            print("    first:", json.dumps(vers[0], ensure_ascii=False)[:300])
    except Exception as exc:  # noqa: BLE001
        print(f"=== params={params or 'none'} -> ERROR {type(exc).__name__}: {exc}")
