locals {
  azs = var.availability_zones

  common_tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/network"
    },
    var.tags,
  )

  subnets = merge(
    {
      app = {
        cidr = var.app_subnet_cidr
        gw   = var.app_gateway_ip
        az   = local.azs[0]
      }
      data = {
        cidr = var.data_subnet_cidr
        gw   = var.data_gateway_ip
        az   = local.azs[1]
      }
      vpce = {
        cidr = var.vpce_subnet_cidr
        gw   = var.vpce_gateway_ip
        az   = local.azs[0]
      }
    },
    {
      for index, cidr in var.eni_subnet_cidrs : "eni-${index}" => {
        cidr = cidr
        gw   = cidrhost(cidr, 1)
        az   = local.azs[index % length(local.azs)]
      }
    },
  )

  # Flat map of security group rules, keyed by a stable name so adding a rule
  # never re-creates unrelated ones.
  security_group_rules = merge(
    {
      for index, cidr in var.elb_ingress_cidrs : "elb-https-${index}" => {
        security_group_id = huaweicloud_networking_secgroup.elb.id
        direction         = "ingress"
        protocol          = "tcp"
        port_min          = 443
        port_max          = 443
        remote_ip_prefix  = cidr
        description       = "HTTPS from ${cidr}"
      }
    },
    {
      for index, cidr in var.elb_ingress_cidrs : "elb-http-${index}" => {
        security_group_id = huaweicloud_networking_secgroup.elb.id
        direction         = "ingress"
        protocol          = "tcp"
        port_min          = 80
        port_max          = 80
        remote_ip_prefix  = cidr
        description       = "HTTP from ${cidr} (redirects to HTTPS)"
      }
    },
    {
      "elb-egress" = {
        security_group_id = huaweicloud_networking_secgroup.elb.id
        direction         = "egress"
        protocol          = null
        port_min          = null
        port_max          = null
        remote_ip_prefix  = "0.0.0.0/0"
        description       = "Health checks and backend traffic"
      }
    },
    {
      "data-postgres" = {
        security_group_id = huaweicloud_networking_secgroup.data.id
        direction         = "ingress"
        protocol          = "tcp"
        port_min          = 5432
        port_max          = 5432
        remote_ip_prefix  = var.vpc_cidr
        description       = "PostgreSQL from the VPC (LiteLLM pods and nodes)"
      }
      "data-redis" = {
        security_group_id = huaweicloud_networking_secgroup.data.id
        direction         = "ingress"
        protocol          = "tcp"
        port_min          = 6379
        port_max          = 6379
        remote_ip_prefix  = var.vpc_cidr
        description       = "Redis from the VPC (LiteLLM pods and nodes)"
      }
      "data-egress" = {
        security_group_id = huaweicloud_networking_secgroup.data.id
        direction         = "egress"
        protocol          = null
        port_min          = null
        port_max          = null
        remote_ip_prefix  = "0.0.0.0/0"
        description       = "Backup and monitoring endpoints"
      }
    },
    var.ssh_ingress_cidrs == [] ? {} : {
      for index, cidr in var.ssh_ingress_cidrs : "data-ssh-${index}" => {
        security_group_id = huaweicloud_networking_secgroup.data.id
        direction         = "ingress"
        protocol          = "tcp"
        port_min          = 22
        port_max          = 22
        remote_ip_prefix  = cidr
        description       = "SSH from ${cidr}"
      }
    },
  )
}

resource "huaweicloud_vpc" "this" {
  name                  = "${var.name_prefix}-vpc"
  cidr                  = var.vpc_cidr
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_vpc_subnet" "this" {
  for_each = local.subnets

  name              = "${var.name_prefix}-${each.key}"
  cidr              = each.value.cidr
  gateway_ip        = each.value.gw
  vpc_id            = huaweicloud_vpc.this.id
  availability_zone = each.value.az
  tags              = local.common_tags
}

resource "huaweicloud_networking_secgroup" "elb" {
  name                  = "${var.name_prefix}-sg-elb"
  description           = "Ingress to the LiteLLM gateway load balancer"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_networking_secgroup" "data" {
  name                  = "${var.name_prefix}-sg-data"
  description           = "RDS PostgreSQL and DCS Redis access from the VPC"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_networking_secgroup_rule" "this" {
  for_each = local.security_group_rules

  security_group_id = each.value.security_group_id
  direction         = each.value.direction
  ethertype         = "IPv4"
  protocol          = each.value.protocol
  port_range_min    = each.value.port_min
  port_range_max    = each.value.port_max
  remote_ip_prefix  = each.value.remote_ip_prefix
  description       = each.value.description
}

resource "huaweicloud_vpc_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name        = "${var.name_prefix}-nat-eip"
    size        = var.nat_eip_bandwidth_size
    share_type  = "PER"
    charge_mode = var.nat_eip_charge_mode
  }

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                  = "${var.name_prefix}-nat"
  spec                  = var.nat_spec
  vpc_id                = huaweicloud_vpc.this.id
  subnet_id             = huaweicloud_vpc_subnet.this["app"].id
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.common_tags
}

resource "huaweicloud_nat_snat_rule" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id = huaweicloud_nat_gateway.this[0].id
  floating_ip_id = huaweicloud_vpc_eip.nat[0].id
  cidr           = var.vpc_cidr
  description    = "SNAT for ${var.vpc_cidr}"
}
