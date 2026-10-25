# 监控接入 / Monitoring

日志 → **LTS**，指标 → **AOM**，看板 → **本机 Grafana**。所有链路都在内网，
Grafana 不需要公网暴露：它主动去拉 AOM 的 Prometheus 兼容端点。

```
Pod stdout ──► LTS 日志组/流        ──► Grafana (Loki 不适用，LTS 用其 SQL/API)
Pod /metrics (4000) ──► AOM ──► Prometheus 兼容 API ──► 本机 Grafana
AOM 告警规则 ──► SMN 主题 ──► 短信 / 邮件 / IM
```

## 1. 日志进 LTS

Terraform 已创建日志组和日志流（`observability` 输出里有 ID）。剩下的是采集配置：

```bash
# 在 CCE 控制台：集群 → 运维中心 → 日志中心 → 创建采集策略
#   - 容器的 stdout（LiteLLM 走 stdout，结构化 JSON 行）
#   - 采集到 terraform output 里的 lts_log_group_id / lts_log_stream_id
```

验证：

```bash
hcloud lts list-logs --log_group_id <id> --log_stream_id <id> --limit 5
```

LiteLLM 的每个请求在 stdout 有一行 JSON，可用 LTS SQL 直接查慢请求：

```sql
SELECT request_id, model, total_tokens, latency
FROM <stream>
WHERE latency > 30
ORDER BY latency DESC
LIMIT 50
```

## 2. 指标进 AOM

LiteLLM 在 Pod 的 `:4000/metrics` 暴露 Prometheus 指标。chart 已给 Pod 打上采集注解：

```yaml
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "4000"
  prometheus.io/path: "/metrics"
  prometheus.io/allow: "true"
```

```bash
# 确认注解已生效
kubectl get pods -n litellm -o jsonpath='{.items[0].metadata.annotations}'

# 直连一个 Pod 看指标有没有出来（堡垒机上执行）
kubectl -n litellm port-forward deploy/litellm 4000:4000 &
curl -s localhost:4000/metrics | grep '^litellm_' | head -20
```

然后在 CCE 控制台启用 **Prometheus 插件**并指向 AOM（Terraform 的
`metric_backend="aom"` 分支已创建 AOM Prometheus 实例，端点见
`terraform output observability.aom_query_url`）。

## 3. 告警规则导入

```bash
# 规则文件是 AOM 告警规则的声明式描述，含阈值、窗口、runbook 链接
cat monitoring/alerting-rules.yaml
```

导入路径：AOM 控制台 → 告警管理 → 告警规则 → 导入。规则里 `${PROJECT_NAME}`
需要替换成你的项目名：

```bash
sed -i "s/\${PROJECT_NAME}/litellmtest01/" monitoring/alerting-rules.yaml
```

规则按四组划分——**可用性 / 延迟 / 错误 / 饱和与依赖**。其中
`litellm-queueing-requests`（剩余槽位归零）是最有价值的先行指标：
用户还没感知到慢，它已经在告诉你该加副本了。

告警需要通知渠道，先建 SMN 主题并订阅：

```bash
hcloud smn create-topic --name litellm-alerts
hcloud smn subscribe --topic-urn <urn> --protocol email --endpoint ops@example.com
```

## 4. 本机 Grafana

```bash
docker run -d --name grafana -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD="$(terraform -chdir=terraform/examples/cce-ha output -raw grafana_admin_password 2>/dev/null || echo admin)" \
  grafana/grafana-oss:11.2.0
```

数据源指向 AOM 的 Prometheus 兼容端点：

```text
Configuration → Data sources → Add Prometheus
  URL: <terraform output -raw observability.aom_query_url>
  Auth: 华为云 AK/SK 或 AOM 提供的 Bearer Token
  Scrape interval: 30s
  HTTP method: POST          # AOM 的 query 接口只接受 POST
```

导入看板：

```bash
# Grafana → Dashboards → New → Import → Upload JSON file
monitoring/grafana-dashboard.json
```

看板分五段：总览（存活副本、QPS、失败占比、P95、fallback 速率）、
吞吐与延迟、错误与回退、容量与资源、数据层。

`datasource` 变量在导入后选你刚建的 Prometheus 数据源即可。

## 5. 指标名对照

| 面板用到 | 来源 | 说明 |
|---|---|---|
| `litellm_request_total_latency_metric` | LiteLLM | 直方图，算 P50/P95/P99 |
| `litellm_request_total_failures_metric` | LiteLLM | 计数器，按 model/status_code |
| `litellm_fallback_responses_metric` | LiteLLM | fallback 触发次数 |
| `litellm_remaining_requests_metric` | LiteLLM | 剩余并发槽位，饱和先行指标 |
| `litellm_deployment_cooled_down` | LiteLLM | 被路由摘流的模型数 |
| `kube_pod_status_ready` / `kube_pod_container_status_restarts_total` | kube-state-metrics | 就绪与重启 |
| `container_cpu_usage_seconds_total` | cAdvisor | CPU |
| `rds_cpu_util` / `rds_connections_usage` | AOM | RDS 指标 |
| `dcs_memory_usage` / `dcs_hit_ratio` | AOM | DCS 指标 |

> 指标名以 LiteLLM 1.106.3 的导出器为准。升级后先跑
> `curl :4000/metrics` 核对，再更新本表与告警规则——**改名会让告警静默失效**，
> 这是升级检查单里必查的一项。

## 6. 没有 Grafana 时的最低限度

只要两条命令就能判定健康：

```bash
kubectl -n litellm get pods                       # 3/3 Ready
./scripts/smoke-test.sh                           # readiness + models + 一次补全
```
