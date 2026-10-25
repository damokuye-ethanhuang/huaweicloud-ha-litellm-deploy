#!/usr/bin/env python3
"""Dump the signed CCE request headers the SDK actually sends."""
import os

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkcce.v3 import CceClient, ShowClusterSupportConfigurationRequest

region = "cn-southwest-2"
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

orig = BasicCredentials.sign_request


def spy(self, request):
    out = orig(self, request)
    print("=== signed headers ===")
    for k, v in sorted(out.header_params.items()):
        shown = v if k.lower() != "authorization" else v[:80] + "..."
        print(f"  {k}: {shown}")
    print(f"=== method={out.method} url={out.url}")
    return out


BasicCredentials.sign_request = spy

client = (
    CceClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, region))
    .with_region(Region(id=region, endpoint=f"https://cce.{region}.myhuaweicloud.com"))
    .build()
)
try:
    r = client.show_cluster_support_configuration(
        ShowClusterSupportConfigurationRequest(cluster_type="VirtualMachine", network_mode="vpc-router")
    )
    print("OK", len(r.to_dict().get("versions") or []))
except Exception as exc:  # noqa: BLE001
    print("FAIL", str(exc)[:200])
