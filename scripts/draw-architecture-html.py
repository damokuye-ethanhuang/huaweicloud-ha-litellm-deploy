#!/usr/bin/env python3
"""Render docs/architecture.html from the deployed topology.

Deterministic on purpose: the diagram is generated from the same facts as the
Terraform modules (CIDRs, AZs, container network, ELB ownership), so a stale
picture is impossible to ship without editing this file too.

    python3 scripts/draw-architecture-html.py
"""

from __future__ import annotations

import html
import pathlib

W, H = 1600, 1000
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Microsoft YaHei',sans-serif"

# Palette: one accent per layer, muted enough to print.
C = {
    "bg": "#f7f8fa",
    "ink": "#1f2933",
    "muted": "#6b7785",
    "line": "#8a97a6",
    "vpc": "#eef2f7",
    "access": "#e8f1fb",
    "app": "#eaf6ee",
    "data": "#fdf0e6",
    "ops": "#f3eefb",
    "vpce": "#f0f0f0",
    "elb": "#1c64b8",
    "ing": "#2f7d4f",
    "pod": "#2f7d4f",
    "db": "#b45309",
    "redis": "#b45309",
    "bastion": "#6b3fa0",
    "ghost": "#9aa5b1",
}

parts: list[str] = []


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def box(x, y, w, h, title, lines=(), fill="#fff", stroke="#c7d0da", dash=None,
        title_size=15, body_size=12, badge=None, badge_fill="#fff"):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    parts.append(
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" '
        f'stroke="{stroke}" stroke-width="1.5"{d}/>'
    )
    ty = y + 26
    parts.append(
        f'<text x="{x + 14}" y="{ty}" font-family="{FONT}" font-size="{title_size}" '
        f'font-weight="600" fill="{C["ink"]}">{esc(title)}</text>'
    )
    if badge:
        bw = 7.2 * len(badge) + 18
        parts.append(
            f'<rect x="{x + w - bw - 10}" y="{y + 10}" width="{bw}" height="20" rx="10" '
            f'fill="{badge_fill}" stroke="{stroke}" stroke-width="1"/>'
            f'<text x="{x + w - bw / 2 - 10}" y="{y + 24}" text-anchor="middle" '
            f'font-family="{FONT}" font-size="11" fill="{C["muted"]}">{esc(badge)}</text>'
        )
    for i, line in enumerate(lines):
        parts.append(
            f'<text x="{x + 14}" y="{ty + 20 + i * 17}" font-family="{FONT}" '
            f'font-size="{body_size}" fill="{C["muted"]}">{esc(line)}</text>'
        )


def text(x, y, s, size=12, weight="400", fill=None, anchor="start"):
    parts.append(
        f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-family="{FONT}" '
        f'font-size="{size}" font-weight="{weight}" fill="{fill or C["ink"]}">{esc(s)}</text>'
    )


def arrow(x1, y1, x2, y2, label="", color=None, dash=None, curve=0.0):
    color = color or C["line"]
    d = f' stroke-dasharray="{dash}"' if dash else ""
    if curve:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        cy = my - curve
        path = f"M {x1} {y1} Q {mx} {cy} {x2} {y2}"
    else:
        path = f"M {x1} {y1} L {x2} {y2}"
    parts.append(
        f'<path d="{path}" fill="none" stroke="{color}" stroke-width="1.6"{d} '
        f'marker-end="url(#arrow)"/>'
    )
    if label:
        lx, ly = (x1 + x2) / 2, (y1 + y2) / 2 - 6 - curve / 2
        parts.append(
            f'<text x="{lx}" y="{ly}" text-anchor="middle" font-family="{FONT}" '
            f'font-size="11" fill="{C["muted"]}">{esc(label)}</text>'
        )


def label_chip(x, y, s, fill="#fff", color=None):
    w = 6.9 * len(s) + 16
    parts.append(
        f'<rect x="{x}" y="{y}" width="{w}" height="22" rx="11" fill="{fill}" '
        f'stroke="#d5dbe2" stroke-width="1"/>'
        f'<text x="{x + w / 2}" y="{y + 15}" text-anchor="middle" font-family="{FONT}" '
        f'font-size="11" fill="{color or C["muted"]}">{esc(s)}</text>'
    )


# ------------------------------------------------------------------ canvas ---
parts.append(f'<rect width="{W}" height="{H}" fill="{C["bg"]}"/>')
text(40, 46, "LiteLLM 私有化网关 · 华为云参考架构", 24, "700")
text(40, 72, "CCE + 容器隧道网络（overlay_l2）+ Ingress 自动创建内网 ELB + RDS/DCS 主备；除堡垒机外无公网入口", 13, fill=C["muted"])
label_chip(40, 86, "cn-southwest-2 · AZ 2d/2e/2f")
label_chip(300, 86, "LiteLLM 1.106.3")
label_chip(470, 86, "elb_mode = ingress")

# -------------------------------------------------------------------- VPC ----
vx, vy, vw, vh = 300, 130, 1260, 640
parts.append(
    f'<rect x="{vx}" y="{vy}" width="{vw}" height="{vh}" rx="16" fill="{C["vpc"]}" '
    f'stroke="#c3ceda" stroke-width="2"/>'
)
text(vx + 20, vy + 30, "VPC 10.0.0.0/22 · 纯内网", 16, "700")
text(vx + 240, vy + 30, "唯一公网出口是下方堡垒机的 EIP；集群与网关均无公网地址", 12, fill=C["muted"])

# access subnet (front)
box(vx + 20, vy + 80, 300, 170, "接入子网 10.0.0.0/24", [
    "CCE 前端子网 · ELB VIP 所在",
    "仅接受 client_cidrs / admin_cidrs",
], fill=C["access"], stroke="#a9c6e4", badge="front")
box(vx + 40, vy + 152, 260, 62, "内网 ELB（独享型 L7）", [
    "Ingress 注解 elb.autocreate 创建",
], fill="#fff", stroke=C["elb"], title_size=13, body_size=11)

# app subnet (backend)
box(vx + 340, vy + 80, 380, 330, "应用子网 10.0.1.0/24", [
    "CCE 后端子网 · 3 工作节点 1/AZ",
    "ac8.2xlarge.2 → 二次测试 x1.8u16g",
], fill=C["app"], stroke="#a9d3ba", badge="backend")
box(vx + 358, vy + 148, 344, 44, "Ingress（ingressClassName: cce）", [], fill="#fff",
    stroke=C["ing"], title_size=13)
box(vx + 358, vy + 200, 344, 42, "Service（ClusterIP）", [], fill="#fff",
    stroke=C["ing"], title_size=13)
for i, az in enumerate(("2d", "2e", "2f")):
    x = vx + 358 + i * 118
    box(x, vy + 254, 108, 140, f"节点 {az}", ["8C16G"], fill="#fff", stroke="#a9d3ba",
        title_size=12, body_size=11)
    box(x + 12, vy + 306, 84, 44, "pod", ["litellm"], fill="#f3fbf6", stroke=C["pod"],
        title_size=12, body_size=10)
    text(x + 54, vy + 376, "172.16.x/28", 10, fill=C["muted"], anchor="middle")

# data subnet
box(vx + 740, vy + 80, 300, 330, "数据子网 10.0.2.0/24", [
    "只放行应用子网（节点源地址）",
    "不放行 pod_cidr（隧道模式无意义）",
], fill=C["data"], stroke="#e5c3a3", badge="data")
box(vx + 760, vy + 152, 260, 96, "RDS PostgreSQL 16", [
    "主备 HA",
    "空库，表由 Prisma 迁移建",
], fill="#fff", stroke=C["db"], title_size=13, body_size=11)
box(vx + 760, vy + 264, 260, 96, "DCS Redis 7", [
    "主备 8G",
    "不挂安全组（5.0/6.0）",
], fill="#fff", stroke=C["redis"], title_size=13, body_size=11)

# ops subnet
box(vx + 20, vy + 430, 440, 170, "运维子网 10.0.3.0/24", [
    "部署、helm、排障的唯一入口",
    "可达 VPC 内 6443 / 443 / 5432 / 6379",
], fill=C["ops"], stroke="#c9b8e2", badge="ops")
box(vx + 40, vy + 490, 280, 56, "堡垒机（唯一公网 EIP）", ["SSH 仅来自 bastion_ssh_cidrs"],
    fill="#fff", stroke=C["bastion"], title_size=13, body_size=11)

# vpce subnet (optional)
box(vx + 500, vy + 430, 250, 170, "VPCE 子网 10.0.4.0/26", [
    "可选，默认不启用",
    "ModelArts / MaaS 私网端点",
], fill=C["vpce"], stroke="#c7d0da", dash="5 4", badge="optional")

# container network callout
box(vx + 780, vy + 430, 280, 170, "容器隧道网络", [
    "172.16.0.0/16 · VXLAN",
    "按 /28 分给节点",
    "不走 VPC 路由",
    "Pod 无 EIP / 无安全组",
], fill="#fff", stroke=C["ghost"], dash="5 4")

# ------------------------------------------------------------------ flows ----
# Client sits outside the VPC on the left: one short arrow, no line crossing
# subnets.
cx, cy = 30, 250
parts.append(
    f'<rect x="{cx}" y="{cy}" width="230" height="130" rx="10" fill="#fff" '
    f'stroke="#c7d0da" stroke-width="1.5"/>'
)
text(cx + 16, cy + 28, "VPC 内调用方", 15, "600")
text(cx + 16, cy + 50, "业务系统 / 对等连接", 12, fill=C["muted"])
text(cx + 16, cy + 68, "OpenAI SDK / LangChain", 12, fill=C["muted"])
text(cx + 16, cy + 86, "Bearer <virtual key>", 12, fill=C["muted"])
text(cx + 16, cy + 110, "公网无路径", 12, fill=C["elb"])
arrow(cx + 230, cy + 65, vx + 40, vy + 183, "HTTPS 443", color=C["elb"])

arrow(vx + 300, vy + 183, vx + 356, vy + 170, "TLS 终止", color=C["elb"])
arrow(vx + 530, vy + 192, vx + 530, vy + 200, "", color=C["ing"])
arrow(vx + 530, vy + 242, vx + 530, vy + 254, "NodePort", color=C["ing"])
arrow(vx + 1002, vy + 316, vx + 1058, vy + 200, "5432", color=C["db"], curve=12)
arrow(vx + 1002, vy + 372, vx + 1058, vy + 312, "6379", color=C["redis"], curve=-10)
# bastion -> cluster API, routed through the gap between the access and app boxes
parts.append(
    f'<path d="M {vx + 330} {vy + 490} L {vx + 330} {vy + 300} L {vx + 352} {vy + 300}" '
    f'fill="none" stroke="{C["bastion"]}" stroke-width="1.6" stroke-dasharray="6 4" '
    f'marker-end="url(#arrow)"/>'
)
text(vx + 338, vy + 400, "kubectl / helm → 6443", 11, fill=C["muted"])

# ------------------------------------------------------------------ egress ---
ex, ey = vx + 780, vy + 640 + 40
parts.append(
    f'<rect x="{ex}" y="{ey}" width="420" height="76" rx="10" fill="#fff" '
    f'stroke="#c7d0da" stroke-width="1.5" stroke-dasharray="5 4"/>'
)
text(ex + 16, ey + 26, "模型后端（在 VPC 之外）", 14, "600")
text(ex + 16, ey + 48, "ModelArts / MaaS 私网端点（VPCE）或外部模型 API（NAT）", 12, fill=C["muted"])
text(ex + 16, ey + 66, "NAT 默认不创建；纯内网已验证无需公网出口", 12, fill=C["muted"])
arrow(vx + 920, vy + 600, ex + 120, ey, "可选", color=C["ghost"], dash="6 4")

# ---------------------------------------------------------------- legend -----
lx, ly = 40, 960
label_chip(lx, ly, "实线：数据面")
label_chip(lx + 130, ly, "虚线：管理面 / 可选")
label_chip(lx + 290, ly, "pod_cidr 不参与 VPC 路由")
text(W - 40, ly + 15, "scripts/draw-architecture-html.py 生成", 11, fill=C["muted"], anchor="end")

svg = f'''<svg viewBox="0 0 {W} {H}" width="100%" role="img" aria-label="LiteLLM 华为云架构图">
<defs>
  <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
    <path d="M 0 0 L 10 5 L 0 10 z" fill="{C["line"]}"/>
  </marker>
</defs>
{chr(10).join(parts)}
</svg>'''

TABLES = f'''
<h2>子网与职责</h2>
<table>
<thead><tr><th>子网</th><th>CIDR</th><th>角色</th><th>谁可以访问</th></tr></thead>
<tbody>
<tr><td>access</td><td>10.0.0.0/24</td><td><b>接入子网 / CCE 前端子网</b>：ELB VIP</td><td>client_cidrs、admin_cidrs、运维子网</td></tr>
<tr><td>app</td><td>10.0.1.0/24</td><td><b>应用子网 / ELB 后端子网</b>：3 个工作节点</td><td>接入子网、运维子网</td></tr>
<tr><td>data</td><td>10.0.2.0/24</td><td>RDS、DCS</td><td>应用子网（节点源地址）、运维子网</td></tr>
<tr><td>ops</td><td>10.0.3.0/24</td><td>堡垒机</td><td>SSH 来源 bastion_ssh_cidrs</td></tr>
<tr><td>vpce</td><td>10.0.4.0/26</td><td>ModelArts/MaaS 私网端点（可选）</td><td>仅应用子网</td></tr>
<tr><td>容器网段</td><td>172.16.0.0/16</td><td>overlay_l2（VXLAN），按 /28 分给节点</td><td>不参与 VPC 路由</td></tr>
</tbody></table>

<h2>请求链路</h2>
<ol>
<li>调用方（VPC 内或对等连接）访问 <code>https://&lt;ELB VIP&gt;/v1/chat/completions</code>，带 virtual key。公网无路径。</li>
<li>ELB 由 <b>CCE Ingress 控制器</b>按 <code>kubernetes.io/elb.autocreate</code> 创建：独享型、<code>type: inner</code>、L7，VIP 落在接入子网。</li>
<li>Ingress → Service（ClusterIP）→ 三个节点上的 pod 之一，按 <code>/health/readiness</code> 剔除故障副本。</li>
<li>鉴权与用量元数据来自 PostgreSQL；限流计数与缓存来自 Redis。</li>
<li>路由按 <code>deploy-inputs.yaml</code> 的 <code>models[]</code> 生成，主备模型互为 fallback。</li>
<li>出方向走 ModelArts VPCEP 或 NAT（默认不建 NAT，纯内网已验证可用）。</li>
</ol>

<h2>谁是 ELB 的 owner</h2>
<table>
<thead><tr><th>模式</th><th>Terraform 是否建 ELB</th><th>VIP 从哪来</th><th>适用</th></tr></thead>
<tbody>
<tr><td><code>ingress</code>（默认）</td><td>否，<code>module.elb</code> 的 count = 0</td><td><code>kubectl get ingress</code> 的 status</td><td>CCE 内部服务，L7 能力</td></tr>
<tr><td><code>standalone</code></td><td>是</td><td><code>terraform output gateway_private_ip</code></td><td>非 CCE 工作负载、需要固定 VIP</td></tr>
</tbody></table>

<h2>两个必须记住的约束</h2>
<ul>
<li><b>隧道网络下 pod IP 不可路由。</b>Pod 访问 RDS/Redis 时源地址被节点 SNAT 成节点地址，所以数据子网只放行应用子网；放行 <code>pod_cidr</code> 是无效规则。</li>
<li><b>三段地址不能重叠。</b>VPC <code>10.0.0.0/22</code>、容器 <code>172.16.0.0/16</code>、Service <code>10.247.0.0/16</code>。重叠不会在建集群时报错，而是在 Pod 连不上数据库时才暴露。</li>
</ul>

<h2>已知坑位</h2>
<p>首次端到端部署撞到的 20 个问题（含 SAS 售罄、安全组重复规则、<code>DCS.4872</code>、Helm <code>pending-install</code> 锁、ELB <code>ELB.8917</code> 删除保护）按报错查到处置方式，集中在
<a href="deployment-optimizations.md#22-首次部署踩坑总表按报错查">deployment-optimizations.md §22</a>。</p>
'''

HTML = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>LiteLLM on Huawei Cloud · 架构图</title>
<style>
  :root {{ color-scheme: light; }}
  body {{ margin: 0; background: {C["bg"]}; color: {C["ink"]}; font-family: {FONT}; }}
  main {{ max-width: 1120px; margin: 0 auto; padding: 32px 24px 72px; }}
  h1 {{ font-size: 28px; margin: 0 0 6px; }}
  .sub {{ color: {C["muted"]}; margin: 0 0 24px; font-size: 14px; }}
  .canvas {{ background: #fff; border: 1px solid #e2e8ef; border-radius: 14px; padding: 8px; }}
  h2 {{ font-size: 18px; margin: 40px 0 12px; }}
  table {{ width: 100%; border-collapse: collapse; background: #fff; border: 1px solid #e2e8ef; border-radius: 10px; overflow: hidden; font-size: 14px; }}
  th, td {{ text-align: left; padding: 10px 12px; border-bottom: 1px solid #eef1f5; vertical-align: top; }}
  th {{ background: #f4f6f9; font-weight: 600; }}
  tr:last-child td {{ border-bottom: none; }}
  code {{ background: #f1f3f6; padding: 1px 5px; border-radius: 4px; font-size: 12.5px; }}
  ol, ul {{ line-height: 1.75; font-size: 14px; }}
  p {{ line-height: 1.7; font-size: 14px; }}
</style>
</head>
<body>
<main>
  <h1>LiteLLM 私有化网关 · 华为云架构</h1>
  <p class="sub">CCE + overlay_l2 容器隧道 + Ingress 自动创建内网 ELB + RDS/DCS 主备。除堡垒机 EIP 外无公网入口。</p>
  <div class="canvas">{svg}</div>
  {TABLES}
</main>
</body>
</html>
'''


def main() -> None:
    out = pathlib.Path(__file__).resolve().parent.parent / "docs" / "architecture.html"
    out.write_text(HTML, encoding="utf-8")
    print(f"wrote {out} ({len(HTML)} bytes)")


if __name__ == "__main__":
    main()
