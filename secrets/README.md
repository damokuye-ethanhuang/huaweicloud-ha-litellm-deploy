# Secrets: examples only

This directory holds **templates**, not credentials. The real files live outside
the repository, in `$LITELLM_DEPLOY_HOME` (default `~/.litellm-deploy`):

```
~/.litellm-deploy/secrets/hw.env     AK/SK        ./scripts/creds.sh set
~/.litellm-deploy/secrets/app.env    model keys   edit by hand, 0600
```

The repository keeps `hw.env.example` and `app.env.example` so the format is
documented and `creds.sh set` has something to start from. Both are tracked;
neither contains a value.

```bash
./scripts/creds.sh set        # prompts with hidden input, writes hw.env at 0600

$EDITOR ~/.litellm-deploy/secrets/app.env
# GLM_API_KEY=sk-...
# DEEPSEEK_API_KEY=            # empty: the endpoint does not authenticate
```

Rules:

- One variable per model entry, named exactly as its `api_key_env` in
  `deploy-inputs.yaml`.
- Leave the value empty rather than inventing a placeholder - LiteLLM sends an
  empty key, which is correct for unauthenticated internal endpoints.
- `app.env` is the only place a provider key may live. Never in
  `deploy-inputs.yaml`, Helm values, or on a command line.
- Keys are merged into the `litellm-secrets` Kubernetes Secret on every
  `deploy-app`; the salt key in that Secret must not be rotated once models
  exist (see `docs/troubleshooting.md`).
- `scripts/remote-deploy.sh` copies `app.env` into the bastion bundle with mode
  0600 and never commits it.

A different `LITELLM_DEPLOY_HOME` per checkout keeps two deployments (and their
AK/SK) apart.
