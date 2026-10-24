# 升级流程 / Upgrade procedure

本文是 `version-presets.yaml` 中 `upgrade_guide` 指向的过程。凡是把
`litellm_version` 提到 preset 之上的改动，都必须走完本文并在 PR 里留下记录。

> ⚠️ 升级**不是只改镜像 tag**。版本一变，配置项、指标名、迁移脚本、默认值都可能跟着变，
> 因此要走完一遍完整的方案更新：Release Notes 差异 → 配置兼容性 → 指标与告警核对 →
> 迁移验证 → 灰度 → 回滚预案 → 更新 preset 与文档。跳过的每一步都会在下次故障时补回来。

## 判定矩阵

| 目标版本 | preflight 结果 | 需要做的事 |
|---|---|---|
| = `preset` | 通过 | 直接部署 |
| < `preset` | 警告 | 降级不可逆，先备份；确认旧版本能兼容当前库结构 |
| preset < v ≤ `max_compatible` | **阻断** | 走完本文，然后 `ACK_UPGRADE=1` 重跑 preflight |
| > `max_compatible` | **阻断**（ACK 无效） | 先更新 `version-presets.yaml`，属于方案更新 |

`ACK_UPGRADE=1` 只表示“流程已走完”，不改变任何技术行为；它存在的目的是让跳过流程
这件事必须留下显式痕迹。

## 步骤

### 1. 版本调研（写进 PR 描述）

- 读目标版本的 release notes，逐条记录 **Action required** 与迁移相关条目。
- 从 `preset` 到目标版本之间，列出所有跨过的次版本。
- 对照 `version-presets.yaml` 的 `compatibility` 检查 PostgreSQL / Redis / K8s
  的最低版本要求是否仍然满足。

### 2. 迁移演练（必须做，且必须用还原库）

```bash
# 从最近的 RDS 备份还原出一个临时实例，取其连接串
export DATABASE_URL='postgresql://.../<临时库>?schema=public'
docker run --rm -e DATABASE_URL="$DATABASE_URL" \
  -e DISABLE_SCHEMA_UPDATE=false \
  ghcr.io/berriai/litellm:<目标版本> --skip_server_startup
```

记录：迁移耗时、新增/变更的表与索引、是否有表重建或数据回填。

判定标准：

- 迁移耗时必须小于 `migration.activeDeadlineSeconds`（默认 1800s），并留 50% 余量；
- 若存在大表索引构建，评估窗口期与 RDS 磁盘/IOPS 余量；
- 演练后库可以丢弃，不要复用。

### 3. 变更参数

只改 `deploy-inputs.yaml` 里的 `litellm_version`，其余参数不动：

```yaml
sizing:
  - key: litellm_version
    value: "1.106.6"     # 原 1.106.3
```

### 4. 预检 + 计划

```bash
ACK_UPGRADE=1 ./scripts/deploy.sh preflight
./scripts/deploy.sh plan        # 只应出现镜像 tag 变化
```

`plan` 里若出现基础设施变更，说明改动越界，停止并排查。

### 5. 备份

```bash
# 手动备份当前 RDS 实例（控制台「备份与恢复 → 手动备份」），记录备份 ID
```

回滚镜像不会回滚库结构，备份是唯一可靠的退路。

### 6. 执行

```bash
./scripts/deploy.sh deploy-app
```

执行顺序由 chart 保证：

1. `pre-upgrade` 钩子跑迁移 Job（`--skip_server_startup`）；
2. 迁移成功才滚动更新 Deployment（`maxSurge: 1`、`maxUnavailable: 0`）；
3. 迁移失败则发布会中止，旧 Pod 继续服务。

### 7. 验证

```bash
./scripts/deploy.sh verify
MODEL=<你的模型名> ./scripts/smoke-test.sh
```

必须确认：`/health/readiness` 返回 `db: connected`，且至少一次真实推理成功。

### 8. 记录

在 PR 中附上：release notes 摘要、迁移耗时、演练结论、验证输出。这批内容就是
`version-presets.yaml` 下次更新的依据。

## 回滚

```bash
helm -n litellm history litellm
helm -n litellm rollback litellm <上一个 revision>
```

若目标版本已执行过 schema 迁移，旧版本可能无法启动，此时只能还原步骤 5 的备份。

## 更新 preset 本身

`preset` 代表“经过验证的基线”。确认目标版本在真实环境稳定运行一段时间（建议至少
一个完整业务周期）后，才在 PR 中把 `preset` 提到该版本，并同步更新
`README.md`、`CHANGELOG.md` 和 `max_compatible`。这是方案更新，不是日常升级。
