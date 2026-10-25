#!/usr/bin/env python3
"""Resolve the availability zones to deploy into, then write them into
deploy-inputs.yaml.

Order of preference:

1. `az_policy: auto` (default) - ask the region which AZs currently accept new
   resources (ECS os-availability-zone plus a per-AZ flavor check), then apply
   `az_preferred` to pick among them. Preference wins only for AZs the region
   actually reports; a dead AZ is never chosen just because it is preferred.
2. `az_policy: fixed` - use `az_list` exactly as written.

Why prefer rather than hardcode: in cn-southwest-2 the live AZs are 2a/2d/2e/2f
(there is no 2b/2c), and 2a is the older one. Deploying there by accident is
legal but not what we want, so 2d/2e/2f are preferred when present.

  scripts/resolve-az.py                 # query and write
  scripts/resolve-az.py --json          # machine readable
  scripts/resolve-az.py --dry-run       # show, do not write

Exit codes: 0 ok, 2 could not determine AZs, 3 credentials unavailable.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INPUTS = REPO / "deploy-inputs.yaml"

# Enough for a 3-AZ spread; RDS/DCS primary/standby take the first two.
NEED = 3


def die(msg: str, code: int) -> None:
    print(f"[fail] {msg}", file=sys.stderr)
    sys.exit(code)


def input_value(key: str) -> str:
    m = re.search(rf'  - key: {key}\n    value: "?([^"\n]+)"?', INPUTS.read_text(encoding="utf-8"))
    return m.group(1) if m else ""


def input_list(key: str) -> list[str]:
    m = re.search(rf'  - key: {key}\n    value: \[([^\]]*)\]', INPUTS.read_text(encoding="utf-8"))
    if not m:
        return []
    return [x.strip().strip('"').strip("'") for x in m.group(1).split(",") if x.strip()]


def credentials() -> tuple[str, str]:
    ak = os.environ.get("HW_ACCESS_KEY", "")
    sk = os.environ.get("HW_SECRET_KEY", "")
    if not (ak and sk):
        env_file = REPO / "secrets" / "hw.env"
        if env_file.is_file():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                v = v.strip().strip('"').strip("'")
                if k == "HW_ACCESS_KEY":
                    ak = ak or v
                elif k == "HW_SECRET_KEY":
                    sk = sk or v
    return ak, sk


def iam_token(ak: str, sk: str, region: str) -> tuple[str, str]:
    from datetime import datetime, timezone

    body = json.dumps({
        "auth": {"identity": {"methods": ["hw_ak_sk"],
                              "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
                 "scope": {"project": {"name": region}}},
    })
    req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens",
                                 data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json;charset=utf8")
    req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.headers["X-Subject-Token"], json.load(resp)["token"]["project"]["id"]


def list_azs(region: str) -> list[str]:
    """AZs the region reports as available."""
    ak, sk = credentials()
    if not (ak and sk):
        die("no credentials: ./scripts/creds.sh set, or export HW_ACCESS_KEY / HW_SECRET_KEY", 3)
    token, project_id = iam_token(ak, sk, region)

    url = f"https://ecs.{region}.myhuaweicloud.com/v2/{project_id}/os-availability-zone"
    req = urllib.request.Request(url, method="GET")
    req.add_header("X-Auth-Token", token)
    with urllib.request.urlopen(req, timeout=25) as resp:
        data = json.load(resp)

    zones = []
    for zone in data.get("availabilityZoneInfo", []):
        name = zone.get("zoneName")
        state = (zone.get("zoneState") or {}).get("available")
        if name and state is not False:
            zones.append(name)
    return sorted(zones)


def az_has_capacity(region: str, az: str, flavor: str) -> bool:
    """True when the flavor is offered in this AZ."""
    ak, sk = credentials()
    token, project_id = iam_token(ak, sk, region)
    url = (f"https://ecs.{region}.myhuaweicloud.com/v2/{project_id}/cloudservers/flavors"
           f"?availability_zone={az}&limit=2000")
    req = urllib.request.Request(url, method="GET")
    req.add_header("X-Auth-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        names = {f.get("name") for f in data.get("flavors", [])}
        return flavor in names
    except Exception:  # noqa: BLE001 - endpoint unavailable: do not exclude the AZ
        return True


def choose(available: list[str], preferred: list[str]) -> tuple[list[str], list[str]]:
    """Pick the preferred AZs that exist, topped up from the rest."""
    present = [a for a in preferred if a in available]
    leftovers = [a for a in available if a not in present]
    chosen = present + leftovers
    return chosen[:NEED], present


def write_azs(azs: list[str]) -> bool:
    text = INPUTS.read_text(encoding="utf-8")
    rendered = ", ".join(f'"{a}"' for a in azs)
    new, n = re.subn(r'(  - key: az_list\n    value: )\[[^\]]*\]', rf'\1[{rendered}]', text, count=1)
    if n == 0:
        return False
    INPUTS.write_text(new, encoding="utf-8")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    region = args.region or input_value("region")
    policy = input_value("az_policy") or "auto"
    preferred = input_list("az_preferred")
    current = input_list("az_list")
    flavor = input_value("cce_node_flavor") or "c7.xlarge.2"

    if not region:
        die("region not found in deploy-inputs.yaml", 2)

    if policy == "fixed":
        payload = {"region": region, "policy": "fixed", "az_list": current,
                   "preferred": preferred, "changed": False}
        if args.json:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
        else:
            print(f"region     {region}")
            print("policy     fixed")
            print(f"az_list    {', '.join(current)}")
            print("\nnot changed (az_policy: fixed)")
        return 0

    try:
        available = list_azs(region)
    except Exception as exc:  # noqa: BLE001
        die(f"could not list AZs for {region}: {exc}", 2)

    with_flavor = [a for a in available if az_has_capacity(region, a, flavor)]
    chosen, present = choose(with_flavor, preferred)
    payload = {
        "region": region,
        "policy": policy,
        "available": available,
        "with_flavor": with_flavor,
        "preferred": preferred,
        "preferred_present": present,
        "az_list": chosen,
        "changed": chosen != current,
    }

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    print(f"region     {region}")
    print(f"policy     {policy}")
    print(f"available  {', '.join(available)}")
    print(f"{flavor:<10} {', '.join(with_flavor) if with_flavor else '(none reported; using all)'}")
    print(f"preferred  {', '.join(present) if present else '(none of the preferred AZs exist here)'}")
    print(f"chosen     {', '.join(chosen)}")
    if len(chosen) < NEED:
        print(f"\n[warn] only {len(chosen)} AZ(s) usable; RDS/DCS need two for primary/standby")

    if args.dry_run:
        return 0
    if chosen != current and write_azs(chosen):
        print(f"\nwrote az_list = {chosen} to deploy-inputs.yaml")
    else:
        print("\nalready up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
