# 手工部署指导 / Manual deployment

不使用本仓库脚本、完全手工在控制台点出来的部署路径。适合以下场景：不允许在运维 PC
上装 Terraform、需要理解每一步在做什么、或者要把流程交接给不熟悉 Git 的同事。

> 参数全部来自 `deploy-inputs.yaml`。本文出现的 `{项目名}` 指该项的
> `project_name`，例如 `litellmtest01`。资源命名规则：
> **`{项目名}-{组件}`**，所以 VPC 叫 `litellmtest01-vpc`、CCE 叫
> `litellmtest01-cce`，以此类推。

## 0. 前置条件

| 项 | 要求 |
|---|---|
| 账号 | 已完成实名认证，余额充足，非欠费状态 |
| 权限 | 能创建 VPC / ELB / CCE / RDS / DCS / KMS / CSMS / LTS / AOM / VPCEP |
| 区域 | 按 `deploy-inputs.yaml` 的 `region`，本文以 `cn-north-4` 为例 |
| 证书 | 内部 CA 证书已签发（PEM），并已上传到 SCM |
| 镜像 | 内网无法访问 `ghcr.io` 时，先把镜像同步到 SWR（见第 8 步） |

**AZ 提醒**：不要假设 AZ 是 a/b/c。`cn-southwest-2` 是 `2a/2d/2e`。创建资源前先在
「弹性云服务器 → 创建实例」页面的可用区下拉框里确认本区域真实存在的 AZ。

## 1. 网络

### 1.1 VPC

| 字段 | 值 |
|---|---|
| 名称 | `{项目名}-vpc` |
| IPv4 网段 | `vpc_cidr`，如 `10.0.0.0/16` |
| 企业项目 | 按需 |

### 1.2 子网（4 个）

| 名称 | 网段 | 用途 | 可用区 |
|---|---|---|---|
| `{项目名}-subnet-app` | `subnet_app_cidr` | CCE 节点 + 内网 ELB VIP | AZ1 |
| `{项目名}-subnet-data` | `subnet_data_cidr` | RDS、DCS | AZ2 |
| `{项目名}-subnet-vpce` | `subnet_vpce_cidr` | VPCEP 终端节点 | AZ1 |
| `{项目名}-subnet-eni` | `subnet_eni_cidrs[0..2]` | CCE Turbo 容器网段，每 AZ 一个 | AZ1/2/3 |

创建时把 DNS 服务器填上区域默认值（通常 `100.125.1.250` / `100.125.21.250`），
CCE 节点安装依赖 DNS。

## 2. 安全组

### 2.1 `{项目名}-sg-elb`（内网 ELB）

| 方向 | 协议/端口 | 源 | 说明 |
|---|---|---|---|
| 入站 | TCP 443 | `client_cidrs` | 业务系统调用网关 |
| 入站 | TCP 443 | `admin_cidrs` | Admin UI（可合并到上一条，但建议单独记录） |
| 出站 | 全部 | `0.0.0.0/0` | 健康检查与回源 |

### 2.2 `{项目名}-sg-data`（数据库）

| 方向 | 协议/端口 | 源 | 说明 |
|---|---|---|---|
| 入站 | TCP 5432 | `vpc_cidr` | 只允许 VPC 内访问 PostgreSQL |
| 入站 | TCP 6379 | `vpc_cidr` | 只允许 VPC 内访问 Redis |
| 出站 | 全部 | `0.0.0.0/0` | 备份、监控 |

默认规则里那条 `0.0.0.0/0` 入站必须删掉。

## 3. 加密密钥（KMS）

按 `encryption_mode` 三选一：

| 分支 | 操作 |
|---|---|
| `kms` | KMS → 创建密钥，别名 `{项目名}-kms`，开启自动轮换（90 天），记下密钥 ID |
| `dew` | 不创建，向安全团队索取已有密钥 ID，并确认当前账号有 `kms:key:decrypt` 权限 |
| `disabled` | 跳过本节；后面创建 RDS/CCE 时不要勾选磁盘加密（仅实验） |

## 4. 数据库 PostgreSQL（RDS）

| 字段 | 值 |
|---|---|
| 实例名称 | `{项目名}-rds` |
| 引擎版本 | PostgreSQL 16 |
| 实例类型 | 主备 |
| 规格 | `rds_flavor` 对应的规格（如 4 核 16G） |
| 存储 | 100 GB，SSD |
| 可用区 | AZ1 + AZ2（主备） |
| 网络 | `{项目名}-vpc` / `{项目名}-subnet-data` |
| 安全组 | `{项目名}-sg-data` |
| 磁盘加密 | 第 3 步的密钥 |
| 备份 | 自动备份，保留 7 天 |

创建完成后：

1. 记下**内网地址**与端口（5432）。
2. 进入「数据库管理」，创建数据库 `litellm`（字符集 UTF8）。
3. 管理员密码设为一个强随机值，**立刻**保存到 CSMS 的
   `{项目名}-litellm-db-password`。

## 5. 缓存 Redis（DCS）

| 字段 | 值 |
|---|---|
| 实例名称 | `{项目名}-dcs` |
| 版本 | Redis 7.0 |
| 类型 | 主备 |
| 规格 | `dcs_flavor` 对应规格（如 2 GB） |
| 可用区 | AZ1（主）+ AZ2（备） |
| 网络 | `{项目名}-vpc` / `{项目名}-subnet-data` |
| 安全组 | `{项目名}-sg-data` |

记下内网地址与端口，密码保存到 CSMS 的
`{项目名}-litellm-redis-password`。

## 6. 容器集群（CCE）

| 字段 | 值 |
|---|---|
| 集群名称 | `{项目名}-cce` |
| 集群类型 | CCE Turbo（容器网络 `eni`） |
| 版本 | 1.31 |
| 规格 | `cce.s2.small`（50 节点以内） |
| 控制面 | 3 个 master，分别在 AZ1/2/3 |
| 网络 | `{项目名}-vpc` / `{项目名}-subnet-app` |
| 容器子网 | 三个 `{项目名}-subnet-eni` |
| 认证 | RBAC |

创建后添加 3 个节点池，每 AZ 一个：

| 节点池 | 规格 | 系统盘 | 数据盘 | 数量 |
|---|---|---|---|---|
| `{项目名}-pool-az1` | `node_flavor`（如 4 核 16G） | SSD 50 GB | SSD 100 GB | 1 |
| `{项目名}-pool-az2` | 同上 | 同上 | 同上 | 1 |
| `{项目名}-pool-az3` | 同上 | 同上 | 同上 | 1 |

磁盘加密选第 3 步的密钥（`disabled` 分支不选）。

## 7. 内网负载均衡（ELB）与证书

1. SCM → 上传内部 CA 证书，拿到证书 ID。
2. ELB → 创建独享型实例：

| 字段 | 值 |
|---|---|
| 名称 | `{项目名}-elb` |
| 类型 | 独享型 |
| 规格 | 弹性规格（按 LCU 计费） |
| 网络类型 | **私网**（不绑定 EIP，纯内网方案的关键） |
| 子网 | `{项目名}-subnet-app` |
| 可用区 | AZ1 + AZ2 |
| 安全组 | `{项目名}-sg-elb` |

记下自动分配的**私网 IP**，业务的内部 DNS 记录指向它。

## 8. 镜像同步到 SWR（内网必做）

控制台「容器镜像服务 → 我的镜像 → 客户端上传」页面会给出登录命令。手工执行：

```bash
# 1. 拉取上游镜像（在有外网的机器上）
docker pull ghcr.io/berriai/litellm:1.106.3

# 2. 登录 SWR，用户名格式为 {区域}@{AK}
docker login swr.cn-north-4.myhuaweicloud.com -u cn-north-4@<AK>

# 3. 打标签并推送
docker tag ghcr.io/berriai/litellm:1.106.3 \
  swr.cn-north-4.myhuaweicloud.com/<组织>/litellm:1.106.3
docker push swr.cn-north-4.myhuaweicloud.com/<组织>/litellm:1.106.3
```

## 9. 观测后端

### 9.1 LTS 日志

1. LTS → 创建日志组 `{项目名}-lts`，保留 30 天。
2. 在组内创建两个日志流：`{项目名}-lts-elb-access`、`{项目名}-lts-app`。
3. 回到 ELB 详情页 → 访问日志 → 关联日志组和 `-elb-access` 日志流。

### 9.2 AOM 指标

AOM → Prometheus 实例 → 新建，名称 `{项目名}-aom`，类型 CCE，保留期 360h。
记下 **HTTP API 地址**，本地 Grafana 用它做数据源。

### 9.3 本地 Grafana

Grafana 在**本地**安装，不在云上：

```bash
docker run -d --name grafana -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD='<强口令>' \
  grafana/grafana:11.2.0
```

数据源填 AOM 的 HTTP API 地址（认证方式参考 AOM 控制台给出的示例），看板在
Grafana 里编排。管理口令存 CSMS 的 `{项目名}-grafana-admin`。

## 10. 密钥（CSMS）

按表格建 5 条凭据，名称必须与部署清单一致：

| 凭据名称 | 内容 |
|---|---|
| `{项目名}-litellm-master-key` | `sk-` 开头的 48 位随机串（Admin UI 登录 + 管理 API） |
| `{项目名}-litellm-salt-key` | `sk-` 开头的 48 位随机串（加密 provider 凭据，**永不更换**） |
| `{项目名}-litellm-db-password` | 第 4 步的数据库密码 |
| `{项目名}-litellm-redis-password` | 第 5 步的 Redis 密码 |
| `{项目名}-grafana-admin` | 第 9.3 步的 Grafana 口令 |

生成随机串：`openssl rand -hex 24`（前面加 `sk-`）。

## 11. 部署 LiteLLM

在 CCE 集群里创建命名空间 `litellm`，然后：

1. 创建 Secret `litellm-secrets`（密钥管理 → 创建密钥 → `kubernetes.io/dockerconfigjson`
   之外的「Opaque 密钥」），内容为上面 5 条中的前 4 条，键名分别是
   `LITELLM_MASTER_KEY`、`LITELLM_SALT_KEY`、`DATABASE_URL`
   （形如 `postgresql://root:<密码>@<RDS内网地址>:5432/litellm?schema=public`）、
   `REDIS_PASSWORD`，再加上模型密钥（如 `GLM_API_KEY`，与 `api_key_env` 同名）。
2. 创建 ConfigMap `litellm-config`，`config.yaml` 内容按
   `out/models.rendered.yaml`（模型列表）+ 下面的静态段拼成**一个 YAML 文档**：

```yaml
model_list:
  - model_name: glm-5.3
    litellm_params:
      model: openai/glm-5.3
      api_key: os.environ/GLM_API_KEY
      api_base: http://<VPCEP私网IP>/v2/
    model_info:
      mode: chat

router_settings:
  routing_strategy: simple-shuffle
  num_retries: 2
  timeout: 600
  redis_host: <DCS内网地址>
  redis_port: 6379
  redis_password: <Redis密码>

litellm_settings:
  drop_params: true
  cache: true
  cache_params:
    type: redis
    host: <DCS内网地址>
    port: 6379
    password: <Redis密码>

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true
  proxy_batch_write_at: 60
  database_connection_pool_limit: 10
  trusted_proxy_ranges:
    - 10.0.0.0/8
```

> 必须是单文档。分成 `---` 两段时 LiteLLM 只读第一段，模型列表会静默丢失
> （已在 1.106.3 上验证）。

3. 创建**迁移任务**（一次性 Job，跑在 Deployment 之前）：

```yaml
apiVersion: batch/v1
kind: Job
metadata: {name: litellm-migrate, namespace: litellm}
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 1800
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: swr.cn-north-4.myhuaweicloud.com/<组织>/litellm:1.106.3
          args: ["--skip_server_startup"]
          envFrom: [{secretRef: {name: litellm-secrets}}]
          env:
            - {name: DISABLE_SCHEMA_UPDATE, value: "false"}
```

等到 Job 显示「已完成」，看日志出现 `All migrations have been successfully applied`
和 `Request-log indexes are all in place`。

4. 创建**工作负载**（无状态 Deployment），3 副本：

| 字段 | 值 |
|---|---|
| 名称 | `litellm` |
| 镜像 | SWR 中的 `litellm:1.106.3` |
| 容器端口 | 4000 |
| 启动命令 | `--config /app/config/config.yaml --port 4000 --num_workers 1` |
| 环境变量 | 从 Secret `litellm-secrets` 全量导入，另加 `DISABLE_SCHEMA_UPDATE=true`、`STORE_MODEL_IN_DB=True` |
| 挂载 | ConfigMap `litellm-config` → `/app/config` |
| CPU / 内存 | 请求=限制：1 核 / 4 GiB |
| 存活探针 | `GET /health/liveliness`，15s |
| 就绪探针 | `GET /health/readiness`，10s |
| 优雅退出 | preStop `sleep 10`，宽限期 90s |
| 调度 | 反亲和：3 个副本分布到不同 AZ |

5. 创建**服务**：类型 `负载均衡`，选择第 7 步的内网 ELB，端口 443 → 容器 4000，
   协议 HTTPS，证书选第 1 步的证书。

## 12. 验收

在能访问 `client_cidrs` 网段的机器上：

```bash
curl -s https://<ELB私网IP>/health/liveliness          # "I'm alive!"
curl -s https://<ELB私网IP>/health/readiness           # {"status":"healthy","db":"connected"}
curl -s https://<ELB私网IP>/v1/models \
  -H "Authorization: Bearer <master key>"              # 列出模型
curl -s https://<ELB私网IP>/v1/chat/completions \
  -H "Authorization: Bearer <master key>" \
  -H 'Content-Type: application/json' \
  -d '{"model":"maas-deepseek","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
```

四项全过，才算部署完成。Admin UI 在 `https://<ELB私网IP>/ui`。

## 13. 手工部署与脚本部署的差异

| 项 | 手工 | 脚本 |
|---|---|---|
| 参数来源 | 照着 `deploy-inputs.yaml` 抄 | 由 preflight 自动渲染 |
| 命名 | 手工保证 `{项目名}-` 前缀 | 命名模块强制 |
| 密码 | 手工生成并录入 CSMS | Terraform 生成并写 CSMS |
| 迁移 | 手工创建 Job | chart 的 pre-upgrade 钩子 |
| 版本门禁 | 需要自己对照 `version-presets.yaml` | preflight 自动拦截 |
| 适合 | 一次性、审计要求、无 CI | 日常与多环境 |

手工路径不做状态管理，**不要**和脚本路径混用同一套资源：一旦用脚本接管，Terraform
会认为这些资源都不存在并尝试重建。二选一。
