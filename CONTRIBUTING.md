# Contributing

## Before you start

- Open an issue for anything larger than a typo or a version bump, so the design
  is agreed before the code.
- Keep changes scoped: infrastructure modules, the chart, and the scripts are
  separate concerns.

## Local checks

```bash
make bootstrap     # toolcheck
make fmt           # terraform fmt -recursive
make validate      # fmt check, terraform validate, helm lint/template, shellcheck
```

`make validate` needs no cloud credentials. CI runs the same target, so a green
local run is a good predictor.

## Changing the LiteLLM config

`config/litellm-config.yaml` is the single source of truth. The chart copy is
generated:

```bash
make sync-config
make validate
```

CI fails when the two files drift.

## Changing the chart

- Bump `version` in `charts/litellm/Chart.yaml` for anything that changes
  rendered output.
- Keep `appVersion` aligned with the pinned LiteLLM release.
- Never add a secret to `values.yaml`. The chart requires `existingSecret` on
  purpose.

## Changing Terraform

- Every module must keep `terraform validate` clean against the pinned provider.
- Provider version bumps belong in one commit, with `terraform fmt` output and a
  note about which fields changed.
- Do not add `access_key`/`secret_key` variables. Credentials come from the
  environment.
- Prefer a new module over a flag that switches a module between two unrelated
  topologies.

## Commit style

Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`.
Keep the subject imperative and under ~72 characters.

## Intellectual property

This repository must contain only original work:

- do not copy vendor documentation, screenshots or diagrams into the repo;
  summarise and link instead;
- do not vendor third-party code without checking its licence and adding the
  required attribution;
- do not commit images, PDFs or downloaded archives;
- the LiteLLM configuration and Helm chart here are original; LiteLLM itself is
  consumed as a container image, not vendored.

## Pull request checklist

- [ ] `make validate` passes
- [ ] no credentials, state files or kubeconfigs added
- [ ] docs updated for behaviour changes
- [ ] `CHANGELOG.md` entry for user-visible changes
- [ ] chart version bumped when rendered manifests change
