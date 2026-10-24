locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/cce"
    },
    var.tags,
  )

  is_turbo = var.container_network_type == "eni"

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
    for_each = length(var.availability_zones) >= 3 ? var.availability_zones : []
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
    condition     = length(var.availability_zones) >= 3
    error_message = "Fewer than three availability zones: the CCE control plane will be created with a single master and is not highly available. Pass az_list with three zones if the region offers them."
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
  }

  data_volumes {
    size       = var.data_volume_size
    volumetype = var.data_volume_type
    kms_key_id = var.kms_key_id
  }

  tags = merge(local.tags, { az = var.availability_zones[count.index % length(var.availability_zones)] })

  timeouts {
    create = "60m"
    delete = "30m"
  }
}
