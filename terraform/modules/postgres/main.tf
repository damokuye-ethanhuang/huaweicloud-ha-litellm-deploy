locals {
  tags = merge(
    {
      "managed-by" = "terraform"
      "module"     = "huaweicloud-litellm-gateway/postgres"
    },
    var.tags,
  )

  is_prepaid = var.charging_mode == "prePaid"
}

resource "huaweicloud_rds_instance" "this" {
  name                  = "${var.name_prefix}-pg"
  flavor                = var.flavor
  ha_replication_mode   = var.ha_replication_mode
  vpc_id                = var.vpc_id
  subnet_id             = var.subnet_id
  security_group_id     = var.security_group_id
  availability_zone     = var.availability_zones
  enterprise_project_id = var.enterprise_project_id

  db {
    type     = "PostgreSQL"
    version  = var.engine_version
    password = var.password
  }

  volume {
    type               = var.volume_type
    size               = var.volume_size
    disk_encryption_id = var.kms_key_id
  }

  backup_strategy {
    start_time = var.backup_start_time
    keep_days  = var.backup_keep_days
  }

  charging_mode = var.charging_mode
  period_unit   = local.is_prepaid ? var.period_unit : null
  period        = local.is_prepaid ? var.period : null
  auto_renew    = local.is_prepaid ? "true" : null

  tags = local.tags
}

resource "huaweicloud_rds_pg_database" "litellm" {
  instance_id   = huaweicloud_rds_instance.this.id
  name          = var.database_name
  character_set = "UTF8"
}
