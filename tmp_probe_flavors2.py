#!/usr/bin/env python3
"""List ECS flavors per AZ via the ECS SDK (nova-style API)."""
import os

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkecs.v2 import EcsClient, ListFlavorsRequest

region = "cn-southwest-2"
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()
pid = os.environ["HW_PROJECT_ID"]

client = (
    EcsClient.new_builder()
    .with_credentials(BasicCredentials(ak, sk, pid))
    .with_region(Region(id=region, endpoint=f"https://ecs.{region}.myhuaweicloud.com"))
    .build()
)

for az in ("cn-southwest-2d", "cn-southwest-2e", "cn-southwest-2f"):
    try:
        r = client.list_flavors(ListFlavorsRequest(availability_zone=az))
        fl = r.flavors or []
        c7 = [f for f in fl if (f.name or "").startswith("c7.")]
        print(f"{az}: total={len(fl)} c7={len(c7)}")
        for f in sorted(c7, key=lambda x: (x.vcpus or 0, x.ram or 0)):
            print(f"   {f.name:<16} {f.vcpus}C/{(f.ram or 0)//1024}G")
    except Exception as exc:  # noqa: BLE001
        print(f"{az}: ERROR {str(exc)[:150]}")
