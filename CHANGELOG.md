# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- One deployment implementation: `deploy-app.sh` is a shim over
  `deploy.sh deploy-app`. The previous duplicate read a removed output and
  skipped the rendered model list, producing a gateway with no models.
- `deploy.sh --remote` runs in-cluster stages on the bastion; a machine outside
  the VPC cannot reach the CCE API or the private ELB.
- Documentation consolidated: one canonical flow (`docs/deployment.md`), one
  checklist (`docs/sa-checklist.md`), one index in the READMEs.
- The flow ships as an agent skill in `skills/litellm-huaweicloud-deploy`,
  symlinked into `~/.hermes/skills` by `make skill-install`.

### Added

- `monitoring/`: AOM alert rules, Grafana dashboard, wiring guide.
- `docs/sa-checklist.md`: solution-architect planning checklist.
- `scripts/check-docs.py`: fails on removed concepts, broken links and README
  drift; `scripts/check-monitoring.py`: validates alert rules and their runbook
  anchors.
- `scripts/remote-deploy.sh`: bastion bundle/push/exec.

### Removed

- `scripts/preflight.sh`, `scripts/deploy-infra.sh`, `scripts/bastion-exec.sh`
  (superseded by `deploy.sh`, `remote-deploy.sh`).
- `doc-forlearn01.txt` (external draft, not part of this project).

## [0.1.0] - 2026-10-24

Initial public release.

### Added

- Terraform modules: `network`, `postgres`, `redis`, `cce`, `elb`,
  `observability`, `vpn`, `vpcep`, validated against
  `huaweicloud/huaweicloud` 1.99.1.
- `examples/cce-ha`: CCE cluster with three control-plane masters, one node pool
  per AZ, RDS PostgreSQL 16 primary/standby, DCS Redis 7 primary/standby,
  dedicated ELB with elastic L7 flavor, NAT egress, KMS encryption, CSMS
  secrets, LTS access logs, optional VPN gateway and ModelArts VPC endpoint.
- `examples/vm-single`: single-ECS lab tier with Docker, local PostgreSQL and
  Redis, driven by cloud-init.
- Helm chart with a pre-install/pre-upgrade migration Job, readiness/liveness/
  startup probes, PodDisruptionBudget, topology spread across zones and hosts,
  rolling update with `maxUnavailable: 0`, and CCE ELB Service annotations.
- Deployment scripts: infra deploy, app deploy (secrets from Terraform outputs
  plus an optional provider env file), break-glass migration, smoke test, SWR
  image mirroring, destroy.
- Production LiteLLM configuration: Redis-backed router and cache, batched spend
  writes, bounded connection pool, trusted proxy ranges.
- Documentation: architecture, deployment, operations, security, cost,
  troubleshooting, ModelArts private access, Huawei Cloud region/AZ reference.
- CI validating Terraform, the chart, script linting, config drift and secrets.

### Pinned

- LiteLLM `v1.106.3`.
- Terraform provider `huaweicloud/huaweicloud` `~> 1.99` (1.99.1 at release).
