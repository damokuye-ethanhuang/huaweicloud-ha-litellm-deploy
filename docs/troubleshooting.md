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

### Bastion has no `kubectl`/`helm` after boot

The bootstrap script installs both via apt and `dl.k8s.io`, and runs with
`set -e`. Two egress rules are therefore mandatory:

- **TCP 80** — the stock Ubuntu sources fetch over plain HTTP.
- **UDP 53** — the VPC resolvers are `100.125.x`, outside the VPC CIDR, so a
  rule limited to the VPC range blocks DNS and every download fails with
  `Temporary failure resolving 'repo.huaweicloud.com'`.

`module.network` now ships both. To repair a running bastion without rebuilding
it: `bash /var/lib/cloud/instance/user-data.txt` on the box (wait for
`cloud-init status` to leave `running` first, or apt will be locked).

### `Permission denied` for `root` on the bastion

This image refuses root password login. `admin_pass` is set at creation and the
password is stored in CSMS, but SSH still answers `Permission denied` — and a
reset password only takes effect after a reboot, which some change-control
processes forbid.

Use a key: set `bastion_public_key` to the contents of your `*.pub`. Terraform
creates the key pair and attaches it to the instance. Rotating this on an
existing bastion needs the instance replaced
(`-replace=module.bastion[0].huaweicloud_compute_instance.bastion`); the EIP
survives, the private IP does not.

### `Unexpected initial node password format`

CCE requires 8–26 characters covering at least **three of** lowercase, uppercase,
digits and special characters, and accepts only a limited special set
(`!@$%^*-_=+?`). A `random_password` with `special = false` produces letters and
digits only — two classes — and is rejected. The example pins
`min_lower/min_upper/min_numeric/min_special = 1` and an `override_special` set
for this reason.

### `panic: checkable object status report for unexpected checkable object var.xxx`

Terraform 1.9.x crashes intermittently when `-target` is used together with
`validation` blocks: the check result is reported for a variable that the
targeted graph excluded, and the reporting code panics. The variable named in
the panic differs run to run (`var.metric_backend`, `var.aom_retention`, ...),
which is the giveaway - it is a race, not a bad value.

Fix: use Terraform **≥ 1.17** (`terraform version`). The root module now
requires it. If you must stay on 1.9, avoid `-target` (run a flat
`terraform apply`) and the crash disappears.

### `Error: Invalid target "module.x.resource_type"`

`-target` needs a full resource address including the resource's own name, e.g.
`module.cce.huaweicloud_cce_node.workers`, not `module.cce.huaweicloud_cce_node`
(that is a type, not an address). `module.postgres` always works because it is a module address.

`module.elb` only works in `elb_mode = standalone`. With the default
`elb_mode = ingress` that module has `count = 0`, and Terraform rejects the
target with "no matching objects" — target `module.cce` instead.

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

`dcs_ssl_enable = true` requires the cache config to use TLS as well: the chart
renders `litellm_settings.cache_params` with TLS when `REDIS_SSL=true`, which the
Secret already carries from the Terraform outputs. If Redis errors persist,
confirm the pod actually received the variable:

```bash
kubectl -n litellm exec deploy/litellm -- printenv REDIS_SSL
```

Set `redis_ssl_enable = false` in `deploy-inputs.yaml` only if DCS is configured
without TLS; mixing the two is the usual cause of `redis: disconnected`.

### Provider credentials stopped working

Someone changed `LITELLM_SALT_KEY`. It encrypts provider credentials in the
database; restoring the previous value is the only fix. If it is lost, re-enter
every provider credential in the Admin UI.

### All replicas down

Every pod is failing readiness, or none exists. Check in this order — each step
rules out one layer:

```bash
kubectl -n litellm get pods -o wide          # are pods even scheduled?
kubectl -n litellm describe pod <pod>        # Events: ImagePull, probes, OOM
kubectl -n litellm logs deploy/litellm --previous --tail=80
```

| What you see | Cause | Fix |
|---|---|---|
| `0/3 nodes available` | nodes full or NotReady | `kubectl get nodes`, check worker status and disk |
| `CreateContainerConfigError` | referenced Secret missing or missing key | recreate the Secret with `deploy-app.sh` |
| `ImagePullBackOff` | image not mirrored / pull secret wrong | see the ImagePullBackOff section above |
| Exits immediately with a Pydantic error | rendered config is invalid for this LiteLLM version | check the migration job logs; re-render via preflight |

LiteLLM refuses to start when the config cannot be parsed, so a config error
looks identical to a crash loop. Always read `--previous` logs before touching
the deployment.

### Requests are slow

Separate provider latency from gateway saturation before changing anything:

```bash
kubectl -n litellm port-forward deploy/litellm 4000:4000 &
curl -s localhost:4000/metrics | grep -E 'remaining_requests|latency_metric_count'
```

- `litellm_remaining_requests_metric` at or near 0 → **saturation**. Requests
  are queued behind `max_parallel_requests`. Add a replica (`kubectl -n litellm
  scale deploy/litellm --replicas=4`) or raise the per-worker cap in
  `deploy-inputs.yaml`.
- Remaining slots healthy but P95 high → **provider**. Check whether the
  fallback rate rose at the same time. Long-context prompts streaming thousands
  of tokens legitimately take minutes; compare against the model's own metrics
  before blaming the gateway.
- Both fine but callers complain → look at `latency` per request in LTS; a
  single pathological prompt can dominate the average without moving P95.

### Fallbacks are firing

A non-zero `litellm_fallback_responses_metric` rate means the primary model is
failing and traffic is being served by the secondary. The gateway is still up —
this alert is about the model backends, not the pods.

```bash
curl -s http://<gateway-vip>/v1/models -H "Authorization: Bearer $MASTER" | jq
kubectl -n litellm logs deploy/litellm --tail=200 | grep -i 'fallback\|cooldown'
```

Look for `cooldown` entries naming the primary: a model that fails
`allowed_fails` times enters cooldown and is skipped for `cooldown_time`. Fix
the provider (quota, key, endpoint reachability from the app subnet), then wait
out the cooldown. Do **not** disable fallbacks to silence the alert.

### Too many database connections

Each pod opens a pool of `database_connection_pool_limit`. Three replicas at
10 each plus the migration job is well under a default `max_connections`, but a
scale-out or an HPA burst can cross it.

```bash
# on RDS: current usage
psql -h <rds> -U litellm -d litellm -c \
  "select count(*), state from pg_stat_activity group by state;"
```

Either lower `database_connection_pool_limit` in `deploy-inputs.yaml` and
redeploy, or raise the RDS parameter group's `max_connections` and restart the
instance. Prefer lowering the pool: the gateway does not need a large pool
because requests are long and few, not short and many.

## Destroying a test stack

`terraform destroy` has two deliberate guards and two platform states that can
stop it halfway. All four are expected, none of them means the state file is
corrupt.

### `random_password.salt_key has lifecycle.prevent_destroy set`

That guard exists so a re-apply can never rotate `LITELLM_SALT_KEY` (it would
make every stored provider credential unreadable). A full teardown has to lift
it on purpose:

```bash
# flip to false, destroy, flip back and commit - never leave it false
terraform -chdir=terraform/examples/cce-ha destroy -refresh=false
```

### `Instance cannot be destroyed` / `DBS.301139 The instance is stopped`

RDS refuses to be deleted while stopped ("Reboot it before deleting it"), and a
reboot of a stopped instance can itself be rejected with
`DBS.200452 Another operation is being performed ... or the DB instance is
faulty`. Start it from the console first, then re-run destroy. Deleting the
database resource inside a stopped instance hangs for ten minutes and then
fails, so do not start destroy until the instance is ACTIVE.

### `CCE.01403001 It's forbidden to delete hosts on current cluster status`

A hibernated cluster refuses node deletion (status `Hibernation`). Wake it in
the console, wait for `Available`, then re-run destroy. Kubernetes API calls
also fail in this state with `dial tcp <api>:5443: i/o timeout`, which looks
like a network fault and is not one.

### Order that avoids most of the pain

1. `kubectl delete ns litellm` (in ingress mode this is what removes the ELB
   and its ENIs, so the VPC is not held by a lingering ENI);
2. destroy CCE, then RDS (must be ACTIVE), then the network layer;
3. confirm no EIP is still allocated - a leftover EIP keeps billing silently.

## Bastion access

### `Permission denied (publickey)` although the key is registered

`ssh(1)` reads `<key>.pub` next to the identity file to decide which key to
offer. If that `.pub` is stale (the private key was regenerated, the `.pub`
was not), ssh offers a key the server never received and every login fails
while the private key itself is perfectly valid.

```bash
ssh-keygen -y -f $LITELLM_DEPLOY_HOME/state/bastion_key > $LITELLM_DEPLOY_HOME/state/bastion_key.pub   # rewrite the .pub
ssh -vv -i $LITELLM_DEPLOY_HOME/state/bastion_key root@<bastion> 2>&1 | grep Offering   # shows which key is offered
```

`./scripts/deploy.sh bastion-key` rewrites both halves for this reason.

### Attaching a keypair to a running bastion does nothing

The ECS keypair association call returns success, but the guest never picks the
key up: keypairs are applied at first boot. After `bastion_public_key` changes,
the instance must be replaced:

```bash
terraform -chdir=terraform/examples/cce-ha apply \
  -replace='module.bastion[0].huaweicloud_compute_instance.bastion'
```

The bootstrap template also writes the same key into
`/root/.ssh/authorized_keys` and creates the `opt` account (passwordless sudo),
so a fresh instance is reachable even if the platform keypair injection does
not reach the guest.

### `permission denied` for both root and the named account

Check the source address before anything else: a laptop whose egress IP differs
per destination (carrier or corporate NAT pools) will connect from an address
that is not in `bastion_ssh_cidrs`, and the failure is a connect timeout, not a
refusal.

```bash
curl -s https://ipinfo.io/ip; curl -s https://ifconfig.me/ip   # may differ
```

## Ingress and the CCE-created ELB

### Ingress has no ADDRESS and events show `ELB.8904`

```
Create ELB(ingress: litellm) error: status_code: 404,
resp_body: {"error_msg":"get network or subnet info by elb_virsubnet_ids failed","error_code":"ELB.8904"}
```

The two subnet fields in `kubernetes.io/elb.autocreate` take **different id
types**, and mixing them up produces exactly this 404:

| Field | Takes | Where it comes from |
|---|---|---|
| `vip_subnet_cidr_id` | Neutron **subnet** id | `module.network.access_subnet_neutron_id` (`ipv4_subnet_id`) |
| `elb_virsubnet_ids` | VPC **network** id (list) | `module.network.access_subnet_id` (`huaweicloud_vpc_subnet.this.id`) |

Verified against the ELB v3 API directly: `vip=<subnet id>` +
`elb_virsubnet_ids=[<network id>]` creates an internal ELB; any other
combination returns 404. Both fields belong to the **access** subnet — the VIP
sits in the ingress subnet, in front of the app subnet.

Also note `kubernetes.io/elb.autocreate` is **immutable**: change it and the
Ingress must be deleted and recreated, otherwise helm's patch is rejected and
the old ELB configuration silently stays.

### VIP answers but every request times out

1. Check the listener port matches the protocol. With `tls_mode = none` the
   listener must be HTTP:80; an HTTP listener on 443 is unreachable from
   anything probing 80 (including `scripts/smoke-test.sh`).
2. Check the ELB pool has members. On an overlay (`overlay_l2`) cluster the
   Service must be **NodePort** — CCE registers `node:nodePort` as pool
   members. A ClusterIP Service leaves the pool empty and the VIP accepts the
   connection then hangs up.

```bash
kubectl -n litellm get ingress litellm -o jsonpath='{.metadata.annotations}'
kubectl -n litellm get svc litellm -o jsonpath='{.spec.type}'
```

### `deploy-app` keeps deploying the previous configuration

The bastion bundle is a cache of rendered values. `scripts/remote-deploy.sh`
re-renders and re-uploads it on every `deploy-app`/`verify` for exactly this
reason: an "exists" check is not a freshness check, and a stale
`values.yaml` silently deploys yesterday's annotations (this cost two
debugging rounds on the ELB subnet id).

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
