# Troubleshooting

## Terraform

### `Error: Unsupported argument`

The provider schema moved. Every module in this repository is validated against
`huaweicloud/huaweicloud` 1.99.1; if you bump the provider, run
`terraform validate` before planning.

### CCE creation times out

CCE takes 20-40 minutes. The module allows 60 minutes. If it still times out,
check the CCE console for the cluster event log; the usual causes are an
exhausted EIP/ELB quota or an unsupported Kubernetes version in the region.

### `flavor ... not found`

Flavor codes are region specific. Verify with the console or a
`data.huaweicloud_rds_flavors` / `huaweicloud_dcs_flavors` lookup, then update
`terraform.tfvars`. The defaults are verified for `cn-north-4` only.

### ELB plan fails with "Could not find an elastic L7 flavor"

The region has no `L7_elastic_max` flavor available. Set `elb_l7_flavor_id`
explicitly to a fixed L7 flavor ID from the ELB console.

### `enable_https requires certificate_id`

Upload the certificate to SCM/ELB and put its ID in `certificate_id`, or set
`enable_https = false` for a lab.

## Application deployment

### Service stays `Pending`, no external IP

The CCE ELB integration did not accept the annotations. Check:

```bash
kubectl -n litellm describe svc litellm
kubectl -n litellm get events --sort-by=.lastTimestamp | tail -20
```

Compare the annotation block in `scripts/deploy-app.sh` with your CCE version's
documentation. The four that matter are `kubernetes.io/elb.id`,
`kubernetes.io/elb.class`, `kubernetes.io/elb.protocol-port` and
`kubernetes.io/elb.cert-id`.

### ELB returns 502 / 504

1. `kubectl -n litellm get pods` — are all three Ready?
2. `kubectl -n litellm port-forward svc/litellm 4000:443` and curl
   `/health/readiness` locally. If that works, the problem is between ELB and
   the nodes (security group or node port), not in LiteLLM.
3. Check the ELB backend health in the console: if all backends are unhealthy,
   the health check path or port is wrong.

### `ImagePullBackOff`

China regions often cannot reach `ghcr.io`. Mirror the image:

```bash
SWR_REGION=cn-north-4 SWR_ORG=my-org ./scripts/mirror-image.sh 1.106.3
```

and set `litellm_image_repository` to the SWR path. Also check that the CCE
node pool can resolve and reach the registry (NAT gateway present).

### Migration job fails

```bash
kubectl -n litellm get jobs
kubectl -n litellm logs job/litellm-migrate-1
```

| Log line | Cause |
|---|---|
| `Can't reach database server` | wrong `DATABASE_URL`, RDS SG, or the database is failing over |
| `password authentication failed` | secret out of sync with RDS |
| `P1001` / timeout | NAT or subnet routing missing |
| index build timeout | large `LiteLLM_SpendLogs`; raise `migration.activeDeadlineSeconds` |

After fixing, rerun:

```bash
./scripts/migrate.sh
```

The release is blocked until the hook succeeds; the old pods keep serving.

### Pods `CrashLoopBackOff` with `OOMKilled`

LiteLLM's Prisma query engine keeps a memory high-water mark. The chart gives
each pod 4 GiB, which is the documented floor. If you enabled
`store_prompts_in_spend_logs`, raise the limit instead of lowering it.

### Readiness 503, `db: disconnected`

- RDS failover in progress: wait for the console to report the new primary.
- Security group changed: 5432 must be open from the pod/node CIDR.
- Connection ceiling reached: `too many clients already` in the pod logs. Lower
  `database_connection_pool_limit` or scale RDS.

### `401` on `/v1/models`

The endpoint requires the master key:

```bash
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" https://<eip>/v1/models
```

If the key was rotated, update the Secret and restart the deployment.

### Redis errors after enabling TLS

`dcs_ssl_enable = true` requires the cache config to use TLS as well. Uncomment
`ssl: true` under `litellm_settings.cache_params` in
`config/litellm-config.yaml`, run `make sync-config`, and redeploy. The router
`redis_host`/`redis_port` block has no separate TLS switch; use the cache block
for TLS and leave the router on the plain endpoint only if DCS allows it.

### Provider credentials stopped working

Someone changed `LITELLM_SALT_KEY`. It encrypts provider credentials in the
database; restoring the previous value is the only fix. If it is lost, re-enter
every provider credential in the Admin UI.

## Observability

### No logs in LTS

- `terraform output lts_log_group_id` must be non-null.
- The ELB log association requires the load balancer to exist first; if the
  apply created the association before the ELB was ready, re-apply.
- Check the LTS stream name: `<prefix>-elb-access`.

### Alarms never fire

Alarms are opt-in and the SMN subscription must be confirmed by email. Verify
the metric name and dimension in the CES console for your region first — a wrong
metric produces a resource that exists but never triggers.

## Getting help

Open an issue with: `terraform version`, provider version, region, the failing
resource, and the relevant log excerpt (redact keys).
