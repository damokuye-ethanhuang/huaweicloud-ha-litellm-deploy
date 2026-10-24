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
INPUTS = REPO / "deploy-inputs.yaml"
PRESETS = REPO / "version-presets.yaml"
TF_DIR = REPO / "terraform" / "examples" / "cce-ha"
OUT_DIR = REPO / "out"

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


def credentials(report: Report) -> None:
    cred_file = Path(os.path.expanduser("~/.huaweicloud/credentials"))
    if (os.environ.get("HW_ACCESS_KEY") and os.environ.get("HW_SECRET_KEY")) or cred_file.is_file():
        report.add("credentials", OK, "AK/SK present (dedicated IAM user recommended)")
    else:
        report.add("credentials", FAIL, "export HW_ACCESS_KEY / HW_SECRET_KEY")


# ---------------------------------------------------------------- rendering ---

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
    tls = v.get("tls_mode")
    v["enable_https"] = tls in ("elb_cert", "internal_ca")
    mode = v.get("model_endpoint_mode")
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
        "vpce_subnet_cidr": v.get("subnet_vpce_cidr"),
        "pod_cidr": v.get("pod_cidr") or "172.16.0.0/16",
        "cce_container_network_type": "overlay_l2",
        "cce_node_flavor": v.get("node_flavor"),
        "cce_cluster_version": v.get("cce_cluster_version") or "",
        "bastion_eip_bandwidth_size": v.get("bastion_eip_bandwidth_mbit") or 100,

        "allowed_client_cidrs": v.get("client_cidrs"),
        "admin_access_cidrs": v.get("admin_cidrs"),
        "enable_nat_gateway": v.get("enable_nat_gateway"),
        "nat_eip_bandwidth_size": v.get("nat_bandwidth_mbit") or 100,
        "bastion_enabled": v.get("bastion_enabled", True),
        "bastion_ssh_cidrs": v.get("bastion_ssh_cidrs") or [],
        "bastion_flavor": v.get("bastion_flavor") or "c7.large.2",
        "vpn_enabled": v.get("vpn_enabled"),
        "customer_gateway_ip": v.get("customer_gateway_ip") or "0.0.0.0",
        "model_endpoint_mode": v.get("model_endpoint_mode"),
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
    for key, value in pairs.items():
        lines.append(f"{key} = {hcl(value)}")
    lines += ["", 'tags = {', f'  owner = {hcl(v.get("owner") or "unknown")}', '  "managed-by" = "terraform"', "}", ""]
    return "\n".join(lines)


def null_ok() -> None:
    return None


def render_helm(v: dict[str, Any], flat: dict[str, Any], doc: dict[str, Any]) -> str:
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
        for m in (doc.get("models") or [])
    ]
    values = {
        "replicaCount": v.get("litellm_replicas") or 3,
        "image": {"tag": str(v.get("litellm_version"))},
        "models": models,
        "env": {
            "STORE_MODEL_IN_DB": "True",
            "DISABLE_SCHEMA_UPDATE": "true",
        },
        "observability": {
            "grafanaEndpoint": v.get("grafana_endpoint") or "",
            "logBackend": v.get("log_backend"),
            "metricBackend": v.get("metric_backend"),
        },
    }
    header = "# Generated by scripts/preflight.py from deploy-inputs.yaml - do not edit.\n"
    return header + yaml.safe_dump(values, sort_keys=False, default_flow_style=False)


def render_models(doc: dict[str, Any]) -> str:
    models = doc.get("models") or []
    entries = []
    for m in models:
        litellm_params = {
            "model": f"openai/{m['model']}",
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

    return "# Generated from deploy-inputs.yaml models[] - do not edit.\n" + yaml.safe_dump(
        {"model_list": entries}, sort_keys=False, default_flow_style=False
    )


def render_plan(v: dict[str, Any], doc: dict[str, Any], counts: dict[str, int]) -> str:
    models = doc.get("models") or []
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
| 接入/应用/数据/VPCE 子网 | `-maas-access-subnet` / `-maas-app-subnet` / `-maas-data-subnet` / `-maas-vpce-subnet` |
| 安全组 | `-maas-sg-elb` / `-maas-sg-data` / `-maas-sg-admin` / `-maas-sg-bastion` |
| CCE 集群 | `{v.get('project_name')}-maas-cce` |
| RDS / DCS | `{v.get('project_name')}-maas-rds` / `-maas-dcs` |
| 内网 ELB | `{v.get('project_name')}-maas-elb` |
| 跳板机 | `{v.get('project_name')}-maas-bastion`（唯一公网 EIP） |
| 密钥（CSMS） | `{v.get('project_name')}-litellm-master-key` 等 |

## 网络 / Network

| 项 | 值 |
|---|---|
| 区域 | {v.get('region')} ({v.get('site_type')}) |
| VPC | {v.get('vpc_cidr')} |
| 应用子网 | {v.get('subnet_app_cidr')} |
| 数据子网 | {v.get('subnet_data_cidr')} |
| VPCE 子网 | {v.get('subnet_vpce_cidr')} |
| 容器网段 | {", ".join(v.get('subnet_eni_cidrs') or [])} |
| 允许调用 | {", ".join(v.get('client_cidrs') or []) or "(未填)"} |
| 允许管理 | {", ".join(v.get('admin_cidrs') or []) or "(未填)"} |
| 网关 VIP | {v.get('gateway_private_ip') or "由 ELB 分配"} |
| 公网暴露 | **无**（内网 ELB，不绑 EIP） |

## 访问与出口 / Access and egress

| 项 | 值 |
|---|---|
| 模型接入方式 | {v.get('model_endpoint_mode')} |
| NAT 网关 | {'启用' if v.get('enable_nat_gateway') else '不创建'} |
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
    args = ap.parse_args()

    doc, flat = load(Path(args.inputs).resolve())
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

    models = doc.get("models") or []
    if not models:
        report.add("models", FAIL, "at least one model entry is required")
    for m in models:
        name = m.get("name", "?")
        missing = [f for f in ("name", "model", "mode") if not m.get(f)]
        if missing:
            report.add(f"models[{name}]", FAIL, f"missing fields: {', '.join(missing)}")
        elif m.get("provider") in ("modelarts", "maas") and not m.get("api_base") and flat.get("model_endpoint_mode", {}).get("value") != "vpcep":
            report.add(f"models[{name}]", WARN, "no api_base and no ModelArts VPC endpoint: the model will not be reachable")
        else:
            report.add(f"models[{name}]", OK, f"{m.get('provider')} / {m.get('model')}")

    v = merged(flat)
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

    OUT_DIR.mkdir(exist_ok=True)
    TF_DIR.mkdir(parents=True, exist_ok=True)
    (TF_DIR / "terraform.tfvars").write_text(render_tfvars(v), encoding="utf-8")
    (OUT_DIR / "helm-values.yaml").write_text(render_helm(v, flat, doc), encoding="utf-8")
    (OUT_DIR / "models.rendered.yaml").write_text(render_models(doc), encoding="utf-8")
    (OUT_DIR / "deployment-plan.md").write_text(render_plan(v, doc, counts), encoding="utf-8")
    (OUT_DIR / "preflight.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    if not args.json:
        print("\nrendered: terraform.tfvars, out/helm-values.yaml, out/models.rendered.yaml,")
        print("          out/deployment-plan.md, out/preflight.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
