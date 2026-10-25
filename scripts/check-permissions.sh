#!/usr/bin/env bash
# Read-only permission probe: can this identity see the services the deployment
# touches? Anything 403 here fails later at `apply`, not at `plan`, so run this
# before the first apply.
#
# Uses list calls only. Creates nothing. Safe to run against production.
#
#   ./scripts/check-permissions.sh
#   ./scripts/check-permissions.sh --json
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO/scripts/lib.sh"

JSON=0
[ "${1:-}" = "--json" ] && JSON=1

load_credentials || die "no credentials: ./scripts/creds.sh set, or export HW_ACCESS_KEY / HW_SECRET_KEY"

REGION="$(grep -A1 '  - key: region' "$REPO/deploy-inputs.yaml" | grep 'value:' | awk '{print $2}' | tr -d '"')"
REGION="${REGION:-${HW_REGION_NAME:-cn-southwest-2}}"

PY=""
for candidate in "$REPO/.venv-sdk/bin/python" python3; do
  if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
done
[ -n "$PY" ] || die "python3 required"

log "probing $REGION with read-only list calls"

"$PY" - "$REGION" "$JSON" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

region = sys.argv[1]
as_json = sys.argv[2] == "1"
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()


def token_and_project():
    body = json.dumps({
        "auth": {"identity": {"methods": ["hw_ak_sk"],
                              "hw_ak_sk": {"access": {"key": ak},
                                           "secret": {"key": sk}}},
                 "scope": {"project": {"name": region}}},
    })
    req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens",
                                 data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json;charset=utf8")
    req.add_header("X-Sdk-Date",
                   datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.headers["X-Subject-Token"], json.load(resp)["token"]["project"]["id"]


try:
    token, pid = token_and_project()
except Exception as exc:  # noqa: BLE001
    print(f"[fail] IAM token failed: {exc}", file=sys.stderr)
    sys.exit(3)

# One read-only call per service. Paths are the documented list endpoints.
# method matters: KMS lists keys with POST, everything else is GET.
CHECKS = [
    ("VPC",   "GET",  f"https://vpc.{region}.myhuaweicloud.com/v1/{pid}/vpcs", None),
    ("EIP",   "GET",  f"https://vpc.{region}.myhuaweicloud.com/v1/{pid}/publicips", None),
    ("VPCEP", "GET",  f"https://vpcep.{region}.myhuaweicloud.com/v1/{pid}/vpc-endpoints?limit=1", None),
    ("NAT",   "GET",  f"https://nat.{region}.myhuaweicloud.com/v2/{pid}/nat_gateways?limit=1", None),
    ("ECS",   "GET",  f"https://ecs.{region}.myhuaweicloud.com/v1/{pid}/cloudservers/detail?limit=1", None),
    ("CCE",   "GET",  f"https://cce.{region}.myhuaweicloud.com/api/v3/projects/{pid}/clusters", None),
    ("ELB",   "GET",  f"https://elb.{region}.myhuaweicloud.com/v3/{pid}/elb/loadbalancers?limit=1", None),
    ("RDS",   "GET",  f"https://rds.{region}.myhuaweicloud.com/v3/{pid}/instances?limit=1", None),
    ("DCS",   "GET",  f"https://dcs.{region}.myhuaweicloud.com/v2/{pid}/instances?limit=1", None),
    ("KMS",   "POST", f"https://kms.{region}.myhuaweicloud.com/v1.0/{pid}/kms/list-keys", {"limit": 1}),
    ("LTS",   "GET",  f"https://lts.{region}.myhuaweicloud.com/v2/{pid}/groups", None),
    ("CES",   "GET",  f"https://ces.{region}.myhuaweicloud.com/V1.0/{pid}/alarms?limit=1", None),
    ("SMN",   "GET",  f"https://smn.{region}.myhuaweicloud.com/v2/{pid}/notifications/topics?limit=1", None),
]

results = []
for name, method, url, payload in CHECKS:
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Auth-Token", token)
    # LTS rejects requests without a Content-Type even when there is no body.
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            results.append({"service": name, "status": resp.status, "ok": True,
                            "detail": "readable"})
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        # Only 401/403 mean "this identity may not do it". A 400/404/405 means
        # this probe called the wrong path or method - that says nothing about
        # permissions, so never report it as a permission failure.
        if exc.code in (401, 403):
            results.append({"service": name, "status": exc.code, "ok": False,
                            "detail": "forbidden", "raw": body[:120]})
        else:
            results.append({"service": name, "status": exc.code, "ok": None,
                            "detail": f"probe inconclusive (HTTP {exc.code})",
                            "raw": body[:120]})
    except Exception as exc:  # noqa: BLE001
        results.append({"service": name, "status": 0, "ok": None,
                        "detail": f"{type(exc).__name__}"})

if as_json:
    print(json.dumps({"region": region, "project_id": pid, "results": results},
                     indent=2, ensure_ascii=False))
else:
    print(f"region {region}  project {pid}\n")
    print(f"{'SERVICE':<8} {'RESULT':<12} DETAIL")
    for r in results:
        mark = "ok" if r["ok"] is True else ("skip" if r["ok"] is None else "FAIL")
        print(f"{r['service']:<8} {mark:<12} {r['detail']}")
    bad = [r["service"] for r in results if r["ok"] is False]
    print()
    if bad:
        print(f"[fail] no read access: {', '.join(bad)}")
        print("       these fail at apply, not plan - grant the role first")
        sys.exit(1)
    print("[ ok ] every service the deployment touches is readable")
PY
