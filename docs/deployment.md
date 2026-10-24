# Deployment

## 0. SDK（用于解析 CCE 版本）

CCE 会下线旧版本，且部分区域要求精确补丁号（如 `v1.31.1-r0`）。部署时用官方 SDK
查询本区域当前支持的版本，而不是写死一个会过期的值：

```bash
python3 -m venv .venv-sdk
.venv-sdk/bin/pip install huaweicloudsdkcce
.venv-sdk/bin/python scripts/resolve-cce-version.py --dry-run
```

鉴权走 SDK 自带的凭据链（`HW_ACCESS_KEY`/`HW_SECRET_KEY` 或
`~/.huaweicloud/credentials`），仓库里不写任何签名逻辑。

## 1. Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.6 | Infrastructure |
| Helm | >= 3.14 | Chart |
| kubectl | >= 1.28 | Cluster access |
| jq, curl | any recent | Scripts |
| Docker | optional | Mirroring the image into SWR |

Quotas to confirm before the first apply: 3 worker ECS, 1 CCE cluster, 1 RDS
instance, 1 DCS instance, 1 ELB, 3 EIPs (gateway, NAT, optional VPN ×2), 6
subnets and 4 security groups in the target region.

## 2. Credentials and IAM

Create a **dedicated IAM user** for this deployment. Do not reuse an existing
production account or its AK/SK.

```bash
export HW_ACCESS_KEY=...
export HW_SECRET_KEY=...
```

The provider also reads `~/.huaweicloud/credentials`, but environment variables
are easier to scope per shell and keep out of files.

A starter policy (scope it down before production) needs the services used by
the modules:

```
vpc:*, nat:*, elb:*, ecs:*, evs:*, ims:*, cce:*, rds:*, dcs:*,
kms:*, csms:*, lts:*, smn:*, ces:*, vpn:*, vpcep:*, iam:identityProviders:get
```

The deployer also needs permission to read its own IAM user and to create
resources in the target enterprise project.

> The China site supports enterprise projects; the international site does not.
> `site_type = "international"` forces `enterprise_project_id = "0"`.

## 3. Region and flavor verification

Flavor codes are region specific. `cn-north-4` is verified in this repository;
any other region must be re-checked:

- `docs/huaweicloud-regions.md` lists region codes, endpoint patterns and the
  AZ irregularity that breaks hardcoded `a/b/c` assumptions;
- `terraform/examples/cce-ha/terraform.tfvars.example` names every code you may
  need to change.

AZs are discovered with `data.huaweicloud_availability_zones` when `az_list` is
empty, so an unusual suffix such as `cn-southwest-2a/2d/2e` is not a problem.

## 4. Remote state (recommended)

The state contains generated passwords and the cluster kubeconfig.

```bash
cp terraform/examples/cce-ha/backend.tf.example terraform/examples/cce-ha/backend.tf
# edit bucket/key/region, enable server-side encryption on the bucket
terraform -chdir=terraform/examples/cce-ha init -migrate-state
```

Restrict the bucket to the deployment role and a small operator group.

## 5. TLS certificate

TLS terminates at the ELB, so the certificate must exist before the app is
deployed.

1. Upload or import the certificate in SCM.
2. Push it to ELB (or import it directly under ELB → Certificates).
3. Copy the **ELB certificate ID** into `certificate_id`.
4. Keep `enable_https = true`.

The ID is referenced by the CCE Service annotation
`kubernetes.io/elb.cert-id`. Setting `enable_https = false` is allowed for the
lab only and produces a warning.

## 6. Deploy infrastructure

```bash
cp terraform/examples/cce-ha/terraform.tfvars.example terraform/examples/cce-ha/terraform.tfvars
$EDITOR terraform/examples/cce-ha/terraform.tfvars

make plan     # review the full plan
make apply    # 20-40 minutes, CCE dominates
```

Expected outputs: `gateway_url`, `elb_public_ip`, `loadbalancer_id`,
`certificate_id`, `cluster_id`, `kube_config_raw`, `database`, `redis`,
`app_env`, `secret_names`, `lts_log_group_id`.

`terraform output` prints secrets in clear text; treat your terminal scrollback
as sensitive.

## 7. Deploy the application

```bash
# optional provider keys, merged into the Kubernetes Secret
cat > secrets/app.env <<'EOF'
OPENAI_API_KEY=sk-...
MODELARTS_API_BASE=https://<endpoint>/v1
MODELARTS_API_KEY=...
EOF

make app-deploy
```

What the script does, in order:

1. writes `kube_config_raw` to `~/.kube/litellm-cce.yaml` (0600);
2. creates the namespace and the `litellm-secrets` Secret from Terraform
   outputs plus `secrets/app.env`;
3. builds a values file with the ELB annotations (id, class, protocol-port,
   certificate);
4. runs `helm upgrade --install --wait`, which executes the migration Job as a
   pre-install hook **before** the Deployment rolls out;
5. runs the smoke test.

If the migration job fails, the release stops and the previous pods keep
serving. Fix the cause and rerun; see `docs/troubleshooting.md`.

## 8. Verify

```bash
make smoke
MODEL=maas-chat make smoke       # also sends one chat completion

kubectl -n litellm get pods
kubectl -n litellm logs job/litellm-migrate-1 --tail=50
```

Manual checks:

```bash
curl -s https://<eip>/health/liveliness
curl -s https://<eip>/health/readiness
curl -s https://<eip>/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

The Admin UI is at `https://<eip>/ui`; log in with the master key.

## 9. China-region image mirroring

If the cluster cannot reach `ghcr.io`:

```bash
SWR_REGION=cn-north-4 SWR_ORG=my-org ./scripts/mirror-image.sh 1.106.3
```

Then set in `terraform.tfvars`:

```hcl
litellm_image_repository = "swr.cn-north-4.myhuaweicloud.com/my-org/litellm"
```

and rerun `make app-deploy`. SWR login uses `{region}@{AK}` as the username;
the script handles it.

## 10. Teardown

```bash
CONFIRM=yes make destroy
kubectl delete namespace litellm    # after the cluster is gone this is optional
```

Destroying the stack deletes the database. Take a manual backup first if the
data matters.

## Deployment checklist

- [ ] dedicated IAM user, least-privilege policy, MFA on the console account
- [ ] remote state on an encrypted, private OBS bucket
- [ ] `elb_ingress_cidrs` restricted to known egress ranges
- [ ] TLS certificate configured, `enable_https = true`
- [ ] flavor codes re-verified for the target region
- [ ] image mirrored to SWR (China regions)
- [ ] `secrets/app.env` created and gitignored
- [ ] `make smoke` passes, including one real chat completion
- [ ] backup retention and alarm subscription confirmed
