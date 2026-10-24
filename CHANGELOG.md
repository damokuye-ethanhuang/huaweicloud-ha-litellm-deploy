# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
