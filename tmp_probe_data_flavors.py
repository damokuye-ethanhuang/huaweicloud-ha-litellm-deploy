#!/usr/bin/env python3
"""Check RDS PostgreSQL and DCS Redis HA flavors exist in cn-southwest-2."""
import os

from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkcore.region.region import Region
from huaweicloudsdkrds.v3 import RdsClient, ListFlavorsRequest as RdsListFlavors

region = "cn-southwest-2"
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()
pid = os.environ["HW_PROJECT_ID"]


def region_obj(svc):
    return Region(id=region, endpoint=f"https://{svc}.{region}.myhuaweicloud.com")


rds = (RdsClient.new_builder()
       .with_credentials(BasicCredentials(ak, sk, pid))
       .with_region(region_obj("rds")).build())

print("=== RDS PostgreSQL HA flavors ===")
try:
    r = rds.list_flavors(RdsListFlavors(database_name="PostgreSQL", version_name="16"))
    fl = r.flavors or []
    print(f"  total={len(fl)}")
    for f in fl:
        d = f.to_dict() if hasattr(f, "to_dict") else {}
        code = d.get("spec_code", "")
        if ".ha" in code or d.get("instance_mode") == "ha":
            azs = d.get("instance_flavors") or []
            names = sorted({(a.get("az_desc") or a.get("code") or "") for a in azs})
            print(f"  {code:<32} vcpu={d.get('vcpu')} mem={d.get('mem')}G mode={d.get('instance_mode')}")
            print(f"      azs: {names[:8]}")
except Exception as exc:  # noqa: BLE001
    print("  RDS ERROR", str(exc)[:250])

print("\n=== DCS Redis HA flavors ===")
try:
    from huaweicloudsdkdcs.v2 import DcsClient, ListFlavorsRequest as DcsFlavors
    dcs = (DcsClient.new_builder()
           .with_credentials(BasicCredentials(ak, sk, pid))
           .with_region(region_obj("dcs")).build())
    for cap in ("ha", "single"):
        try:
            r = dcs.list_flavors(DcsFlavors(capacity=cap))
            for f in (r.flavors or []):
                d = f.to_dict() if hasattr(f, "to_dict") else {}
                print(f"  {d.get('spec_code','?'):<32} cap={d.get('capacity')} "
                      f"mem={d.get('max_memory')} az={str(d.get('availability_zones'))[:70]}")
        except Exception as exc:  # noqa: BLE001
            print(f"  capacity={cap} ERROR {str(exc)[:160]}")
except Exception as exc:  # noqa: BLE001
    print("  DCS ERROR", str(exc)[:200])
