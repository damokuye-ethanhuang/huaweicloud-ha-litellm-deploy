# 部署方案优化点与踩坑记录

> 来源：example-litellm 首次真实部署（cn-southwest-2，2026-10-25）。
> 每条都是实际踩到的问题，不是预设的最优实践。整理进 `docs/deployment.md`
> 与 `scripts/` 之后再删除本文件。

## 1. 堡垒机提前、并行创建

**现状**：堡垒机排在第 5 阶段（最后），理由是“纯计费、可独立失败”。
**问题**：应用层调试全都依赖堡垒机，它最后才到位，导致前面所有验证都要等。

**改法**：
- 堡垒机与网络/安全组同批创建（阶段 0/1），不依附 CCE。
- 应用部署阶段并行做两件事：① 堡垒机拉取镜像并推 SWR；② 集群/数据面继续建。
- 计费顾虑用“创建后即停”或按需规格解决，而不是靠延后创建。

## 2. 镜像供应链：堡垒机下载 → SWR → Pod 内网拉取

**纯内网前提**：Pod 不应有公网出口，NAT 出网对工作负载应收掉。

**实施**：
1. 堡垒机 `docker pull` 上游镜像（源站或国内加速源）。
2. `docker tag` → `swr.<region>.myhuaweicloud.com/<org>/<repo>:<tag>`。
3. `docker push` 到同区域 SWR。
4. 集群侧用 imagePullSecret（私有仓库），`litellm_image_repository` 指向 SWR。
5. Pod 从 SWR 拉取，全程内网，不依赖 NAT。

**实测数据（cn-southwest-2）**：
| 源 | 速度 | 结论 |
|---|---|---|
| ghcr.io（直连） | 节点侧长时间无进展 | 不可用 |
| ghcr.nju.edu.cn | **7.0 MB/s** | 可用，堡垒机侧拉取 |
| docker.m.daocloud.io | manifest 401 | 不可用 |
| SWR 同区域 | 内网到达 | Pod 侧唯一正确来源 |

- 镜像 `litellm:1.106.3`：压缩 419MB / 解压 1.81GB / 24 层。
- SWR 接入点区分：注册中心 `swr.<region>.myhuaweicloud.com`，
  管理 API `swr-api.<region>.myhuaweicloud.com`（两者不可混用，混用返回 404）。

## 3. 资源配置：requests 必须小于节点可分配内存

**现象**：3 副本 `requests=limits=4Gi`，节点 8GiB 实际可分配仅 ~6.1GiB，
加上系统组件与迁移 Job 后**全部 Pod 永久 Pending**（`Insufficient memory`）。

**改法**：`requests` 取 2Gi、`limits` 保留 4Gi（官方建议作为上限）。
调度按 requests，限制按 limits，两者不该相等。

## 4. 终止中的 Pod 会继续占配额

**现象**：上一版 Pod 处于 `Terminating` 达 18 分钟（kubelet 卡在镜像拉取），
其内存请求未释放，新 Pod 无法调度。

**改法**：重部署脚本在 `helm upgrade` 前检查 `Terminating` 超过 N 分钟的 Pod，
必要时 `--force --grace-period=0` 清理；排障文档给出判定命令。

## 5. 迁移 Job 不能引用尚未创建的资源

**现象**：迁移 Job 是 `pre-install` 钩子，却引用 chart 内的 ServiceAccount，
报 `serviceaccount "litellm" not found`，release 挂起 6 分钟直到超时。

**改法**：迁移 Job 不设 `serviceAccountName`（它只连 PostgreSQL，不需要 K8s API）。

## 6. 镜像与工具安装不要经过本地机器中转

**约束**：本机到云端上行极慢（实测 ~5–7 KB/s），而云端到公网下行正常。
**改法**：只在本地写脚本上传；开源工具一律在堡垒机内下载安装。
- kubectl：`snap install kubectl --classic`（拿到 1.35.9，落在集群 1.36 的 ±1 内）。
- helm：`mirrors.huaweicloud.com/helm/...`。
- 避免 `scp` 大文件，会静默截断（实测 helm 只传了 1.1MB 就段错误）。

## 7. 带宽按阶段调整

构建/灌镜像阶段临时提到 **300 Mbit/s**（EIP + NAT 各一条），
稳定运行后降回实际需求，按流量计费避免空跑。

## 8. 堡垒机初始化依赖的出向规则（易漏）

bootstrap 用 apt + 官方源，`set -e`，所以必须放行：
- **TCP 80**（apt 走 http）
- **UDP 53**（VPC 解析器在 `100.125.0.0/16`，不在 VPC 段内）
- TCP 443（下载）

漏任何一条都会表现为“kubectl/helm 没装上”，且 cloud-init 只报 error 不报警。

## 9. 堡垒机认证：密钥优先

该镜像禁止 root 口令登录；重置口令需重启（部分环境禁止重启）。
`bastion_public_key` 传入公钥由 Terraform 建密钥对，是唯一稳定路径。

## 10. 推送/传输：先巡检网络与鉴权，再动手

**规范**：任何 `docker push`、`scp`、`obsutil cp` 之前，必须先跑
`scripts/preflight-network.sh <目标镜像>`，五项依次检查：

| 检查 | 判定 | 失败含义 |
|---|---|---|
| DNS | 解析到 `100.125.x`（纯内网场景） | 解析到公网地址说明走 NAT，不符合内网要求 |
| TCP 443 | 可建连 | 安全组出向缺规则或无路由 |
| `/v2/` | 返回 200/401 | 超时=网络不通，404=域名用错 |
| 鉴权 | `docker manifest inspect` 成功 | 未登录、密码错、仓库不存在 |
| 磁盘 | ≥ 5GiB | 拉取中途会失败 |

## 11. 命令成功 ≠ 操作成功

**事故**：`docker push ... | tail -3` 在后台执行，日志尾部是 `docker images`
输出，真正的 `denied: Authenticate Error` 被挤出窗口；管道让整体退出码取自
`tail`，`set -e` 没有触发。结果被当成成功，直到控制台看不到镜像才发现。

**三条硬规则**：
1. 推送/传输不要接管道；要用 `scripts/push-image.sh`，它内部 `set -o pipefail`
   且失败时打印错误尾部并 `exit 1`。
2. 推送后必须验证产物：目标端 `manifest inspect` 可读、镜像 ID 与源一致。
3. 日志只 `tail` 会漏错；判失败要用退出码或 `grep -E 'error|denied|failed'`，
   不要用"最后几行看起来正常"来判断。

## 12. 等待要事件驱动，不要 sleep N

**现状**：部署/验证过程中用 `sleep 60`、`sleep 180` 盲等，快的时候白等，慢的时候不够。
**改法**：
- 就绪判定用 `kubectl rollout status deployment/litellm --timeout=900s`，完成即返回。
- 单资源用 `kubectl wait --for=condition=Available --timeout=…`。
- 外部接口用轮询 + 条件退出，不用固定睡眠。
- 等待期间应并行做文档或其它不冲突的工作。

## 13. SWR 鉴权：AK/SK 直连不被接受

**现象**：`docker login -u cn-southwest-2@<AK> -p <SK>` 返回
`denied: Authenticate Error`；用它生成的 imagePullSecret 在节点侧报
`failed to fetch oauth token ... 401 Unauthorized`。

**正确做法**：
1. 取 SWR 登录指令（**POST** 才有，GET 返回 404）：
   `POST https://swr-api.<region>.myhuaweicloud.com/v2/manage/utils/secret`
   头部 `X-Auth-Token: <IAM token>`，返回 `auths` 中的 base64 `user:pass`。
2. `docker login` 用该 user/pass。
3. 集群侧用同一组凭据建 imagePullSecret：
   `kubectl create secret docker-registry swr-cred --docker-server=swr.<region>.myhuaweicloud.com --docker-username=<user> --docker-password=<pass>`
4. 该凭据 **24 小时**有效。生产环境需在 SWR 控制台启用“长期有效登录指令”，
   或使用机器人账号，避免 24h 后 Pod 重建拉取失败。

**接入点区分**（混用必 404）：
- 注册中心 `swr.<region>.myhuaweicloud.com`（`/v2/` 返回 401 即正常）
- 管理 API `swr-api.<region>.myhuaweicloud.com`

## 14. 资源规格：以官方建议为基准，按节点可分配量反推机型

**官方建议**（docs.litellm.ai/docs/proxy/prod）原文：

> Give each pod 1 vCPU and 4Gi of memory, as both requests and limits, and scale
> both with the worker count if you run more than one worker per container.

即 `requests == limits == 1 vCPU / 4Gi`，每个 worker 4Gi。本工程照此设置，
不做“请求低于上限”的折中——之前的 1Gi/2Gi 降配偏离官方，已回退。

**节点选型计算**（实测数据，CN 西南-贵阳）：

| 机型 | 规格 | 可分配内存 | 系统组件 | 单 Pod(4Gi) 后余量 | 结论 |
|---|---|---|---|---|---|
| c7.xlarge.2 | 4C8G | 6.14Gi | ~0.9Gi | ~1.2Gi | 放得下但**没有 surge 余量**，滚动更新会卡住 |
| c7.xlarge.4 | 4C16G | ~14Gi | ~0.9Gi | ~9Gi | **采用**：1 副本/AZ，surge 与单 AZ 故障均可承受 |
| c7.2xlarge.2 | 8C16G | ~14Gi | ~0.9Gi | ~9Gi | 同内存但 CPU 翻倍，单价更高，无必要 |

**关键约束**：单 Pod 4Gi 请求 + 系统 0.9Gi 后，8G 机型只剩 1.2Gi，
而滚动更新需要额外的 surge Pod——这就是“看着能放下、升级时却卡住”的根因。

**换机型必须重建节点**：provider 明确报
`flavor_id can't be updated`，需 `-replace=module.cce...workers[i]`，
不能用原地变配。

## 附录：首次端到端验证结果（cn-southwest-2，2026-10-25）

拓扑：内网 ELB `10.0.1.132:443` → CCE 3 节点（`ac8.2xlarge.2`，8C16G，2d/2e/2f）
→ LiteLLM 3 副本（每副本 1 vCPU/4Gi，官方规格）→ RDS PG 主备 + DCS 主备。

| 验证项 | 结果 |
|---|---|
| 镜像来源 | 堡垒机从加速源拉取 → 推 SWR → Pod 走内网 SWR，无公网依赖 |
| 数据库 schema | Prisma 迁移 Job 完成，213 个迁移已应用（`_prisma_migrations`） |
| `GET /health/readiness` | 200 |
| `GET /v1/models`（带 master key） | 200，返回 `glm-5.3`、`deepseek-v4.1-flash` |
| `GET /v1/models`（无认证） | 401 |
| 副本 AZ 分布 | 2d / 2e / 2f 各 1，硬亲和约束生效 |
| 故障切换 | 删除 1 个副本，60 秒内持续 200，无中断 |

**节点规格结论**：`ac8.xlarge.4`（4C16G）不够——CCE 系统组件占 3250m/3920m，
剩 670m 装不下 1 vCPU 的 Pod，导致只能单 AZ。`ac8.2xlarge.2`（8C16G，7910m）
可稳定 1 副本/AZ。

## 15. 销毁顺序：应用 → 集群 → 数据，且不要先删堡垒机

**现象**：`terraform destroy` 在
`huaweicloud_rds_pg_database.litellm` 处失败：
`DBS.1010155 Other users are accessing the database`。

**原因**：LiteLLM Pod 仍在连 PostgreSQL（连接池），数据库对象无法删除。
同时堡垒机若先被销毁，就再没有入口去 `helm uninstall` 释放连接。

**正确顺序**：
1. `helm uninstall` + 删除 `litellm` namespace（释放数据库连接）
2. 销毁 CCE（节点、集群）
3. 销毁 ELB、VPC、安全组
4. 最后销毁 RDS/DCS/KMS

Terraform 一次 destroy 不保证顺序，必要时用 `-target` 分步：
`-target=module.cce -target=module.elb`，再全量 destroy。

## 16. 运维脚本的两个自伤陷阱

1. **`pkill -f "<pattern>"` 会杀掉自己**：通过 ssh 执行的命令行本身包含该
   pattern，`pkill` 匹配到自身导致命令被 SIGKILL，表现为“执行后无输出”。
   用 `pgrep -x <进程名>` 精确匹配，或先查 PID 再 kill 具体 PID。
2. **`cmd | tail -N` 掩盖退出码**：见第 11 条。判成败只看退出码或
   `grep -E 'error|denied|failed'`，不要靠“最后几行看着正常”。

## 17. 纯内网验证：关掉 NAT 后服务仍可用

关闭 NAT 网关（同时删除 SNAT 规则与其 EIP）后复查：

- `/health/readiness` 仍返回 200，3 副本 Running
- 镜像可从内网 SWR（`100.125.x`）拉取，不依赖公网

证明架构不依赖公网出口。**注意**：之后若要给节点装包或拉公网镜像，
必须先经堡垒机下载并推 SWR，不能指望节点直连。

## 18. ELB 删除保护会阻断销毁

**现象**：`terraform destroy` 报
`ELB.8917 Deletion Protection of loadbalancer ... is enable`。

删除保护是安全最佳实践，但 IaC 建的对象会把它一起建出来，销毁前必须先关：

```bash
# PUT，body 用布尔值，字符串 "false" 无效
PUT https://elb.<region>.myhuaweicloud.com/v3/<project>/elb/loadbalancers/<lb-id>
{"loadbalancer": {"deletion_protection_enable": false}}
```

**建议**：把删除保护做成变量（默认开、销毁前显式关），或在
`docs/deployment.md` 的 teardown 步骤里加一条前置检查。

## 19. 销毁与清理的完整顺序（实测可用）

1. `helm uninstall` + 删除 namespace（释放 RDS 连接，否则数据库删不掉）
2. `terraform destroy -target=module.cce -target=module.elb`
   （集群里有 Pod 时数据层删不掉）
3. 关闭 ELB 删除保护（见第 18 条）
4. `terraform destroy` 全量（VPC/子网/ELB/RDS/DCS/KMS/CSMS）
5. 清理本地敏感产物：`$LITELLM_DEPLOY_HOME/out/bastion/app.env`、`$LITELLM_DEPLOY_HOME/state/bastion_key`、`.local/.bpass`
6. `./scripts/creds.sh clear` → `./scripts/handoff.py scrub` → `check` 必须输出 `clean`
7. **SWR 里的镜像不会随 Terraform 销毁**：`swr.<region>/<org>/litellm:<tag>`
   会继续占存储，需要另行删除组织或镜像。

## 20. 首次部署的最终验证结果（可作为回归基线）

| 检查 | 期望 |
|---|---|
| `kubectl get pods` | 3/3 Running，分布在 3 个不同 zone |
| `curl :443/health/readiness` | 200 |
| `curl -H "Authorization: Bearer $MASTER_KEY" :443/v1/models` | 200，返回配置的模型列表 |
| 不带 token 访问 `/v1/models` | 401 |
| 删除 1 个副本 | 60 秒内持续 200 |
| 关闭 NAT 后 | 上述全部仍成立 |

## 21. 二次改造：容器隧道网络 + Ingress 建 ELB

第一轮用的是 `vpc-router`（Pod 地址由 VPC 路由可达）+ Terraform 直接建 ELB +
Service `type=LoadBalancer` 绑 ELB。第二轮改成：

| 项 | 第一轮 | 第二轮 | 原因 |
|---|---|---|---|
| 容器网络 | `vpc-router` | `overlay_l2`（VXLAN/OVS 隧道，`172.16.0.0/16`，按 /28 块分给节点） | 不占 VPC 地址、不消耗子网、不需要逐段加路由；节点数增长不受子网大小限制 |
| 数据层放行 | `app` 子网 + `pod_cidr` | 只放行 `app` 子网 | 隧道模式下 Pod 出 VPC 被节点 SNAT 成节点地址，`pod_cidr` 规则永远不会命中 |
| ELB 归属 | Terraform 建（`module.elb`） | CCE Ingress 控制器按注解 `kubernetes.io/elb.autocreate` 建 | ELB 与 Ingress 生命周期一致，改端口/证书不用动 Terraform state |
| Service | `type=LoadBalancer` + ELB 注解 | `type=ClusterIP`，由 Ingress 暴露 | Ingress 才能拿到 L7 能力（多路径、按 Host 分流、WAF/证书统一管） |
| front subnet | ELB VIP 在 `access` | 不变：VIP 仍在 `access`，后端在 `app` | `vip_subnet_cidr_id` = access，`elb_virsubnet_ids` = app（backend），两者不能混用 |

判定口径（写死在代码里，不靠人记）：

- `elb_mode = ingress`（默认）→ `module.elb` 的 `count = 0`，Terraform 不建 ELB；
  `gateway_url` 输出为空，VIP 从 `kubectl -n litellm get ingress` 的
  `.status.loadBalancer.ingress[0].ip` 读。
- `elb_mode = standalone` → 回到第一轮模型，`elb_vip_address` 才允许填。

二次改造新引入的两个坑：

1. **`-target=module.elb` 在 ingress 模式下直接失败**：模块 `count = 0` 时
   Terraform 报 `no matching objects`。`apply-staged.sh` 的 `edge` 阶段会读
   `elb_mode`，ingress 模式下整段跳过。
2. **Helm values 里的 ELB 注解曾在两个脚本里各写一份**（`deploy.sh` 与
   `remote-deploy.sh`），改一处必然漂移。现在统一走
   `scripts/render-helm-values.py`。

## 22. 首次部署踩坑总表（按报错查）

每条都是第一轮真实撞到的，不是推演。按这个表查比读全文快。

| # | 现象 / 报错 | 根因 | 处置 |
|---|---|---|---|
| 1 | `The specified az cn-southwest-2f is not available for master volumes: volume type SAS is sold out` | 该 AZ 的 SAS 盘售罄；provider 1.99.1 的 `masters` 块**没有卷类型字段**，改不了盘型 | 换 AZ 建集群，或用单 master `cce.s1.small` 绕开。不要试图在 `masters` 里写 `volume_type`，schema 不接受 |
| 2 | `Security Group rule: conflict in the request` | `client_cidrs` / `admin_cidrs` / ops 子网填了同一个 `10.0.3.0/24`，三条规则去重后内容相同 | 规则按 `(sg_key, direction, protocol, ports, cidr)` 去重后再建，见 `maas-network/main.tf` |
| 3 | `CSMS.0401 Failed to encrypt or decrypt the secret value by using KMS` | 瞬时错误，同参数直接调 API 返回 200 | 重试；不要改配置。收尾删掉探测用的 secret |
| 4 | `EVS.2264` 节点数据盘加密失败 | 集群委托 `cce_admin_trust` 没有 KMS 权限 | `encrypt_node_volumes = false`（默认），或用有 KMS 权限的委托 |
| 5 | `Unexpected initial node password format` | 随机密码含 `"` `\` `/` 等被拒字符，或长度越界 | 8–26 位、至少三类字符、限定特殊字符集（`random_password.node` 已按此约束） |
| 6 | `DCS.4872 Do not support security group whitelist` | Redis 5.0/6.0 主备实例不支持安全组白名单 | 不传 `security_group_id`，靠data 子网隔离 + 密码 |
| 7 | 副本长期 `Pending`，`FailedScheduling: Insufficient memory` | 按总核数选机型，忽略系统组件占用（约 3.25 核 / 数百 MB） | 按**可分配量**反推：`ac8.2xlarge.2`（8C16G）实测 3 副本可跑，`c7.xlarge.2` 不行 |
| 8 | `flavor_id can't be updated`（直接改机型） | 节点规格不支持原地变更 | 先把 tfvars 改回旧机型 `destroy` 节点，再切新机型 `apply`；`-replace` 同样失败 |
| 9 | 迁移 Job `BackoffLimitExceeded`，Pod 连不上 RDS | 当时是 `vpc-router`，Pod 网段未被data 子网放行 | 已由架构消除：`overlay_l2` 下data 子网放行节点子网即可，不再需要 `pod_cidr` 规则 |
| 10 | ELB 报 `subnet ... could not be found` | ELB v3 要 **neutron 子网 id**，传 VPC 子网 id 会被拒 | 用 `data.huaweicloud_vpc_subnet` 取 `ipv4_subnet_id`；已封装成 `app_subnet_neutron_id` / `access_subnet_neutron_id` 输出 |
| 11 | `Deletion Protection of loadbalancer ... is enable`（`ELB.8917`），destroy 卡住 | ELB 默认开删除保护，provider 无对应字段 | 模块默认 `deletion_protection = false`；已建好的实例需先调 API 关保护再删 |
| 12 | Helm `another operation (install/upgrade/rollback) is in progress` | 上次安装中断留下 `pending-install` 锁 | `helm uninstall --no-hooks <release>` → 删残留 Job → 重装 |
| 13 | 配置里 3 个模型只加载了 1 个 / 完全没生效 | `config.yaml` 写成多文档（`---`），LiteLLM 只读第一个文档 | ConfigMap 用 `include` + `.Files.Get` 拼成**单文档**；仓库里不允许出现第二个 `---` |
| 14 | `cce_cluster_version` 填了不支持的版本，plan 阶段被拒 | 各区域支持版本不同且会变 | 留空让 SDK 调 `show_cluster_support_configuration` 解析（`scripts/resolve-cce-version.py`，无凭据时 exit 3） |
| 15 | 堡垒机 `curl` 网关被拦 | `admin_cidrs` 没包含 `10.0.0.0/24`（access 子网），而堡垒机在 ops 子网 | `admin_cidrs` 必须含access 子网与 ops 子网 |
| 16 | 镜像 push 报 401 / `SWR` 拒绝 AK/SK 直连 | SWR 需要临时登录指令，不接受长期 AK/SK 直接鉴权 | `scripts/mirror-image.sh` 走 `swr auth` 换 docker login |
| 17 | Pod 拉镜像极慢 / 超时 | 走公网 NAT 拉 Docker Hub | 堡垒机下载 → push SWR → Pod 只从内网 SWR 拉；NAT 可整体关闭（已验证） |
| 18 | `terraform destroy` 先删堡垒机后失联 | 销毁顺序错 | 应用 → 集群 → 数据 → 堡垒机；见第 19 条 |
| 19 | 资源删到一半 state 与云端不一致 | 删除保护、依赖倒序、ELB 归属 | 按第 19 条顺序；ingress 模式下先删 Ingress（ELB 随之删除）再删 VPC |
| 20 | `-target=module.elb` 在 ingress 模式报 `no matching objects` | 模块 `count = 0` | 用 `module.cce` 或整段跳过，见第 21 条 |
| 21 | 二轮 plan 里 NAT+EIP 又出现了；镜像又指回 `ghcr.io` | 第一轮已拍板的决策（`--close` NAT、镜像走 SWR）只改了云端/state，没改成 `deploy-inputs.yaml` 的默认值——重构时默认值把决策冲掉了 | 决策必须落到输入项与代码默认值：`model_endpoint_mode=none`（不建 NAT）、`image_supply_chain=swr` + `swr_org`（镜像引用由 Terraform 输出推导），并加 check 块与 deploy-app 前置校验拒绝回退 |

回归基线（第一轮实测，可作为第二轮对照）：3/3 Pod 跨 3 AZ、`/health/readiness`
200、`/v1/models` 返回配置模型、无 token 401、删 1 副本 60 秒内无 5xx、关 NAT 后
全部仍成立。
