# Repository map — every file, and who uses it

145 tracked files. Each row below answers "what is this for" and "what reads it".
Two things were deleted during the audit (`docs/architecture.html` and its
generator); everything else has a caller. Generated files are listed separately
because they must never be committed.

## Top level

| File | What it is | Who uses it |
|---|---|---|
| `deploy-inputs.yaml` | Phases 1–2: infrastructure and gateway baseline. The only file an operator edits. | `preflight.py` (reads), `fill-inputs.sh` (writes 4 values), `inputs-table.py` (renders a table) |
| `models.yaml` | Phase 3: the model list and fallback policy. | `preflight.py --with-models`, `models-diff.py`, `deploy.sh models` |
| `version-presets.yaml` | The validated LiteLLM version, plus the upgrade gate boundaries. | `preflight.py` (`check_version`), `docs/upgrade-procedure.md` |
| `AGENTS.md` | What an automated agent may and may not do. | every agent session; referenced by the skill |
| `Makefile` | Thin wrapper over `deploy.sh` and the linters. | humans, CI |
| `README.md` / `README.zh-CN.md` | Entry point, with the architecture image at the top. | humans, GitHub |
| `CHANGELOG.md` | Why each release changed. | humans |
| `CONTRIBUTING.md` | How to change the repo without breaking the deploy path. | contributors |
| `SECURITY.md` | How to report a vulnerability. | contributors |
| `LICENSE` | Apache-2.0. | GitHub |
| `.gitignore` | Keeps state, tfvars, plans, venvs and the runtime home out of git. | git |
| `.gitattributes` | Forces LF so a Windows checkout cannot break `#!/usr/bin/env bash`. | git |
| `.editorconfig` | Indentation and final-newline rules. | editors |
| `.pre-commit-config.yaml` | Runs `make lint` before a commit. | contributors |
| `.terraform-version` | 1.17.0, the version CI and the docs assume. | tfenv users, CI |

## `terraform/` — infrastructure

Ten modules, all used by at least one example; nothing here is decorative.

| Module | What it creates | Used by |
|---|---|---|
| `modules/maas-network` | VPC, five subnets, security groups, the bastion's egress rules | `examples/cce-ha` |
| `modules/cce` | Cluster plus one node pool per AZ, GPSSD2 volumes | `examples/cce-ha` |
| `modules/postgres` | RDS PostgreSQL primary/standby, KMS-encrypted | `examples/cce-ha` |
| `modules/redis` | DCS Redis primary/standby | `examples/cce-ha` |
| `modules/elb` | A Terraform-owned ELB (`elb_mode = standalone` only) | `examples/cce-ha` |
| `modules/bastion` | The jump host, its EIP (optional) and the bootstrap script | `examples/cce-ha` |
| `modules/observability` | LTS log group, AOM Prometheus instance, alarm rules | `examples/cce-ha` |
| `modules/vpcep` | ModelArts private endpoint | `examples/cce-ha` |
| `modules/vpn` | VPN gateway for on-prem callers (`vpn_enabled`) | `examples/cce-ha` |
| `modules/naming` | `<project>-maas-<component>` name and tag convention | all of the above |

| Example | What it is | Used by |
|---|---|---|
| `examples/cce-ha` | The production stack. Everything in the docs refers to this. | `deploy.sh`, `destroy.sh`, CI |
| `examples/vm-single` | One ECS with local PostgreSQL/Redis, for evaluation only. | README (lab tier) |
| `examples/*/terraform.tfvars.example` | Shape of the generated tfvars; `preflight` writes the real file. | humans (reading), `preflight` (not read) |
| `examples/*/versions.tf`, `.terraform.lock.hcl` | Provider pinning. | `terraform init` |
| `examples/cce-ha/backend.tf.example` | Remote state config to copy when you use OBS. | `docs/deployment.md` |

## `charts/litellm/` — the application

| File | What it renders | Notes |
|---|---|---|
| `templates/configmap.yaml` | The single LiteLLM config document: `model_list`, router, cache, general settings | `store_model_in_db: false`; empty model list renders `[]` |
| `templates/deployment.yaml` | Gateway pods, probes, `preStop`, checksum annotation | rolls when the config changes |
| `templates/migration-job.yaml` | Prisma migrations as a pre-install/pre-upgrade hook | tables are never created by hand |
| `templates/service.yaml` | ClusterIP (ingress mode) or LoadBalancer (standalone) | |
| `templates/ingress.yaml` | The `elb.autocreate` annotation that makes the internal ELB | immutable; `ingress-apply.sh` converges it |
| `templates/pdb.yaml` | PodDisruptionBudget, keeps 2 of 3 replicas during drains | |
| `templates/hpa.yaml` | Optional HPA, off by default (`autoscaling.enabled`) | not rendered in the default profile |
| `templates/serviceaccount.yaml`, `_helpers.tpl`, `NOTES.txt` | Standard chart plumbing | |
| `values.yaml` | Every knob, with the reasoning inline | read by `render-helm-values.py` |

## `scripts/` — the deployment engine

| Script | What it does | Called by |
|---|---|---|
| `deploy.sh` | The stage switch: preflight, plan, apply-infra, apply-stream, deploy-app, verify, ingress, verify-ui, models, seal, unseal | humans, CI, the skill |
| `lib.sh` | Shared shell helpers: repo root, runtime home, credentials, terraform outputs | every other shell script |
| `preflight.py` | Validates inputs, renders `terraform.tfvars` and the Helm values | `deploy.sh`, `models` stage |
| `fill-inputs.sh` | Asks the four questions, writes only those lines | humans (phase 1) |
| `inputs-table.py` | Renders the parameter table; `--actionable` shows only what is left | humans, agents |
| `set-input.py` | Sets one value in `deploy-inputs.yaml` | `deploy.sh seal` / `unseal` |
| `creds.sh` | AK/SK lifecycle: set, status, load, check, clear | humans, `bootstrap.sh`, `remote-deploy.sh` |
| `apply-staged.sh` | Ordered apply (network → data → cluster → everything) | `deploy.sh apply-infra`, docs |
| `apply-stream.py` | `terraform apply -json` rendered as live progress | `deploy.sh apply-stream` |
| `resolve-az.py` | Picks real AZs for the region | `preflight.py` |
| `resolve-cce-version.py` | Asks the CCE SDK which versions are still supported | `deploy.sh` before plan |
| `check-cce-versions.py` | Compares the pin against the vendor bulletin | CI, `docs/huaweicloud-regions.md` |
| `render-helm-values.py` | Merges rendered values with runtime ELB/Ingress wiring | `deploy.sh`, `remote-deploy.sh` |
| `remote-deploy.sh` | Bundles values + chart + secrets and runs Helm on the bastion | `deploy.sh --remote` |
| `ingress-apply.sh` | Converges the immutable Ingress annotation, `--check` reports drift | `deploy.sh ingress` |
| `verify-ui.sh` | Fetches `/ui/`, screenshots it through the bastion | `deploy.sh verify-ui` |
| `smoke-test.sh` | Readiness, model list, one completion | `deploy.sh verify`, `remote-deploy.sh` |
| `migrate.sh` | Re-runs the migration Job when a release died after the hook | `docs/troubleshooting.md` |
| `mirror-image.sh` | Pull upstream, push to SWR, verify the manifest | bastion, `docs/deployment.md` |
| `push-image.sh` | Network/auth/disk preflight, push, manifest check | `mirror-image.sh` |
| `preflight-network.sh` | Checks DNS/TCP/TLS to a registry before a 419 MB pull | `push-image.sh` |
| `models-diff.py` | Added / removed / changed models and fallbacks; flags a rename | `deploy.sh models --check` |
| `destroy.sh` | Uninstalls the release, then destroys; refuses without `CONFIRM=yes` | humans |
| `handoff.py` | Customer-facing form, plus scrub/check of local artifacts | `deploy.sh`, `destroy.sh` |
| `audit-secrets.py` | Finds credential-shaped files and tracked secrets | `make audit`, CI |
| `check-docs.py` | Every file documented, every link resolves, README parity | `make lint` |
| `check-monitoring.py` | Dashboard JSON and alert rules stay valid | `make lint` |
| `check-permissions.sh` | Lists the IAM actions each stage needs | `docs/permissions.md` |
| `install-tools.sh` | Installs missing terraform/helm/kubectl/jq/python3 | humans, phase 0 |
| `bootstrap.sh` | Prints tool versions and credential state | humans, `install-tools.sh` |
| `lint.sh` | shellcheck + terraform fmt/validate + helm lint + docs + monitoring | `make lint`, CI |

## `docs/` — the documentation set

| Document | Question it answers |
|---|---|
| `index.md` | Which document answers which question; the file map |
| `repository-map.md` | This page: every file and its caller |
| `architecture.md` | Components, failure domains, request path |
| `architecture.png` / `.zh-CN.png` / `.drawio` | The picture (deploy-time state), editable in diagrams.net |
| `deployment.md` | Step-by-step deploy, what each stage proves |
| `phase1-inputs.md` | The four values you must decide, and why |
| `prompts.md` | Paste-ready prompt per phase |
| `inputs-guide.md` | Field-by-field reference for `deploy-inputs.yaml` |
| `credentials.md` | Four ways to supply AK/SK, and how to prove them gone |
| `security.md` | Secrets, network, TLS, IAM, who may call the gateway |
| `permissions.md` | Required IAM roles per stage |
| `sa-checklist.md` | Planning checklist before stage 1 |
| `operations.md` | Scaling, upgrades, rollback, backup, key rotation |
| `upgrade-procedure.md` | What a version bump requires before `ACK_UPGRADE=1` |
| `troubleshooting.md` | Symptom → cause → fix |
| `deployment-optimizations.md` | Field notes from the real deployments |
| `manual-deployment.md` | Console click-through when Terraform is not allowed |
| `modelarts-intranet.md` | Calling ModelArts over a private endpoint |
| `huaweicloud-regions.md` | Regions, endpoints, AZ quirks, flavour codes |
| `cost.md` | Resource list and cost levers |

## Everything else

| Path | What it is | Used by |
|---|---|---|
| `monitoring/alerting-rules.yaml` | AOM alarm rules (13 metrics) | `check-monitoring.py`, `docs/operations.md` |
| `monitoring/grafana-dashboard.json` | Dashboard for a local Grafana | `check-monitoring.py`, `monitoring/README.md` |
| `monitoring/README.md` | How to wire AOM/LTS into Grafana | humans |
| `secrets/hw.env.example` | Shape of the AK/SK file | `creds.sh` |
| `secrets/app.env.example` | Shape of the provider-key file | `deploy-app.sh` (env-file) |
| `secrets/README.md` | Where secrets live, four supply paths | humans, `docs/credentials.md` |
| `skills/litellm-huaweicloud-deploy/SKILL.md` | The agent-facing flow and decisions | agent sessions; symlinked into `~/.hermes/skills` |
| `.github/workflows/ci.yml` | terraform fmt/validate, helm lint, shellcheck, docs, monitoring | GitHub Actions |

## How this was verified

```bash
git ls-files | wc -l                       # 145 tracked files
for m in terraform/modules/*/; do ...      # 10/10 modules referenced by an example
helm template t charts/litellm ...         # ConfigMap, Deployment, Ingress, Job, PDB, Service, SA
grep -rl '<script name>' .                 # every script has a caller outside docs/index.md
```

Results: no tracked file is unreferenced. Three things were removed because they
were not: `docs/architecture.html` and `scripts/draw-architecture-html.py` (the
old picture and its generator, replaced by the PNG/drawio pair) and
`scripts/__pycache__` (build debris, now ignored).

## Generated — never commit

| Path | Produced by |
|---|---|
| `~/.litellm-deploy/out/*` | `preflight.py` (tfvars, helm values, plan, preflight.json) |
| `~/.litellm-deploy/state/*` | staged plans, bastion key, model snapshots, handoff backups |
| `terraform/examples/*/terraform.tfvars` | `preflight.py` |
| `terraform/examples/*/terraform.tfstate*` | Terraform (contains generated passwords) |
| `terraform/examples/*/.terraform/` | `terraform init` |
| `terraform/examples/*/tfplan` | `terraform plan` |
| `.venv-sdk/` | optional local SDK venv |
