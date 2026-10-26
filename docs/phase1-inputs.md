# 第 1 阶段：把参数填对（含可直接粘贴的提示词）

这一页只解决一件事：在开始建任何资源之前，把 `deploy-inputs.yaml` 里**确实需要你决定**的几个值填掉，
确认 plan 没问题，再进入第 2 阶段。第 2 阶段部署基线网关，第 3 阶段才导模型。

## 最短路径：一条命令，回答 4 个问题

不用翻 55 行 YAML，也不用记参数名。在仓库根目录运行：

```bash
./scripts/fill-inputs.sh
```

它依次问 4 个问题（每个都先解释这个值是什么、填错会怎样），然后**只改
`deploy-inputs.yaml` 这一个文件**、只改这 4 行，其余 51 个参数原样不动：

```
1/4 project_name       所有资源名的前缀
2/4 owner              写进资源标签，账单和告警按它归属
3/4 bastion_ssh_cidrs  允许 SSH 堡垒机的公网出口 IP
4/4 swr_org            镜像推到哪个 SWR 组织（回车 = 跟 project_name 一致）
```

改完它会打印实际改动，并告诉你下一条命令。想先看当前值：

```bash
./scripts/fill-inputs.sh --show
```

非交互（CI 或让 agent 代跑）：

```bash
PROJECT_NAME=acme-litellm OWNER=platform-team \
  BASTION_SSH_CIDRS=1.2.3.4/32 \
  ./scripts/fill-inputs.sh --yes
```

校验不过会直接拒绝写入并指出哪一位不对（比如 CIDR 少了 `/32`），不会写半个文件。

**只有这一个文件需要你改。** 下面这些都不是你手改的：

| 文件 | 谁生成 |
|---|---|
| `terraform/examples/cce-ha/terraform.tfvars` | `preflight` 从 `deploy-inputs.yaml` 渲染，手改会被下次运行覆盖 |
| `$LITELLM_DEPLOY_HOME/out/*`（helm-values、plan、preflight.json） | 同上，属于产物 |
| `models.yaml` | 第 3 阶段才填，现在保持 `models: []` |
| `$LITELLM_DEPLOY_HOME/secrets/hw.env` | `./scripts/creds.sh set` 写，不需要编辑 |

## 不换区域（贵阳 `cn-southwest-2`）能不能直接跑通？

**参数这一层可以。** 现在的默认值就是第一轮真实部署跑通的那一套：区域 `cn-southwest-2`、可用区
`2d/2e/2f`、节点 `x1.8u.16g` 三副本、RDS/DCS 主备、`overlay_l2` 容器网络、Ingress 自建内网 ELB、
无 NAT、KMS 加密、LTS/AOM 观测。你把这 4 个值填掉，第 1 阶段的参数就是完整的。

但**参数之外还有 5 件事**必须成立，缺任何一件都会在很晚的阶段失败：

| 前提 | 怎么确认 | 不满足时的症状 |
|---|---|---|
| AK/SK 有权限（VPC / CCE / RDS / DCS / ELB / EVS / EIP / SWR / KMS / LTS / AOM / SMN / IMS） | `./scripts/creds.sh status` 显示 configured；权限清单见 `docs/permissions.md` | `plan` 阶段 403，或 apply 到一半 `Unauthorized` |
| SWR 组织已存在 | SWR 控制台 → 组织管理，确认组织名（`swr_org`）在列表里 | `mirror-image.sh` 推送失败（`unauthorized` / `not found`） |
| 镜像已经镜像进 SWR | 堡垒机上 `./scripts/mirror-image.sh 1.106.3`，看到 `Image mirrored to swr.<region>.myhuaweicloud.com/<org>/litellm:1.106.3`（脚本推送后会校验 manifest，缺失即报错） | Pod `ImagePullBackOff`，事件里是 pull access denied |
| 你的公网出口 IP 写对 | 你自己机器上 `curl -s ifconfig.me` | SSH **超时**，`deploy-app` / `verify` 全部做不了 |
| 配额足够（EIP / ELB / RDS / DCS / ECS / EVS / ENI） | 控制台「资源配额」 | `apply` 中途 `QuotaExceeded`，已建的一半资源计费 |

两件事会自动适配，不需要你改：

- **CCE 版本**：`cce_cluster_version` 默认 `v1.36`，但部署时 `scripts/resolve-cce-version.py` 会用官方
  SDK 查询本区域当前支持的版本再填入（CCE 会淘汰旧版本，写死会过期）。
- **可用区**：`az_policy: auto` 会在部署前用 `scripts/resolve-az.py` 查询本区域真实可用的 AZ，
  按 `az_preferred` 的顺序挑选。

第一轮踩过的三个坑已经固化在代码里，重跑不会再遇到：

| 坑 | 现状 |
|---|---|
| 数据盘 `SAS` 在该区域售罄 | 默认卷类型已改为 `GPSSD2`（`terraform/modules/cce/variables.tf`） |
| ELB 删除保护导致 `destroy` 被 `ELB.8917` 挡住 | `elb_deletion_protection` 默认 `false` |
| 销毁时 RDS 报「Other users are accessing the database」 | `scripts/destroy.sh` 现在先 `helm uninstall` 并等 Pod 消失，再 `terraform destroy`；没有 kubeconfig 时跳过并告警 |

**唯一没在贵阳验证过的是第 3 阶段**（`models.yaml` + `./scripts/deploy.sh models`）。它是这次新拆出来
的流程，第 1、2 阶段的代码路径没有变化；第一次 `--apply` 建议守在现场，看 Deployment 滚动完成、
`/v1/models` 从 `[]` 变成你的模型列表。

## 为什么只有 4 个要填

`deploy-inputs.yaml` 一共 55 个参数，其中 51 个已经填好了**第一轮真实部署验证过的值**（贵阳区域、
3 AZ、8U16G 节点、RDS/DCS 主备、LiteLLM 1.106.3、overlay 容器网络、Ingress 自建内网 ELB、无 NAT、
KMS/LTS/AOM）。剩下 4 个模板没法替你决定，因为它们取决于"你是谁、在哪个区域、从哪台机器连过来"。

一条命令看当前还差什么：

```bash
python3 scripts/inputs-table.py --actionable
```

输出 4 行；填完再跑，输出 `<!-- 0 field(s) still need you -->`。这个视图只列两类字段：
**被标记为占位符且仍是出厂值的**，和**必填但为空的**（条件不满足的字段不会打扰你，例如
`certificate_id` 在 `tls_mode: none` 时不出现）。

## 逐项说明

### 1. `project_name`

| | |
|---|---|
| 现在是什么 | `example-litellm` |
| 填成什么 | 3–24 位，小写字母开头，只含小写字母、数字、连字符，例如 `acme-litellm` |
| 为什么必须换 | 它是**所有资源名的前缀**：`<项目>-maas-vpc`、`-cce`、`-rds`、`-elb`、`-dcs`，SWR 组织名也默认跟它一致。它同时是唯一性锚点——同一个华为云账号下两个项目用同一个名字，`apply` 会因资源已存在而失败。 |
| 不改的后果 | preflight 只给 warning 不拦（名字本身是合法的），失败会推迟到 `apply` 阶段，那时已经建了一半资源。 |

### 2. `owner`

| | |
|---|---|
| 现在是什么 | 空 |
| 填成什么 | 团队名或邮箱前缀，2–40 字符，例如 `platform-team` 或 `zhangsan` |
| 为什么必须填 | 它会被写进每一个资源的 tag。账单分摊、告警通知、"这堆资源是谁的、能不能删"全靠这个标签。 |
| 不改的后果 | preflight 直接 FAIL，因为留空等于交付了一套没人认领的资源。 |

### 3. `bastion_ssh_cidrs`

| | |
|---|---|
| 现在是什么 | `203.0.113.10/32` —— 这是文档专用示例地址（RFC 5737），永远连不上 |
| 填成什么 | 执行部署那台机器的**公网出口 IP**，形如 `["1.2.3.4/32"]`。公司网络有多个 NAT 出口时把它们都列上。 |
| 为什么必须填 | 堡垒机是整套架构里**唯一**带公网 EIP 的主机，`helm`、`kubectl`、`verify`、`verify-ui` 都必须从它上面执行。CCE 集群本身没有公网端点，客户端也不在 VPC 里。这条规则不对，后面每个阶段都做不了。 |
| 填错的症状 | 表现为 SSH **连接超时**（而不是"拒绝"），很容易误判成堡垒机没起来或安全组方向反了。查法：在你自己机器上 `curl ifconfig.me`，注意运营商 NAT 池可能给你不同的出口 IP。 |

### 4. `swr_org`

| | |
|---|---|
| 现在是什么 | `example-litellm` |
| 填成什么 | 建议**与 `project_name` 一致**；该组织需要先在 SWR 控制台存在（或用 API 创建） |
| 为什么必须确认 | 容器节点没有任何出网能力，镜像只能走"堡垒机下载 → 推到 SWR → Pod 从 SWR 拉"这条链路。推送地址就是 `swr.<region>.myhuaweicloud.com/<swr_org>/litellm`，仓库名固定 `litellm`。 |
| 不一致的后果 | 不会报错，但镜像会推到另一个组织，`ImagePullBackOff` 时你会去错误的地方找。preflight 对"与 `project_name` 不一致"给提示。 |

## 如果换了 region，要连带改这些

默认值是贵阳 `cn-southwest-2`，可用区 `2d / 2e / 2f`。改区域时：

1. `region` 改成目标区域代码（如 `cn-north-4`、`me-east-1`）。
2. `az_list` / `az_preferred` 换成该区域真实存在的 AZ。`az_policy: auto` 会在部署前用
   `scripts/resolve-az.py` 查询本区域可用 AZ 并按顺序挑选，但**列表里的值必须真实存在**，
   否则查询结果为空、preflight 报错。
3. 规格编码可能不同（`node_flavor`、`rds_flavor`、`dcs_flavor` 都是区域相关的），
   preflight 的 `flavor:availability` 检查会去查，查不到会提示。
4. `swr_org` 不用带 region，代码会自动拼。

国际站还要把 `site_type` 改成 `international`（国际站不支持企业项目，`enterprise_project_id` 必须留 `0`）。

## 这些参数不用动，原因是它们就是第一轮跑通的值

### 网络

| 参数 | 值 | 为什么是这个值 |
|---|---|---|
| `vpc_cidr` | `10.0.0.0/21` | 模块按顺序从里面切出 access/app/data/ops 四个 `/24` 和 vpce 的 `/26`；`/21` 刚好装下且留余量，不需要你另外规划 |
| `subnet_access_cidr` / `_app_` / `_data_` / `_ops_` / `_vpce_` | `10.0.0.0/24` … `10.0.4.0/26` | 与 VPC 配套。access 放内网 ELB VIP，app 放 CCE 节点，data 放 RDS/DCS（只允许 app 访问），ops 放堡垒机 |
| `pod_cidr` | `172.16.0.0/16` | `overlay_l2` 的 VXLAN 隧道网段，不占 VPC 地址，因此不需要单独建容器子网 |
| `cce_container_network_type` | `overlay_l2` | 第一轮验证：`vpc-router` 需要额外的 ENI 配额，且 Pod 直连 VPC；overlay 更省配额。代价是 Pod IP 在 VPC 内不可路由，所以数据子网的安全组按"app 子网"放行而不是按 Pod 网段——这套配置已经按此写好 |
| `elb_mode` | `ingress` | ELB 由 CCE 的 Ingress 控制器按注解创建并管理生命周期，Terraform 不持有它。`standalone` 只在"必须由外部系统拥有 ELB"时用 |

### 规模

| 参数 | 值 | 为什么是这个值 |
|---|---|---|
| `node_flavor` | `x1.8u.16g` | 单个网关 Pod 的 requests 是 1 vCPU / 4Gi，节点还要留给 kubelet、容器运行时和系统组件。第一轮实测 2C4G 放不下（Pod 一直 Pending） |
| `nodes_per_az` | `1` | 三个 AZ 各一个节点，挂掉一个 AZ 仍有两个副本在服务 |
| `litellm_replicas` | `3` | 一 AZ 一副本。连接预算 = 副本 × 工作进程 × 每进程连接池(10) = 30，远低于 RDS 上限 |
| `cce_cluster_flavor` | `cce.s2.large` | 控制面规格（决定 API Server/etcd 规模），和节点规格是两件事 |
| `rds_flavor` / `dcs_flavor` | `rds.pg.n1.xlarge.2.ha` / `redis.ha.xu1.large.r2.2` | 必须 `.ha`。单机实例在重启/升级窗口内会让整个网关不可用，测试环境也不放宽 |

### 镜像与出口

| 参数 | 值 | 为什么是这个值 |
|---|---|---|
| `image_supply_chain` | `swr` | 节点无出网，只能从 SWR 拉。首次部署前要在堡垒机上跑 `scripts/mirror-image.sh <版本>`，镜像才会出现在 SWR |
| `model_endpoint_mode` | `none` | 纯内网：不建 NAT，节点无公网。模型端点必须是内网可达地址（ModelArts VPCEP 或已打通的专线/对等连接） |
| `bastion_eip_bandwidth_mbit` | `300` | 按流量计费，拉镜像时带宽大、空闲时不花钱。这是唯一需要公网带宽的地方 |

### 加密与观测

| 参数 | 值 | 为什么是这个值 |
|---|---|---|
| `encryption_mode` | `kms` | 新建 KMS 密钥，加密 RDS 存储卷和 CCE 节点数据盘。`dew` 是"用已有密钥"，`none` 只建议实验用 |
| `log_backend` / `metric_backend` | `lts` / `aom` | 日志与指标落云上，Grafana 看板在你本机编排、只负责查询 |
| `aom_retention` / `log_retention_days` | `360h` / `30` | AOM 接口只接受这几个固定值；日志 30 天按常见审计要求 |
| `grafana_endpoint` | `http://10.20.30.40:3000` | 你本机的 Grafana 地址。从 VPC 外访问不到是**正常现象**，preflight 只 warn 不拦 |

### 版本

| 参数 | 值 | 为什么是这个值 |
|---|---|---|
| `litellm_version` | `1.106.3` | 与 `version-presets.yaml` 的 `preset` 一致，是目前唯一完整验证过的基线。升级必须先走 `docs/upgrade-procedure.md`，并用 `ACK_UPGRADE=1` 明确确认 |
| `cce_cluster_version` | `v1.36` | 留空或保持默认，部署时由官方 SDK 查询本区域当前支持的版本并填入（CCE 会淘汰旧版本，写死会过期） |

## 提示词（整段粘贴给 agent）

```text
按三阶段流程部署 LiteLLM 到华为云。仓库就是当前 workspace。
先读 skills/litellm-huaweicloud-deploy/SKILL.md（三阶段流程）和 AGENTS.md（禁止事项）。

【已经改好，不要动】
- terraform/、charts/、scripts/：第一轮真实部署验证通过，除非我明确要求，不要修改
- models.yaml：第 3 阶段才填，现在保持 models: [] 空数组，不要往里加模型
- 渲染产物（terraform.tfvars、out/ 下的文件）由 preflight 生成，不要手改

【这一步只做第 1 阶段：确认参数】
1. 先跑 ./scripts/fill-inputs.sh --show 告诉我这四个值现在是什么，再跑
   python3 scripts/inputs-table.py --actionable 确认没有别的缺项。
   然后逐条问我这 4 个值，每条说清：填什么格式、为什么需要它、填错会怎样。不要自己编值。
2. 我回答后运行 ./scripts/fill-inputs.sh（交互式）或我用 --yes 参数给你值。
   这个脚本只改 deploy-inputs.yaml 里的 4 行，其它文件一律不动。
   然后跑 ./scripts/deploy.sh preflight。
3. 把 preflight 的 FAIL 逐条解释并给出修法；WARN 也要说明是否需要处理，直到 0 blocking。
4. 只跑到 ./scripts/deploy.sh plan 就停下，用一段话汇报：将创建多少个资源、关键规格、
   预计费用、有没有会替换已有资源的破坏性变更。
5. 我说「确认」之后，才允许 apply-infra。

【规则】
- 不要向我索要 AK/SK。我自己写进 ~/.litellm-deploy/secrets/hw.env，你只跑 creds.sh status 看状态。
- 不要把模型写进 deploy-inputs.yaml；模型属于第 3 阶段。
- 任何阶段失败立刻停，报阶段名和原始错误，不要绕过检查继续。
- 不要用改安全组、加 EIP/NAT、手动改 tfstate 的方式"让它跑通"。
```

## 填完自检

```bash
python3 scripts/inputs-table.py --actionable     # 期望：0 field(s) still need you
./scripts/deploy.sh preflight                    # 期望：0 blocking
./scripts/deploy.sh plan                         # 期望：saved plan + 资源清单
```

`preflight` 输出的三条 warning 通常可以忽略，它们是环境提示而非配置错误：

- `admin-reach`：`admin_cidrs` 是否覆盖 ELB VIP 所在子网（默认已覆盖，换网段时才会响）
- `flavor:availability`：当前区域是否有该规格（换 region 时才会响）
- `grafana_endpoint`：从 VPC 外访问不到你本机的 Grafana，这是预期行为
