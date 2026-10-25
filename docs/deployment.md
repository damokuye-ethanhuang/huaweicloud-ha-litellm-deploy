# Deployment

This is the **canonical end-to-end deployment flow** for the production (CCE)
tier. Everything else points here:

| Where | What it is |
|---|---|
| **this file** | the authoritative stage-by-stage flow |
| [AGENTS.md](../AGENTS.md#the-deployment-loop) | the same loop as an agent contract (what an agent may run unattended) |
| [docs/manual-deployment.md](manual-deployment.md) | console click-through, for when Terraform is not allowed |
| [docs/inputs-guide.md](inputs-guide.md) | how to fill `deploy-inputs.yaml` |
| [docs/sa-checklist.md](sa-checklist.md) | planning checklist to complete **before** stage 1 |
| [README.md](../README.md#quick-start) | 60-second version, lab tier |

## The flow at a glance

```
fill deploy-inputs.yaml
        │
        ▼
[0] preflight ──► validates inputs, renders tfvars / helm values / models
        │           artifacts land in out/<project>/
        ▼
[1] plan ──────► saves tfplan, costs nothing, changes nothing
        │
        ▼
   OPERATOR REVIEWS THE PLAN          ◄── the only mandatory stop
        │
        ▼
[2] apply-infra ─► VPC, subnets, SG, CCE, RDS, DCS, ELB, LTS/AOM, bastion
        │           20–40 min, dominated by CCE
        │           RDS is created EMPTY: databases exist, tables do not
        ▼
[3] deploy-app ──► kubeconfig, Secret, SQL schema migration, helm upgrade
        │           migration Job runs FIRST, then pods start
        │           run from the bastion: CCE has no public endpoint
        ▼
[4] verify ──────► readiness, /v1/models, one real completion, tables present
        │
        ▼
   hand out a tenant key (never the master key)
```

Single entry point:

```bash
./scripts/deploy.sh <stage>              # preflight | plan | apply-infra | deploy-app | verify | all
./scripts/deploy.sh --remote <stage>     # run an in-cluster stage on the bastion
```

### Where each stage runs

A machine outside the VPC can create infrastructure — cloud APIs are public — but
it **cannot reach the cluster or the gateway**: the CCE API has no public
endpoint and the ELB is internal. Only the in-VPC bastion is called a bastion;
your own machine is just a PC.

| Stage | Host | Why |
|---|---|---|
| preflight | operator PC | renders artifacts, no cloud calls |
| plan, apply-infra | operator PC | cloud API only |
| deploy-app | **bastion** | needs the cluster API and helm |
| verify | **bastion** | the ELB VIP is routable only inside the VPC |
| day-2 kubectl / helm / psql | **bastion** | same reason, plus the ops subnet may reach the data layer |

`--remote` automates the handoff: it bundles rendered values, the chart, the
Secret contents and the kubeconfig, uploads them to `/root/litellm-bundle`, and
executes helm there. The bastion needs **only kubectl and helm** — no Terraform,
no cloud credentials, no repo clone.

Every stage is idempotent and re-runnable. `all` exists but must never run
unattended — it includes `apply`.

## 0. One-time setup

### Toolchain

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.6 | infrastructure |
| Helm | >= 3.14 | chart |
| kubectl | >= 1.28 | cluster access |
| Python 3 | >= 3.9 | preflight, SDK, checks |
| jq, curl | any recent | scripts |
| Docker | optional | mirroring the image into SWR |

`./scripts/bootstrap.sh` checks all of these and tells you what is missing.

### Credentials

Create a **dedicated IAM user**; do not reuse a production account's AK/SK.
They live in one file, `secrets/hw.env`, which is gitignored:

```bash
./scripts/creds.sh set        # prompts, hides input, chmod 600
./scripts/creds.sh status     # masked view of what preflight will use
./scripts/creds.sh clear      # back to empty, run this after testing
```

When a customer supplies the credentials, send them `./scripts/handoff.py form`
instead: it states where each value goes without ever asking for a secret in a
chat window. `HW_ACCESS_KEY` / `HW_SECRET_KEY` exported in the shell still win
over the file, so CI needs no file on disk.

The HuaweiCloud Terraform provider and the Python SDK both follow the same
credential chain, so `~/.huaweicloud/credentials` works too. No signing code
lives in this repository.

Minimum service scope (narrow it further for production):

```
vpc:* nat:* elb:* ecs:* evs:* ims:* cce:* rds:* dcs:* kms:* csms:*
lts:* aom:* smn:* ces:* vpn:* vpcep:* swr:*
```

### CCE version

CCE retires old Kubernetes versions and some regions require an exact patch
level (e.g. `v1.31.1-r0`). `deploy-inputs.yaml` leaves `cce_cluster_version`
empty on purpose: `deploy.sh` resolves it per region at run time through the
official SDK.

```bash
python3 -m venv .venv-sdk
.venv-sdk/bin/pip install huaweicloudsdkcce
.venv-sdk/bin/python scripts/resolve-cce-version.py --dry-run   # show, do not write
./scripts/check-cce-versions.py                                 # API + preset drift
```

`check-cce-versions.py` compares the live list (SDK) and any vendor doc page you
add to `version-presets.yaml:cce.doc_sources` against the preset, and with
`--write` bumps `max_minor`. The procedure for a real upgrade is in
`docs/upgrade-procedure.md`.

If you must pin a version, put it in `deploy-inputs.yaml` and note why.

### Remote state (recommended)

State contains generated passwords and the cluster kubeconfig.

```bash
cp terraform/examples/cce-ha/backend.tf.example terraform/examples/cce-ha/backend.tf
# edit bucket / key / region, enable server-side encryption on the bucket
terraform -chdir=terraform/examples/cce-ha init -migrate-state
```

Restrict the bucket to the deployment role plus a small operator group. Treat
state as a secret, not as configuration.

## 1. Fill the inputs

`deploy-inputs.yaml` is the **only** file you edit. Every resource name derives
from `project_name`, so one value renames the whole stack.

```bash
python3 scripts/inputs-table.py            # Markdown table of every field
python3 scripts/inputs-table.py --format csv
```

The five fields people get wrong:

| Field | What it actually controls |
|---|---|
| `project_name` | prefix of every resource name (`<project>-maas-vpc`, …) |
| `client_cidrs` | who may call `/v1/*` — must be **private** ranges; the ELB is internal and never sees a public source address |
| `admin_cidrs` | who may reach the Admin UI and key APIs — narrower than `client_cidrs`, usually the bastion subnet |
| `bastion_ssh_cidrs` | who may SSH to the bastion — this is where your **office/public egress** range belongs |
| `certificate_id` | ELB certificate **UUID**, not its display name (only when `enable_https = true`) |

A public CIDR in `client_cidrs` or `admin_cidrs` is rejected by design: an
internal load balancer cannot receive traffic from the internet, so such a rule
would only give false comfort.

## 2. Stage: preflight

```bash
./scripts/deploy.sh preflight
```

Offline-checks every input, validates the version against
`version-presets.yaml`, then renders:

```
out/<project>/
├── terraform.tfvars        # for the CCE tier
├── helm-values.yaml        # ELB annotations, resources, models
├── models.yaml             # model_list + fallbacks
├── query-plan.json         # resource naming plan
└── preflight.json          # machine-readable result
```

Fix every `FAIL` before continuing. `python3 scripts/preflight.py --json` gives
the same result as JSON, which is what an agent should read.

Common blockers and their meaning are in [AGENTS.md](../AGENTS.md#what-each-check-means).

## 3. Stage: plan

```bash
./scripts/deploy.sh plan
```

Writes `out/<project>/tfplan`. Read the plan:

```bash
terraform -chdir=terraform/examples/cce-ha show -no-color out/../tfplan | less
```

Look for `-/+` (replacement) and `-` (deletion) on stateful resources — a
replaced `huaweicloud_rds_instance` or `huaweicloud_cce_cluster` is a rebuild,
not an update. If a replacement is unexpected, stop and fix the inputs rather
than applying.

> **This is the mandatory human stop.** `apply-infra` must not run until a
> person has read the plan.

## 4. Stage: apply-infra

```bash
./scripts/deploy.sh apply-infra
```

20–40 minutes; CCE node provisioning dominates. Safe to re-run after a partial
failure.

Outputs worth knowing:

| Output | Meaning |
|---|---|
| `gateway_private_ip` | internal ELB VIP — point internal DNS here |
| `gateway_url` | `http(s)://<vip>`, the caller-facing endpoint |
| `bastion.public_ip` / `bastion.ssh` | the **only** public IP in the stack, plus a ready SSH command |
| `cluster_id`, `kube_config_raw` | cluster access (sensitive) |
| `database`, `redis` | connection details (sensitive) |
| `app_env` | the Secret's contents (sensitive) |
| `observability` | LTS group/stream, AOM endpoint |
| `encryption` | which branch is active (`kms` / `dew` / `disabled`) |

`terraform output` prints secrets in clear text — treat your scrollback as
sensitive.

## 5. Stage: deploy-app

CCE has **no public endpoint**, so this stage belongs on the bastion. Two ways:

```bash
# A. automated handoff (recommended)
export BASTION_KEY=~/.ssh/litellm-bastion
./scripts/deploy.sh --remote deploy-app

# B. manual
ssh -i "$BASTION_KEY" root@"$(terraform -chdir=terraform/examples/cce-ha output -json bastion | jq -r .public_ip)"
# on the bastion: /root/litellm-bundle/install.sh (pushed by `remote-deploy.sh push`)
```

`--remote` runs `scripts/remote-deploy.sh`: `bundle` → `push` → helm on the
bastion. Inspect the bundle at `out/bastion/` if a push fails.

What it does, in order:

1. writes `kube_config_raw` to `~/.kube/litellm-cce.yaml` (0600);
2. creates the namespace and the `litellm-secrets` Secret from Terraform
   outputs, merged with any provider keys in `secrets/app.env` (gitignored);
3. renders the values file with ELB annotations (id, class, protocol-port,
   certificate);
4. runs `helm upgrade --install --wait`. Helm executes the **SQL migration Job**
   first (`pre-install` / `pre-upgrade` hook, weight -5), waits for it, and only
   then replaces the Deployment — see [5.1](#51-tables-come-from-litellms-own-migrations-not-from-sql-in-this-repo);
5. runs the smoke test.

If the migration fails, the release stops and the previous pods keep serving.
Fix the cause and re-run; see [troubleshooting](troubleshooting.md).

Provider keys: put them in `secrets/app.env` (never in `deploy-inputs.yaml`,
never on a command line). A model whose `api_key_env` is missing from that file
simply has no key — that is valid for endpoints that do not authenticate.

### 5.1 Tables come from LiteLLM's own migrations, not from SQL in this repo

There is no `CREATE TABLE` step and no schema file in this repository — by
design. The schema is LiteLLM's, so it is applied by LiteLLM's bundled Prisma
migrations, which ship inside the image and run automatically:

| Moment | Who creates what |
|---|---|
| `apply-infra` | RDS PostgreSQL 16 primary/standby, and the **empty logical database** with its role and password. No tables, no DDL. |
| `deploy-app` → `helm upgrade` | Helm runs the migration Job first (`pre-install`/`pre-upgrade`, weight `-5`) and waits for it. That Job is `litellm --skip_server_startup` with `DISABLE_SCHEMA_UPDATE=false`, so `prisma migrate deploy` creates every table, index and enum LiteLLM needs. |
| `deploy-app` → pods | Start **only after** the Job succeeded, with `DISABLE_SCHEMA_UPDATE=true`, so no pod ever migrates and two pods never race. |

Re-running `deploy-app` is safe and idempotent: Prisma applies only migrations
that have not been applied yet, so a second run is a no-op.

The Job definition is `charts/litellm/templates/migration-job.yaml` and is
deleted on success (`hook-succeeded`).

**Do not hand-write SQL or import a dump into this database.** LiteLLM checks
the migration state on startup; a schema created from a third-party dump will
either be rejected or silently diverge, and the next real upgrade will fail. If
you need seed data, use the Admin UI or the API, not `psql INSERT`.

Verify from the bastion:

```bash
# did the migration run and succeed?
kubectl -n litellm get jobs -l app.kubernetes.io/component=migration
kubectl -n litellm logs job/$(kubectl -n litellm get jobs \
  -l app.kubernetes.io/component=migration -o jsonpath='{.items[0].metadata.name}') --tail=40

# do the tables exist? (read-only check from the ops subnet)
psql "$LITELLM_DATABASE_URL" -c '\dt'
# LiteLLM_ProxyModelTable, LiteLLM_VerificationToken, LiteLLM_TeamTable,
# LiteLLM_SpendLogs, LiteLLM_UserTable, ... plus the _prisma_migrations table
```

`_prisma_migrations` is the authoritative record: one row per applied migration.
If it is empty while the gateway serves traffic, something bypassed the Job.

Break-glass when a release failed after the Job was already garbage-collected:

```bash
./scripts/migrate.sh     # re-applies the chart's migration Job and waits for it
```

`LITELLM_SALT_KEY` is what makes stored provider credentials readable, so a
database restored from backup must be paired with the salt from the same backup.

## 6. Stage: verify

```bash
./scripts/deploy.sh --remote verify        # runs on the bastion
MODEL=glm-5.3 ./scripts/deploy.sh --remote verify   # also sends one real completion

kubectl -n litellm get pods                # 3/3 Running, across AZs
```

Manual checks, from inside the VPC:

```bash
curl -s http://<vip>/health/liveliness
curl -s http://<vip>/health/readiness      # db: connected, redis: connected
curl -s http://<vip>/v1/models -H "Authorization: Bearer ***" | jq -r '.data[].id'
```

Database check — the gateway can serve `/v1/models` from memory even if the
schema is wrong, so confirm the tables directly:

```bash
# on the bastion
kubectl -n litellm get jobs -l app.kubernetes.io/component=migration
psql "$LITELLM_DATABASE_URL" -c "select count(*) from _prisma_migrations where finished_at is not null;"
```

A non-zero count with no `rolled_back_at` rows means the schema is in sync with
the image. If the Job is already deleted (hook-succeeded) this is the only record
left, which is why it is checked here rather than assumed.

Then verify the thing smoke tests cannot: **make the primary model fail** and
confirm the request succeeds on the fallback. That is the entire point of the
two-model layout, and it is the one check people skip.

The Admin UI is at `http://<vip>/ui`. Do not hand the master key to callers —
issue a tenant key instead ([security](security.md#who-calls-the-gateway)).

## 7. After deploy

- import the alert rules and dashboard: [monitoring/README.md](../monitoring/README.md)
- record `owner`, region, AZs and the resolved CCE version in your CMDB
- back up `LITELLM_SALT_KEY` and the Terraform state; losing the salt makes
  every stored provider credential unreadable
- budget/cost review: [cost.md](cost.md)

## 8. China-region image mirroring

If the cluster cannot reach `ghcr.io`:

```bash
SWR_REGION=cn-southwest-2 SWR_ORG=my-org ./scripts/mirror-image.sh 1.106.3
```

Then set the repository in `deploy-inputs.yaml`
(`image_repository`) and re-run `deploy-app`. SWR login uses `{region}@{AK}` as
the username; the script handles it.

## 9. Teardown

```bash
CONFIRM=yes ./scripts/destroy.sh terraform/examples/cce-ha
./scripts/handoff.py scrub     # back up, then clear AK/SK and customer values
./scripts/handoff.py check     # must print "clean"
```

Destroying the stack deletes the database. Take a manual backup first if the
data matters.

`scrub` copies `deploy-inputs.yaml` and anything under `secrets/` to
`.local/handoff-<timestamp>/` (gitignored) before clearing: project name,
customer CIDRs, model endpoints and both credential files. `check` is what you
run before handing a laptop back or opening a PR.

## Stage-level checklist

Tick these as the stages complete, not at the end:

- [ ] `docs/sa-checklist.md` fully ticked
- [ ] dedicated IAM user, least-privilege policy, MFA on the console account
- [ ] remote state on an encrypted, private OBS bucket
- [ ] `cce_cluster_version` resolved (or pinned with a reason)
- [ ] preflight: zero `FAIL`
- [ ] plan: read by a human, every replacement explained
- [ ] apply-infra: outputs captured somewhere durable
- [ ] apply-infra: RDS is primary/standby and the logical database exists but is **empty** (no tables yet — that is correct)
- [ ] deploy-app: migration Job succeeded before pods rolled
- [ ] deploy-app: pods started with `DISABLE_SCHEMA_UPDATE=true` (no pod migrated)
- [ ] verify: `_prisma_migrations` has rows and no rolled-back entries
- [ ] verify: readiness green, `/v1/models` lists both models
- [ ] verify: fallback proven by forcing the primary to fail
- [ ] alert rules and dashboard imported
- [ ] tenant key issued, master key retained by ops only
