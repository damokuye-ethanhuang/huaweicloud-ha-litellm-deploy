# Architecture

## Component map

| Layer | Resource | Why |
|---|---|---|
| Ingress | Dedicated internal ELB, elastic L7 flavor, two AZs | No EIP. Reachable only from `client_cidrs` / `admin_cidrs` inside the VPC |
| Public entry | One EIP on the bastion, in the ops subnet | The only address on the internet; SSH only, from `bastion_ssh_cidrs` |
| Compute | CCE cluster, 3 masters, one node pool per AZ | Survives an AZ loss and reschedules pods |
| Application | 3 LiteLLM replicas, 1 Uvicorn worker each | Stateless; scale with replicas |
| State | RDS PostgreSQL 16 primary/standby, two AZs | Keys, teams, budgets, spend logs, config |
| Coordination | DCS Redis 7 primary/standby, two AZs | Cross-replica rate limits, router state, cache |
| Egress | NAT gateway + SNAT | Private pods reaching model APIs on the internet |
| Private models | VPCEP endpoint subnet | Reaching ModelArts/MaaS without any egress |
| Secrets | CSMS + generated passwords | No static credentials anywhere |
| Keys | KMS | RDS volume and node disk encryption |
| Logs | LTS + ELB log association | Access logs without an agent |
| Alerts | Cloud Eye → SMN → email | Opt-in; metric names vary by region |

## Network zones

One VPC, `10.0.0.0/21`, carved into fixed slots so a typo fails the plan instead
of silently overlapping something:

| Subnet | CIDR | Holds | Ingress |
|---|---|---|---|
| access | /24 | Internal ELB VIP | `client_cidrs`, `admin_cidrs`, ops subnet |
| app | /24 | CCE worker nodes | from access, from ops |
| data | /24 | RDS, DCS | 5432/6379 from app and ops only |
| ops | /24 | The bastion, future jump hosts | SSH from `bastion_ssh_cidrs` |
| vpce | /26 | ModelArts endpoint ENIs | optional, off by default |

The ops subnet is the one place that may reach everything in the VPC — ELB 443,
PostgreSQL 5432, Redis 6379, the CCE API on 6443 — because that is where
debugging happens. Nothing else crosses zone boundaries.

## Request path

1. A client inside the VPC calls `https://<elb-vip>/v1/chat/completions` with a
   virtual key. There is no public path to this address.
2. The ELB terminates TLS with the certificate referenced by the CCE Service
   annotation and forwards to the Service's node port.
3. kube-proxy picks one of the three pods. Readiness (`/health/readiness`) keeps
   pods with a broken database connection out of rotation.
4. The pod authenticates the virtual key. Authentication and spend metadata come
   from PostgreSQL; rate-limit counters and the response cache come from Redis.
5. The router selects a model deployment; retries and fallbacks come from
   `deploy-inputs.yaml` (`models[]`) via `router_settings` in the rendered config.
6. The request leaves through the NAT gateway, or through the ModelArts VPC
   endpoint when private inference is enabled.

## Operations path

```
operator PC ──ssh(22)──> bastion (ops subnet) ──> CCE API 6443 (kubectl/helm)
                                             ├─> ELB 443 (smoke test, Admin UI)
                                             ├─> RDS 5432 (psql)
                                             └─> DCS 6379 (redis-cli)
```

Terraform runs on the operator PC: it only talks to the cloud APIs. Everything
that needs to be *inside* the VPC — helm, kubectl, smoke tests, database
inspection — runs on the bastion. The operator PC is an ordinary machine; it has
no route to the cluster or the gateway VIP, by design.

## Failure domains

| Failure | Impact | Recovery |
|---|---|---|
| One pod dies | None; two remain | Deployment recreates it; readiness gates traffic |
| One worker node dies | Pods on it reschedule | CCE reschedules; PDB keeps 2 available |
| One AZ fails | Loses one node and one ELB AZ | Remaining two AZs serve; RDS/DCS fail over |
| RDS primary fails | Writes pause during failover | Managed failover to the standby in the second AZ |
| RDS is unreachable | Readiness 503 → pods leave rotation | Fix connectivity; `allow_requests_on_db_unavailable` is deliberately **not** enabled |
| Redis primary fails | Brief cache/rate-limit errors | DCS failover; gateway keeps serving |
| NAT gateway fails | No egress to external models | Single NAT is a known limitation; recreate or add a second one |
| Bastion unreachable | No in-VPC operations | Console VNC still works; the gateway keeps serving |
| Bad release | Rolling update stops at `maxUnavailable: 0` | Roll back the image; migrations are not reversible |

## Why CCE and not plain VMs

The gateway is stateless, so Kubernetes buys three things that are expensive to
script on VMs: hitless rolling updates, readiness-gated traffic, and
rescheduling after a node failure. The VM example exists for evaluation and for
teams that cannot run a cluster, not as a production topology.

## Ownership boundaries

| Owned by Terraform | Owned by Helm |
|---|---|
| VPC, subnets, security groups | Deployment, Service, ConfigMap |
| CCE cluster and node pools | PodDisruptionBudget, HPA (optional) |
| RDS, DCS, KMS, CSMS | Migration Job (pre-install/pre-upgrade hook) |
| ELB, bastion EIP, certificate reference | Probes, topology spread, resource limits |
| LTS, SMN, Cloud Eye alarms | — |

The split matters during an incident: changing the image is a Helm operation and
takes seconds; changing the database size is a Terraform operation and takes
tens of minutes.

## Upgrade flow

```mermaid
flowchart LR
  A[Bump litellm_version] --> B[terraform plan/apply<br/>infra unchanged]
  B --> C[helm upgrade]
  C --> D[Migration Job<br/>--skip_server_startup<br/>DISABLE_SCHEMA_UPDATE=false]
  D -->|success| E[Rolling update<br/>maxSurge 1, maxUnavailable 0]
  D -->|failure| F[Release stops<br/>old pods keep serving]
```

The gateway pods run with `DISABLE_SCHEMA_UPDATE=true`. They never race each
other applying Prisma migrations, and a failed migration cannot leave a
half-upgraded fleet.

## Known limitations

- **Single region.** Multi-region active/active is out of scope; the LiteLLM
  docs describe a shared-database multi-region topology if you need it.
- **Single NAT gateway.** Egress is an AZ-scoped dependency.
- **No autoscaling by default.** LiteLLM replicas take minutes to become
  useful, so HPA is opt-in and CPU-based only.
- **Cloud Eye alarms are opt-in.** Metric names and dimensions differ between
  regions; guessing them would produce a broken first apply.
- **CCE Service annotations are isolated in one script.** If your CCE version
  expects a different annotation set, only `scripts/deploy.sh` changes.
