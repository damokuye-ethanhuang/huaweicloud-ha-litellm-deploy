#!/usr/bin/env python3
"""Generate the post-deployment architecture diagram as a .drawio file.

    python3 scripts/draw-architecture.py [--out docs/architecture-post-deploy.drawio]

Reads deploy-inputs.yaml and version-presets.yaml so the diagram reflects the
actual parameters (project prefix, CIDRs, chosen branches) instead of a drawing
that drifts from the deployment.

Only original work: every shape, label and coordinate is generated here.
"""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
INPUTS = REPO / "deploy-inputs.yaml"
PRESETS = REPO / "version-presets.yaml"

# style helpers ---------------------------------------------------------------
BAND = "rounded=0;whiteSpace=wrap;html=1;dashed=1;strokeColor=#9aa4b2;fillColor=none;verticalAlign=top;align=left;spacingLeft=8;spacingTop=4;fontSize=11;fontStyle=1;fontColor=#5b6472;"
BOX = "rounded=1;whiteSpace=wrap;html=1;arcSize=8;strokeWidth=1;"
ZONE = "rounded=1;whiteSpace=wrap;html=1;dashed=1;fillColor=#f6f8fb;strokeColor=#b6c0cc;verticalAlign=top;align=left;spacingLeft=10;spacingTop=6;fontSize=11;fontStyle=1;fontColor=#44505f;"
TITLE = "text;html=1;fontSize=18;fontStyle=1;align=left;verticalAlign=middle;fontColor=#1b2430;"
NOTE = "text;html=1;fontSize=10;align=left;verticalAlign=top;fontColor=#5b6472;whiteSpace=wrap;"
EDGE = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;strokeWidth=1.5;strokeColor=#44505f;"
EDGE_DASH = "edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=block;endFill=1;dashed=1;strokeWidth=1.2;strokeColor=#8b95a3;"


def box_style(fill: str, stroke: str, font: str = "#1b2430") -> str:
    return f"{BOX}fillColor={fill};strokeColor={stroke};fontColor={font};"


class Diagram:
    def __init__(self) -> None:
        self.root = ET.Element("mxGraphModel", dx="1600", dy="1000", grid="1", gridSize="10",
                               guides="1", tooltips="1", connect="1", arrows="1", fold="1",
                               page="1", pageScale="1", pageWidth="1654", pageHeight="1169",
                               math="0", shadow="0")
        self.model = ET.SubElement(self.root, "root")
        ET.SubElement(self.model, "mxCell", id="0")
        ET.SubElement(self.model, "mxCell", id="1", parent="0")
        self._ids = 1

    def _id(self, prefix: str) -> str:
        self._ids += 1
        return f"{prefix}{self._ids}"

    def cell(self, value: str, x: int, y: int, w: int, h: int, style: str, parent: str = "1", cid: str | None = None) -> str:
        cid = cid or self._id("v")
        c = ET.SubElement(self.model, "mxCell", id=cid, value=value, style=style, vertex="1", parent=parent)
        ET.SubElement(c, "mxGeometry", x=str(x), y=str(y), width=str(w), height=str(h), **{"as": "geometry"})
        return cid

    def edge(self, src: str, dst: str, label: str = "", style: str = EDGE) -> None:
        c = ET.SubElement(self.model, "mxCell", id=self._id("e"), value=label, style=style,
                          edge="1", parent="1", source=src, target=dst)
        ET.SubElement(c, "mxGeometry", relative="1", **{"as": "geometry"})

    def write(self, path: Path) -> None:
        tree = ET.ElementTree(self.root)
        ET.indent(tree, space="  ")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'<?xml version="1.0" encoding="UTF-8"?>\n'
                         b'<mxfile host="drawio" agent="scripts/draw-architecture.py" type="device">\n'
                         b'  <diagram id="post-deploy" name="Architecture">\n'
                         + ET.tostring(self.root, encoding="utf-8") +
                         b'\n  </diagram>\n</mxfile>\n')


def load() -> tuple[dict, dict]:
    doc = yaml.safe_load(INPUTS.read_text(encoding="utf-8")) or {}
    flat: dict[str, dict] = {}
    for items in doc.values():
        if isinstance(items, list):
            for item in items:
                if isinstance(item, dict) and "key" in item:
                    flat[item["key"]] = item
    presets = yaml.safe_load(PRESETS.read_text(encoding="utf-8")) or {}
    return flat, presets


def val(flat: dict, key: str, default: str = "") -> str:
    v = (flat.get(key) or {}).get("value")
    if isinstance(v, list):
        return ", ".join(str(x) for x in v) if v else default
    return str(v) if v not in (None, "") else default


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO / "docs" / "architecture-post-deploy.drawio"))
    args = ap.parse_args()

    flat, presets = load()
    project = val(flat, "project_name", "litellm")
    region = val(flat, "region", "cn-north-4")
    vpc = val(flat, "vpc_cidr", "10.0.0.0/16")
    access_cidr = val(flat, "subnet_access_cidr", "10.0.0.0/24")
    app_cidr = val(flat, "subnet_app_cidr", "10.0.1.0/24")
    data_cidr = val(flat, "subnet_data_cidr", "10.0.2.0/24")
    vpce_cidr = val(flat, "subnet_vpce_cidr", "10.0.3.0/27")
    pod_cidr = val(flat, "pod_cidr", "172.16.0.0/16")
    net_type = val(flat, "cce_container_network_type", "vpc-router")
    vpce_on = val(flat, "vpce_enabled", "false").lower() == "true"
    client = val(flat, "client_cidrs", "10.20.0.0/16")
    admin = val(flat, "admin_cidrs", "10.20.10.0/24")
    egress = val(flat, "model_endpoint_mode", "vpcep")
    tls = val(flat, "tls_mode", "internal_ca")
    enc = val(flat, "encryption_mode", "kms")
    logb = val(flat, "log_backend", "lts")
    metb = val(flat, "metric_backend", "aom")
    grafana = val(flat, "grafana_endpoint", "http://<grafana>:3000")
    replicas = val(flat, "litellm_replicas", "3")
    node_flavor = val(flat, "node_flavor", "c7.xlarge.4")
    rds_flavor = val(flat, "rds_flavor", "rds.pg.n1.xlarge.2.ha")
    dcs_flavor = val(flat, "dcs_flavor", "redis.ha.xu1.large.r2.2")
    version = val(flat, "litellm_version", "1.106.3")
    bastion = val(flat, "bastion_enabled", "true").lower() != "false"
    bastion_ssh = val(flat, "bastion_ssh_cidrs", "")
    bastion_flavor = val(flat, "bastion_flavor", "c7.large.2")
    nodes_per_az = int(val(flat, "nodes_per_az", "1") or 1)
    az_count = 3
    total_nodes = nodes_per_az * az_count
    preset = str((presets.get("litellm") or {}).get("preset", version))
    models = [m for m in (yaml.safe_load(INPUTS.read_text(encoding="utf-8")).get("models") or [])]

    d = Diagram()
    d.cell(f"<b>{project}</b> — LiteLLM gateway on Huawei Cloud (internal)", 40, 20, 900, 30, TITLE)
    d.cell(f"region {region} · deploy-inputs.yaml · LiteLLM {version} (preset {preset}) · "
           f"generated {datetime.now(timezone.utc).strftime('%Y-%m-%d')}", 40, 48, 1100, 20, NOTE)

    # --- clients -------------------------------------------------------------
    zone_clients = d.cell(f"企业内网调用方 / Internal clients<br/>{client}", 40, 100, 240, 120, ZONE)
    c_api = d.cell("<b>业务系统</b><br/>OpenAI SDK / LangChain", 60, 140, 200, 34, box_style("#e8f1fb", "#7aa7d9"))
    c_adm = d.cell("<b>运维 / 堡垒机</b><br/>Admin UI", 60, 178, 200, 34, box_style("#e8f1fb", "#7aa7d9"))
    d.cell(f"仅允许：{admin}", 60, 214, 200, 16, NOTE, parent=zone_clients)

    # operator bastion: the only public IP in the stack
    zone_ops = d.cell("运维入口 / Operator access", 330, 640, 300, 150, ZONE) if bastion else None
    bastion_box = d.cell(
        f"<b>{project}-maas-bastion</b><br/>按需计费 EIP · {bastion_flavor}<br/>"
        f"kubectl + helm（CCE 无公网端点）<br/>"
        f"SSH 白名单：{bastion_ssh or '未开（仅控制台）'}",
        350, 676, 260, 84, box_style("#fff2f2", "#cf7b7b")) if bastion else None

    # --- edge / ELB ----------------------------------------------------------
    zone_edge = d.cell(f"{project}-maas-access-subnet {access_cidr}<br/>接入层（私网，无 EIP）", 330, 100, 300, 190, ZONE)
    elb = d.cell(f"<b>{project}-maas-elb</b><br/>独享型 ELB · 弹性规格<br/>私网 VIP · {tls}<br/>:443 → pod:4000",
                 350, 132, 260, 74, box_style("#eaf4ec", "#6aa877"))
    cert = d.cell(f"证书 {project}-maas-cert", 350, 214, 260, 26, box_style("#f3f6f9", "#aab5c2"))

    # --- VPC -----------------------------------------------------------------
    zone_vpc = d.cell(f"VPC {project}-maas-vpc &nbsp;{vpc}", 40, 330, 1180, 520, ZONE)

    # app subnet / CCE
    zone_cce = d.cell(
        f"CCE {project}-maas-cce · {net_type}<br/>"
        f"控制面 {az_count if az_count >= 3 else 1} master(s) · 工作节点 {total_nodes} 台（独立 node 资源，按 AZ 轮转）"
        f"（{nodes_per_az}/AZ × {az_count} AZ，{node_flavor}）<br/>"
        f"{project}-maas-app-subnet {app_cidr} · 容器网络 {net_type}（{pod_cidr}，VPC 路由）",
        70, 370, 660, 250, ZONE)
    pods = []
    for idx, az in enumerate(("AZ-a", "AZ-b", "AZ-c"), start=1):
        px = 90 + (idx - 1) * 210
        pods.append(d.cell(f"<b>litellm pod {idx}</b><br/>{az} · {node_flavor}<br/>:4000 · 1 worker",
                           px, 420, 190, 66, box_style("#fff6e5", "#d9a441")))
    d.cell(f"{replicas} replicas · PDB minAvailable 2 · topology spread by zone/host<br/>"
           f"migration job: litellm --skip_server_startup (pre-upgrade hook)", 90, 500, 620, 44,
           box_style("#f7f9fc", "#b6c0cc"))
    d.cell(f"Service type=LoadBalancer<br/>annotations: elb.id / elb.class / cert-id", 90, 556, 620, 40,
           box_style("#f7f9fc", "#b6c0cc"))

    # data subnet
    zone_data = d.cell(f"{project}-maas-data-subnet {data_cidr}（仅应用子网可达）", 760, 370, 430, 250, ZONE)
    rds = d.cell(f"<b>{project}-maas-rds</b><br/>PostgreSQL 16 主备跨 2 AZ<br/>{rds_flavor}<br/>"
                 f"key/team/budget/spend_logs", 780, 410, 390, 74, box_style("#eef0fb", "#7d86c9"))
    dcs = d.cell(f"<b>{project}-maas-dcs</b><br/>Redis 7 主备跨 2 AZ<br/>{dcs_flavor}<br/>"
                 f"限流计数 / 路由状态 / 缓存", 780, 500, 390, 74, box_style("#eef0fb", "#7d86c9"))
    d.cell(f"安全组 {project}-maas-sg-data：5432/6379 仅来自应用子网", 780, 584, 390, 24, NOTE, parent=zone_data)

    # vpce subnet
    zone_vpce = d.cell(f"{project}-maas-vpce-subnet {vpce_cidr}", 70, 640, 660, 110, ZONE)
    vpce = d.cell(f"<b>{project}-maas-vpce</b> · ModelArts 私网接入" if vpce_on else
                  "<b>VPCE 未启用</b>（测试环境不建终端节点，子网规划保留）",
                  90, 676, 380, 50, box_style("#eef7f6", "#5ea29a") if vpce_on else box_style("#f3f6f9", "#aab5c2"))
    d.cell(f"出网方式：{egress} · 容器网络 {net_type}，无独立容器子网", 490, 690, 220, 26, NOTE, parent=zone_vpce)

    # egress / nat
    zone_egress = d.cell("出网 / Egress", 760, 640, 430, 110, ZONE)
    nat = d.cell(f"<b>{project}-maas-nat</b><br/>NAT + SNAT" if egress == "nat" else
                 "<b>NAT 未创建</b><br/>（无公网出口）",
                 780, 676, 390, 50, box_style("#fdeeee", "#cf7b7b") if egress == "nat" else box_style("#f3f6f9", "#aab5c2"))

    # --- management plane (outside VPC) --------------------------------------
    zone_mgmt = d.cell("管理面 / Management plane（不承载业务流量）", 1260, 100, 330, 750, ZONE)

    kms_boxes = {
        "kms": f"<b>{project}-maas-kms</b><br/>新建 KMS 密钥 · 90 天轮换<br/>RDS 卷 + CCE 节点盘",
        "dew": "已有 DEW/KMS 密钥<br/>（安全团队维护）<br/>RDS 卷 + CCE 节点盘",
        "disabled": "<b>未启用加密</b><br/>仅实验环境",
    }
    kms = d.cell(kms_boxes.get(enc, kms_boxes["kms"]), 1280, 140, 290, 62,
                 box_style("#f2eefb", "#8e7cc3"))

    csms = d.cell(f"<b>CSMS 凭据</b><br/>{project}-litellm-master-key<br/>"
                  f"{project}-litellm-salt-key<br/>{project}-litellm-db-password<br/>"
                  f"{project}-litellm-redis-password<br/>（凭据名不含 maas，与命名模块一致）", 1280, 222, 290, 92,
                  box_style("#f2eefb", "#8e7cc3"))

    lts = d.cell(f"<b>LTS</b> {project}-maas-lts<br/>ELB 访问日志 + 应用日志<br/>保留 {val(flat, 'log_retention_days', '30')} 天"
                 if logb == "lts" else "<b>LTS 未启用</b>",
                 1280, 334, 290, 62, box_style("#eaf1f8", "#5687b5"))

    aom = d.cell(f"<b>AOM</b> {project}-maas-aom<br/>Prometheus 实例 · 保留 {val(flat, 'aom_retention', '360h')}"
                 if metb == "aom" else "<b>AOM 未启用</b>",
                 1280, 416, 290, 56, box_style("#eaf1f8", "#5687b5"))

    graf = d.cell(f"<b>本地 Grafana</b><br/>{grafana}<br/>看板在本地编排", 1280, 492, 290, 56,
                  box_style("#fff6e5", "#d9a441"))

    smn = d.cell(f"<b>SMN</b> {project}-maas-alarms<br/>告警通知 → 邮件", 1280, 568, 290, 50,
                 box_style("#eaf1f8", "#5687b5"))

    obs_note = d.cell("日志入 LTS，指标入 AOM；<br/>Grafana 只读查询，不落数据。", 1280, 636, 290, 40, NOTE)

    # --- external model endpoints -------------------------------------------
    zone_models = d.cell("模型服务 / Model endpoints", 760, 800, 430, 190, ZONE)
    y = 836
    for m in models[:4]:
        d.cell(f"<b>{m.get('name')}</b><br/>{m.get('model')} · {m.get('mode', 'chat')}"
               + (f"<br/>{m.get('api_base')}" if m.get("api_base") else "<br/>（经 VPCEP 私网地址）"),
               780, y, 390, 34, box_style("#eef7f6", "#5ea29a"))
        y += 40

    gov = d.cell("治理边界 / Governance<br/>不做 key 计费与配额管理（按约定）<br/>"
                 "纯内网：无 EIP、无公网 MaaS 端点<br/>CIDR 白名单 + 内部 CA TLS + CSMS/KMS",
                 70, 800, 660, 190, box_style("#f7f9fc", "#9aa4b2"))

    # --- operator path -------------------------------------------------------
    if bastion_box is not None:
        d.edge(c_adm, bastion_box, "SSH（公网 EIP）", EDGE_DASH)
        d.edge(bastion_box, zone_cce, "helm / kubectl（VPC 内）", EDGE_DASH)

    # --- edges ---------------------------------------------------------------
    d.edge(c_api, elb, "HTTPS 443")
    d.edge(c_adm, elb, "Admin UI")
    d.edge(elb, pods[0], "转发")
    d.edge(elb, pods[1], "", EDGE_DASH)
    d.edge(elb, pods[2], "", EDGE_DASH)
    d.edge(pods[0], rds, "5432")
    d.edge(pods[1], rds, "", EDGE_DASH)
    d.edge(pods[0], dcs, "6379")
    d.edge(pods[2], dcs, "", EDGE_DASH)
    d.edge(pods[1], vpce, "推理")
    d.edge(vpce, zone_models, "私网")
    if egress == "nat":
        d.edge(pods[2], nat, "")
        d.edge(nat, zone_models, "公网（仅 nat 模式）", EDGE_DASH)
    d.edge(rds, kms, "加密", EDGE_DASH)
    d.edge(kms, csms, "", EDGE_DASH)
    d.edge(elb, lts, "访问日志", EDGE_DASH)
    d.edge(pods[1], aom, "指标", EDGE_DASH)
    d.edge(aom, graf, "查询", EDGE_DASH)
    d.edge(pods[2], smn, "告警", EDGE_DASH)

    out = Path(args.out)
    d.write(out)
    print(f"wrote {out.relative_to(REPO)} ({out.stat().st_size} bytes)")
    print(f"project={project} vpc={vpc} egress={egress} enc={enc} obs={logb}/{metb} models={len(models)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
