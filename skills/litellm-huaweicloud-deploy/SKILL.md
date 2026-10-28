---
name: litellm-huaweicloud-deploy
description: "Use when deploying HA LiteLLM on Huawei Cloud (private CCE). Terraform builds a private VPC, three-worker CCE, RDS PostgreSQL HA and DCS Redis HA; Helm runs three replicas behind an internal ELB, then verify proves readiness."
version: 1.2.2
license: Apache-2.0
compatibility: "Needs the repository checkout: every command is repo-relative. Also Terraform 1.17+, Helm 3.16+, kubectl, python3, and Huawei Cloud credentials exported in the shell; only the bastion can reach the cluster and the internal ELB."
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

Run every command below **from the repository root** — the paths are relative to
it. Installing this skill copies only `SKILL.md`, so the checkout is what makes
the commands exist.

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
| `apply-stream` | your machine | same apply, live per-resource progress from `apply -json` |
| `deploy-app` | **bastion** | needs cluster API + helm |
| `verify` | **bastion** | the ELB VIP is routable from inside the VPC only, and it only exists after the Ingress reconciles |
| `ingress` | your machine (drives the bastion) | converges the immutable `elb.autocreate` annotation, then proves the VIP serves |
| `verify-ui` | your machine (drives the bastion) | `/ui/` HTML + headless-Chrome screenshot as evidence |
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

## 1. Environment, then orient

### 1.1 Step 0 - pick the host before running anything

A wrong host shows up 20 minutes into `apply-infra`, so settle it first.

| Host | Verdict |
|---|---|
| Linux VM, macOS | supported - the reference setup |
| Windows + WSL2 (Ubuntu 22.04+) | supported - clone inside the WSL filesystem |
| Windows + Git Bash | untested - path translation and a no-op `chmod` fail late |
| Windows native (PowerShell, cmd) | unsupported - the entry points are bash |

**Recommended: run the agent on a Linux VM in the cloud**, not a laptop. Hermes
on a small ECS is the cheapest reliable option, and Claude Code, Codex CLI,
Cursor or Gemini CLI are equally fine - the flow only needs a shell. The reasons
are practical: `apply-infra` holds many API connections for 20-40 minutes,
`deploy-app`/`verify` hop through the bastion over ssh, and
`$LITELLM_DEPLOY_HOME` must survive the whole run. Laptop sleep, VPN flaps and
CRLF checkouts all surface as confusing mid-apply failures.

The repo installs its own toolchain, announced first (AGENTS.md forbids silent
installs):

```bash
./scripts/install-tools.sh --check    # what is missing, exit 1 if anything is
./scripts/install-tools.sh            # terraform 1.17, helm 3.16, kubectl 1.37, jq, curl, unzip, python3
DRY_RUN=1 ./scripts/install-tools.sh  # print every command, change nothing
```

On Windows the order matters: `powershell -c "wsl --install -d Ubuntu"`,
reboot, open Ubuntu, `git clone` **there**, then run the installer. Never clone
on the Windows side and work from `/mnt/c` - `chmod 700` on the secrets
directory is a no-op on DrvFs.

An agent without a shell (chat-only UI) cannot run this flow; say so instead of
starting.

### 1.2 Read these, in this order

1. `AGENTS.md` — what an agent may and may not do (authoritative).
2. `docs/index.md` — the file map: which document answers which question, and
   what every script and module is for. Start here when the repo is unfamiliar.
3. `deploy-inputs.yaml` — every parameter, with `help` text and validation.
4. `version-presets.yaml` — the validated LiteLLM baseline.
5. `docs/sa-checklist.md` — planning checklist; tick it before stage 1.

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

### Credentials

Never ask for AK/SK in chat. The operator picks one of four paths (detail in
`secrets/README.md`):

1. `./scripts/creds.sh set` - hidden input, 0600 file. It refuses to run without
   a TTY, so an agent cannot fill it in on their behalf.
2. Export `HW_ACCESS_KEY` / `HW_SECRET_KEY` in the shell that runs the
   deployment (for Hermes as a service: `~/.hermes/.env`, then restart).
3. `./scripts/creds.sh set --from-env` after exporting - non-interactive.
4. `~/.huaweicloud/credentials` when the SDK is already configured.

Verify with `./scripts/creds.sh status` (shows the source and a masked AK);
never verify by printing the values.

### Models are not an input (phase 3)

`deploy-inputs.yaml` describes infrastructure and the gateway baseline only.
Preflight never reads a model list, so stages 1-2 complete with no provider at
all - which is what makes "the control plane works" a testable statement.

Models and fallbacks live in `models.yaml` and are applied by their own stage:

```bash
./scripts/deploy.sh models --check      # validate + diff against what is applied
./scripts/deploy.sh models --apply      # render, roll the pods, snapshot
./scripts/deploy.sh models --rollback   # re-apply the previous snapshot
```

Operators paste a table; convert it to this shape:

```
glm-5.3 | https://<maas-vpce-ip>/v2/ | sk-xxx | openai/glm-5.3
deepseek-v4.1-flash | https://<modelarts-vpce-ip>/v1/ | | openai/deepseek-v4.1-flash
```

Column order: `name | api_base | api_key | model`.

- `name` is the tenant-facing contract (`"model": "glm-5.3"`). Never rename it
  after go-live; change `model` or `api_base` instead. `--check` flags a rename.
- `api_base` is not policed. Nodes have no egress, so a public URL simply fails
  at call time; preflight only warns.
- `api_key` empty means the endpoint does not authenticate: keep `api_key_env`
  and leave that variable unset in `app.env`. Never write a key into a YAML file.
- `fallbacks.enabled: true` with no explicit `pairs` means all-to-all among the
  models. Past three models, list pairs explicitly.

## 3. Stage flow

```bash
./scripts/install-tools.sh --check # 0. toolchain; installs on consent
./scripts/deploy.sh preflight      # validate + render out/
./scripts/deploy.sh plan           # save tfplan, change nothing
#   ◄── MANDATORY: a human reads the plan before apply
./scripts/deploy.sh apply-infra    # 20–40 min
./scripts/deploy.sh apply-stream   # same saved plan, live progress + $LITELLM_DEPLOY_HOME/out/apply-timeline.jsonl
./scripts/deploy.sh --remote deploy-app   # helm on the bastion
./scripts/deploy.sh --remote verify       # smoke on the bastion
./scripts/deploy.sh ingress              # converge Ingress (idempotent), prove VIP
./scripts/deploy.sh verify-ui            # /ui/ HTML + screenshot through the bastion
./scripts/deploy.sh models --check       # phase 3: what would change
./scripts/deploy.sh models --apply       # phase 3: models + fallbacks, rolling restart
./scripts/deploy.sh models --rollback    # phase 3: undo the last model change
CONFIRM=yes ./scripts/deploy.sh seal     # closing: delete the bastion EIP (no public IP left)
CONFIRM=yes ./scripts/deploy.sh unseal   # re-open for maintenance (new address)
```

`--remote all` does bundle + upload + deploy-app + verify in one go.

Every stage is idempotent. `all` without `--remote` includes apply and must
never run unattended.

### Phase 3: models and fallbacks

Phase 2 leaves the gateway running with `model_list: []`. `/v1/models` returning
200 with an empty array is the phase-2 exit criterion: database, Redis, auth and
the UI are proven before any provider is involved.

`models.yaml` is the only model source. `store_model_in_db: false` and
`STORE_MODEL_IN_DB=False` are deliberate: with either true, a model created in
the Admin UI lands in the database and the two lists diverge silently - the
drift the three-phase split exists to prevent. Do not flip them back.

`--check` changes nothing and prints added / removed / changed entries plus
fallback changes. `--apply` renders values, runs the same helm path as
`deploy-app`, and snapshots to `$STATE_DIR/models.applied.yaml` (the previous
becomes `models.prev.yaml`, which is what `--rollback` re-applies). A config
change rolls the pods; `maxUnavailable: 0` plus `preStop` keep in-flight streams
alive.

### Closing: seal the stack

Only the bastion ever holds a public IP, so sealing is one switch:
`bastion_eip_enabled`. `./scripts/deploy.sh seal` writes it to
`deploy-inputs.yaml` (never `-var`, or the next plain apply re-creates the EIP),
renders, plans, and - only with `CONFIRM=yes` - applies the two-resource destroy.
It then proves the result: `bastion_public_ip` empty and no `huaweicloud_vpc_eip`
left in state. `unseal` reverses it and assigns a new address.

Seal last, after phase 3 passes. Once sealed, nothing outside the VPC can reach
the gateway or the bastion; `--remote` stages stop working until `unseal`.

### Ingress: the three settings that decide whether it works

`kubernetes.io/elb.autocreate` is immutable and its two subnet fields take
different id types. Getting either wrong looks identical from the outside: the
Ingress has no `ADDRESS` and events show `ELB.8904 get network or subnet info by
elb_virsubnet_ids failed`.

| Setting | Correct value | Wrong value looks like |
|---|---|---|
| `vip_subnet_cidr_id` | Neutron subnet id of the **access** subnet | 404 `subnet ... could not be found` |
| `elb_virsubnet_ids` | VPC **network** id of the access subnet | `ELB.8904` |
| listener port | 80 without a certificate, 443 with one | VIP accepts nothing on the port you probe |
| Service type | **NodePort** (overlay cluster) | pool has zero members, VIP hangs up |

`./scripts/deploy.sh ingress` encodes all four: it compares the live Ingress with
the rendered bundle, deletes and recreates when the immutable annotation drifted,
waits for the VIP, and fails if `/health/readiness` does not answer through it.
`scripts/ingress-apply.sh --check` reports drift and exits 2 without changing
anything — use it before blaming the app.

### Verifying what the operator will see

Pod counts are not evidence that the gateway works: the UI is a Next.js SPA, so
an HTML fetch alone proves nothing either. `./scripts/deploy.sh verify-ui`
fetches `/ui/` through the bastion, opens an ssh tunnel, renders the page with
headless Chrome, and calls readiness plus `/v1/models` with the master key. It
writes `$LITELLM_DEPLOY_HOME/out/verification/litellm-ui.{html,png}` (gitignored).

### What `deploy-app` does

1. kubeconfig → bundled (0600);
2. namespace + `litellm-secrets` from Terraform outputs merged with
   `$LITELLM_DEPLOY_HOME/secrets/app.env`;
3. merges `$LITELLM_DEPLOY_HOME/out/helm-values.yaml` (models, fallbacks, resources) with runtime ELB
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

- Internal only: ELB has no EIP; the bastion is the only host that ever has one,
  and `deploy.sh seal` removes it once the deployment is verified.
- Every failure hit in the first end-to-end run is catalogued in
  `docs/deployment-optimizations.md` §22 — check it before inventing a fix.
- Secrets are generated by Terraform into CSMS. Never write them to files, args
  or chat. The bundle's `app.env` is 0600 and never committed.
- `LITELLM_SALT_KEY` is not rotatable once models exist (`prevent_destroy`).
- Never widen a security group, add an EIP, or edit state to "make it work".
  Those are design changes requiring review.
- Models come from `models.yaml` only. The Admin UI is not a model source
  (`store_model_in_db: false`); a model visible there but missing from the file
  means someone broke this rule.
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
