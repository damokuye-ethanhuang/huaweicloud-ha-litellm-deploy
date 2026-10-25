locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/maas-network"
    },
    var.tags,
  )

  # Four role-separated /24s plus a small VPCE /26, carved in a fixed order so
  # that a mistyped CIDR fails the plan instead of silently overlapping:
  #   access     internal ELB VIP
  #   app        CCE workers
  #   data       RDS, DCS (no other subnet may reach 5432/6379)
  #   ops        the in-VPC bastion; may reach every service in the VPC
  #   vpce       ModelArts private endpoints (optional, /26)
  subnet_slots = cidrsubnets(
    var.vpc_cidr,
    3, 3, 3, 3, 5
  )

  # Rendered in the precondition message below; kept as a local because HCL
  # cannot nest a quoted join(", ", ...) inside a format() call.
  expected_subnets = join(", ", slice(local.subnet_slots, 0, 4))

  subnets = {
    access = { cidr = var.access_subnet_cidr, name = var.names["subnet_access"] }
    app    = { cidr = var.app_subnet_cidr, name = var.names["subnet_app"] }
    data   = { cidr = var.data_subnet_cidr, name = var.names["subnet_data"] }
    ops    = { cidr = var.ops_subnet_cidr, name = var.names["subnet_ops"] }
  }

  sg_rule_specs = merge(
    # --- internal ELB: clients and admins in, backends out ---
    {
      for i, cidr in var.client_cidrs : "elb-client-${i}" => {
        sg_key    = "elb"
        direction = "ingress"
        protocol  = "tcp"
        from      = 443
        to        = 443
        cidr      = cidr
        note      = "Gateway API from ${cidr}"
      }
    },
    {
      for i, cidr in var.admin_cidrs : "elb-admin-${i}" => {
        sg_key    = "elb"
        direction = "ingress"
        protocol  = "tcp"
        from      = 443
        to        = 443
        cidr      = cidr
        note      = "Admin UI from ${cidr}"
      }
    },
    # The ops subnet exists so an operator can debug every layer from one place:
    # it reaches the ELB, PostgreSQL, Redis and the CCE API, and nothing else is
    # opened for it.
    {
      "elb-ops" = {
        sg_key    = "elb"
        direction = "ingress"
        protocol  = "tcp"
        from      = 443
        to        = 443
        cidr      = var.ops_subnet_cidr
        note      = "Gateway calls from the ops subnet (bastion smoke tests)"
      }
    },
    {
      "elb-egress" = {
        sg_key    = "elb"
        direction = "egress"
        protocol  = null
        from      = null
        to        = null
        cidr      = var.app_subnet_cidr
        note      = "Health checks and backend traffic to the app subnet"
      }
    },

    # --- data subnet: PostgreSQL and Redis only from the app subnet ---
    {
      "data-postgres" = {
        sg_key    = "data"
        direction = "ingress"
        protocol  = "tcp"
        from      = 5432
        to        = 5432
        cidr      = var.app_subnet_cidr
        note      = "PostgreSQL from the app subnet only"
      }
      "data-redis" = {
        sg_key    = "data"
        direction = "ingress"
        protocol  = "tcp"
        from      = 6379
        to        = 6379
        cidr      = var.app_subnet_cidr
        note      = "Redis from the app subnet only"
      }
      # Overlay container network (tunnel mode): pods get IPs from the
      # container CIDR but those IPs are NOT routable from the VPC - the node
      # SNATs pod traffic to its own address, so the app-subnet rules above
      # already cover the gateway. Only vpc-router and ENI (CCE Turbo) give
      # pods VPC-visible addresses and need an explicit rule.
      # Without this distinction the plan carries rules that can never match,
      # which hides the real question during a connectivity incident.
    },
    (var.pod_cidr_ingress_enabled ? {
      "data-postgres-pods" = {
        sg_key    = "data"
        direction = "ingress"
        protocol  = "tcp"
        from      = 5432
        to        = 5432
        cidr      = var.pod_cidr
        note      = "PostgreSQL from pod IPs (vpc-router / ENI modes only)"
      }
      "data-redis-pods" = {
        sg_key    = "data"
        direction = "ingress"
        protocol  = "tcp"
        from      = 6379
        to        = 6379
        cidr      = var.pod_cidr
        note      = "Redis from pod IPs (vpc-router / ENI modes only)"
      }
    } : {}),
    {
      "data-egress" = {
        sg_key    = "data"
        direction = "egress"
        protocol  = null
        from      = null
        to        = null
        cidr      = "0.0.0.0/0"
        note      = "Backups and monitoring"
      }
      # Debugging only: the bastion may reach the data layer, pods may not.
      "data-ops-postgres" = {
        sg_key    = "data"
        direction = "ingress"
        protocol  = "tcp"
        from      = 5432
        to        = 5432
        cidr      = var.ops_subnet_cidr
        note      = "psql from the ops subnet"
      }
      "data-ops-redis" = {
        sg_key    = "data"
        direction = "ingress"
        protocol  = "tcp"
        from      = 6379
        to        = 6379
        cidr      = var.ops_subnet_cidr
        note      = "redis-cli from the ops subnet"
      }
    },

    # --- bastion: SSH in from the operator ranges, out to the VPC ---
    {
      for i, cidr in var.bastion_ssh_cidrs : "bastion-ssh-${i}" => {
        sg_key    = "bastion"
        direction = "ingress"
        protocol  = "tcp"
        from      = 22
        to        = 22
        cidr      = cidr
        note      = "Operator SSH from ${cidr}"
      }
    },
    {
      "bastion-egress-vpc" = {
        sg_key    = "bastion"
        direction = "egress"
        protocol  = null
        from      = null
        to        = null
        cidr      = var.vpc_cidr
        note      = "kubectl/helm to the CCE API and the internal ELB"
      }
      "bastion-egress-dns" = {
        sg_key    = "bastion"
        direction = "egress"
        protocol  = "udp"
        from      = 53
        to        = 53
        # The VPC resolvers live in 100.125.0.0/16, outside the VPC CIDR, so
        # without this every name lookup fails and apt/kubectl/helm installs die
        # with "Temporary failure resolving".
        cidr = "0.0.0.0/0"
        note = "DNS to the VPC resolvers"
      }
      "bastion-egress-https" = {
        sg_key    = "bastion"
        direction = "egress"
        protocol  = "tcp"
        # 80 as well: apt fetches over plain HTTP on the stock Ubuntu sources, and
        # the bootstrap script runs with `set -e`, so a blocked 80 aborts it and
        # kubectl/helm never get installed.
        from = 80
        to   = 443
        cidr = "0.0.0.0/0"
        note = "apt (80) plus package and chart downloads (443)"
      }
    },
  )

  # Specs that differ only in key still render the *same* rule, and the API
  # rejects the duplicate with "conflict in the request" instead of ignoring it.
  # That happens as soon as client_cidrs, admin_cidrs and the ops subnet overlap
  # - i.e. the normal lab setup where all three are 10.0.3.0/24 - so collapse on
  # the rule's identity: security group, direction, protocol, port range, CIDR.
  sg_ids = {
    elb     = huaweicloud_networking_secgroup.elb.id
    data    = huaweicloud_networking_secgroup.data.id
    bastion = huaweicloud_networking_secgroup.bastion.id
  }

  # The grouping (... => spec...) form does not error on repeated keys; it
  # collects them into a list, which is exactly the dedupe that is needed.
  sg_rule_groups = {
    for k, spec in local.sg_rule_specs :
    join("|", [
      spec.sg_key,
      spec.direction,
      coalesce(spec.protocol, "any"),
      # tostring(null) returns null rather than raising, so try() would not
      # catch it - coalesce is what skips nulls here.
      coalesce(tostring(spec.from), "any"),
      coalesce(tostring(spec.to), "any"),
      spec.cidr,
    ]) => spec...
  }

  sg_rules = {
    for k, group in local.sg_rule_groups :
    replace(replace(k, "/", "_"), ".", "_") => {
      sg        = local.sg_ids[group[0].sg_key]
      direction = group[0].direction
      protocol  = group[0].protocol
      from      = group[0].from
      to        = group[0].to
      cidr      = group[0].cidr
      note      = group[0].note
    }
  }
}

resource "huaweicloud_vpc" "this" {
  name                  = var.names["vpc"]
  cidr                  = var.vpc_cidr
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

# ELB v3's `vip_subnet_cidr_id` (exposed by the provider as `ipv4_subnet_id`)
# wants the NEUTRON subnet id, not the VPC subnet id that this resource has as
# its `id`. Passing the wrong one fails at apply with the misleading
# "subnet <id> could not be found" (ELB.8904). The data source resolves the
# mapping; it is exported as app_subnet_neutron_id.
data "huaweicloud_vpc_subnet" "app" {
  id = huaweicloud_vpc_subnet.this["app"].id
}

data "huaweicloud_vpc_subnet" "access" {
  id = huaweicloud_vpc_subnet.this["access"].id
}

resource "huaweicloud_vpc_subnet" "this" {
  for_each = local.subnets

  name              = each.value.name
  cidr              = each.value.cidr
  gateway_ip        = cidrhost(each.value.cidr, 1)
  vpc_id            = huaweicloud_vpc.this.id
  availability_zone = var.availability_zone
  tags              = local.tags

  lifecycle {
    precondition {
      condition = contains(local.subnet_slots, each.value.cidr)
      error_message = format(
        "Subnet %s (%s) does not match the layout carved from %s. Expected one of: %s.",
        each.key,
        each.value.cidr,
        var.vpc_cidr,
        local.expected_subnets
      )
    }
  }
}

# ModelArts private access needs its own small subnet: endpoint ENIs and pods
# must not compete for addresses, and the subnet can be skipped entirely in a
# test environment.
resource "huaweicloud_vpc_subnet" "vpce" {
  count = var.create_vpce_subnet ? 1 : 0

  name              = var.names["subnet_vpce"]
  cidr              = var.vpce_subnet_cidr
  gateway_ip        = cidrhost(var.vpce_subnet_cidr, 1)
  vpc_id            = huaweicloud_vpc.this.id
  availability_zone = var.availability_zone
  tags              = local.tags
}

resource "huaweicloud_networking_secgroup" "elb" {
  name                  = var.names["sg_elb"]
  description           = "Internal load balancer: 443 from allow-listed networks only"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_networking_secgroup" "data" {
  name                  = var.names["sg_data"]
  description           = "Data subnet: PostgreSQL and Redis reachable from the app subnet only"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_networking_secgroup" "bastion" {
  name                  = var.names["sg_bastion"]
  description           = "Ops subnet: SSH in from allow-listed ranges, outbound to the whole VPC"
  delete_default_rules  = true
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_networking_secgroup_rule" "this" {
  for_each = local.sg_rules

  security_group_id = each.value.sg
  direction         = each.value.direction
  ethertype         = "IPv4"
  protocol          = each.value.protocol
  port_range_min    = each.value.from
  port_range_max    = each.value.to
  remote_ip_prefix  = each.value.cidr
  description       = each.value.note
}

resource "huaweicloud_vpc_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name        = var.names["eip"]
    size        = var.nat_eip_bandwidth_size
    share_type  = "PER"
    charge_mode = var.nat_eip_charge_mode
  }

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  name                  = var.names["nat"]
  spec                  = var.nat_spec
  vpc_id                = huaweicloud_vpc.this.id
  subnet_id             = huaweicloud_vpc_subnet.this["app"].id
  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags
}

resource "huaweicloud_nat_snat_rule" "this" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id = huaweicloud_nat_gateway.this[0].id
  floating_ip_id = huaweicloud_vpc_eip.nat[0].id
  cidr           = var.vpc_cidr
  description    = "SNAT for ${var.vpc_cidr}"
}
