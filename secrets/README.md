# Local provider keys

Create `app.env` here (the whole directory is gitignored except this README) with
one `KEY=VALUE` per line. Keys are referenced by `api_key_env` in
`deploy-inputs.yaml`; the app deployment merges this file into the
`litellm-secrets` Kubernetes Secret on every run.

```bash
# secrets/app.env — never commit this file
GLM_API_KEY=sk-...
DEEPSEEK_API_KEY=            # empty: the endpoint does not authenticate
```

Rules:

- One variable per model entry, named exactly as its `api_key_env`.
- Leave the value empty rather than inventing a placeholder — LiteLLM sends an
  empty key, which is correct for unauthenticated internal endpoints.
- This file is the only place a provider key may live. Do not put keys in
  `deploy-inputs.yaml`, Helm values, or a command line.
- `scripts/remote-deploy.sh` copies this file into the bastion bundle with mode
  0600 and never commits it.
