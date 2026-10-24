# Huawei Cloud regions, endpoints and availability zones

Reference data used by this repository. Region and AZ codes are **not**
interchangeable: flavor codes, AZ suffixes and available services differ per
site. Always re-check with the API before changing `region`.

## Endpoint rule

```
https://{service}.{region}.myhuaweicloud.com
```

| Service | Endpoint |
|---|---|
| IAM (global) | `iam.myhuaweicloud.com` |
| VPC | `vpc.{region}.myhuaweicloud.com` |
| ECS | `ecs.{region}.myhuaweicloud.com` |
| EVS | `evs.{region}.myhuaweicloud.com` |
| IMS | `ims.{region}.myhuaweicloud.com` |
| RDS | `rds.{region}.myhuaweicloud.com` |
| DCS | `dcs.{region}.myhuaweicloud.com` |
| CCE | `cce.{region}.myhuaweicloud.com` |
| ELB | `elb.{region}.myhuaweicloud.com` |
| NAT | `nat.{region}.myhuaweicloud.com` |
| KMS | `kms.{region}.myhuaweicloud.com` |
| CSMS | `csms.{region}.myhuaweicloud.com` |
| LTS | `lts.{region}.myhuaweicloud.com` |
| SMN | `smn.{region}.myhuaweicloud.com` |
| CES | `ces.{region}.myhuaweicloud.com` |
| VPN | `vpn.{region}.myhuaweicloud.com` |
| VPCEP | `vpcep.{region}.myhuaweicloud.com` |
| OBS | `obs.{region}.myhuaweicloud.com` |
| SWR | `swr.{region}.myhuaweicloud.com` |

The Terraform provider derives endpoints from `region`, so no per-service
endpoint configuration is normally needed.

## China site

| Region | Name |
|---|---|
| `cn-north-1` | 华北-北京一 |
| `cn-north-2` | 华北-北京二 |
| `cn-north-4` | 华北-北京四 |
| `cn-north-9` | 华北-乌兰察布一 |
| `cn-east-2` | 华东-上海二 |
| `cn-east-3` | 华东-上海一 |
| `cn-south-1` | 华南-广州 |
| `cn-southwest-2` | 西南-贵阳一 |

## International site (common regions)

| Region | Name |
|---|---|
| `ap-southeast-1` | 亚太-香港 |
| `ap-southeast-2` | 亚太-曼谷 |
| `ap-southeast-3` | 亚太-新加坡 |
| `ap-southeast-4` | 亚太-雅加达 |
| `eu-west-101` | 欧洲-巴黎 |
| `af-south-1` | 非洲-约翰内斯堡 |
| `me-east-1` | 中东-利雅得 |
| `sa-east-1` | 南美-圣保罗 |

> The China site does support enterprise projects; the international site does
> not. The `cce-ha` example forces `enterprise_project_id = "0"` when
> `site_type = "international"`.

## Availability zone codes are irregular

AZ suffixes are **not** guaranteed to be `a/b/c` or contiguous. Verified
examples (2026-10):

| Region | AZs | Note |
|---|---|---|
| `cn-north-4` | `4a`, `4b`, `4c`, `4g` | skips d/e/f |
| `cn-southwest-2` | `2a`, `2d`, `2e`, `2f` | no b/c |
| `me-east-1` | `1a`, `1b`, `1c` | three zones |
| `ap-southeast-3` | `3a`, `3b`, `3c`, `3e` | skips d |
| `ap-southeast-2` | `2a`, `2b`, `2c` | three zones |

Because of this, the examples never hardcode AZ names:

```hcl
data "huaweicloud_availability_zones" "this" {}

locals {
  az_count = min(3, length(data.huaweicloud_availability_zones.this.names))
  azs      = length(var.az_list) > 0 ? var.az_list : slice(data.huaweicloud_availability_zones.this.names, 0, local.az_count)
}
```

Set `az_list` explicitly only when you need a specific pair of zones (for
example to keep RDS and the ELB in the same two zones).

## Flavor codes are region specific

The defaults in `terraform/examples/cce-ha/variables.tf` were verified in
`cn-north-4`:

| Resource | Code |
|---|---|
| CCE cluster | `cce.s2.small` |
| CCE node | `c7.xlarge.4` |
| RDS PostgreSQL | `rds.pg.n1.xlarge.2.ha` |
| DCS Redis | `redis.ha.xu1.large.r2.2` |
| ELB | elastic L7 (`L7_elastic_max`, selected automatically) |

Changing region means re-validating every one of these codes. The RDS and DCS
modules expose data-source lookups as an alternative, but pinned codes are
preferred for reproducibility.

## Verifying a region quickly

```bash
export HW_ACCESS_KEY=... HW_SECRET_KEY=...
cat > /tmp/az.tf <<'EOF'
terraform {
  required_providers {
    huaweicloud = { source = "huaweicloud/huaweicloud", version = "~> 1.99" }
  }
}
provider "huaweicloud" { region = "cn-north-4" }
data "huaweicloud_availability_zones" "this" {}
output "azs" { value = data.huaweicloud_availability_zones.this.names }
EOF
terraform -chdir=/tmp init -backend=false && terraform -chdir=/tmp apply -auto-approve
```

The same check is available without Terraform:

```bash
curl -s https://ecs.cn-north-4.myhuaweicloud.com/ | head -c 200
```
