# 参数填写指南 / Inputs guide

部署只需要改一个文件：**`deploy-inputs.yaml`**。填完运行
`./scripts/deploy.sh preflight`（或 `python3 scripts/preflight.py`），它会校验并生成下游
需要的全部产物。

## 为什么是这个形式

参数清单同时服务两类使用者：

| 使用者 | 读什么 | 怎么用 |
|---|---|---|
| 人 | `deploy-inputs.yaml` 的 `help` 字段 | 逐项填写，每项都有中文说明 |
| Agent | 同一文件的 `required` / `validate` / `allowed` | 按清单询问缺失项，按 `validate` 判断合法性 |
| Terraform | `out/` 下的渲染产物 | 不用再填一次 |

用 YAML 而不是表格，是因为它能在同一个文件里同时表达“值”和“校验规则”；表格适合
纯人工填写，但 agent 无法可靠地从表格里解析约束。想用表格视图时，运行
`python3 scripts/inputs-table.py` 会输出一份 Markdown 表格。

## 必填项（不填一定跑不起来）

| 参数 | 含义 | 常见填法 |
|---|---|---|
| `project_name` | 所有资源名的前缀 | `litellmtest01` |
| `owner` | 负责人/团队，写进标签 | `platform-team` |
| `region` | 区域 | `cn-north-4` |
| `vpc_cidr` | VPC 网段 | `10.0.0.0/22`（切 4 个 /24 + 1 个 /26；不能与数据中心、对端 VPC 重叠） |
| `subnet_app_cidr` 等 | access/app/data/ops 四个 /24 + 一个 /26 | 默认值可用，必须正好是 VPC 切出来的那几段 |
| `subnet_ops_cidr` | 运维子网，堡垒机所在 | `10.0.3.0/24`；可访问 VPC 内全部服务 |
| `client_cidrs` | 谁能调用网关 | `["10.20.0.0/16"]` |
| `admin_cidrs` | 谁能进 Admin UI / 密钥 API | `["10.20.10.0/24"]`（比上一条窄）。**必须同时包含运维子网和access 子网**，否则堡垒机 curl 网关会挂住 |
| `cce_container_network_type` | 容器网络模型 | `overlay_l2`（默认，隧道，不占 VPC 地址）；`vpc-router` / `eni` 为备选 |
| `pod_cidr` | 容器网段 | `172.16.0.0/16`，必须与 VPC、Service `10.247.0.0/16` 都不重叠 |
| `elb_mode` | 谁来创建 ELB | `ingress`（默认，CCE Ingress 自动建）；`standalone` 才由 Terraform 建 |
| `elb_l7_flavor_name` | 独享型 ELB 的 L7 规格 | 测试 `L7_flavor.elb.s1.small`，生产按并发调大 |
| `model_endpoint_mode` | 出网方式 | 纯内网选 `vpcep` |
| `modelarts_vpce_service_id` | ModelArts 私网接入 ID | 控制台「内网接入」页复制 |
| `tls_mode` | 传输加密方式 | 内网选 `internal_ca` |
| `certificate_id` | 证书 ID | SCM/ELB 里的证书 UUID |
| `encryption_mode` | 数据加密 | `kms` / `dew` / `disabled` |
| `grafana_endpoint` | 本机 Grafana 地址 | `http://10.20.30.40:3000` |

## 三个容易踩的坑

1. **CIDR 必须是私网地址。** preflight 会拒绝 `0.0.0.0/0` 和任何公网段——这是纯内网
   方案，公网暴露不是配置问题而是需求问题。唯一例外是 `bastion_ssh_cidrs`：它写的是
   运维 PC 的公网出口，只用于 SSH 到堡垒机。
2. **`admin_cidrs` 不是 `client_cidrs` 的子集也没关系，但不要更宽。** Admin UI 能创建
   密钥，它的可达范围应该比推理接口更小。
3. **加密的 `disabled` 分支只为实验。** 生产环境即使选 `dew`，也不要选 `disabled`。

## 凭据放哪

`deploy-inputs.yaml` 里永远不写密钥，只写**变量名**：

| 什么东西 | 放哪里 | 谁来填 |
|---|---|---|
| 华为云 AK/SK | `secrets/hw.env`（`./scripts/creds.sh set`，gitignore） | 部署方或客户 |
| 模型 API key | `secrets/app.env`，变量名与 `api_key_env` 一致 | 部署方或客户 |
| 其余参数 | `deploy-inputs.yaml` | 部署方或客户 |

把 `./scripts/handoff.py form` 的输出直接发给客户，上面写清了每一项该填到哪；测试
结束跑 `./scripts/handoff.py scrub && ./scripts/handoff.py check`，确认没有客户数据
留在机器上。

## 模型列表：直接粘贴表格

允许直接贴这种四列格式（`名称 | api_base | api_key | model`），我会转成 YAML：

```
glm-5.3 | https://<maas-vpce-ip>/v2/ | sk-xxx | openai/glm-5.3
deepseek-v4.1-flash | https://<modelarts-vpce-ip>/v1/ | | openai/deepseek-v4.1-flash
```

转换规则：

- 第 3 列 KEY **不写进** `deploy-inputs.yaml`，而是写进 `secrets/app.env`
  （已 gitignore），YAML 里只留 `api_key_env` 的变量名；
- 第 3 列为空表示该端点免认证，变量留空即可；
- 已有条目只追加不替换；
- 所有条目互为 fallback。

## 模型列表怎么写

`models` 是数组，可以写任意多组，每组字段：

```yaml
models:
  - name: glm-5.3                  # 对外模型名，客户端用这个调用
    model: glm-5.3                 # 上游真实模型名（渲染时自动加 openai/ 前缀）
    api_base: https://<vpce-ip>/v2/   # 留空则用 VPCEP 默认地址
    api_key_env: GLM_API_KEY       # 密钥放哪个环境变量
    mode: chat                     # chat | embedding | rerank | image_generation
    max_tokens: 8192
    rpm: null                      # 可选限速
    tpm: null
```

必填只有 `name`、`model`、`mode`；`api_base` 留空表示走 VPCEP 私网地址。
没有 `provider` 字段——所有模型都按 OpenAI 兼容协议调用。

密钥**不写在这个文件里**，放在 `secrets/app.env`（已 gitignore），部署时合并进
Kubernetes Secret。

## 渲染产物

preflight 通过后生成：

| 文件 | 用途 |
|---|---|
| `terraform/examples/cce-ha/terraform.tfvars` | Terraform 输入，**不要手改** |
| `out/helm-values.yaml` | Helm values（含模型列表，不含密钥） |
| `out/models.rendered.yaml` | 单看模型列表，便于 review |
| `out/deployment-plan.md` | 人读的部署计划（命名、网段、模型、容量） |
| `out/preflight.json` | agent 判读用的结构化结果 |

改了任何参数，重跑 preflight 即可，下游不需要再改。

## 版本

`litellm_version` 受 `version-presets.yaml` 约束：

- 等于 `preset`：直接部署；
- 高于 `preset` 但在 `max_compatible` 内：必须先走
  [升级流程](upgrade-procedure.md)，然后 `ACK_UPGRADE=1` 重跑 preflight；
- 高于 `max_compatible`：先更新预设文件（属于方案更新）。
