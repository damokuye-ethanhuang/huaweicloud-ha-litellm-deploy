# Permissions

What the deployment needs, who needs it, and why. Derived from the resources
this repository actually creates — the tables below were built by enumerating
every `resource`/`data` block under `terraform/`, so nothing here is speculative.

Huawei Cloud grants access through **IAM roles** (coarse, per service) or
**policies** (fine-grained). Roles are enough to deploy; policies are for teams
that must minimise blast radius. Both are covered.

## Three principals, three different permission sets

Do not hand one identity all three. The whole point of the split is that the
long-lived runtime has no cloud API rights at all.

| Principal | Where it runs | Needs | Must not have |
|---|---|---|---|
| **Deployment operator** | your own machine (or CI) | create/delete the infrastructure below | `kubectl` cluster-admin in CI, runtime secrets |
| **Bastion operator** | the in-VPC bastion | `kubectl` + `helm` on the cluster, SSH | any cloud API write permission |
| **Runtime (pods)** | CCE worker nodes | nothing from IAM | an agency (`委托`) — see below |

The gateway authenticates to PostgreSQL and Redis with passwords from a
Kubernetes Secret. It never calls a cloud API, so no agency is attached to the
nodes and a compromised pod cannot pivot into your cloud account.

## Deployment operator: roles per service

Grant the role to a **user group**, then put the operator's IAM user in it.
Every role below is a built-in Huawei Cloud system role.

| Role | Covers (resource types this repo creates) | Needed at |
|---|---|---|
| `VPC Administrator` | `huaweicloud_vpc`, `huaweicloud_vpc_subnet`, `huaweicloud_networking_secgroup`, `huaweicloud_networking_secgroup_rule`, `huaweicloud_vpc_eip`, `huaweicloud_compute_eip_associate`, `huaweicloud_vpcep_endpoint` | plan (data sources), apply |
| `NAT Administrator` | `huaweicloud_nat_gateway`, `huaweicloud_nat_snat_rule` | apply |
| `CCE Administrator` | `huaweicloud_cce_cluster`, `huaweicloud_cce_node` | apply |
| `ECS Administrator` | `huaweicloud_compute_instance` (bastion), `huaweicloud_availability_zones`, `huaweicloud_images_image` | plan, apply |
| `ELB Administrator` | `huaweicloud_elb_loadbalancer`, `huaweicloud_elb_certificate`, `huaweicloud_elb_log`, `huaweicloud_elb_flavors` | plan, apply |
| `RDS Administrator` | `huaweicloud_rds_instance`, `huaweicloud_rds_pg_database` | apply |
| `DCS Administrator` | `huaweicloud_dcs_instance`, `huaweicloud_dcs_flavors` | plan, apply |
| `KMS Administrator` | `huaweicloud_kms_key`, `huaweicloud_csms_secret` | apply |
| `LTS Administrator` | `huaweicloud_lts_group`, `huaweicloud_lts_stream` | apply |
| `AOM Administrator` | `huaweicloud_aom_prom_instance` | apply |
| `CES Administrator` | `huaweicloud_ces_alarmrule` | apply |
| `SMN Administrator` | `huaweicloud_smn_topic`, `huaweicloud_smn_subscription` | apply |
| `VPN Administrator` | `huaweicloud_vpn_gateway`, `huaweicloud_vpn_customer_gateway` | only if `vpn_enabled=true` |
| `SWR Administrator` | image mirroring (`scripts/mirror-image.sh`) | only if you mirror the image |
| `Tenant Administrator` | creates the CCE agency | only on first cluster creation |

Read-only roles are enough for `preflight` and `plan`. `apply` needs the write
roles. If your process reviews plans under a different identity, that identity
only needs the `* ReadOnlyAccess` equivalents plus the two data sources above.

### The one non-obvious requirement: the CCE agency

Creating a CCE cluster makes CCE act on your behalf (attach EVS volumes, join
nodes, bind ELB). Huawei Cloud represents this with an **agency** (委托). On the
first cluster in a project, the platform needs to create it, which requires
`iam:agencies:create` — held by `Tenant Administrator`, not by
`CCE Administrator`.

Two ways to handle it:

1. Grant `Tenant Administrator` to the deployment identity **for the first
   apply only**, then remove it. Simplest, and what most teams do.
2. An administrator creates the agency up front and the deployment identity
   gets only `CCE Administrator`. Ask for an agency named
   `cce_admin_trust` scoped to CCE.

If `apply` fails with an agency or `iam:agencies` error while creating the
cluster, this is why — it is not a bug in the Terraform.

### Policy names: `*FullPolicy` vs the older role wording

Huawei Cloud renamed its system permissions. The current IAM policies are named
`<Service>FullPolicy` / `<Service>ReadOnlyPolicy` — the official CCE Terraform
best practice calls out `CCEFullPolicy` and `CCEReadOnlyPolicy` for the operator
group, and `IAMFullPolicy` for the identity that creates users and grants.
Gateways and consoles still show the older role wording (`CCE Administrator`,
`VPC Administrator`, `Tenant Administrator`) for the same grants, so both names
in this document refer to the same thing: pick whichever your console lists, and
do not assume a name that is not shown there.

To get the exact display names in your account, open **IAM → Permissions →
Policies**, filter by service, and copy the name into `docs/permissions.md` for
your own deployment.

### Worker disk encryption needs the agency to hold KMS

`encrypt_node_volumes = true` makes CCE encrypt EVS volumes with the project
key. CCE performs that call **as the cluster agency**, not as your AK/SK, so the
agency must be able to use the key. Without that, node creation fails with:

```
CCE_CM.0004 Request is invalid
Invalid cmkid, err: ... check-cmk-permission-via-agency ...
{"message":"get Agency's token failed.","code":"EVS.2264"}
```

The key is valid in that case — the agency is the problem. Either grant
`cce_admin_trust` KMS access, or leave `encrypt_node_volumes = false` (default)
and rely on the platform's default EVS encryption.

## Minimal custom policy instead of broad roles

For teams that cannot grant service-wide administrator roles, one policy
covering exactly the actions this repository uses:

```json
{
  "Version": "1.1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "vpc:vpcs:*", "vpc:subnets:*", "vpc:securityGroups:*",
        "vpc:publicIps:*", "vpc:bandwidths:*", "vpc:ports:*",
        "vpc:vpcs:list", "vpc:subnets:list", "vpc:securityGroups:list",
        "vpcep:endpoints:*",
        "nat:natGateways:*", "nat:snatRules:*",
        "cce:cluster:*", "cce:node:*",
        "ecs:cloudServers:*", "ecs:flavors:get", "ecs:serverKeypairs:*",
        "ims:images:list",
        "elb:loadbalancers:*", "elb:certificates:*", "elb:logtanks:*",
        "elb:flavors:get",
        "rds:instance:*", "rds:database:*", "rds:flavors:list",
        "dcs:instance:*", "dcs:flavors:list",
        "kms:cmk:*", "kms:dek:*", "csms:secret:*",
        "lts:groups:*", "lts:streams:*",
        "aom:*:get*", "aom:*:list*", "aom:prometheus:*",
        "ces:alarms:*",
        "smn:topic:*",
        "iam:agencies:create", "iam:agencies:list",
        "iam:permissions:grantRoleToAgency"
      ]
    }
  ]
}
```

Trim `vpn:*` and `swr:*` if you do not use those paths. Keep the write actions
off the runtime identity and off the bastion identity.

## What the bastion operator needs

Nothing from IAM. The bastion gets:

- the kubeconfig written by `deploy.sh deploy-app` (0600, in the operator's
  home directory), or its own kubeconfig issued by CCE;
- `kubectl` and `helm` installed;
- network reachability to the cluster API (`6443`), which the ops subnet
  security group already allows.

Do **not** create a kubeconfig for the bastion with cluster-admin and leave it
there after the deployment. Issue one, use it, revoke it — CCE lets you bind a
kubeconfig to an IAM user, which is preferable to a shared cluster-admin file.

## Auditors and read-only access

Grant the read-only counterpart of each role above (`VPC ReadOnlyAccess`,
`CCE ReadOnlyAccess`, `RDS ReadOnlyAccess`, and so on) to the audit group. Every
check in `scripts/preflight.py` and everything `verify` inspects is read-only,
so an auditor can reproduce the post-deploy verification without any write
permission.

## Checking an identity before you deploy

`preflight` reports whether credentials are present but does not enumerate every
API permission — that would need a call per service. To confirm an identity can
do the work, ask it to read the services the deployment touches:

```bash
./scripts/check-permissions.sh          # read-only probe, prints a matrix
```

Anything reporting `403` there will fail at `apply`, not at `plan`, so run it
before the first apply rather than during it.
