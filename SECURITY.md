# Security policy

## Reporting a vulnerability

Do not open a public issue for security problems. Use GitHub's private
vulnerability reporting (Security → Advisories → Report a vulnerability) on this
repository.

Include: affected version/commit, a reproduction or proof of concept, the
impact you expect, and whether a fix is already known.

## Scope

In scope:

- credential handling in the Terraform modules, scripts and chart;
- network exposure created by the modules (security group rules, public IPs);
- defaults that weaken TLS, authentication or secret storage;
- supply-chain issues in how the LiteLLM image is pinned or verified.

Out of scope:

- vulnerabilities in LiteLLM itself — report those upstream;
- vulnerabilities in Huawei Cloud managed services — report them to Huawei;
- findings that require an already-compromised cloud account.

## Supported versions

Only the latest tagged release of this repository receives fixes. The pinned
LiteLLM version is bumped as part of normal maintenance; see
[docs/operations.md](docs/operations.md) for the upgrade procedure.

## What we already assume

- The Terraform state contains generated secrets. Protect it accordingly.
- `secrets/app.env` is a local file and is gitignored; leaking it is a
  credential incident, not a bug.
- The lab example (`terraform/examples/vm-single`) is deliberately insecure:
  plain HTTP, secrets in user_data, single node. It is documented as such and
  must not be used for production traffic.
