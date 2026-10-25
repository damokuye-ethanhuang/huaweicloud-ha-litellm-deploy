locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/cce"
    },
    var.tags,
  )

  is_turbo = var.container_network_type == "eni"

  # cce.s2.* is the HA control plane (three masters). cce.s1.* is a single
  # master, and passing a masters block to it is rejected, so the block is
  # driven by the flavor and not by the AZ list alone.
  is_ha_cluster = startswith(var.cluster_flavor, "cce.s2")

  # One node pool per AZ keeps the worker nodes spread across zones even when
  # the node pool itself is later scaled.
  node_pools = { for index, az in var.availability_zones : "az${index}" => az }
}

resource "huaweicloud_cce_cluster" "this" {
  name                   = var.names["cce"]
  flavor_id              = var.cluster_flavor
  cluster_version        = var.cluster_version == "" ? null : var.cluster_version
  cluster_type           = "VirtualMachine"
  vpc_id                 = var.vpc_id
  subnet_id              = var.subnet_id
  container_network_type = var.container_network_type
  container_network_cidr = local.is_turbo ? null : var.container_network_cidr
  eni_subnet_id          = local.is_turbo ? join(",", var.eni_subnet_ids) : null
  authentication_mode    = "rbac"
  enterprise_project_id  = var.enterprise_project_id
  charging_mode          = var.charging_mode
  period                 = var.charging_mode == "prePaid" ? var.period : null
  period_unit            = var.charging_mode == "prePaid" ? var.period_unit : null

  dynamic "masters" {
    for_each = local.is_ha_cluster && length(var.availability_zones) >= 3 ? var.availability_zones : []
    content {
      availability_zone = masters.value
    }
  }

  tags = local.tags

  timeouts {
    create = "60m"
    delete = "60m"
  }

  lifecycle {
    precondition {
      condition     = !local.is_turbo || length(var.eni_subnet_ids) >= 2
      error_message = "CCE Turbo (container_network_type = \"eni\") requires at least two ENI subnet IDs."
    }
  }
}

check "control_plane_ha" {
  assert {
    condition     = !local.is_ha_cluster || length(var.availability_zones) >= 3
    error_message = "cce.s2.* is the three-master control plane but fewer than three availability zones were given: the cluster will be created with a degraded control plane. Pass three AZs or use cce.s1.* deliberately."
  }
}

# Workers are individual namespaced nodes, not pools: the count is explicit,
# each node lands in a chosen AZ by round-robin, and scaling is a Terraform
# change rather than a pool resize. This also keeps the node lifecycle visible
# in the plan (one resource per node).
resource "huaweicloud_cce_node" "workers" {
  count = var.node_count_per_az * length(var.availability_zones)

  cluster_id        = huaweicloud_cce_cluster.this.id
  name              = "${var.names["cce_pool"]}-${count.index + 1}"
  flavor_id         = var.node_flavor
  availability_zone = var.availability_zones[count.index % length(var.availability_zones)]
  password          = var.node_password
  os                = var.node_os == "" ? null : var.node_os
  subnet_id         = var.subnet_id

  charging_mode = var.charging_mode
  period_unit   = var.charging_mode == "prePaid" ? var.period_unit : null
  period        = var.charging_mode == "prePaid" ? var.period : null
  auto_renew    = var.charging_mode == "prePaid" ? "true" : null

  root_volume {
    size       = var.root_volume_size
    volumetype = var.root_volume_type
    kms_key_id = var.kms_key_id
    # GPSSD2 (and GPSSD2-like types) are rejected unless both are supplied;
    # the API error is "GPSSD2 volume type both iops and throughput are required".
    iops       = var.volume_iops
    throughput = var.volume_throughput
  }

  data_volumes {
    size       = var.data_volume_size
    volumetype = var.data_volume_type
    kms_key_id = var.kms_key_id
    iops       = var.volume_iops
    throughput = var.volume_throughput
  }

  tags = merge(local.tags, { az = var.availability_zones[count.index % length(var.availability_zones)] })

  timeouts {
    create = "60m"
    delete = "30m"
  }
}

# The control-plane security group is created by CCE with its own defaults. Add
# exactly one rule: an operator on the ops subnet must be able to run
# kubectl/helm against the private API endpoint, and nothing wider.
resource "huaweicloud_networking_secgroup_rule" "ops_kube_api" {
  count = var.ops_cidr == "" ? 0 : 1

  security_group_id = huaweicloud_cce_cluster.this.security_group_id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = var.ops_cidr
  description       = "kubectl and helm from the ops subnet"
}
