locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/elb"
    },
    var.tags,
  )

  upload_certificate = var.certificate_pem != "" && var.private_key_pem != ""
}

# Elastic L7 flavor: the load balancer scales with traffic and is billed per
# LCU, which is what the Huawei Cloud solution recommends for this workload.
data "huaweicloud_elb_flavors" "l7_elastic" {
  count = var.l7_flavor_id == "" ? 1 : 0

  type = "L7_elastic_max"
}

locals {
  l7_flavor_id = var.l7_flavor_id != "" ? var.l7_flavor_id : try(data.huaweicloud_elb_flavors.l7_elastic[0].ids[0], null)

  certificate_id = var.certificate_id != "" ? var.certificate_id : try(huaweicloud_elb_certificate.this[0].id, "")
}

resource "huaweicloud_elb_certificate" "this" {
  count = local.upload_certificate ? 1 : 0

  name        = var.names["cert"]
  certificate = var.certificate_pem
  private_key = var.private_key_pem
  description = "TLS certificate for the LiteLLM gateway"
}

resource "huaweicloud_vpc_eip" "this" {
  count = var.internal ? 0 : 1

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name        = var.names["eip"]
    size        = var.eip_bandwidth_size
    share_type  = "PER"
    charge_mode = var.eip_charge_mode
  }

  tags = local.tags
}

resource "huaweicloud_elb_loadbalancer" "this" {
  name                       = var.names["elb"]
  vpc_id                     = var.vpc_id
  ipv4_subnet_id             = var.subnet_id
  ipv4_address               = var.vip_address == "" ? null : var.vip_address
  availability_zone          = var.availability_zones
  l7_flavor_id               = local.l7_flavor_id
  ipv4_eip_id                = var.internal ? null : huaweicloud_vpc_eip.this[0].id
  charging_mode              = var.charging_mode
  deletion_protection_enable = var.deletion_protection
  enterprise_project_id      = var.enterprise_project_id
  tags                       = local.tags

  lifecycle {
    precondition {
      condition     = local.l7_flavor_id != null
      error_message = "Could not find an elastic L7 flavor in this region. Set elb_l7_flavor_id explicitly."
    }

    precondition {
      condition     = !var.enable_https || local.certificate_id != ""
      error_message = "enable_https requires certificate_id (an ELB certificate). Upload the certificate in SCM/ELB first, or set enable_https = false for a lab deployment."
    }
  }
}
