# 华为云 LiteLLM 高可用网关

用 Terraform + Helm 把 [LiteLLM](https://github.com/BerriAI/litellm) 部署成
华为云上的高可用、OpenAI 兼容 AI 网关。

![license](https://img.shields.io/badge/license-Apache--2.0-blue)
![terraform](https://img.shields.io/badge/terraform-%3E%3D1.6-623CE4)
![litellm](https://img.shields.io/badge/litellm-v1.106.3-1f6feb)

## 这是什么

LiteLLM 用一个 OpenAI 兼容端点统一 100+ 模型提供商，提供虚拟 Key、预算、
用量统计、故障转移和管理后台。本仓库按平台团队真正上线的方式部署它：

| 组件 | 实现 |
|---|---|
| 计算 | CCE（Kubernetes），3 个控制面 master + 每 AZ 一个工作节点池 |
| 入口 | 独享型 ELB，**弹性规格（按 LCU 计费）**，EIP，TLS 终结 |
| 状态 | RDS for PostgreSQL 16，跨 2 AZ 主备 |
| 缓存/限流 | DCS for Redis 7，跨 2 AZ 主备 |
| 出网 | NAT 网关 + SNAT，私有访问模型 API |
| 密钥 | CSMS + 每次部署随机生成，不入库 |
| 加密 | KMS 加密 RDS 卷与 CCE 节点盘 |
| 可观测 | LTS 采集 ELB 访问日志，可选 CES 告警 + SMN |
| 混合云 | 可选 VPN 网关（隧道手工对接） |
| 内网推理 | 可选 ModelArts VPCEP 私网接入 |

全部资源由 Terraform 管理：`plan` 可以先看全量变更，模块可被其他项目复用。

## 架构

```mermaid
flowchart LR
  C["VPC 内客户端<br/>业务子网 / 对等连接"] -->|HTTPS 443| ELB["内网 ELB<br/>由 CCE Ingress 自动创建"]
  ELB --> ING["Ingress（ingressClassName: cce）"]
  ING --> SVC["Service（ClusterIP）"]
  subgraph VPC["VPC 10.0.0.0/22 · 无公网入口"]
    SVC --> P1["pod · AZ-d"]
    SVC --> P2["pod · AZ-e"]
    SVC --> P3["pod · AZ-f"]
    P1 & P2 & P3 --> RDS[("RDS PG 16 主备")]
    P1 & P2 & P3 --> DCS[("DCS Redis 7 主备")]
    P1 & P2 & P3 -.->|默认不开| NAT[NAT]
  end
  OP["运维 PC"] -->|SSH 22| BAST["堡垒机<br/>唯一公网 EIP"]
  BAST -.kubectl/helm.-> P1
  NAT -.-> MaaS["ModelArts / MaaS"]
  NAT -.-> EXT["外部模型 API"]
```

Pod 运行在容器隧道网络（`overlay_l2`，`172.16.0.0/16`），VPC 不为该网段配路由：
Pod 访问 RDS/Redis 时源地址被转换为节点地址，所以data 子网只放行app 子网。

请求路径：VPC 内客户端 → 内网 ELB（TLS，由 Ingress 创建）→ Service → 三个 Pod 之一
→ 经 NAT 或 ModelArts VPCEP 调用模型。集群外唯一入口是堡垒机（公网 EIP），它只用于
helm/kubectl 和排障。Pod 无状态，需要跨故障保留的数据都在 RDS/Redis。

## 快速开始

### 生产版（CCE 高可用）——受支持的路径

```bash
./scripts/creds.sh set          # 专用 IAM 用户的 AK/SK → secrets/hw.env（已 gitignore）
$EDITOR deploy-inputs.yaml      # 另一个需要改的文件

./scripts/deploy.sh preflight   # 校验参数并渲染 out/
./scripts/deploy.sh plan        # 生成 plan，不做任何变更
#   ◄── 人工看完 plan 再继续
./scripts/deploy.sh apply-infra # 20–40 分钟，主要是 CCE
#   或：./scripts/deploy.sh apply-stream（同一份 plan，逐资源实时进度）
./scripts/deploy.sh --remote deploy-app   # 在堡垒机上跑 helm
./scripts/deploy.sh --remote verify       # 在堡垒机上做 smoke
./scripts/deploy.sh ingress              # 一次性收敛 CCE ELB Ingress（幂等）
./scripts/deploy.sh verify-ui            # 通过堡垒机取 HTML + 截图取证

./scripts/handoff.py scrub && ./scripts/handoff.py check   # 测完清场，必须输出 clean
```

`creds.sh` 是凭据的唯一落盘位置；已经 export 的 `HW_ACCESS_KEY` / `HW_SECRET_KEY`
优先级更高，所以 CI 不需要文件。客户交付时把 `./scripts/handoff.py form` 的输出发过去，
上面写明了每个值填到哪，不会要求在聊天窗口里贴密钥。

`--remote` 的原因：VPC 外的机器既连不上集群（CCE 无公网端点），也访问不到
网关（ELB 是私网）。堡垒机是唯一有公网 IP 的主机，所以集群内动作都在那里执行，
它只需要 `kubectl` 和 `helm`，不需要 Terraform 和 AK/SK。

`ingress` 单独成一个阶段，是因为 `kubernetes.io/elb.autocreate` **不可修改**：
改子网、可用区、端口或规格都会被 API 拒绝，旧的 ELB 继续服务。该阶段把集群现状
和渲染出的 bundle 对比，不一致就删除重建，再通过 VIP 访问 `/health/readiness`
证明真的通了；加 `--check` 只报告漂移、不做变更。`verify-ui` 则通过堡垒机抓
`/ui/` 并用无头 Chrome 截图，让「已部署」有产物可查，而不是只看 Pod 数量。

模型端点和 KEY 分开管理：端点写在 `deploy-inputs.yaml` 的 `models[]`，KEY 写在
`secrets/app.env`（已 gitignore），YAML 里只用 `api_key_env` 引用变量名：

```bash
cat > secrets/app.env <<'EOF'
GLM_API_KEY=sk-...
DEEPSEEK_API_KEY=
EOF
```

留空表示该端点免认证。**不要把 KEY 写进 `deploy-inputs.yaml`。**

### 单机版（vm-single，约 10 分钟）——仅评估

```bash
cp terraform/examples/vm-single/terraform.tfvars.example terraform/examples/vm-single/terraform.tfvars
$EDITOR terraform/examples/vm-single/terraform.tfvars   # 改 allowed_ingress_cidrs

terraform -chdir=terraform/examples/vm-single init
terraform -chdir=terraform/examples/vm-single apply
```

实例会自动装 Docker，启动 PostgreSQL 16、Redis 7 和 LiteLLM，访问
`http://<eip>:4000`。单点、明文 HTTP、密钥经 cloud-init 下发，
**不要放生产 Key**，也不要指望它和生产版行为一致。

主密钥在 CSMS 和 Terraform 输出里：

```bash
terraform -chdir=terraform/examples/cce-ha output -json app_env | jq -r .LITELLM_MASTER_KEY
```

## 版本基线

固定 **LiteLLM `v1.106.3`**（2026-10-24 发布，写作时最新稳定版）：

- 包含 1.106.3 起更换的 cosign 签名密钥，镜像验签与上游一致；
- 包含本仓库自动化的迁移 + SpendLogs 索引行为（独立迁移 Job，
  Pod 侧 `DISABLE_SCHEMA_UPDATE=true`）。

版本号只在 `litellm_version` 和 chart `values.yaml` 两处。升级与回滚流程见
[docs/operations.md](docs/operations.md)。

## 安全模型

- **仓库和 tfvars 里没有静态凭据**：AK/SK 放在 `secrets/hw.env`（已 gitignore、
  `chmod 600`，由 `creds.sh` 写入）或环境变量里；`handoff.py check` 只要还留着就报错。
- **所有密码每次部署随机生成**：数据库/Redis 24 位，主密钥/盐密钥 48 位。
- **`LITELLM_SALT_KEY` 带 `prevent_destroy`**：它加密数据库里的 provider
  凭据，换了就解不开。
- **TLS 在 ELB 终结**，`enable_https = false` 只用于实验环境。
- **Provider Key 只进 Kubernetes Secret**，不进 Helm values。
- **数据面仅 VPC 可达**：RDS/DCS 不绑公网 IP，安全组只放行 VPC 网段。

完整清单见 [docs/security.md](docs/security.md)。

## 目录结构

`docs/index.md` 是权威的文件地图：每个脚本、模块、文档负责什么，什么问题该看哪一篇。概览：

| 路径 | 作用 |
|---|---|
| [`terraform/modules/`](terraform/modules) | 10 个模块：`maas-network`、`bastion`、`cce`、`elb`、`postgres`、`redis`、`observability`、`vpcep`、`vpn`、`naming` |
| [`terraform/examples/cce-ha/`](terraform/examples/cce-ha) | 生产：CCE + RDS + DCS + 由 Ingress 自建的 ELB |
| [`terraform/examples/vm-single/`](terraform/examples/vm-single) | 单机实验：一台 ECS + 本地 PostgreSQL / Redis |
| [`charts/litellm/`](charts/litellm) | Helm chart（迁移 hook、PDB、探针、拓扑打散；config 由 values + 参数渲染） |
| [`scripts/`](scripts) | 部署引擎：preflight/plan/apply、helm 交接、Ingress 收敛、镜像同步、销毁 |
| [`docs/`](docs) | 架构、部署、运维、安全、成本、排障、文件地图 |
| [`monitoring/`](monitoring) | AOM 告警规则 + Grafana 看板 + 接入说明 |
| [`skills/`](skills) | agent skill（部署流程），`make skill-install` 安装 |

完整清单见 [docs/index.md](docs/index.md)。

## 验证状态

两类证据分开列。

**离线验证**（不需要云凭据，`make validate`）：

- **10 个模块 + 2 个示例**的 `terraform fmt -check` / `terraform validate`，
  Terraform 1.17.0，provider `huaweicloud/huaweicloud` **1.99.1**；
- chart 的 `helm lint` / `helm template`，含迁移 hook 与 Ingress；
- 所有脚本通过 `shellcheck`；文档链接、中英 README 链接一致性、
  `docs/index.md` 文件地图完整性；
- 监控资产：告警规则里的每个指标都能在看板中找到。

**真实账号验证**——在 `cn-southwest-2` 完整跑通一次，随后销毁：

- `cce-ha` 示例按 edge → data → compute → cache → ops 分阶段 apply：CCE 3 节点
  跨 AZ、RDS PostgreSQL 主备、DCS Redis 主备；
- 表结构由 Helm pre-install hook 自动迁移，未手工执行 SQL、未导入 dump；
- 3 个网关副本通过 CCE Ingress 自建的内网 ELB 正常响应
  `/health/readiness` 与 `/v1/models`；
- `/ui/` 返回 SPA，并经堡垒机用无头浏览器渲染成功；
- 关闭 NAT 网关后 Pod 仍正常服务（镜像已入 SWR 时不需要 Pod 出公网）；
- `terraform destroy` 后本工程在账号内资源归零（`state list` 为空，
  EIP/ELB/RDS/DCS/CCE 均无残留）。

**未验证**，明确标注：

- `cn-southwest-2` 以外的区域（endpoint、规格编码、CCE 版本）；
- TLS 路径——测试使用的是 HTTP 监听，未接 SCM 证书；
- 经 VPCEP 访问 ModelArts / MaaS（`vpcep` 模块）——测试用的是 OpenAI 兼容端点；
- AOM 告警实际触发（Cloud Eye 指标名因区域而异，告警默认不启用）；
- `vm-single` 单机示例，以及 `--remote all` 一次跑完的路径。

你账号里的第一次 `terraform plan` 仍然是真正的验收。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/index.md](docs/index.md) | **先看这篇**：哪个问题看哪篇文档，以及仓库里每个文件的职责 |
| [docs/architecture.md](docs/architecture.md) | 组件、故障域、请求链路、升级流程 |
| [docs/architecture.html](docs/architecture.html) | 可视化架构：子网、请求链路、ELB 归属、坑位索引（由 `scripts/draw-architecture-html.py` 生成） |
| [docs/deployment.md](docs/deployment.md) | 前置条件、IAM、凭据、逐步部署 |
| [docs/operations.md](docs/operations.md) | 扩缩容、升级、回滚、备份恢复、密钥轮换 |
| [docs/security.md](docs/security.md) | 密钥、网络、TLS、镜像验签、IAM、谁可以调用 |
| [docs/sa-checklist.md](docs/sa-checklist.md) | 可勾选的规划清单：网络、外网边界、数据、加密、上线 |
| [docs/permissions.md](docs/permissions.md) | IAM 最小权限清单、CCE 委托、策略命名（`*FullPolicy`） |
| [docs/inputs-guide.md](docs/inputs-guide.md) | 参数怎么填，模型列表怎么写 |
| [docs/manual-deployment.md](docs/manual-deployment.md) | 不用 Terraform 时的手工控制台步骤 |
| [docs/upgrade-procedure.md](docs/upgrade-procedure.md) | 版本升级必须走的流程 |
| [monitoring/README.md](monitoring/README.md) | LTS 日志、AOM 指标、告警导入、本机 Grafana |
| [monitoring/alerting-rules.yaml](monitoring/alerting-rules.yaml) | AOM 告警规则（可用性/延迟/错误/饱和） |
| [monitoring/grafana-dashboard.json](monitoring/grafana-dashboard.json) | Grafana 看板（对接 AOM 的 Prometheus 端点） |
| [skills/litellm-huaweicloud-deploy/SKILL.md](skills/litellm-huaweicloud-deploy/SKILL.md) | agent skill：阶段流程、堡垒机交接、故障路由 |
| [docs/cost.md](docs/cost.md) | 资源清单、参考价格、降本手段 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 现象 → 原因 → 处理 |
| [docs/deployment-optimizations.md](docs/deployment-optimizations.md) | 真实部署的 22 个坑位：现象、根因、修法 |
| [docs/modelarts-intranet.md](docs/modelarts-intranet.md) | 通过 VPCEP 私网调用 ModelArts |
| [docs/huaweicloud-regions.md](docs/huaweicloud-regions.md) | Region、Endpoint、AZ 规律、规格编码 |

## 许可证

Apache-2.0。LiteLLM 本身是 MIT 许可，本仓库不内联其代码。
