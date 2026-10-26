# Documentation map

Start here. This page says **which document answers which question**, and what
every file in the repository is for. If you add, rename or delete a file, update
this page in the same commit — `scripts/check-docs.py` fails the build when a
script, a Terraform module or a document is missing from it.

- New to the repository → [README](../README.md) for the what/why, then
  [docs/architecture.md](architecture.md) for the shape.
- About to deploy → [docs/sa-checklist.md](sa-checklist.md) →
  [docs/inputs-guide.md](inputs-guide.md) → [docs/deployment.md](deployment.md).
- Something is broken → [docs/troubleshooting.md](troubleshooting.md), then
  [docs/deployment-optimizations.md](deployment-optimizations.md) (the same
  failure seen in the field, with the fix).
- Reviewing the design → [docs/architecture.md](architecture.md),
  [docs/security.md](security.md), [docs/permissions.md](permissions.md),
  [docs/cost.md](cost.md).
- Upgrading LiteLLM → [docs/upgrade-procedure.md](upgrade-procedure.md) and
  `version-presets.yaml`.

## Repository layout

```
.
├── deploy-inputs.yaml        ← the only file an operator edits
├── version-presets.yaml      ← the validated LiteLLM baseline
├── AGENTS.md                 ← what an automated agent may run (authority)
├── Makefile                  ← thin wrapper over scripts/deploy.sh
├── terraform/
│   ├── modules/              ← 10 reusable modules (no project names inside)
│   └── examples/
│       ├── cce-ha/           ← production: CCE + RDS + DCS + ingress ELB
│       └── vm-single/        ← lab: one ECS, local PostgreSQL/Redis
├── charts/litellm/           ← Helm chart (app only, infrastructure is Terraform)
├── scripts/                  ← the deployment engine (bash + python)
├── docs/                     ← this directory
├── monitoring/               ← AOM alarms, Grafana dashboard, wiring guide
├── secrets/                  ← credential files, examples only in git
└── skills/                   ← agent skill that drives the same scripts
```

## Every file, and what it is for

### Root

| File | Role |
|---|---|
| `deploy-inputs.yaml` | Single input file: project name, network, models, sizing, feature switches. Validated by `scripts/preflight.py`, which also renders every generated artifact from it. |
| `version-presets.yaml` | LiteLLM `preset` / `max_compatible` / evidence rules. The upgrade gate reads it; nothing else may hard-code a version. |
| `AGENTS.md` | Agent contract: which stages may run unattended, what is forbidden (no `apply` without a reviewed plan, no `state rm`, no public listener). |
| `README.md` / `README.zh-CN.md` | Overview, architecture sketch, quick start, validation status, documentation table. Must link the same files (enforced). |
| `CONTRIBUTING.md` | Local setup, what `make validate` covers, commit and review rules. |
| `SECURITY.md` | How to report a vulnerability and the security posture this design assumes. |
| `CHANGELOG.md` | Keep-a-Changelog history; every user-visible change lands here. |
| `LICENSE` | Apache-2.0. |
| `Makefile` | Every target delegates to `scripts/deploy.sh`; no logic of its own. |
| `.terraform-version` | Pinned Terraform **1.17.0**. 1.9.8 panics on `-target` with checkable objects; do not lower it. |
| `.pre-commit-config.yaml` | Hooks: fmt, validate, shellcheck, docs links. |
| `.editorconfig`, `.gitignore` | Editor/whitespace rules; `.gitignore` also blocks state, plans, rendered values, `secrets/*.env`, `out/`, `tmp_*.py`. |

### `scripts/` — the deployment engine

| File | Role |
|---|---|
| `scripts/deploy.sh` | Entry point. Stages: `preflight`, `plan`, `apply-infra`, `deploy-app`, `verify`, `bastion-key`, `ingress`, `verify-ui`, `all`; `--remote` runs the in-cluster stages over the bastion. |
| `scripts/preflight.py` | Validates `deploy-inputs.yaml` (CIDRs, TLS, region, models, version gate) and **renders** `out/` — tfvars, Helm values, bundle. The only place inputs become artifacts. |
| `scripts/audit-secrets.py` | Pre-publication audit: forbidden paths (plans, state, keys, kubeconfigs), credential/PII patterns in the tree, and every blob in git history. Masked output; `make audit`. |
| `scripts/apply-stream.py` | Renders `terraform apply -json` as live per-resource progress (start, 10 s `apply_progress`, elapsed, errors), archives `$LITELLM_DEPLOY_HOME/out/apply-timeline.jsonl`, prints the slowest resources. Same plan gate as `apply-infra`. |
| `scripts/apply-staged.sh` | Applies in dependency order (edge → data → compute → cache → ops) so the slow/risky pieces fail early and metered resources come last. |
| `scripts/remote-deploy.sh` | Bundles values + chart + Secret + kubeconfig, uploads to the bastion, runs helm there. Subcommands: `deploy`, `verify`, `exec`, `put`. |
| `scripts/render-helm-values.py` | Merges `$LITELLM_DEPLOY_HOME/out/helm-values.yaml` with runtime ELB/image settings. The only place that knows how `elb_mode` maps to Ingress annotations. |
| `scripts/ingress-apply.sh` | Converges the CCE ELB Ingress: compares live vs rendered, deletes and recreates when the immutable `elb.autocreate` drifted, waits for the VIP, proves readiness. `--check` reports drift, exits 2. |
| `scripts/verify-ui.sh` | Operator-view proof: `/ui/` HTML through the bastion, headless-Chrome screenshot, readiness and `/v1/models` with the master key. |
| `scripts/smoke-test.sh` | Liveness, readiness, model list, optional chat completion against a reachable gateway. |
| `scripts/migrate.sh` | Break-glass only: re-runs the migration Job when a release died after Helm garbage-collected the hook. |
| `scripts/mirror-image.sh` | Pulls the upstream LiteLLM image into SWR in the same region (run it **on the bastion**, not on the laptop). |
| `scripts/push-image.sh` | `preflight-network.sh` → push with `pipefail` → verify the manifest exists. A bare `docker push | tail` once hid a rejected push. |
| `scripts/preflight-network.sh` | Before any push or bulk transfer: DNS, TCP 443, registry handshake, **authentication**, disk space. |
| `scripts/creds.sh` | AK/SK lifecycle: `set` (hidden prompt, 0600 file), `status`, `load`, `check`, `clear`. Credentials never appear in arguments or chat. |
| `scripts/handoff.py` | Customer-data lifecycle: `show`, `scrub` (back up, then clear every customer value), `check`. Run after every test. |
| `scripts/resolve-az.py` | Picks availability zones (policy + preferred order, verified against the account), writes them into the tfvars. |
| `scripts/resolve-cce-version.py` | Resolves which CCE Kubernetes minors the region actually accepts (bulletin lifecycle table + negative probe) and writes the newest commercial one. |
| `scripts/check-cce-versions.py` | Independent re-check of the pinned CCE version against the bulletin; non-zero when the preset falls behind. |
| `scripts/check-permissions.sh` | Read-only probe: can this identity see the services a deployment needs? Prints the role list from `docs/permissions.md` when it cannot. |
| `scripts/check-docs.py` | Keeps documentation honest: links resolve, the two READMEs agree, removed concepts stay removed, every script/module/document is listed in this page. |
| `scripts/check-monitoring.py` | Validates `monitoring/` — alarm metrics exist in the dashboard, JSON parses, links resolve. |
| `scripts/lint.sh` | Offline validation chain used by `make validate` and CI: fmt, validate, helm lint/template, shellcheck, docs, monitoring. |
| `scripts/inputs-table.py` | Prints `deploy-inputs.yaml` as a fill-in table (Markdown or CSV) to paste into a ticket or chat. |
| `scripts/draw-architecture-html.py` | Regenerates `docs/architecture.html` from the topology constants. |
| `scripts/destroy.sh` | Destroys an example; requires `CONFIRM=yes` because it deletes the database and the salt key. |
| `scripts/bootstrap.sh` | Toolchain check: prints the versions the repository expects and where they were found. |
| `scripts/install-tools.sh` | Installs what `bootstrap.sh` reports as missing: terraform/helm/kubectl into `~/.local/bin` (no sudo), jq/curl/unzip/python3 via apt/dnf/brew. `--check` reports only, `DRY_RUN=1` prints commands. Refuses Git Bash and points at WSL2. |
| `scripts/deploy-app.sh` | Compatibility shim; the application path lives in `deploy.sh`. Kept so old runbooks do not break. |
| `scripts/lib.sh` | Shared helpers: logging, redaction, retries, kubeconfig handling. |

### `terraform/modules/` — ten modules, no project names inside

| Module | What it creates | Notes |
|---|---|---|
| `maas-network` | VPC, four subnets (access/app/data/ops), security groups and their rules, optional NAT + EIP | NAT exists only for `model_endpoint_mode = nat`; every rule is derived from the CIDR inputs |
| `cce` | CCE cluster (`overlay_l2`), worker nodes across AZs, node security-group rules | Cluster version comes from the resolver; `is_ha_cluster` is derived from the flavor |
| `elb` | Standalone ELB + optional certificate + EIP | Only when `elb_mode = standalone`; the default path lets the Ingress own the ELB |
| `postgres` | RDS PostgreSQL HA instance + application database | `rds.*.ha` is enforced — single-node is refused by preflight |
| `redis` | DCS Redis HA instance | Redis 5/6 HA takes no security group; the module does not set one |
| `bastion` | One ECS + EIP, cloud-init bootstrap | The only host with a public address; kubectl + helm only |
| `observability` | LTS log group/stream, CES alarms, SMN topic and subscription | Alarms are opt-in: metric names differ per region |
| `vpcep` | VPC endpoint for ModelArts / MaaS | Used when models are reached over a private endpoint |
| `vpn` | Customer gateway + VPN gateway | Optional hybrid connectivity |
| `naming` | Name and tag locals (`<project>-maas-<component>`) | No resources; keeps naming in one place |

### `terraform/examples/`

| Path | Role |
|---|---|
| `cce-ha/` | Production example: wires the modules, owns the tfvars, exports the values `deploy.sh` consumes. |
| `vm-single/` | Lab example: one ECS with local PostgreSQL and Redis. Explicitly not HA — evaluation only. |

### `charts/litellm/` — application only

| File | Role |
|---|---|
| `Chart.yaml`, `values.yaml` | Chart metadata and defaults (1 vCPU / 4 GiB, probes, topology spread). |
| `templates/deployment.yaml` | Gateway Deployment; `DISABLE_SCHEMA_UPDATE=true`, runs as non-root. |
| `templates/migration-job.yaml` | Pre-install/pre-upgrade hook that applies LiteLLM's bundled Prisma migrations. |
| `templates/configmap.yaml` | Single-document `config.yaml` rendered from the inputs (models, fallbacks, router settings). |
| `templates/ingress.yaml` | CCE ELB Ingress (`ingressClassName: cce`) with the `elb.autocreate` annotation. |
| `templates/service.yaml` | ClusterIP/NodePort Service; the Ingress owns external access. |
| `templates/hpa.yaml`, `pdb.yaml` | Optional autoscaling and the disruption budget. |
| `templates/serviceaccount.yaml`, `_helpers.tpl`, `NOTES.txt`, `.helmignore` | Identity, template helpers, install notes, packaging exclusions. |

### `docs/`

| Document | Contents |
|---|---|
| `index.md` | This map: what to read when, and what every file is for. |
| `docs/architecture.md` | Components, failure domains, request path, network segments, upgrade flow. |
| `architecture.html` | Rendered topology (regenerate with `scripts/draw-architecture-html.py`). |
| `docs/deployment.md` | Prerequisites, IAM, credentials, step-by-step deploy, what each stage proves. |
| `docs/operations.md` | Scaling, upgrades, rollback, backup/restore, key rotation, day-2 checks. |
| `docs/security.md` | Secrets, network, TLS, image verification, IAM, who may call the gateway. |
| `docs/permissions.md` | Required IAM roles per stage, minimal custom policy, CCE agency caveat. |
| `docs/sa-checklist.md` | Tick-box planning checklist: network, egress, data, encryption, go-live. |
| `docs/inputs-guide.md` | How to fill each input, how to write the model array. |
| `docs/manual-deployment.md` | Console click-through when Terraform is not allowed. |
| `docs/upgrade-procedure.md` | What a version bump actually requires before `ACK_UPGRADE=1`. |
| `docs/troubleshooting.md` | Symptom → cause → fix, including the four things that block a teardown. |
| `docs/deployment-optimizations.md` | Field notes from real deployments: 22 issues with symptom, root cause, fix. |
| `docs/cost.md` | Resource list, reference prices, cost levers. |
| `docs/huaweicloud-regions.md` | Regions, endpoints, AZ quirks, flavor codes. |
| `docs/modelarts-intranet.md` | Calling ModelArts over a private endpoint. |

### `monitoring/`, `secrets/`, `skills/`

| Path | Role |
|---|---|
| `monitoring/README.md` | How logs reach LTS, metrics reach AOM, and Grafana pulls AOM from inside the VPC. |
| `monitoring/alerting-rules.yaml` | AOM alarm rules: availability, latency, error rate, saturation. |
| `monitoring/grafana-dashboard.json` | Dashboard for AOM's Prometheus-compatible endpoint. |
| `secrets/README.md` | What belongs in `$LITELLM_DEPLOY_HOME/secrets/app.env` and `$LITELLM_DEPLOY_HOME/secrets/hw.env`, and what must never be committed. |
| `secrets/app.env.example` | Template for provider API keys (`api_key_env` names, never the keys themselves). |
| `secrets/hw.env.example` | Template for AK/SK; filled by `scripts/creds.sh set`, never by hand-editing. |
| `skills/litellm-huaweicloud-deploy/SKILL.md` | Agent skill: the same flow, the decisions behind it, and failure routing. Installed with `make skill-install`. |

## Generated, never committed

`scripts/preflight.py` and the deploy stages write these; all are gitignored.

| Path | Produced by | Contents |
|---|---|---|
| `out/terraform.tfvars` | preflight | Module inputs derived from `deploy-inputs.yaml` |
| `$LITELLM_DEPLOY_HOME/out/helm-values.yaml` | preflight | Models, fallbacks, resources, image |
| `out/bundle.tar.gz` | `--remote` | Chart + values + Secret + kubeconfig for the bastion |
| `out/tfplan` | `plan` | The saved plan `apply-infra` consumes |
| `$LITELLM_DEPLOY_HOME/out/verification/` | `verify-ui` | `litellm-ui.html`, `litellm-ui.png` evidence |
| `$LITELLM_DEPLOY_HOME/secrets/hw.env`, `$LITELLM_DEPLOY_HOME/secrets/app.env` | `creds.sh`, operator | Live credentials (0600, gitignored) |

## Keeping this page true

- A new script, module or document is not finished until it appears above.
- `scripts/check-docs.py` enforces that: `scripts/*`, `terraform/modules/*` and
  `docs/*.md` must be referenced here, and the two READMEs must link the same
  documents.
- Describe the **responsibility**, not the current implementation detail. If a
  file's job changes, change its row.
