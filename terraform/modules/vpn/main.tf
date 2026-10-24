locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/vpn"
    },
    var.tags,
  )

  create_customer_gateway = var.customer_gateway_ip != "0.0.0.0"
}

data "huaweicloud_vpn_gateway_availability_zones" "this" {
  flavor          = var.flavor
  attachment_type = "vpc"
}

resource "huaweicloud_vpn_gateway" "this" {
  name               = var.names["vpn"]
  vpc_id             = var.vpc_id
  connect_subnet     = var.connect_subnet_id
  local_subnets      = var.local_subnets
  availability_zones = slice(data.huaweicloud_vpn_gateway_availability_zones.this.names, 0, 2)
  flavor             = var.flavor

  eip1 {
    bandwidth_name = "${var.names["eip"]}-1"
    type           = "5_bgp"
    bandwidth_size = var.eip_bandwidth_size
    charge_mode    = "traffic"
  }

  eip2 {
    bandwidth_name = "${var.names["eip"]}-2"
    type           = "5_bgp"
    bandwidth_size = var.eip_bandwidth_size
    charge_mode    = "traffic"
  }

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_vpn_customer_gateway" "this" {
  count = local.create_customer_gateway ? 1 : 0

  name = "${var.names["vpn"]}-cgw"
  ip   = var.customer_gateway_ip

  tags = local.tags
}
