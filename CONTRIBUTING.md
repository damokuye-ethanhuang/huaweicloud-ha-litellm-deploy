# Contributing

## Before you start

- Open an issue for anything larger than a typo or a version bump, so the design
  is agreed before the code.
- Keep changes scoped: infrastructure modules, the chart, and the scripts are
  separate concerns.

## Local checks

Before anything goes public, run `make audit`. It fails on a committed saved
plan, state file or private key, on credential/PII patterns, and on anything
still present in git history - a secret removed by `git rm` is still in the
object database and still published by `git push`.

```bash
make bootstrap     # toolcheck
make fmt           # terraform fmt -recursive
make validate      # fmt check, terraform validate, helm lint/template, shellcheck
```

`make validate` needs no cloud credentials. CI runs the same target, so a green
local run is a good predictor.

## Changing the LiteLLM config

There is no hand-edited `config.yaml`. Non-secret settings live in
`charts/litellm/values.yaml` under `config.settings`, the model list is rendered
from `deploy-inputs.yaml`, and `scripts/deploy.sh preflight` writes the result to
`out/helm-values.yaml`. Edit the inputs, re-run preflight, redeploy:

```bash
./scripts/deploy.sh preflight
./scripts/deploy.sh --remote deploy-app
```

Never add a second YAML document to the generated config: LiteLLM reads only the
first document and silently ignores the rest.

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
