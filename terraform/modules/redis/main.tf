locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/redis"
    },
    var.tags,
  )

  is_prepaid = var.charging_mode == "prePaid"

  # Only query the flavor catalogue when the caller did not pin a flavor code.
  lookup_flavor = var.flavor == ""
}

data "huaweicloud_dcs_flavors" "ha" {
  count = local.lookup_flavor ? 1 : 0

  cache_mode     = "ha"
  capacity       = var.capacity
  engine         = "Redis"
  engine_version = var.engine_version
}

resource "huaweicloud_dcs_instance" "this" {
  name               = var.names["dcs"]
  engine             = "Redis"
  engine_version     = var.engine_version
  capacity           = var.capacity
  flavor             = local.lookup_flavor ? try(data.huaweicloud_dcs_flavors.ha[0].flavors[0].name, null) : var.flavor
  availability_zones = var.availability_zones
  password           = var.password
  vpc_id             = var.vpc_id
  subnet_id          = var.subnet_id
  security_group_id  = var.security_group_id
  ssl_enable         = var.ssl_enable

  charging_mode = var.charging_mode
  period_unit   = local.is_prepaid ? var.period_unit : null
  period        = local.is_prepaid ? var.period : null
  auto_renew    = local.is_prepaid ? "true" : null

  enterprise_project_id = var.enterprise_project_id
  tags                  = local.tags

  lifecycle {
    precondition {
      condition     = !local.lookup_flavor || try(length(data.huaweicloud_dcs_flavors.ha[0].flavors) > 0, false)
      error_message = "No DCS flavor matched capacity/engine_version in this region. Set `dcs_flavor` explicitly (flavor codes are region specific)."
    }
  }
}
