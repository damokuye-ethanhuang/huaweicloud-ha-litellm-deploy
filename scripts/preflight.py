#!/usr/bin/env python3
"""Validate deploy-inputs.yaml and render every artifact downstream needs.

Outputs (all regenerated on each run):
  terraform/examples/cce-ha/terraform.tfvars   terraform inputs
  out/helm-values.yaml                         Helm values (no secrets)
  out/models.rendered.yaml                     model_list for litellm-config
  out/deployment-plan.md                       human readable plan
  out/preflight.json                           machine readable report

Exit codes:
  0  ready
  2  blocked: required inputs missing or invalid
  3  environment problem (missing tool, credentials, unreachable endpoint)

Usage:
  scripts/preflight.py                 # validate + render
  scripts/preflight.py --check-only    # validate only
  scripts/preflight.py --json          # JSON report on stdout
  scripts/preflight.py --skip-network  # no outbound probes
"""
from __future__ import annotations

import argparse
import ipaddress
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

REPO = Path(__file__).resolve().parent.parent


def _runtime_home() -> Path:
    """Runtime state lives outside the repository; see scripts/lib.sh."""
    env = os.environ.get("LITELLM_DEPLOY_HOME")
    return Path(env).expanduser() if env else Path.home() / ".litellm-deploy"


RUNTIME_HOME = _runtime_home()
MODELS_FILE = Path(os.environ.get("MODELS_FILE") or (Path(__file__).resolve().parent.parent / "models.yaml"))
INPUTS = REPO / "deploy-inputs.yaml"
PRESETS = REPO / "version-presets.yaml"
TF_DIR = REPO / "terraform" / "examples" / "cce-ha"
OUT_DIR = Path(os.environ.get("OUT_DIR") or RUNTIME_HOME / "out")
SECRETS_DIR = Path(os.environ.get("SECRETS_DIR") or RUNTIME_HOME / "secrets")

OK, WARN, FAIL = "ok", "warn", "fail"


@dataclass
class Result:
    key: str
    status: str
    message: str


@dataclass
class Report:
    results: list[Result] = field(default_factory=list)

    def add(self, key: str, status: str, message: str) -> None:
        self.results.append(Result(key, status, message))

    def counts(self) -> dict[str, int]:
        out = {OK: 0, WARN: 0, FAIL: 0}
        for r in self.results:
            out[r.status] += 1
        return out


def fail(msg: str, code: int = 2) -> None:
    print(f"[fail] {msg}", file=sys.stderr)
    sys.exit(code)


def load(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        import yaml
    except ImportError:
        fail("PyYAML is required: pip install pyyaml", 3)
    if not path.is_file():
        fail(f"inputs file not found: {path}")
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    flat: dict[str, Any] = {}
    for section, items in doc.items():
        if not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict) and "key" in item:
                flat[item["key"]] = item
    return doc, flat


def blank(v: Any) -> bool:
    return v is None or (isinstance(v, str) and not v.strip()) or (isinstance(v, list) and not v)


def required_state(item: dict[str, Any], flat: dict[str, Any]) -> tuple[bool, str]:
    if item.get("required") is True:
        return True, "required"
    spec = item.get("required_if")
    if spec:
        for expr in str(spec).split(","):
            parent, _, expected = expr.partition("=")
            p = flat.get(parent.strip())
            if p and str(p.get("value")) == expected.strip():
                return True, f"required because {parent.strip()}={expected.strip()}"
        return False, ""
    return False, ""


def cidr_err(value: str, private_only: bool = True) -> str | None:
    try:
        net = ipaddress.ip_network(value, strict=False)
    except ValueError as exc:
        return f"not a CIDR ({exc})"
    if net.version != 4:
        return "IPv4 only"
    if private_only and not net.is_private:
        return f"{value} is public; this design is private-only"
    if net.prefixlen < 8:
        return f"{value} is too wide"
    return None


def validate(item: dict[str, Any], flat: dict[str, Any]) -> str | None:
    key, value, rule = item["key"], item.get("value"), item.get("validate")

    if item.get("allowed") and value not in item["allowed"]:
        return f"must be one of {item['allowed']}, got {value!r}"
    rng = item.get("allowed_int_range")
    if rng is not None:
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            return "must be a number"
        if not rng[0] <= value <= rng[1]:
            return f"must be between {rng[0]} and {rng[1]}"
    pattern = item.get("format")
    if pattern and isinstance(value, str) and not re.fullmatch(pattern, value):
        return f"invalid format (expected {pattern})"

    if rule == "cidr_private_v4":
        return cidr_err(str(value))
    if rule == "cidr_public_or_private_list":
        if not isinstance(value, list) or not value:
            return "needs at least one CIDR (office egress /32 recommended)"
        for entry in value:
            try:
                ipaddress.ip_network(str(entry), strict=False)
            except ValueError as exc:
                return f"{entry}: not a CIDR ({exc})"
    if rule == "cidr_private_v4_list":
        if not isinstance(value, list) or not value:
            return "needs at least one private CIDR"
        for entry in value:
            err = cidr_err(str(entry))
            if err:
                return f"{entry}: {err}"
    if rule == "subnet_in_vpc":
        vpc = flat.get("vpc_cidr", {}).get("value")
        entries = value if isinstance(value, list) else [value]
        for entry in entries:
            err = cidr_err(str(entry))
            if err:
                return f"{entry}: {err}"
            if vpc:
                try:
                    if not ipaddress.ip_network(entry, strict=False).subnet_of(
                        ipaddress.ip_network(str(vpc), strict=False)
                    ):
                        return f"{entry} is outside vpc_cidr {vpc}"
                except (ValueError, TypeError):
                    return f"{entry}: cannot compare with vpc_cidr"
    if rule == "ipv4" and value:
        try:
            ipaddress.ip_address(str(value))
        except ValueError:
            return "not an IPv4 address"
    if rule == "uuid" and value:
        if not re.fullmatch(r"[0-9a-fA-F-]{32,36}", str(value)):
            return "not a UUID; copy the ID, not the name"
    if rule == "email" and value:
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", str(value)):
            return "not an email address"
    if key == "az_list" and isinstance(value, list) and value:
        if len(value) < 2:
            return "need at least two AZs for RDS/DCS primary/standby"
    return None


def region_exists(region: str, report: Report) -> None:
    url = f"https://ecs.{region}.myhuaweicloud.com/"
    try:
        with urllib.request.urlopen(url, timeout=8) as resp:
            report.add("region", OK, f"{region} reachable (HTTP {resp.status})")
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            report.add("region", OK, f"{region} reachable (HTTP {exc.code}, auth required)")
        elif exc.code == 404:
            report.add("region", FAIL, f"{region} does not exist (404)")
        else:
            report.add("region", WARN, f"{region} returned HTTP {exc.code}")
    except Exception as exc:  # noqa: BLE001 - network probe
        report.add("region", WARN, f"cannot probe {url}: {exc}")


def tcp_probe(url: str, report: Report, key: str = "grafana_endpoint") -> None:
    parsed = urlparse(url if "//" in url else f"http://{url}")
    host, port = parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)
    if not host:
        report.add(key, FAIL, f"cannot parse host from {url}")
        return
    try:
        with socket.create_connection((host, port), timeout=4):
            report.add(key, OK, f"{host}:{port} reachable")
    except OSError as exc:
        report.add(key, WARN, f"{host}:{port} not reachable from here ({exc}); expected when deploying from outside the VPC")


def tools(report: Report, need_cluster: bool) -> None:
    required = ["terraform", "jq"]
    if need_cluster:
        required += ["helm", "kubectl"]
    for tool in required:
        path = shutil.which(tool)
        report.add(f"tool:{tool}", OK if path else FAIL, path or "missing - see docs/deployment.md")


CRED_FILE = SECRETS_DIR / "hw.env"


def parse_env_file(path: Path) -> dict[str, str]:
    """Read the KEY=VALUE file the operator fills in. No shell, no expansion."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def credentials(report: Report) -> None:
    file_values = parse_env_file(CRED_FILE)
    has_env = bool(os.environ.get("HW_ACCESS_KEY") and os.environ.get("HW_SECRET_KEY"))
    has_file = bool(file_values.get("HW_ACCESS_KEY") and file_values.get("HW_SECRET_KEY"))
    sdk_file = Path(os.path.expanduser("~/.huaweicloud/credentials")).is_file()

    if has_env or has_file:
        where = "environment" if has_env else str(CRED_FILE)
        report.add("credentials", OK, f"AK/SK present from {where} (dedicated IAM user recommended)")
    elif sdk_file:
        report.add("credentials", OK, "AK/SK present in ~/.huaweicloud/credentials")
    else:
        report.add(
            "credentials",
            FAIL,
            f"fill {CRED_FILE} (./scripts/creds.sh set) or export HW_ACCESS_KEY / HW_SECRET_KEY",
        )


def check_subnet_overlaps(flat: dict[str, Any], report: Report) -> None:
    """Overlapping subnets are rejected by the VPC API only after a long apply."""
    keys = [
        "subnet_access_cidr",
        "subnet_app_cidr",
        "subnet_data_cidr",
        "subnet_ops_cidr",
        "subnet_vpce_cidr",
    ]
    nets = {}
    for key in keys:
        value = flat.get(key, {}).get("value")
        if not value:
            continue
        try:
            nets[key] = ipaddress.ip_network(str(value), strict=False)
        except ValueError:
            continue  # reported by the per-field validator

    clashes = [
        f"{a} ({nets[a]}) overlaps {b} ({nets[b]})"
        for i, a in enumerate(nets)
        for b in list(nets)[i + 1 :]
        if nets[a].overlaps(nets[b])
    ]
    if clashes:
        for clash in clashes:
            report.add("subnets-overlap", FAIL, clash)
    else:
        report.add("subnets", OK, f"{len(nets)} subnets, no overlap")


def _net(value):
    try:
        return ipaddress.ip_network(str(value), strict=False)
    except (ValueError, TypeError):
        return None


def check_container_cidr(flat: dict[str, Any], report: Report) -> None:
    """Container CIDR must be disjoint from the VPC and the service range.

    Overlaps are not rejected by CCE at create time; they show up later as
    pods that cannot reach RDS or as a cluster that never becomes ready.
    """
    pod = _net(flat.get("pod_cidr", {}).get("value") or "172.16.0.0/16")
    vpc = _net(flat.get("vpc_cidr", {}).get("value"))
    service = ipaddress.ip_network("10.247.0.0/16")

    if pod is None:
        report.add("container-cidr", FAIL, "pod_cidr is not a valid CIDR")
        return
    clashes = [name for name, net in (("VPC", vpc), ("service", service)) if net and pod.overlaps(net)]
    if clashes:
        report.add(
            "container-cidr",
            FAIL,
            f"pod_cidr {pod} overlaps the {' and '.join(clashes)} range; "
            "the three ranges (VPC / container / service 10.247.0.0/16) must be disjoint",
        )
    else:
        report.add("container-cidr", OK, f"container network {pod} is disjoint from VPC and service ranges")


def check_admin_reach(flat: dict[str, Any], report: Report) -> None:
    """The bastion is in the ops subnet and must be allowed on the gateway SG.

    This is the failure that looks like 'the gateway is up but curl hangs': the
    ELB security group only accepts admin_cidrs, and the ops/access subnets are
    easy to forget because they are not part of 'the customer network'.
    """
    admin = [_net(v) for v in (flat.get("admin_cidrs", {}).get("value") or [])]
    admin = [n for n in admin if n is not None]
    targets = {
        "ops subnet (bastion)": _net(flat.get("subnet_ops_cidr", {}).get("value")),
        "access subnet (ELB VIP)": _net(flat.get("subnet_access_cidr", {}).get("value")),
    }
    missing = [
        label
        for label, target in targets.items()
        if target is not None and not any(a.overlaps(target) for a in admin)
    ]
    if missing:
        report.add(
            "admin-reach",
            WARN,
            "admin_cidrs does not cover " + " or ".join(missing) +
            "; the bastion will not reach the gateway (curl hangs, no 403)",
        )
    else:
        report.add("admin-reach", OK, "admin_cidrs covers the ops and access subnets")


def check_image_supply(flat: dict[str, Any], report: Report) -> None:
    """In swr mode the image must already be in SWR before deploy-app.

    Nodes have no public egress (that is the design), so a pod that references
    an upstream registry simply hangs in ImagePullBackOff. The mirror step is
    therefore part of the deployment, not an optimisation.
    """
    chain = (flat.get("image_supply_chain", {}).get("value") or "swr")
    org = flat.get("swr_org", {}).get("value") or ""
    if chain != "swr":
        report.add("image-supply", OK, f"nodes pull directly from their repository ({chain})")
        return
    if not org:
        report.add("image-supply", FAIL, "image_supply_chain = swr but swr_org is empty")
        return
    report.add(
        "image-supply",
        OK,
        f"bastion -> swr.{flat.get('region', {}).get('value')}.myhuaweicloud.com/{org}/litellm -> pods; "
        "run scripts/mirror-image.sh from the bastion before deploy-app",
    )


# ---------------------------------------------------------------- rendering ---

def _iam(ak: str, sk: str, region: str) -> tuple[str, str]:
    """Return (token, project_id). Shared by the flavor check below."""
    import urllib.request

    body = json.dumps(
        {
            "auth": {
                "identity": {"methods": ["hw_ak_sk"], "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
                "scope": {"project": {"name": region}},
            }
        }
    ).encode()
    req = urllib.request.Request(
        "https://iam.myhuaweicloud.com/v3/auth/tokens", data=body, headers={"Content-Type": "application/json"}
    )
    token = urllib.request.urlopen(req, timeout=20).headers["X-Subject-Token"]
    body = json.dumps(
        {"auth": {"identity": {"methods": ["token"], "token": {"id": token}}, "scope": {"project": {"name": region}}}}
    ).encode()
    req = urllib.request.Request(
        "https://iam.myhuaweicloud.com/v3/auth/tokens", data=body, headers={"Content-Type": "application/json"}
    )
    project = json.loads(urllib.request.urlopen(req, timeout=20).read())["token"]["project"]["id"]
    return token, project


def check_node_flavor(v: dict[str, Any], report: Report, skip_network: bool) -> None:
    """A wrong flavor name only fails after ~10 minutes of cluster creation.

    CCE resolves the node flavor through ECS ExtraSpecs, so the exact string
    matters: `x1.8u16g` is rejected while `x1.8u.16g` is accepted. Verify the
    name against every AZ in the plan before Terraform starts, and normalise
    the common doc-style misspelling when the region confirms the fix.
    """
    import urllib.request

    flavor = str(v.get("node_flavor") or "")
    az_list = [str(az) for az in (v.get("az_list") or [])]
    region = str(v.get("region") or "")
    if not flavor or not az_list or not region:
        return
    if skip_network:
        report.add("flavor:availability", WARN, "network checks skipped: flavor not verified against the region")
        return

    file_values = parse_env_file(CRED_FILE)
    ak = os.environ.get("HW_ACCESS_KEY") or file_values.get("HW_ACCESS_KEY", "")
    sk = os.environ.get("HW_SECRET_KEY") or file_values.get("HW_SECRET_KEY", "")
    if not (ak and sk):
        report.add("flavor:availability", WARN, "no AK/SK: flavor not verified (CCE will reject a bad name mid-apply)")
        return

    try:
        token, project = _iam(ak, sk, region)
    except Exception as exc:  # noqa: BLE001 - offline or bad credentials is a warning here
        report.add("flavor:availability", WARN, f"could not query ECS flavors: {exc}")
        return

    cache: dict[str, set[str]] = {}

    def flavors(az: str) -> set[str]:
        if az not in cache:
            url = f"https://ecs.{region}.myhuaweicloud.com/v1/{project}/cloudservers/flavors?availability_zone={az}"
            req = urllib.request.Request(url, headers={"X-Auth-Token": token})
            data = json.loads(urllib.request.urlopen(req, timeout=30).read())
            cache[az] = {f["name"] for f in data.get("flavors", [])}
        return cache[az]

    try:
        missing = [az for az in az_list if flavor not in flavors(az)]
    except Exception as exc:  # noqa: BLE001
        report.add("flavor:availability", WARN, f"could not query ECS flavors: {exc}")
        return

    if not missing:
        report.add("flavor:availability", OK, f"{flavor} offered in {', '.join(az_list)}")
        return

    # Documented 8C16G spec is written x1.8u.16g; x1.8u16g (or x1.8u.16G) is a
    # frequent paste error and the region list is the authority on the exact name.
    m = re.match(r"^([a-z]+\d*)\.(\d+)u(\d+)g$", flavor, re.IGNORECASE)
    alt = f"{m.group(1)}.{m.group(2)}u.{m.group(3)}g" if m else ""
    if alt and alt != flavor:
        try:
            if all(alt in flavors(az) for az in az_list):
                v["node_flavor"] = alt
                report.add(
                    "flavor:availability",
                    WARN,
                    f"{flavor} is not a real flavor; rendering {alt} instead "
                    f"(set node_flavor: {alt} in deploy-inputs.yaml to silence this)",
                )
                return
        except Exception:  # noqa: BLE001
            pass

    report.add(
        "flavor:availability",
        FAIL,
        f"{flavor} not offered in {', '.join(missing)}; CCE fails node creation with "
        "'GetFlavorExtraSpecs failed: flavor not found'",
    )


def hcl(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, list):
        return "[" + ", ".join(hcl(x) for x in v) + "]"
    if v is None:
        return "null"
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


def merged(flat: dict[str, Any]) -> dict[str, Any]:
    """Effective values with derived switches resolved."""
    v = {k: item.get("value") for k, item in flat.items()}
    # Inputs marked `from_file: true` hold a path; inline the file contents so
    # key material never has to sit in deploy-inputs.yaml or in a commit.
    for key, item in flat.items():
        if not item.get("from_file") or not isinstance(v.get(key), str) or not v[key]:
            continue
        path = Path(v[key])
        if not path.is_absolute():
            path = REPO / path
        try:
            v[key] = path.read_text(encoding="utf-8").strip()
        except OSError:
            v[key] = ""
    tls = v.get("tls_mode")
    v["enable_https"] = tls in ("elb_cert", "internal_ca")
    mode = v.get("model_endpoint_mode")
    # NAT exists only for public model APIs. The intranet default (none) and
    # vpcep both create no NAT: nodes have no public egress.
    v["enable_nat_gateway"] = mode == "nat"
    v["vpce_enabled"] = mode == "vpcep"
    enc = v.get("encryption_mode")
    v["encryption_enabled"] = enc in ("kms", "dew")
    v["create_kms_key"] = enc == "kms"
    v["existing_kms_key_id"] = v.get("existing_kms_key_id") or ""
    v["enable_lts_logs"] = v.get("log_backend") == "lts"
    v["enable_aom"] = v.get("metric_backend") == "aom"
    v["vpn_enabled"] = bool(v.get("vpn_enabled"))
    v["bastion_enabled"] = v.get("bastion_enabled", True)
    return v


def render_tfvars(v: dict[str, Any]) -> str:
    pairs = {
        "region": v.get("region"),
        "site_type": v.get("site_type"),
        "project_name": v.get("project_name"),
        "environment": v.get("environment"),
        "enterprise_project_id": v.get("enterprise_project_id"),
        "vpc_cidr": v.get("vpc_cidr"),
        "az_list": v.get("az_list") or [],
        "access_subnet_cidr": v.get("subnet_access_cidr"),
        "app_subnet_cidr": v.get("subnet_app_cidr"),
        "data_subnet_cidr": v.get("subnet_data_cidr"),
        "ops_subnet_cidr": v.get("subnet_ops_cidr"),
        "vpce_subnet_cidr": v.get("subnet_vpce_cidr"),
        "pod_cidr": v.get("pod_cidr") or "172.16.0.0/16",
        # Must match the Terraform variable default (overlay_l2). Rendering a
        # different model here silently builds a network the docs do not
        # describe - that bug shipped once already.
        "cce_container_network_type": v.get("cce_container_network_type") or "overlay_l2",
        "elb_mode": v.get("elb_mode") or "ingress",
        "elb_l7_flavor_name": v.get("elb_l7_flavor_name") or "L7_flavor.elb.s1.small",
        "cce_node_flavor": v.get("node_flavor"),
        "cce_cluster_flavor": v.get("cce_cluster_flavor") or "cce.s2.large",
        "cce_cluster_version": v.get("cce_cluster_version") or "",
        "bastion_eip_bandwidth_size": v.get("bastion_eip_bandwidth_mbit") or 100,

        "allowed_client_cidrs": v.get("client_cidrs"),
        "admin_access_cidrs": v.get("admin_cidrs"),
        "enable_nat_gateway": v.get("enable_nat_gateway"),
        "nat_eip_bandwidth_size": v.get("nat_bandwidth_mbit") or 100,
        "bastion_enabled": v.get("bastion_enabled", True),
        "bastion_ssh_cidrs": v.get("bastion_ssh_cidrs") or [],
        "bastion_flavor": v.get("bastion_flavor") or "c7.large.2",
        "bastion_public_key": v.get("bastion_public_key") or "",
        "vpn_enabled": v.get("vpn_enabled"),
        "customer_gateway_ip": v.get("customer_gateway_ip") or "0.0.0.0",
        "model_endpoint_mode": v.get("model_endpoint_mode"),
        "image_supply_chain": v.get("image_supply_chain") or "swr",
        "swr_org": v.get("swr_org") or "",
        "modelarts_vpce_service_id": v.get("modelarts_vpce_service_id") or "",
        "vpce_enabled": v.get("vpce_enabled"),
        "tls_mode": v.get("tls_mode"),
        "enable_https": v.get("enable_https"),
        "certificate_id": v.get("certificate_id") or "",
        "encryption_mode": v.get("encryption_mode"),
        "encryption_enabled": v.get("encryption_enabled"),
        "create_kms_key": v.get("create_kms_key"),
        "kms_key_id": v.get("existing_kms_key_id") or null_ok(),
        "enable_lts_logs": v.get("enable_lts_logs"),
        "enable_aom": v.get("enable_aom"),
        "aom_retention": v.get("aom_retention") or "360h",
        "lts_log_ttl_days": v.get("log_retention_days") or 30,
        "alarm_email": v.get("alarm_email") or "",
        "cce_node_count_per_az": v.get("nodes_per_az") or 1,
        "rds_flavor": v.get("rds_flavor"),
        "dcs_flavor": v.get("dcs_flavor"),
        "litellm_version": str(v.get("litellm_version")),
        "charging_mode": v.get("charging_mode") or "postPaid",
        "period": v.get("period_months") or 1,
    }
    lines = [
        "# Generated by scripts/preflight.py from deploy-inputs.yaml.",
        "# Do not edit: change deploy-inputs.yaml and rerun preflight.",
        "",
    ]
    # Align like `terraform fmt` does, so `fmt -check` stays clean after a render.
    width = max(len(k) for k in pairs)
    for key, value in pairs.items():
        lines.append(f"{key} = {hcl(value)}".replace(f"{key} =", f"{key.ljust(width)} =", 1))
    lines += ["", 'tags = {', f'  owner{" " * 8}= {hcl(v.get("owner") or "unknown")}', '  "managed-by" = "terraform"', "}", ""]
    return "\n".join(lines)


def null_ok() -> None:
    return None


def load_models(path: Path) -> dict[str, Any]:
    """models.yaml is phase 3; preflight only reads it under --with-models."""
    import yaml

    if not path.is_file():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def public_endpoint(api_base: str) -> bool:
    """True only for a literal public IP. Hostnames are left alone: resolving
    them offline is not possible and the egress rules are the real control."""
    from urllib.parse import urlparse

    host = urlparse(api_base if "//" in api_base else f"//{api_base}").hostname or ""
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    return not (addr.is_private or addr.is_loopback or addr.is_link_local)


def fallback_pairs(models_doc: dict[str, Any]) -> list[list[str]]:
    """Explicit pairs, or all-to-all when enabled with no pairs listed."""
    fb = models_doc.get("fallbacks") or {}
    names = [m.get("name") for m in (models_doc.get("models") or []) if m.get("name")]
    if fb.get("pairs"):
        return [list(pair) for pair in fb["pairs"]]
    if fb.get("enabled") and len(names) >= 2:
        return [names]
    return []


def render_helm(v: dict[str, Any], flat: dict[str, Any], models_doc: dict[str, Any]) -> str:
    import yaml

    models = [
        {
            "name": m["name"],
            "model": m["model"],
            "api_base": m.get("api_base") or "",
            "api_key_env": m.get("api_key_env") or "MODEL_API_KEY",
            "mode": m.get("mode") or "chat",
            **({"max_tokens": m["max_tokens"]} if m.get("max_tokens") else {}),
            **({"rpm": m["rpm"]} if m.get("rpm") else {}),
            **({"tpm": m["tpm"]} if m.get("tpm") else {}),
        }
        for m in (models_doc.get("models") or [])
    ]
    values = {
        "replicaCount": v.get("litellm_replicas") or 3,
        "image": {"tag": str(v.get("litellm_version"))},
        "models": models,
        "env": {
            "STORE_MODEL_IN_DB": "False",
            "DISABLE_SCHEMA_UPDATE": "true",
        },
        "observability": {
            "grafanaEndpoint": v.get("grafana_endpoint") or "",
            "logBackend": v.get("log_backend"),
            "metricBackend": v.get("metric_backend"),
        },
        # Phase 3. With no models the chart renders model_list: [] and the
        # gateway serves 404 on /v1/chat/completions - by design, that is what
        # makes "app is up" testable without any provider.
        "fallbacks": {
            "enabled": bool((models_doc.get("fallbacks") or {}).get("enabled", False)),
            "cooldownSeconds": int((models_doc.get("fallbacks") or {}).get("cooldown_seconds") or 60),
            "pairs": fallback_pairs(models_doc),
        },
    }
    header = "# Generated by scripts/preflight.py from deploy-inputs.yaml - do not edit.\n"
    return header + yaml.safe_dump(values, sort_keys=False, default_flow_style=False)


def render_models(models_doc: dict[str, Any]) -> str:
    models = models_doc.get("models") or []
    entries = []
    for m in models:
        # Accept both "glm-5.3" and "openai/glm-5.3": the prefix is added once,
        # so a customer can paste either form without producing "openai/openai/...".
        raw_model = str(m["model"])
        model_id = raw_model if "/" in raw_model else f"openai/{raw_model}"
        litellm_params = {
            "model": model_id,
            "api_key": f"os.environ/{m.get('api_key_env') or 'MODEL_API_KEY'}",
        }
        if m.get("api_base"):
            litellm_params["api_base"] = m["api_base"]
        info = {"mode": m.get("mode") or "chat"}
        if m.get("max_tokens"):
            info["max_tokens"] = m["max_tokens"]
        entry: dict[str, Any] = {"model_name": m["name"], "litellm_params": litellm_params, "model_info": info}
        if m.get("rpm"):
            entry["rpm"] = m["rpm"]
        if m.get("tpm"):
            entry["tpm"] = m["tpm"]
        entries.append(entry)
    import yaml

    return "# Generated from models.yaml - do not edit.\n" + yaml.safe_dump(
        {"model_list": entries}, sort_keys=False, default_flow_style=False
    )


def render_plan(v: dict[str, Any], models_doc: dict[str, Any], counts: dict[str, int]) -> str:
    models = models_doc.get("models") or []
    rows = "\n".join(
        f"| `{m['name']}` | {m['model']} | {m.get('mode', 'chat')} | "
        f"{m.get('api_base') or 'default (VPC endpoint)'} | `{m.get('api_key_env')}` |"
        for m in models
    )
    budget = (v.get("litellm_replicas") or 3) * 1 * 10
    return f"""# 部署计划 / Deployment plan

由 `scripts/preflight.py` 从 `deploy-inputs.yaml` 生成，重复运行会覆盖。
Generated from `deploy-inputs.yaml`; rerun preflight to refresh.

预检结果：**{counts[OK]} 通过 / {counts[WARN]} 警告 / {counts[FAIL]} 阻断**

## 命名 / Naming

所有资源以 `{v.get('project_name')}` 为前缀：

| 资源 | 名称 |
|---|---|
| VPC | `{v.get('project_name')}-maas-vpc` |
| 接入/应用/数据/运维/VPCE 子网 | `-maas-access-subnet` / `-maas-app-subnet` / `-maas-data-subnet` / `-maas-ops-subnet` / `-maas-vpce-subnet` |
| 安全组 | `-maas-sg-elb` / `-maas-sg-data` / `-maas-sg-admin` / `-maas-sg-bastion` |
| CCE 集群 | `{v.get('project_name')}-maas-cce` |
| RDS / DCS | `{v.get('project_name')}-maas-rds` / `-maas-dcs` |
| 内网 ELB | `{v.get('project_name')}-maas-elb` |
| 堡垒机 | `{v.get('project_name')}-maas-bastion`（运维子网，唯一公网 EIP） |
| 密钥（CSMS） | `{v.get('project_name')}-litellm-master-key` 等 |

## 网络 / Network

| 项 | 值 |
|---|---|
| 区域 | {v.get('region')} ({v.get('site_type')}) |
| VPC | {v.get('vpc_cidr')} |
| app 子网 | {v.get('subnet_app_cidr')} |
| data 子网 | {v.get('subnet_data_cidr')} |
| 运维子网 | {v.get('subnet_ops_cidr')}（堡垒机所在，可达 VPC 内全部服务） |
| VPCE 子网 | {v.get('subnet_vpce_cidr')} |
| 容器网络 | `{v.get('cce_container_network_type') or 'overlay_l2'}`，网段 {v.get('pod_cidr') or '172.16.0.0/16'}（不占 VPC 地址、不走 VPC 路由） |
| CCE front subnet | access 子网 {v.get('subnet_access_cidr')}（ELB VIP 所在；后端在app 子网 {v.get('subnet_app_cidr')}） |
| 允许调用 | {", ".join(v.get('client_cidrs') or []) or "(未填)"} |
| 允许管理 | {", ".join(v.get('admin_cidrs') or []) or "(未填)"} |
| ELB 来源 | {'Ingress 控制器自动创建（Terraform 不建）' if (v.get('elb_mode') or 'ingress') == 'ingress' else 'Terraform 直接创建'} |
| 网关 VIP | {'apply 后由 Ingress 分配，从 kubectl 读' if (v.get('elb_mode') or 'ingress') == 'ingress' else (v.get('gateway_private_ip') or '由 ELB 分配')} |
| 公网暴露 | **无**（内网 ELB，不绑 EIP） |

## 访问与出口 / Access and egress

| 项 | 值 |
|---|---|
| 模型接入方式 | {v.get('model_endpoint_mode')}（nat 才会建 NAT） |
| 镜像供应链 | {'堡垒机 → SWR → Pod 内网拉取' if (v.get('image_supply_chain') or 'swr') == 'swr' else '节点直连仓库'}（org: {v.get('swr_org') or '未填'}） |
| NAT 网关 | {'创建（仅当模型在公网）' if v.get('enable_nat_gateway') else '不创建（纯内网）'} |
| ModelArts VPCEP | {'启用' if v.get('vpce_enabled') else '未启用'} |
| VPN | {'启用' if v.get('vpn_enabled') else '未启用'} |
| TLS | {v.get('tls_mode')} |
| 加密 | {v.get('encryption_mode')} |

## 模型 / Models

| 对外模型名 | 上游模型 | 模式 | 地址 | 密钥环境变量 |
|---|---|---|---|---|
{rows}

## 观测 / Observability

| 项 | 值 |
|---|---|
| 日志 | {v.get('log_backend')}（保留 {v.get('log_retention_days')} 天） |
| 指标 | {v.get('metric_backend')}（保留 {v.get('aom_retention')}） |
| Grafana | {v.get('grafana_endpoint')}（看板本地编排，云端只存数据） |
| 告警邮件 | {v.get('alarm_email') or "未配置"} |

## 容量 / Capacity

| 项 | 值 |
|---|---|
| 节点规格 / 每 AZ | {v.get('node_flavor')} / {v.get('nodes_per_az')} |
| 网关副本 | {v.get('litellm_replicas')} |
| 数据库连接预算 | {budget} 个（副本 × 工作进程 × 10），须小于 RDS 上限 |
| RDS / DCS 规格 | {v.get('rds_flavor')} / {v.get('dcs_flavor')} |
| LiteLLM 版本 | {v.get('litellm_version')} |

## 引用的渲染产物 / Generated artifacts

| 文件 | 用途 |
|---|---|
| `terraform/examples/cce-ha/terraform.tfvars` | Terraform 输入 |
| `out/helm-values.yaml` | Helm values（不含密钥） |
| `out/models.rendered.yaml` | 合并进 `config/litellm-config.yaml` 的 model_list |
| `out/preflight.json` | 供 agent 判读的结构化结果 |
"""


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", str(value))[:3])


def check_version(value: str, report: Report, ack_upgrade: bool) -> None:
    """Enforce version-presets.yaml so an upgrade cannot silently skip the plan."""
    import yaml

    if not PRESETS.is_file():
        report.add("litellm_version", WARN, "version-presets.yaml missing; cannot enforce the upgrade gate")
        return
    data = yaml.safe_load(PRESETS.read_text(encoding="utf-8")) or {}
    spec = data.get("litellm") or {}
    preset = str(spec.get("preset", ""))
    minimum = str(spec.get("min_supported", "0"))
    maximum = str(spec.get("max_compatible", preset))
    guide = spec.get("upgrade_guide", "docs/upgrade-procedure.md")

    want, base = version_tuple(value), version_tuple(preset)
    if want < version_tuple(minimum):
        report.add("litellm_version", FAIL, f"{value} is below min_supported {minimum}; this chart targets {preset}")
    elif want == base:
        report.add("litellm_version", OK, f"{value} = preset (validated baseline)")
    elif want < base:
        report.add("litellm_version", WARN, f"{value} < preset {preset}: downgrade, migrations are not reversible - take a backup first")
    elif want <= version_tuple(maximum):
        hint = "acknowledged via ACK_UPGRADE=1" if ack_upgrade else "set ACK_UPGRADE=1 once you have run the upgrade procedure"
        report.add(
            "litellm_version",
            OK if ack_upgrade else FAIL,
            f"{value} > preset {preset} but within max_compatible {maximum}: run {guide} first ({hint})",
        )
    else:
        report.add(
            "litellm_version",
            FAIL,
            f"{value} > max_compatible {maximum}: update version-presets.yaml as part of a documented solution update "
            "(release notes review, migration timing on a restored DB, readiness + one successful inference)",
        )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inputs", default=str(INPUTS))
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--skip-network", action="store_true")
    ap.add_argument("--with-models", action="store_true",
                    help="include models.yaml (phase 3); without it the run renders a model-less baseline")
    ap.add_argument("--models", default=str(MODELS_FILE), help="path to models.yaml")
    args = ap.parse_args()

    doc, flat = load(Path(args.inputs).resolve())
    models_path = Path(args.models).resolve()
    models_doc = load_models(models_path) if args.with_models else {}
    report = Report()

    for key, item in flat.items():
        need, why = required_state(item, flat)
        value = item.get("value")
        if need and blank(value) and not isinstance(value, bool):
            report.add(key, FAIL, f"missing ({why})")
            continue
        if key == "bastion_ssh_cidrs" and flat.get("bastion_enabled", {}).get("value") is True and blank(value):
            report.add(key, FAIL, "missing: the bastion has the only public IP; set your office egress CIDR (or disable the bastion)")
            continue
        err = validate(item, flat) if not blank(value) else None
        if err:
            report.add(key, FAIL, err)
            continue
        shown = value if not isinstance(value, list) else (", ".join(map(str, value)) or "(auto)")
        report.add(key, OK, str(shown))

    # Models are phase 3: infrastructure and the gateway baseline must be
    # deployable without any provider, so a missing model list is not a failure.
    if not args.with_models:
        waiting = len((load_models(models_path) or {}).get("models") or [])
        note = "phase 3 (models.yaml): not applied in this run"
        if waiting:
            note += f", {waiting} entr{'y' if waiting == 1 else 'ies'} waiting"
        report.add("models", OK, note)
    else:
        models = models_doc.get("models") or []
        if not models:
            report.add("models", FAIL, f"{models_path.name} defines no models: add entries, or run without --with-models")
        seen: set[str] = set()
        for m in models:
            name = str(m.get("name") or "?")
            missing = [f for f in ("name", "model") if not m.get(f)]
            if missing:
                report.add(f"models[{name}]", FAIL, f"missing fields: {', '.join(missing)}")
                continue
            if name in seen:
                report.add(f"models[{name}]", FAIL, "duplicate name: tenants address a model by name, so it must be unique")
                continue
            seen.add(name)
            api_base = str(m.get("api_base") or "")
            if api_base and public_endpoint(api_base):
                report.add(
                    f"models[{name}]",
                    WARN,
                    f"{api_base} is a public address: the cluster has no egress unless a NAT gateway exists, "
                    "so calls fail until you open one (advisory only, no block)",
                )
            elif not api_base and flat.get("model_endpoint_mode", {}).get("value") != "vpcep":
                report.add(f"models[{name}]", WARN, "no api_base and no ModelArts VPC endpoint: nothing to resolve")
            else:
                report.add(f"models[{name}]", OK, f"{m.get('model')} ({m.get('mode') or 'chat'})")

        fb = models_doc.get("fallbacks") or {}
        for pair in fb.get("pairs") or []:
            unknown = [n for n in pair if n not in seen]
            if unknown:
                report.add("fallbacks", FAIL, f"pair references undefined model(s): {', '.join(map(str, unknown))}")
            elif len(set(pair)) < 2:
                report.add("fallbacks", FAIL, "a pair needs two different models")
            else:
                report.add("fallbacks", OK, " <-> ".join(map(str, pair)))
        if fb.get("enabled") and len(seen) < 2:
            report.add("fallbacks", WARN, "enabled with fewer than two models: nothing to fall back to")

    v = merged(flat)
    check_subnet_overlaps(flat, report)
    check_container_cidr(flat, report)
    check_admin_reach(flat, report)
    check_image_supply(flat, report)
    check_node_flavor(v, report, args.skip_network)
    if not v.get("cce_cluster_version"):
        report.add("cce_cluster_version", WARN, "empty: resolved at deploy time via huaweicloudsdkcce (scripts/resolve-cce-version.py)")
    check_version(str(v.get("litellm_version", "")), report, bool(os.environ.get("ACK_UPGRADE")))
    tools(report, need_cluster=v.get("enable_https") is not None)
    credentials(report)
    if not args.skip_network:
        if v.get("region"):
            region_exists(str(v["region"]), report)
        if v.get("grafana_endpoint"):
            tcp_probe(str(v["grafana_endpoint"]), report)

    if v.get("metric_backend") == "aom" and not v.get("grafana_endpoint"):
        report.add("grafana_endpoint", WARN, "AOM selected but no Grafana endpoint: dashboards have nowhere to live")

    counts = report.counts()
    payload = {"counts": counts, "results": [r.__dict__ for r in report.results]}

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    else:
        for r in report.results:
            marker = {OK: "ok  ", WARN: "warn", FAIL: "FAIL"}[r.status]
            print(f"{marker}  {r.key:<28} {r.message}")
        print(f"\n{counts[OK]} ok, {counts[WARN]} warnings, {counts[FAIL]} blocking")

    if counts[FAIL]:
        if not args.json:
            print("\nFix the FAIL lines in deploy-inputs.yaml and rerun.", file=sys.stderr)
        return 2

    if args.check_only:
        return 0

    # exist_ok=False here would crash on a fresh LITELLM_DEPLOY_HOME; parents=True
    # because the operator may point it at a directory that does not exist yet.
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    TF_DIR.mkdir(parents=True, exist_ok=True)
    (TF_DIR / "terraform.tfvars").write_text(render_tfvars(v), encoding="utf-8")
    (OUT_DIR / "helm-values.yaml").write_text(render_helm(v, flat, models_doc), encoding="utf-8")
    (OUT_DIR / "models.rendered.yaml").write_text(render_models(models_doc), encoding="utf-8")
    (OUT_DIR / "deployment-plan.md").write_text(render_plan(v, models_doc, counts), encoding="utf-8")
    (OUT_DIR / "preflight.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    if not args.json:
        print(f"\nrendered: terraform.tfvars, {OUT_DIR}/helm-values.yaml,")
        print(f"          {OUT_DIR}/models.rendered.yaml, {OUT_DIR}/deployment-plan.md,")
        print(f"          {OUT_DIR}/preflight.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
