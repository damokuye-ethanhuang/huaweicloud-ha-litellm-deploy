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

Deploys an internal-only LiteLLM gateway: CCE (3 workers, 1/AZ) behind a
**private** ELB, RDS PostgreSQL HA, DCS Redis HA, LTS logs, AOM metrics,
encryption via KMS/DEW, and one bastion that is the only public host.

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
| `verify` | **bastion** | the ELB VIP is routable from inside the VPC only |
| day-2 kubectl | **bastion** | same reason |

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
   annotations and image;
4. `helm upgrade --install --wait`; the migration Job runs as a pre-install /
   pre-upgrade hook, pods run `DISABLE_SCHEMA_UPDATE=true`;
5. smoke test.

A failed migration stops the release; previous pods keep serving.

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
| credentials `FAIL` | ask the operator to export AK/SK in their own shell; never accept them in chat |
| `ssh` to bastion hangs | `bastion_ssh_cidrs` does not include their egress; fix input, re-apply |
| helm cannot reach cluster | you are not on the bastion — use `--remote` |
| `ImagePullBackOff` | image not mirrored to SWR, or pull secret wrong |
| migration job fails | read its logs; do not scale pods to work around it |
| readiness `db: disconnected` | RDS SG, password, or the data subnet is not reachable from app |

## 5. Hard constraints

- Internal only: ELB has no EIP; the bastion is the single public IP.
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
