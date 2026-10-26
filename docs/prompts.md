# 三阶段提示词（直接粘贴）

每个阶段一段，**互相独立**：你可以只贴第 2 阶段，前提是第 1 阶段的 `plan` 已经由你确认。
agent 会先读 `skills/litellm-huaweicloud-deploy/SKILL.md` 和 `AGENTS.md`，那两份文件是流程与禁止事项的权威。

| 阶段 | 做什么 | 产物 / 判据 |
|---|---|---|
| [1 参数](#阶段-1参数确认) | 填 4 个值，跑 preflight + plan | 0 blocking；plan 摘要经你确认 |
| [2 基线](#阶段-2基础设施与网关基线) | 建资源，部署不含模型的网关 | 3 副本 Running；`/v1/models` 返回 `[]` |
| [3 模型](#阶段-3导入模型) | 导入模型与 fallback | 模型列表正确；一次真实 completion |

---

## 阶段 1：参数确认

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

---

## 阶段 2：基础设施与网关基线

```text
继续第 2 阶段：创建基础设施并部署网关基线。**这一步不涉及任何模型。**

前提（如果没满足，先停下告诉我）：preflight 显示 0 blocking，plan 已经我确认。

【按顺序执行】
1. 镜像先到位。在堡垒机上执行 ./scripts/mirror-image.sh 1.106.3
   （脚本会自己预检网络与鉴权、拉取、推送、校验 manifest）。
   如果 SWR 控制台里已经有 litellm:1.106.3，跳过这步并明确告诉我"复用已有镜像"。
2. 在本机执行 ./scripts/deploy.sh apply-infra（20–40 分钟）。
   想逐资源看进度就用 ./scripts/deploy.sh apply-stream；无论哪种，每 2–3 分钟
   给我一句话进展（正在建什么、已完成多少、有没有卡住），不要长时间静默。
3. apply 成功后执行 ./scripts/deploy.sh bastion-key，把堡垒机私钥写到
   ~/.litellm-deploy/state/（Terraform 生成密钥对时才需要）。
4. 执行 ./scripts/deploy.sh --remote deploy-app。helm 必须跑在堡垒机上：
   集群没有公网端点，本机连不上 API Server。
5. 执行 ./scripts/deploy.sh --remote verify。

【本阶段验收标准，缺一不可】
- 堡垒机上 kubectl get pods -n litellm 三个副本都 Running（不是 Pending、不是 CrashLoop）
- /health/readiness 返回 db: connected 和 redis: connected
- /v1/models 返回 200 且是空数组 [] —— 这是本阶段的正确结果：控制面就绪、模型层尚未加载
- 不带 key 调用 /v1/models 返回 401

【规则】
- 不要修改 deploy-inputs.yaml、terraform/、charts/、scripts/。发现问题就报告，由我决定是否改代码。
- 不要往 models.yaml 里加模型：模型是第 3 阶段。
- 任何一步失败立刻停下，报四件事：失败的阶段名、原始错误输出、你的判断、建议的下一步。
  同一个失败最多重试一次；不允许通过跳过检查、放宽安全组、加 EIP/NAT、动 tfstate 的方式绕过。
- 不要把任何密钥明文打印出来；Terraform 的 sensitive 输出必须脱敏后再贴给我。

【结束时给我】
apply 创建的资源数量、三个副本的状态、readiness 原文、/v1/models 原文，
以及你对下一步（第 3 阶段）的建议。
```

---

## 阶段 3：导入模型

```text
第 3 阶段：把模型和 fallback 导入已经跑起来的网关。不要动基础设施。

【准备】
1. 我先给你模型信息，格式通常是：名称 | 端点 | key | 上游模型 ID。
   你按 models.yaml 的结构写进去：name / model / mode / api_base / api_key_env。
   - name 是对外契约（客户端用 "model": "glm-5.3" 调用），一旦确定不要改名；
     换上游只改 model 或 api_base。
   - key 不要写进 YAML：写进 ~/.litellm-deploy/secrets/app.env，YAML 里只用 api_key_env 引用变量名。
   - api_base 留空表示走 ModelArts VPCEP 默认地址。
2. fallback 默认开启且为两两互备；模型超过三个时，和我确认要不要显式写 pairs。

【执行】
3. 先跑 ./scripts/deploy.sh models --check，把 diff 原样给我：
   新增了哪些、删除了哪些、哪些字段改了、fallback 关系有没有变化。这一步不会动集群。
4. 我确认之后跑 ./scripts/deploy.sh models --apply。
   它会重新渲染配置、走和 deploy-app 相同的 helm 路径、并保存快照。
5. 如果滚动过程中有 Pod 没起来，立刻停下报错，不要反复 apply。

【验收标准，缺一不可】
- /v1/models 返回的列表与 models.yaml 完全一致（数量、name 都要对）
- 用 master key 做一次真实的 chat completion，非流式成功一次、流式成功一次
- 测一次 fallback：把某个模型的 api_base 临时指向不可达地址 → models --apply →
  发请求确认自动切到备用模型 → 改回并再次 apply。这一步慢但必须做，否则 fallback 只是配置里的字面值。
- 确认模型请求的延迟与上游一致（不是被缓存或 429 挡掉）

【规则】
- 不要改 terraform/、charts/、scripts/、deploy-inputs.yaml。
- 不要动 store_model_in_db / STORE_MODEL_IN_DB：模型只从 models.yaml 进来，
  在 Admin UI 里加模型会造成两份来源分叉。如果 UI 里出现 models.yaml 之外
  的模型，立刻告诉我。
- 出问题用 ./scripts/deploy.sh models --rollback 回到上一版，不要手改 ConfigMap。

【结束时给我】
/v1/models 原文、一次 completion 的请求与响应（脱敏）、fallback 实测结论、
当前快照路径，以及回滚命令。
```

---

## 收尾：封网（三阶段完成之后）

部署验证通过、模型也导完了，最后把仅有的公网入口去掉。整套设计里只有堡垒机有 EIP，
封网就是删掉它——之后 VPC 里没有任何资源能从公网访问。

```text
三阶段都完成了，现在做封网收尾。

【前提检查，缺一不可】
- 第 2 阶段验收已过：三个副本 Running、readiness db/redis connected
- 第 3 阶段验收已过：/v1/models 与 models.yaml 一致、一次真实 completion 成功
- 我已经不需要再从公网 SSH 进堡垒机了（封网后进不去，只能从 VPC 内访问）

【执行】
1. 跑 CONFIRM 未设置的形式：./scripts/deploy.sh seal
   它会：把 deploy-inputs.yaml 的 bastion_eip_enabled 改成 false → 渲染 → terraform plan，
   然后把 plan 给我看。这一步不会真的删东西。
2. 我看完 plan（应该只有 EIP 和它的绑定关系两个资源被销毁）说「确认」，
   你再跑 CONFIRM=yes ./scripts/deploy.sh seal。
3. 脚本会自己校验：bastion_public_ip 必须为空、state 里不能再有 huaweicloud_vpc_eip。

【验收】
- terraform output bastion_public_ip 返回空
- terraform state list 里没有 huaweicloud_vpc_eip
- 用封网前的那个公网 IP 去 ssh，应该超时（不是拒绝）
- 集群内 kubectl get svc/ingress 仍然正常（内网 ELB VIP 不受影响）

【规则】
- 不要手工去控制台删 EIP，也不要用 SDK 直接调 API：那样 Terraform state 会和现实不一致，
  下次 apply 会试图重建。
- 不要顺手删别的 EIP：脚本只处理本套 stack 创建的那一个。
- 需要再运维时用 CONFIRM=yes ./scripts/deploy.sh unseal（会重新申请 EIP，IP 会变）。

【结束时给我】
seal 前后的资源数、bastion_public_ip 的值（应为空）、以及一句"当前无公网入口"的确认。
```
