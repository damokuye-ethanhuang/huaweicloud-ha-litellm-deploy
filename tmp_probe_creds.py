#!/usr/bin/env python3
"""Compare BasicCredentials vs GlobalCredentials for the CCE call."""
import os

from huaweicloudsdkcore.auth.credentials import BasicCredentials, GlobalCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest

region = "cn-southwest-2"
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()
ep = Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com")

for name, cred in (
    ("BasicCredentials(project)", BasicCredentials(ak, sk, region)),
    ("GlobalCredentials", GlobalCredentials(ak, sk)),
):
    try:
        client = CceClient.new_builder().with_credentials(cred).with_region(ep).build()
        r = client.show_cluster_support_configuration(
            ShowClusterSupportConfigurationRequest(cluster_type="VirtualMachine", network_mode="vpc-router")
        )
        d = r.to_dict()
        print(f"{name}: OK versions={len(d.get('versions') or [])}")
    except Exception as exc:  # noqa: BLE001
        msg = str(exc).split("error_msg:")[-1][:150]
        print(f"{name}: FAIL {msg}")
