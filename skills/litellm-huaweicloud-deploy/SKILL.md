---
name: litellm-huaweicloud-deploy
description: "Use when deploying LiteLLM to Huawei Cloud (internal-only CCE gateway). Runs the staged flow and the bastion handoff."
version: 1.0.0
license: Apache-2.0
metadata:
  hermes:
    tags: [litellm, huaweicloud, cce, terraform, helm, deployment, internal-only]
    category: software-development
    requires_tools: [terminal, read_file, write_file, patch, search_files]
    requires_toolsets: [terminal]
---

# Deploy LiteLLM on Huawei Cloud

Deploys an internal-only LiteLLM gateway: CCE (3 workers, 1/AZ) on an
`overlay_l2` container tunnel network, behind a **private** ELB that the CCE
Ingress controller creates, RDS PostgreSQL HA, DCS Redis HA, LTS logs, AOM
metrics, encryption via KMS/DEW, and one bastion that is the only public host.

**The repository is the source of truth.** This skill describes the flow and the
decisions; commands, parameters and validation live in the repo. If they
disagree, the repo wins — update this file.

Repo: `huaweicloud-ha-litellm-deploy`. If it is not present, ask for the clone
URL. Do not deploy from memory.

---

## 0. Who runs what, where

This is the part people get wrong. A laptop outside the VPC can create
infrastructure (cloud APIs are public) but **cannot reach the cluster or the
gateway** — the CCE API has no public endpoint and the ELB is internal.

| Stage | Runs on | Why |
|---|---|---|
| `preflight` | your machine | renders artifacts only, offline |
| `plan` | your machine | cloud API only |
| `apply-infra` | your machine | cloud API only; 20–40 min |
| `deploy-app` | **bastion** | needs cluster API + helm |
| `verify` | **bastion** | the ELB VIP is routable from inside the VPC only, and it only exists after the Ingress reconciles |
| day-2 kubectl | **bastion** | same reason |

### Two facts that decide most of the design

1. **Container network is `overlay_l2`** (VXLAN tunnel, `172.16.0.0/16` by
   default, /28 blocks per node). Pod IPs are **not** routable from the VPC:
   pod-to-RDS/Redis traffic is source-NATed to the node address. Consequences:
   the data subnet allows the **app** subnet, not `pod_cidr`; pods cannot hold
   EIPs or security groups; nothing outside the cluster can reach a pod
   directly. The three ranges (VPC `10.0.0.0/22`, container `172.16.0.0/16`,
   service `10.247.0.0/16`) must be disjoint.
2. **The ELB belongs to the Ingress** (`elb_mode = ingress`, default). Terraform
   creates no ELB; `kubernetes.io/elb.autocreate` builds a dedicated internal L7
   balancer with its VIP in the **access (front) subnet** and backends on the
   **app subnet**. `terraform output gateway_url` is therefore empty — read the
   VIP from `kubectl get ingress ... .status.loadBalancer.ingress[0].ip`. Use
   `elb_mode = standalone` only when something outside CCE must own the ELB.

3. **Nodes have no public egress, ever.** No NAT gateway is created unless
   `model_endpoint_mode = nat` (public model APIs). Images travel
   bastion -> SWR -> pods (`image_supply_chain = swr`, `swr_org` in
   deploy-inputs): run `scripts/mirror-image.sh <version>` on the bastion
   before the first `deploy-app` of a version. `deploy-app` refuses an image
   that still points at a public registry, and both deploy paths refresh the
   24h `swr-cred` pull secret automatically.

The bastion is the only host with a public EIP. `--remote` makes the handoff
automatic: it bundles rendered values, the chart, the Secret contents and the
kubeconfig, uploads them, and runs helm there. The bastion needs **only kubectl
and helm** — no Terraform, no cloud credentials.

## 1. Orient (always)

Read, in this order:

1. `AGENTS.md` — what an agent may and may not do (authoritative).
2. `deploy-inputs.yaml` — every parameter, with `help` text and validation.
3. `version-presets.yaml` — the validated LiteLLM baseline.
4. `docs/sa-checklist.md` — planning checklist; tick it before stage 1.

## 2. Collect inputs

Only `deploy-inputs.yaml` is edited. One `project_name` renames everything
(`<project>-maas-vpc`, `<project>-maas-cce`, …).

Ask only about what preflight reports as `FAIL`:

```bash
python3 scripts/preflight.py --json     # read results[] where status == "fail"
python3 scripts/inputs-table.py         # human-readable table to paste in chat
```

Group questions: all network CIDRs together, all TLS items together. Never ask
for secrets — Terraform generates them.

The four network fields, precisely:

| Field | Accepts | Meaning |
|---|---|---|
| `client_cidrs` | **private** only | who may call `/v1/*` |
| `admin_cidrs` | **private** only | who may reach Admin UI / key APIs; narrower |
| `bastion_ssh_cidrs` | public or private | who may SSH to the bastion — office egress goes here |
| `gateway_private_ip` | optional | pin the ELB VIP for DNS |

A public CIDR in `client_cidrs`/`admin_cidrs` is refused by design: an internal
LB never sees a public source, so such a rule is false comfort.

### Model list

`models:` is an array; any number of entries. Operators often paste a table;
accept this shape and convert it:

```
glm-5.3 | https://<maas-vpce-ip>/v2/ | sk-xxx | openai/glm-5.3
deepseek-v4.1-flash | https://<modelarts-vpce-ip>/v1/ | | openai/deepseek-v4.1-flash
```

Column order: `name | api_base | api_key | model`. Rules:

- `api_key` empty → the endpoint does not authenticate; still set `api_key_env`
  and leave the variable unset. Never write a key into `deploy-inputs.yaml`.
- Keys go to `secrets/app.env` (gitignored) as `KEY=VALUE`, referenced by
  `api_key_env`.
- Preserve existing entries; append, never replace.
- All entries fall back to each other (`fallbacks.enabled: true`).

## 3. Stage flow

```bash
./scripts/deploy.sh preflight      # validate + render out/
./scripts/deploy.sh plan           # save tfplan, change nothing
#   ◄── MANDATORY: a human reads the plan before apply
./scripts/deploy.sh apply-infra    # 20–40 min
./scripts/deploy.sh --remote deploy-app   # helm on the bastion
./scripts/deploy.sh --remote verify       # smoke on the bastion
```

`--remote all` does bundle + upload + deploy-app + verify in one go.

Every stage is idempotent. `all` without `--remote` includes apply and must
never run unattended.

### What `deploy-app` does

1. kubeconfig → bundled (0600);
2. namespace + `litellm-secrets` from Terraform outputs merged with
   `secrets/app.env`;
3. merges `out/helm-values.yaml` (models, fallbacks, resources) with runtime ELB
   config and image via `scripts/render-helm-values.py` — the only place that
   knows how `elb_mode` maps to annotations;
4. `helm upgrade --install --wait`; the migration Job runs as a pre-install /
   pre-upgrade hook, pods run `DISABLE_SCHEMA_UPDATE=true`;
5. smoke test.

A failed migration stops the release; previous pods keep serving.

**Tables are never created by hand.** `apply-infra` leaves an empty database;
step 4's Job runs LiteLLM's bundled Prisma migrations (`litellm
--skip_server_startup`, `DISABLE_SCHEMA_UPDATE=false`) and Helm waits for it
before the Deployment rolls. Do not write SQL, do not import a dump — LiteLLM
validates migration state on startup and will diverge or fail on the next
upgrade. Re-running `deploy-app` is idempotent; `scripts/migrate.sh` exists only
to re-run the Job when a release died after the hook was garbage-collected.

### What `verify` must prove

- `/health/readiness` → `db: connected`, `redis: connected`
- `/v1/models` lists **both** models
- one real completion succeeds
- **fallback works**: force the primary to fail, confirm the secondary answers
  (smoke tests cannot check this — do it by hand)

## 4. Failure routing

| Symptom | Action |
|---|---|
| preflight `FAIL` on a CIDR | ask for a private CIDR inside `vpc_cidr`; public is refused |
| `certificate_id` format | operator pasted a name; need the SCM/ELB UUID |
| `version > preset` | point to `docs/upgrade-procedure.md`; rerun with `ACK_UPGRADE=1` only after they confirm |
| `version > max_compatible` | stop; `version-presets.yaml` needs updating with evidence |
| credentials `FAIL` | ask the operator to run `./scripts/creds.sh set` themselves; never accept AK/SK in chat |
| `ssh` to bastion hangs | `bastion_ssh_cidrs` does not include their egress; fix input, re-apply |
| helm cannot reach cluster | you are not on the bastion — use `--remote` |
| `ImagePullBackOff` | image never mirrored to SWR (`mirror-image.sh` on the bastion), or the 24h `swr-cred` expired - redeploy to refresh |
| migration job fails | read its logs; do not scale pods to work around it |
| Ingress has no `ADDRESS` | controller has not reconciled; check the ENI quota and that `elb_virsubnet_ids` are real neutron subnet ids |
| destroy blocked by `ELB.8917` | `elb_deletion_protection = true`; set false, apply once, destroy |
| `Security Group rule: conflict in the request` | duplicate rules after de-dup by `(sg_key, direction, protocol, ports, cidr)` |
| `DCS.4872 Do not support security group whitelist` | Redis 5.0/6.0 HA takes no security group; leave it unset |
| Helm `pending-install` lock | `helm uninstall --no-hooks`, delete the leftover Job, reinstall |
| `master volumes: SAS is sold out` | no volume field exists on `masters` in provider 1.99.x; move AZ or use `cce.s1.*` |
| readiness `db: disconnected` | RDS SG, password, or the data subnet is not reachable from app |

## 5. Hard constraints

- Internal only: ELB has no EIP; the bastion is the single public IP.
- Every failure hit in the first end-to-end run is catalogued in
  `docs/deployment-optimizations.md` §22 — check it before inventing a fix.
- Secrets are generated by Terraform into CSMS. Never write them to files, args
  or chat. The bundle's `app.env` is 0600 and never committed.
- `LITELLM_SALT_KEY` is not rotatable once models exist (`prevent_destroy`).
- Never widen a security group, add an EIP, or edit state to "make it work".
  Those are design changes requiring review.
- Callers get tenant keys; the master key stays with ops.
- Data tier stays HA: RDS `.ha` and `redis.ha.` — not single-node, not even in
  tests.

## 6. Iterating on this skill

This file ships inside the repo so it versions with the code. When the flow
changes:

1. change the scripts/docs first;
2. update this file in the same commit;
3. bump `version:` above.

Keep it a **flow + decisions** document. Do not paste command output, rendered
values or environment specifics — those belong in `deploy-inputs.yaml`.
