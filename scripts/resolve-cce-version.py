#!/usr/bin/env python3
"""Resolve the CCE cluster versions cn-southwest-2 accepts, and write the newest
usable one into deploy-inputs.yaml.

How the answer is obtained (in order, each step falling back to the next):

1. Official bulletin page - the CCE Kubernetes version lifecycle table states
   which minors are commercial, public beta, or EOS. This is the source of truth
   for "what exists", and it is what Huawei's own docs tell operators to read.
2. Live API probe - POST a cluster-create request that is deliberately invalid
   in a harmless way (fake VPC id) and read the error. If the service complains
   about the VPC and not the version, the version is accepted here.

There is no "list supported cluster versions" API: ShowVersion returns API
metadata (the string "v3"), and ListReleases is not published in every region
(cn-southwest-2 answers 404). Do not "fix" this script by calling them again.

  scripts/resolve-cce-version.py                 # query and write
  scripts/resolve-cce-version.py --json          # machine readable
  scripts/resolve-cce-version.py --dry-run       # show, do not write
  scripts/resolve-cce-version.py --probe v1.34   # is this version accepted now?

Exit codes: 0 ok, 2 could not resolve, 3 SDK or credentials unavailable,
4 the requested version is not accepted.
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

# Official CCE Kubernetes version strategy bulletin. Huawei keeps this page
# current; the console rule it documents is "latest 3 commercial + newest beta".
BULLETIN = "https://support.huaweicloud.com/intl/zh-cn/bulletin-cce/cce_bulletin_0033.html"

# Shown when the bulletin cannot be fetched or parsed. Verified against the
# bulletin on 2026-10-25; treat as a floor, never as the authority.
FALLBACK_VERSIONS = ["v1.30", "v1.31", "v1.32", "v1.33", "v1.34"]


def die(msg: str, code: int) -> None:
    print(f"[fail] {msg}", file=sys.stderr)
    sys.exit(code)


def input_value(key: str) -> str:
    # [^"\n]* not +: the value may legitimately be empty ("") - that is how
    # "resolve at deploy time" is expressed, and requiring a character made
    # write_version silently skip while reporting success.
    m = re.search(rf'  - key: {key}\n    value: "?([^"\n]*)"?', INPUTS.read_text(encoding="utf-8"))
    return (m.group(1) or "").strip() if m else ""


def version_key(v: str) -> tuple:
    m = re.match(r"v(\d+)\.(\d+)", v)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


# --------------------------------------------------------------------------- #
# 1. bulletin
# --------------------------------------------------------------------------- #
def versions_from_bulletin(url: str = BULLETIN) -> dict:
    """Parse the lifecycle table into commercial/beta/EOS buckets."""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8", "replace")

    text = re.sub(r"<script.*?</script>|<style.*?</style>", "", raw, flags=re.S)
    text = re.sub(r"<[^>]+>", "\n", text)
    import html as _html
    text = _html.unescape(text)
    flat = "\n".join(line.strip() for line in text.split("\n") if line.strip())

    rows = re.findall(
        r"(v1\.\d{2})\s*\n\s*([^\n]{0,12})\s*\n\s*[^\n]{0,20}\n\s*(\d{4}年\d{2}月)\s*\n\s*"
        r"(\d{4}年\d{2}月)\s*\n\s*(\d{4}年\d{2}月)\s*\n\s*(\d{4}年\d{2}月)",
        flat,
    )

    commercial: list[str] = []
    beta: list[str] = []
    eos: list[str] = []
    seen: set[str] = set()
    for ver, state, _b, _c, _ga, _e in rows:
        if ver in seen:
            continue
        seen.add(ver)
        if "已商用" in state:
            commercial.append(ver)
        elif "公测" in state:
            beta.append(ver)
        elif "EOS" in state or "停止服务" in state:
            eos.append(ver)

    return {
        "source": url,
        "commercial": sorted(commercial, key=version_key, reverse=True),
        "beta": sorted(beta, key=version_key, reverse=True),
        "eos": sorted(eos, key=version_key, reverse=True),
    }


# --------------------------------------------------------------------------- #
# 2. credentials + live probe
# --------------------------------------------------------------------------- #
def credentials() -> tuple[str, str, str]:
    ak = os.environ.get("HW_ACCESS_KEY", "")
    sk = os.environ.get("HW_SECRET_KEY", "")
    project = os.environ.get("HW_PROJECT_ID", "")
    if not (ak and sk):
        env_file = REPO / "secrets" / "hw.env"
        if env_file.is_file():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.strip().strip('"').strip("'")
                if key == "HW_ACCESS_KEY":
                    ak = ak or value
                elif key == "HW_SECRET_KEY":
                    sk = sk or value
                elif key == "HW_PROJECT_ID" and not project:
                    project = project or value
    return ak, sk, project


def _iam_token(ak: str, sk: str, region: str) -> tuple[str, str]:
    """AK/SK -> token + project id, scoped to the region's project.

    The SDK's BasicCredentials signs requests with X-Project-Id; passing the
    region *name* there yields 401 'get token error'. Resolve the real project
    id first instead.
    """
    from datetime import datetime, timezone

    body = json.dumps({
        "auth": {
            "identity": {"methods": ["hw_ak_sk"],
                         "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
            "scope": {"project": {"name": region}},
        }
    })
    req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens",
                                 data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json;charset=utf8")
    req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    with urllib.request.urlopen(req, timeout=20) as resp:
        token = resp.headers["X-Subject-Token"]
        project_id = json.load(resp)["token"]["project"]["id"]
    return token, project_id


def probe_version(region: str, version: str) -> tuple[bool, str]:
    """Return (accepted, message) for one cluster version.

    Sends a create request with a bogus VPC id. A version error means the
    version is rejected; a VPC error means the version passed validation.
    """
    ak, sk, _ = credentials()
    if not (ak and sk):
        die("no credentials: ./scripts/creds.sh set, or export HW_ACCESS_KEY / HW_SECRET_KEY", 3)

    try:
        token, project_id = _iam_token(ak, sk, region)
    except Exception as exc:  # noqa: BLE001
        die(f"IAM token failed for {region}: {exc}", 2)

    body = {
        "kind": "Cluster",
        "apiVersion": "v3",
        "metadata": {"name": "version-probe"},
        "spec": {
            "type": "VirtualMachine",
            "flavor": "cce.s1.small",
            "version": version,
            "hostNetwork": {"vpc": "00000000-0000-0000-0000-000000000000",
                            "subnet": "00000000-0000-0000-0000-000000000000"},
            "containerNetwork": {"mode": "vpc-router"},
        },
    }
    url = f"https://cce.{region}.myhuaweicloud.com/api/v3/projects/{project_id}/clusters"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Auth-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
            return True, "created?! unreachable in practice"
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
        low = text.lower()
        # The generic envelope always says "Invalid request." - match only
        # messages that are genuinely about the version, not the envelope.
        version_rejected = any(
            p in low for p in ("version not support", "unsupported version",
                               "version is not supported", "invalid version",
                               "cluster version", "version has reached eos",
                               "eos version")
        )
        if version_rejected:
            return False, text[:240]
        return True, text[:240]
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"


def resolve(region: str, probe: bool) -> dict:
    info: dict = {"region": region}
    try:
        info.update(versions_from_bulletin())
        info["bulletin_ok"] = True
    except Exception as exc:  # noqa: BLE001
        info.update({"source": BULLETIN, "commercial": [], "beta": [], "eos": [],
                     "bulletin_ok": False, "bulletin_error": str(exc)[:160]})

    usable = list(info["commercial"]) + list(info["beta"])
    if not usable:
        usable = list(FALLBACK_VERSIONS)
        info["used_fallback"] = True
    usable.sort(key=version_key, reverse=True)
    info["usable"] = usable
    info["console_create"] = (info["commercial"][:3] + info["beta"][:1]) if info["commercial"] else usable[:3]

    if probe and usable:
        accepted, msg = probe_version(region, usable[0])
        info["probe"] = {"version": usable[0], "accepted": accepted, "detail": msg}
    return info


def write_version(version: str) -> bool:
    text = INPUTS.read_text(encoding="utf-8")
    new, n = re.subn(r'(  - key: cce_cluster_version\n    value: )"?[^"\n]*"?',
                     rf'\1"{version}"', text, count=1)
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
    ap.add_argument("--no-probe", action="store_true", help="skip the live API check")
    ap.add_argument("--probe", metavar="VERSION", help="check one version and exit")
    args = ap.parse_args()

    region = args.region or input_value("region")
    if not region:
        die("region not found in deploy-inputs.yaml", 2)

    if args.probe:
        ok, msg = probe_version(region, args.probe)
        print(f"{region} {args.probe}: {'accepted' if ok else 'REJECTED'}")
        print(f"  {msg}")
        return 0 if ok else 4

    info = resolve(region, probe=not args.no_probe)
    usable = info["usable"]
    if not usable:
        die("no usable CCE version determined", 2)

    latest = usable[0]
    current = input_value("cce_cluster_version")
    payload = {**info, "latest": latest, "current": current}

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    print(f"region     {region}")
    print(f"latest     {latest}")
    print(f"current    {current}")
    print(f"usable     {', '.join(usable[:8])}")
    if info.get("commercial"):
        print(f"commercial {', '.join(info['commercial'][:6])}")
    if info.get("eos"):
        print(f"eos        {', '.join(info['eos'][:6])}")
    print(f"source     {info['source']}" + ("" if info.get("bulletin_ok") else "  [UNREACHABLE - using fallback]"))
    if "probe" in info:
        p = info["probe"]
        print(f"probe      {p['version']} -> {'accepted' if p['accepted'] else 'REJECTED'}")

    if args.dry_run:
        return 0
    if current != latest and write_version(latest):
        print(f"\nwrote cce_cluster_version = {latest} to deploy-inputs.yaml")
    else:
        print("\nalready up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
