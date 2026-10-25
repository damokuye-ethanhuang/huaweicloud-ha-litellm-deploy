#!/usr/bin/env python3
"""Ask CCE which cluster versions it will actually accept in cn-southwest-2.

There is no 'list supported versions' API. The practical answer comes from
POST /api/v3/projects/{id}/clusters validation: an unsupported or EOS version
is rejected with a version error before anything is created.
"""
import json
import os
import urllib.error
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
    tok = resp.headers["X-Subject-Token"]
    pid = json.load(resp)["token"]["project"]["id"]

# Dry-run style probe: send a deliberately invalid cluster to learn what the
# error message says. If it complains about something OTHER than the version,
# the version itself passed validation.
probe = {
    "kind": "Cluster",
    "apiVersion": "v3",
    "metadata": {"name": "version-probe"},
    "spec": {
        "type": "VirtualMachine",
        "flavor": "cce.s1.small",
        "version": "v1.34",
        "hostNetwork": {"vpc": "00000000-0000-0000-0000-000000000000",
                        "subnet": "00000000-0000-0000-0000-000000000000"},
        "containerNetwork": {"mode": "vpc-router"},
    },
}
r = urllib.request.Request(f"https://cce.{region}.myhuaweicloud.com/api/v3/projects/{pid}/clusters",
                           data=json.dumps(probe).encode(), method="POST")
r.add_header("Content-Type", "application/json")
r.add_header("X-Auth-Token", tok)
try:
    with urllib.request.urlopen(r, timeout=30) as resp:
        print("HTTP", resp.status, resp.read()[:300])
except urllib.error.HTTPError as exc:
    txt = exc.read().decode("utf-8", "replace")
    print("HTTP", exc.code)
    print(txt[:600])
