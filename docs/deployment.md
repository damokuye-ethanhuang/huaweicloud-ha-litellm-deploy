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
./scripts/deploy.sh <stage>              # preflight | plan | apply-infra | apply-stream | deploy-app | verify | all
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
They live in one file, `$LITELLM_DEPLOY_HOME/secrets/hw.env`, which is gitignored:

```bash
./scripts/creds.sh set        # prompts, hides input, chmod 600
./scripts/creds.sh status     # masked view of what preflight will use
./scripts/creds.sh clear      # back to empty, run this after testing
```

Four ways to supply the key - interactive `set`, environment variables,
`set --from-env`, or the SDK profile - including the four error messages that
command produces and how to prove the key is gone afterwards, are in
[`credentials.md`](credentials.md).

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

CCE retires old Kubernetes versions, and the version a region accepts changes
over time, so `deploy-inputs.yaml` leaves `cce_cluster_version` empty on purpose
and `deploy.sh` resolves it per run.

There is **no API that lists supported cluster versions** — this is worth
knowing before you go looking for one. `ShowVersion` returns API metadata (the
string `v3`), `ShowClusterSupportConfiguration` returns component flags such as
`kube-apiserver` tuning, and `ListReleases` is not published in every region
(cn-southwest-2 answers 404). Resolution therefore uses two real sources:

1. the official CCE version-strategy bulletin, parsed for the commercial / beta /
   EOS lifecycle table;
2. a live probe — a cluster-create request with a deliberately bogus VPC id. If
   the API complains about the VPC rather than the version, that version is
   accepted in this region.

```bash
python3 -m venv .venv-sdk
.venv-sdk/bin/pip install huaweicloudsdkcce
.venv-sdk/bin/python scripts/resolve-cce-version.py --dry-run      # show
.venv-sdk/bin/python scripts/resolve-cce-version.py --probe v1.34  # test one
./scripts/check-cce-versions.py                                    # preset drift
```

The bulletin URL lives in `scripts/resolve-cce-version.py` (`BULLETIN`); if
Huawei moves the page, update it there. If the page is unreachable the script
falls back to a known-good floor and says so — treat that as a signal to check
the page by hand, not as success.

If you must pin a version, put it in `deploy-inputs.yaml` and note why.

### Availability zones

`az_policy: auto` (default) asks the region which AZs are live and which of them
offer the node flavor, then applies `az_preferred` to choose among them. The
resolved list is written back to `az_list`, and only that list reaches
Terraform — `huaweicloud_availability_zones` has no filter argument, so a
preference cannot be expressed in HCL and must not be faked there.

```bash
.venv-sdk/bin/python scripts/resolve-az.py --dry-run
```

Set `az_policy: fixed` to pin AZs exactly as written and skip the lookup. In
cn-southwest-2 the live AZs are `2a/2d/2e/2f` (there is no `2b`/`2c`); the
default preference is `2d/2e/2f` because `2a` is the older zone.

### Permissions

`docs/permissions.md` lists the IAM role per service and which stage needs it.
Check an identity before the first apply:

```bash
./scripts/check-permissions.sh          # read-only probe, prints a matrix
```

A `403` there would otherwise surface in the middle of `apply`, after some
resources already exist.

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

### Watching it without polling

`apply-infra` prints a line when a resource starts and another when it ends, so a
CCE cluster or an RDS instance is many minutes of silence. Terraform already
emits a stable event stream (`-json`, UI 1.0, `apply_progress` every ~10 s);
`apply-stream` renders it and keeps the same plan gate:

```bash
./scripts/deploy.sh plan
./scripts/deploy.sh apply-stream     # applies the same saved plan, with progress
```

```
12:03:02 apply tfplan
12:03:02 plan: 31 create
12:03:03 + create  huaweicloud_cce_cluster.this
12:03:13 · huaweicloud_cce_cluster.this Still creating... [10s elapsed]
12:18:44 ✓ huaweicloud_cce_cluster.this 15m41s id=...
12:19:02 apply complete 31 added, 0 changed, 0 destroyed in 16m00s
```

- every event is archived to `$LITELLM_DEPLOY_HOME/out/apply-timeline.jsonl`; the run ends with the
  five slowest resources, so a slow stage can be analysed afterwards instead of
  by re-running it;
- `--heartbeat` (30 s) re-prints in-flight resources when a provider goes quiet,
  which distinguishes "slow" from "wedged";
- `--replay $LITELLM_DEPLOY_HOME/out/apply-timeline.jsonl` renders a past run for a ticket;
- output values are counted, never printed.

This stays in the CLI on purpose. Terrakube, Atlantis and tf-controller are good
projects, but each brings a server, its own state/workspace model and a Git
workflow; this repository already gets those from Terraform plus the bastion, and
the constraint here is a private network with no public endpoint to add one to.

### Creation order (use the staged script)

`apply-infra` runs one flat `terraform apply`, which gives no control over the
order Terraform picks. For a first deploy - and whenever something has already
failed - run the stages instead:

```bash
./scripts/apply-staged.sh              # all five stages, in order
./scripts/apply-staged.sh edge data    # only the named ones, in given order
DRY_RUN=1 ./scripts/apply-staged.sh    # plan only
```

| Stage | Creates | Why here |
|---|---|---|
| 1 `edge` | ELB + access log — **skipped when `elb_mode = ingress`** (the Ingress controller creates the ELB after `deploy-app`) | Fastest (~10 s) and historically the riskiest wiring; fails in a minute instead of after the database. |
| 2 `data` | RDS primary/standby + `litellm` database | Longest lead time (~5 min); nothing downstream can be tested without it. |
| 3 `compute` | 3 CCE worker nodes, one per AZ | Slow and complex (~10–15 min) but depends only on network + cluster. |
| 4 `cache` | DCS Redis primary/standby | In-place update, quick. |
| 5 `ops` | Bastion host + EIP association | Metered and fully independent — kept last so a failed earlier stage leaves no public IP billing. |

The stages map onto dependencies, not onto blocks: a stage only references
resources the earlier stages already created. Each stage saves its plan to
`.local/plans/<stage>.tfplan` and applies that exact plan.

> `-target` requires Terraform **≥ 1.17**; older versions panic on variable
> validation under `-target` (see `docs/troubleshooting.md`).


Outputs worth knowing:

| Output | Meaning |
|---|---|
| `gateway_private_ip` | internal ELB VIP — **empty/null in `elb_mode = ingress`**; read it from the Ingress |
| `gateway_url` | `http(s)://<vip>`, the caller-facing endpoint; empty in ingress mode |
| `elb_mode` | `ingress` (default) or `standalone`, so scripts and humans agree on who owns the ELB |
| `ingress_elb` | the `elb.autocreate` parameters the chart renders: VIP subnet (**access**, the CCE front subnet), backend subnets (**app**), AZs, L7 flavor |
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
bastion. Inspect the bundle at `$LITELLM_DEPLOY_HOME/out/bastion/` if a push fails.

**Before the first `deploy-app` of a version** (on the bastion):

```bash
./scripts/mirror-image.sh <version>     # upstream -> SWR; once per version
```

`deploy-app` fails fast when the image reference is not an SWR path, with this
command in the error message.

What it does, in order:

1. writes `kube_config_raw` to `~/.kube/litellm-cce.yaml` (0600);
2. creates the namespace and the `litellm-secrets` Secret from Terraform
   outputs, merged with any provider keys in `$LITELLM_DEPLOY_HOME/secrets/app.env` (gitignored);
3. renders the values file (`scripts/render-helm-values.py`). In
   `elb_mode = ingress` it writes `kubernetes.io/elb.autocreate` (dedicated,
   `type: inner`, VIP in the **access** subnet, backends in the **app** subnet)
   and keeps the Service at `ClusterIP`; in `standalone` it writes the ELB id,
   class, protocol-port and certificate annotations instead;
4. runs `helm upgrade --install --wait`. Helm executes the **SQL migration Job**
   first (`pre-install` / `pre-upgrade` hook, weight -5), waits for it, and only
   then replaces the Deployment — see [5.1](#51-tables-come-from-litellms-own-migrations-not-from-sql-in-this-repo);
5. runs the smoke test.

If the migration fails, the release stops and the previous pods keep serving.
Fix the cause and re-run; see [troubleshooting](troubleshooting.md).

Provider keys: put them in `$LITELLM_DEPLOY_HOME/secrets/app.env` (never in `deploy-inputs.yaml`,
never on a command line). A model whose `api_key_env` is missing from that file
simply has no key — that is valid for endpoints that do not authenticate.

### Where is the gateway VIP?

With `elb_mode = ingress` there is no `terraform output` for it: the ELB comes
into existence while the Ingress controller reconciles, minutes after the plan.
Ask the cluster, not the state:

```bash
kubectl -n litellm get ingress \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}{"\n"}'
```

`./scripts/deploy.sh --remote verify` does exactly this, polling for up to five
minutes before falling back to the API server. The address always belongs to the
**access** subnet (the CCE front subnet); the ELB's backends are node ports on
the **app** subnet. If `kubectl` shows the Ingress without an `ADDRESS`, the
controller has not finished — see [troubleshooting](troubleshooting.md).

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

## 5.2 Phase 3: models (separate from infrastructure)

`deploy-app` finishes with an empty `model_list`, and that is the point: the
gateway, its database, Redis, auth and UI are proven before any provider exists.
`/v1/models` returning 200 with `[]` is the phase-2 exit criterion.

Models and fallbacks are applied by their own stage, from `models.yaml`:

```bash
./scripts/deploy.sh models --check    # validate + diff against the applied snapshot
./scripts/deploy.sh models --apply    # render, helm upgrade, snapshot
./scripts/deploy.sh models --rollback # re-apply models.prev.yaml
```

`--check` talks to nothing, so it is safe to run on the operator's machine before
the maintenance window. `--apply` needs cluster access: locally with kubeconfig,
or `--remote models --apply` to run it through the bastion.

Two settings keep the file authoritative. Both `store_model_in_db: false` (chart)
and `STORE_MODEL_IN_DB=False` (env) are deliberate: with either true, a model
added in the Admin UI lands in the database and the two lists diverge with no
error message. The UI remains usable for keys and spend, but it is not a model
source.

A config change rolls the pods; `maxUnavailable: 0` and `preStop` keep in-flight
streams alive, so a model change costs no failed requests at three replicas.

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

## 8. Image supply chain: bastion -> SWR -> pods

This is the **design**, not an optimisation. Nodes have no public egress (no
NAT gateway is created unless `model_endpoint_mode = nat`), so a pod that
references any public registry hangs in `ImagePullBackOff` with no error to
read. The only path an image may take into the cluster is:

    upstream mirror --(bastion, 300 Mbit/s traffic-billed EIP)--> SWR --(intranet)--> pods

Deploy-inputs keys (section `image_supply`):

| Key | Default | Meaning |
|---|---|---|
| `image_supply_chain` | `swr` | `swr` = the path above; `direct` only when nodes already reach a registry |
| `swr_org` | – | SWR organisation; `terraform output litellm_image` resolves to `swr.<region>.myhuaweicloud.com/<swr_org>/litellm:<version>` |

Run this on the **bastion** (the only public host), once per version:

```bash
./scripts/mirror-image.sh 1.106.3
```

It pulls from the fastest measured upstream (`ghcr.nju.edu.cn`, ~7 MB/s from
cn-southwest-2), pushes to SWR, and verifies the manifest at the destination.
Internally it calls `push-image.sh`, which runs `preflight-network.sh` first
(DNS, TCP 443, registry handshake, **authentication**, disk). Never call
`docker push ... | tail` directly: the pipe returns the exit status of `tail`,
so a rejected push looks like success.

Verified upstream mirrors (2026-10, cn-southwest-2):

| Source | Measured | Note |
|---|---|---|
| `ghcr.nju.edu.cn` | 7.0 MB/s | used by the bastion to pull |
| `ghcr.io` direct | hangs | not reachable from nodes |
| SWR same-region | internal `100.125.x` | the only correct source for pods |

**SWR authentication** — `docker login -u {region}@{AK} -p {SK}` is **rejected**
with `denied: Authenticate Error`. Use the temporary login credential instead:

```bash
# POST (GET returns 404), X-Auth-Token = IAM token for the project
POST https://swr-api.<region>.myhuaweicloud.com/v2/manage/utils/secret
# -> auths[host].auth = base64(user:pass)
```

That credential is valid **24 h**. Both deployment paths refresh the
`swr-cred` pull secret automatically on every `deploy-app` (via
`mirror-image.sh --print-creds`), so an expired secret surfaces as a fast local
failure instead of `ImagePullBackOff` two days later. The manual command, for
reference:

```bash
kubectl -n litellm create secret docker-registry swr-cred \
  --docker-server=swr.<region>.myhuaweicloud.com \
  --docker-username=<user> --docker-password=<pass>
```

`deploy-app` refuses to install an image that still points at a public registry
while `image_supply_chain = swr`, with the mirror command in the error.

Registry vs management endpoint differ and are not interchangeable:
`swr.<region>` (registry, `/v2/` -> 401) and `swr-api.<region>` (management).

## 8.1 Node sizing (measured, not guessed)

Official LiteLLM sizing is **1 vCPU / 4 GiB per pod, requests == limits**
(docs.litellm.ai/docs/proxy/prod). The node must satisfy that *plus* CCE system
pods (~0.9 GiB RAM, and up to ~3.25 vCPU of requests on a 4-vCPU node):

| Flavor | Allocatable | Verdict |
|---|---|---|
| `ac8.xlarge.4` (4C16G) | 3920m CPU | **fails** - system pods hold 3250m, 670m left, a 1-vCPU pod never schedules; replicas collapse into one AZ |
| `ac8.2xlarge.2` (8C16G) | 7910m CPU | **works** - one replica per AZ, room for a surge pod |

Changing `cce_node_flavor` cannot be done in place: the provider rejects it with
`flavor_id can't be updated`. Terraform must destroy and recreate the nodes
(target the node resource, apply, then apply again).

Check the result: `kubectl get pods -o wide` must show the replicas on nodes in
three different `topology.kubernetes.io/zone` values. The chart's zone spread is
`DoNotSchedule` on purpose - with `ScheduleAnyway` the scheduler packs all
replicas into one AZ and a single-zone failure takes the gateway down.

## 8b. Converging the Ingress, and proving the UI renders

`deploy-app` creates the Ingress once; afterwards the annotation
`kubernetes.io/elb.autocreate` cannot be edited (the API rejects it and the old
ELB keeps serving). When a subnet, zone list, port or flavor has to change:

```bash
./scripts/ingress-apply.sh --check    # report drift, change nothing (exit 2 = drift)
./scripts/deploy.sh ingress           # delete + recreate, then prove readiness
```

The stage refuses to guess: it reads the desired annotations from the rendered
bundle (the same file helm consumes), so "what Terraform says" and "what is in
the cluster" cannot diverge silently. It then prints the resolved zone list and
subnet ids before touching anything, because a wrong id type is the failure that
only shows up as `ELB.8904` in `kubectl describe ingress`.

For visual evidence, run from a machine outside the VPC:

```bash
./scripts/deploy.sh verify-ui         # writes $LITELLM_DEPLOY_HOME/out/verification/litellm-ui.{html,png}
```

It fetches `/ui/` through the bastion, opens an ssh tunnel to the private VIP,
renders the page with headless Chrome, then calls readiness and `/v1/models`.
Artifacts are gitignored; attach them to a change request instead of describing
the deployment.

## 9. Teardown

```bash
CONFIRM=yes ./scripts/destroy.sh terraform/examples/cce-ha
./scripts/handoff.py scrub     # back up, then clear AK/SK and customer values
./scripts/handoff.py check     # must print "clean"
```

Destroying the stack deletes the database. Take a manual backup first if the
data matters.

`scrub` copies `deploy-inputs.yaml` and anything under `secrets/` to
`$LITELLM_DEPLOY_HOME/state/handoff-<timestamp>/` (gitignored) before clearing: project name,
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
