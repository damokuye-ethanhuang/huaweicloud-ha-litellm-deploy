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

## Four ways to hand over AK/SK

Pick one. All four end up as `HW_ACCESS_KEY` / `HW_SECRET_KEY` in the process
that runs Terraform, and none of them involve pasting a key into a chat.

**1. `creds.sh set` - the default.** In a terminal you own, on the machine that
runs the deployment:

```bash
./scripts/creds.sh set          # AK, SK typed with no echo; project id optional
```

It writes `~/.litellm-deploy/secrets/hw.env` at 0600 and echoes only a masked
AK. `set` refuses to run when stdin is not a terminal, so an agent cannot type a
secret into it on your behalf - by design.

**2. Environment variables.** `export HW_ACCESS_KEY=... HW_SECRET_KEY=...` in the
shell that starts the deployment, or - when the agent runs as a service - in its
own environment (for Hermes: add them to `~/.hermes/.env` and restart, the
terminal inherits them). Environment variables take precedence over `hw.env`, so
a CI runner can inject credentials without writing anything to disk.

**3. Import an existing export** (non-interactive):

```bash
export HW_ACCESS_KEY=... HW_SECRET_KEY=...
./scripts/creds.sh set --from-env
```

**4. `~/.huaweicloud/credentials`.** If `hcloud` or the SDK is already
configured on this machine, the Terraform provider reads that profile and no
`HW_*` variable is needed at all.

### Checking without exposing anything

```bash
./scripts/creds.sh status    # source=environment|file, AK masked, "configured"
./scripts/creds.sh check     # exit 1 while a live credential is reachable
./scripts/creds.sh clear     # after the test, then handoff.py scrub && check
```

`status` never prints the SK. `check` fails on a live credential whether it came
from the file or from the environment, which is what makes the post-test cleanup
verifiable.
