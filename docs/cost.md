# Cost

Prices move and differ per site. These are the figures from Huawei Cloud's
official LiteLLM solution page (Hong Kong region, on-demand, 2026-09) for a
comparable topology. They are a sanity check, not a quote — use the price
calculator for your region and contract.

## Reference topology

| Resource | Spec | Quantity | Reference price |
|---|---|---|---|
| ECS (CCE workers) | `c7n.2xlarge.2`, 8 vCPU / 16 GiB | 3 | $1.22 / h total |
| CCE | Turbo, `cce.s2.small`, 3 masters | 1 | $0.54 / h |
| RDS PostgreSQL | 16, primary/standby, 8 vCPU / 16 GiB, 100 GB SSD | 1 | $1.05 / h |
| DCS Redis | primary/standby, 8 GB | 1 | $0.21 / h |
| ELB | dedicated, 2 AZs, elastic | 1 | $0.025 / h + $0.00833 / LCU |
| NAT | small | 1 | $2.44 / day |
| EIP | dynamic BGP, traffic billing | 3 | $0.16 / GB |
| LTS | 30-day retention | 1 | usage based |
| MaaS tokens | DeepSeek-V4-Flash | — | $0.135 / M input, $0.27 / M output |

On-demand compute for the always-on pieces works out to roughly
`(1.22 + 0.54 + 1.05 + 0.21 + 0.025) × 730 ≈ $2,220 / month`, plus NAT
(≈ $73 / month), LCU, EIP traffic and tokens. Prepaid commitments are
substantially cheaper at these sizes; the official page quotes about
$248 / month prepaid for its reference configuration.

This repository's defaults are lighter than the reference: `c7.xlarge.4`
workers (4 vCPU / 16 GiB) and a 2 GB Redis. Expect less than the numbers above,
and measure with the calculator.

## What actually drives the bill

1. **Worker nodes** — three always-on nodes dominate. Dropping to 2 nodes saves
   ~33% of compute but removes AZ-level headroom.
2. **Database** — flavour and storage. Spend logs grow; 100 GB is a starting
   point, not a permanent size.
3. **NAT gateway** — fixed daily charge. If every model call goes through the
   ModelArts VPC endpoint and nothing needs the public internet, removing the
   NAT gateway saves about $73/month.
4. **EIP traffic** — gateway ingress is billed too. A public gateway with heavy
   client traffic pays for it.
5. **LCU on the elastic ELB** — cheap at low traffic, grows with connections and
   new connections per second.
6. **Token spend** — usually the largest line at scale, and invisible to
   infrastructure monitoring. LiteLLM's budgets and spend logs are the control.

## Levers

| Lever | Saving | Trade-off |
|---|---|---|
| `charging_mode = "prePaid"` | large | commitment, less flexibility |
| 2 worker nodes instead of 3 | ~33% compute | no AZ-level node headroom |
| Smaller Redis (2 GB) | small | less cache/rate-limit headroom |
| Remove NAT, use VPCE only | ~$73/month | no public model APIs |
| Fixed ELB flavor instead of elastic | predictable | over-provisioned at low traffic |
| Shorter LTS retention | small | less audit history |
| Delete the lab after evaluation | 100% | — |

## Cost guardrails

- Set budgets on every virtual key; a runaway client is the usual cost incident.
- Enable LiteLLM alerting for budget crossings before onboarding teams.
- Keep `store_prompts_in_spend_logs` off unless required — it increases both
  storage and memory.
- Review RDS storage growth monthly; spend logs are the table that grows.
