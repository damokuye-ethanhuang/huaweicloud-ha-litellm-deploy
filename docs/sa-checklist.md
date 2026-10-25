# SA 规划检查清单 / Solution-architect checklist

这是一份**动手前逐项打勾**的清单，不是解释文档。每一项都标注了它是
`[必选]` 还是 `[条件]`，以及对应到哪个参数或哪段代码——**能自动化的部分
`preflight` 会替你查**，剩下的必须人工确认。

用法：

```bash
# 1. 复制成本次部署的记录
cp docs/sa-checklist.md docs/sa-checklist.<项目名>.md

# 2. 逐项打勾；[必选] 项全部完成后才继续
# 3. 跑 preflight，它会复核标了 `preflight` 的项
./scripts/deploy.sh preflight
```

图例：`[必选]` 不做就无法上线 · `[条件]` 按场景取舍 · 最后一列写自动化归属。

---

## 1. 账号与区域

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` 区域已选定且资源同区域 | 全部资源落在同一 region，避免跨区流量费与延迟 | `preflight` |
| [ ] | `[必选]` 可用区不少于 2 个 | 3 AZ 可得 3 master HA；2 AZ 时控制面退化为单 master | `preflight` |
| [ ] | `[必选]` 账号已完成实名与配额检查 | CCE 节点、EIP、RDS、DCS、ELB 各配额够用 | 人工 |
| [ ] | `[条件]` 企业项目 | 多项目共账号时用 `enterprise_project_id` 隔离 | 人工 |
| [ ] | `[必选]` 部署用的 IAM 用户最小权限 | 不给 `Tenant Administrator`；按服务粒度授权 | 人工 |

## 2. 网络规划

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` VPC 网段不与对端冲突 | 要连 IDC / 其他 VPC 时先对齐网段，`/22` 起 | `preflight` |
| [ ] | `[必选]` 三子网按角色拆分 | access / app / data，每段 `/24` | `preflight` |
| [ ] | `[必选]` 数据子网只对应用子网开放 | RDS/DCS 安全组源为 app 网段，不是 `0.0.0.0/0` | `preflight` |
| [ ] | `[必选]` 容器网络不与 VPC 网段重叠 | `vpc-router` 用的是节点 ENI 上的地址段，`pod_cidr` 必须避开 VPC 及对端网段 | `preflight` |
| [ ] | `[条件]` VPCE 子网 | 要访问 ModelArts/MaaS 私网端点时启用，`/27` 足够 | `preflight` |
| [ ] | `[条件]` VPN / 专线 | 客户端在内网才需要；网段与 `client_cidrs` 对齐 | 人工 |

## 3. 外网边界

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` 网关不暴露公网 | ELB `internal=true`，不绑 EIP | `preflight` |
| [ ] | `[必选]` CCE 关闭公网 endpoint | 只留私网 kubeconfig | `preflight` |
| [ ] | `[必选]` 唯一的公网入口是堡垒机 | 按需 EIP，带宽 `bastion_eip_bandwidth_mbit`，用完可解绑 | `preflight` |
| [ ] | `[必选]` 堡垒机 SSH 来源收敛 | `bastion_ssh_cidrs` 只写运维出口 `/32`，禁止 `0.0.0.0/0` | `preflight` |
| [ ] | `[必选]` 运维独立子网 | ops 子网单独 /24，可访问 ELB/RDS/DCS/CCE API，不与应用混布 | `preflight` |
| [ ] | `[必选]` NAT 出口策略明确 | 模型后端在公网才需要 NAT；纯内网则不开 | 人工 |
| [ ] | `[条件]` 是否对外提供 MaaS | **本方案默认不做**；要做需另走安全评审并加 WAF | 人工 |

## 4. 计算与可用性

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` 单 Pod 资源下限 | 网关 Pod 需 4Gi 内存，节点最小 `c7.xlarge.2`（4C8G） | `preflight` |
| [ ] | `[必选]` 副本数 ≥ 2 且跨节点 | 否则单点故障；`PDB minAvailable=2` | `preflight` |
| [ ] | `[条件]` 反亲和 | 副本数 ≥ 3 时可开 podAntiAffinity 强制跨 AZ | `preflight` |
| [ ] | `[必选]` 滚动更新策略 | `maxUnavailable=0`，先起新再停旧 | `preflight` |
| [ ] | `[条件]` HPA | 有突发流量才开；`minReplicas` 不低于 PDB 值 | 人工 |

## 5. 数据层

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` RDS 主备（不是单机） | 规格名带 `.ha`；测试环境同样要求 | `preflight` |
| [ ] | `[必选]` DCS 主备（不是单实例） | 规格名带 `redis.ha.` | `preflight` |
| [ ] | `[必选]` 备份策略与保留期 | 自动备份开启，保留期按合规要求 | 人工 |
| [ ] | `[必选]` 迁移由 Job 执行 | 实例侧 `DISABLE_SCHEMA_UPDATE=true`，不并发建表 | `preflight` |
| [ ] | `[必选]` 表结构由 LiteLLM 官方迁移创建 | Prisma 迁移随镜像分发，禁止手写 SQL / 导入 dump | 人工 + `verify` |
| [ ] | `[必选]` 数据库账号非 root | 应用账号只有本库 DML/DDL 权限 | 人工 |

## 6. 加密与密钥

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` 三选一加密分支明确 | `kms` / `dew` / `disabled`，记录选择理由 | `preflight` |
| [ ] | `[条件]` KMS CMK | `kms` 分支下 RDS/DCS 磁盘加密引用同一 CMK | `preflight` |
| [ ] | `[必选]` 密钥由 IaC 生成 | 不复用现网密码、不手填明文 | 人工 |
| [ ] | `[必选]` `LITELLM_SALT_KEY` 备份 | **一旦改动，已加密的模型凭据全部失效且不可恢复** | 人工 |
| [ ] | `[必选]` 下游应用用 tenant key | master key 只留在运维侧，不下发给业务 | 人工 |
| [ ] | `[条件]` TLS | 内网是否启用 HTTPS；启用则需 `certificate_id` | `preflight` |

## 7. 可观测性

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` 日志落 LTS | 不依赖节点本地盘，滚动后仍可查 | 人工 |
| [ ] | `[必选]` 指标落 AOM | `/metrics` 被采集，保留期明确 | 人工 |
| [ ] | `[必选]` 告警规则已导入 | `monitoring/alerting-rules.yaml` → AOM | 人工 |
| [ ] | `[必选]` Grafana 看板已导入 | `monitoring/grafana-dashboard.json`，数据源指 AOM | 人工 |
| [ ] | `[条件]` 告警通知渠道 | SMN 主题已订阅（短信/邮件/IM） | 人工 |

## 8. 上线前

| | 项 | 要求 | 自动化 |
|---|---|---|---|
| [ ] | `[必选]` `terraform plan` 已人工复核 | 重点看删除/替换，`-/+` 要能解释 | 人工 |
| [ ] | `[必选]` smoke test 全绿 | `/health/readiness`、`/v1/models`、一次真实补全 | `smoke-test.sh` |
| [ ] | `[必选]` fallback 已验证 | 主动让主模型失败一次，确认切到备模型 | 人工 |
| [ ] | `[必选]` 回滚路径确认 | 镜像 tag 可回退、迁移 Job 可重跑 | 人工 |
| [ ] | `[必选]` 成本已估算并确认 | 对照 `docs/cost.md` | 人工 |

---

## 附：本方案默认值（改动需说明理由）

| 项 | 默认 | 偏离原因 |
|---|---|---|
| 可用区数 | 3 | |
| 节点规格 | `c7.xlarge.2` × 1/AZ | |
| 容器网络 | `vpc-router`，不新建容器子网 | |
| 网关副本 | 3，`PDB minAvailable=2` | |
| 外网暴露 | 仅堡垒机 EIP，网关零公网 | |
| 数据层 | RDS PG 主备 + DCS Redis 主备 | |
| 加密 | `kms` | |
| Key 计费配额 | 不启用（仅做模型权限隔离） | |
