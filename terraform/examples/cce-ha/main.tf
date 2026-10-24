locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # The international site does not support enterprise projects.
  eps_id = var.site_type == "international" ? "0" : var.enterprise_project_id

  common_tags = merge(
    {
      "project"     = var.project_name
      "environment" = var.environment
      "managed-by"  = "terraform"
      "component"   = "litellm-gateway"
    },
    var.tags,
  )
}

data "huaweicloud_availability_zones" "this" {}

locals {
  # Empty az_list means: use the first (up to) three zones of the region. The
  # data layer only needs two, the CCE control plane prefers three.
  az_count = min(3, length(data.huaweicloud_availability_zones.this.names))
  azs      = length(var.az_list) > 0 ? var.az_list : slice(data.huaweicloud_availability_zones.this.names, 0, local.az_count)
}

# -----------------------------------------------------------------------------
# Secrets: generated here, stored in CSMS, never committed or passed via -var.
# -----------------------------------------------------------------------------

resource "random_password" "database" {
  length  = 24
  special = false
}

resource "random_password" "redis" {
  length  = 24
  special = false
}

resource "random_password" "node" {
  length  = 16
  special = false
}

resource "random_password" "master_key" {
  length  = 48
  special = false
}

resource "random_password" "salt_key" {
  length  = 48
  special = false

  lifecycle {
    # LITELLM_SALT_KEY encrypts provider credentials stored in the database.
    # Replacing it makes every stored credential unreadable, so Terraform must
    # never regenerate it implicitly.
    prevent_destroy = true
  }
}

locals {
  master_key = "sk-${random_password.master_key.result}"
  salt_key   = "sk-${random_password.salt_key.result}"
}

resource "huaweicloud_kms_key" "this" {
  count = var.encryption_enabled ? 1 : 0

  key_alias         = "${local.name_prefix}-litellm"
  key_description   = "Encryption key for the LiteLLM gateway data stores and node disks"
  rotation_enabled  = true
  rotation_interval = 90

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  name_prefix           = local.name_prefix
  vpc_cidr              = var.vpc_cidr
  availability_zones    = local.azs
  app_subnet_cidr       = var.app_subnet_cidr
  data_subnet_cidr      = var.data_subnet_cidr
  vpce_subnet_cidr      = var.vpce_subnet_cidr
  eni_subnet_cidrs      = var.eni_subnet_cidrs
  elb_ingress_cidrs     = var.elb_ingress_cidrs
  ssh_ingress_cidrs     = var.ssh_ingress_cidrs
  enable_nat_gateway    = var.enable_nat_gateway
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "postgres" {
  source = "../../modules/postgres"

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.data_subnet_id
  security_group_id     = module.network.data_security_group_id
  availability_zones    = slice(local.azs, 0, 2)
  flavor                = var.rds_flavor
  engine_version        = var.rds_pg_version
  volume_size           = var.rds_volume_size
  backup_keep_days      = var.rds_backup_keep_days
  password              = random_password.database.result
  kms_key_id            = var.encryption_enabled ? huaweicloud_kms_key.this[0].id : null
  charging_mode         = var.charging_mode
  period                = var.period
  period_unit           = var.period_unit
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "redis" {
  source = "../../modules/redis"

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.data_subnet_id
  security_group_id     = module.network.data_security_group_id
  availability_zones    = slice(local.azs, 0, 2)
  engine_version        = var.dcs_redis_version
  capacity              = var.dcs_capacity
  flavor                = var.dcs_flavor
  password              = random_password.redis.result
  ssl_enable            = var.dcs_ssl_enable
  charging_mode         = var.charging_mode
  period                = var.period
  period_unit           = var.period_unit
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "cce" {
  source = "../../modules/cce"

  name_prefix            = local.name_prefix
  vpc_id                 = module.network.vpc_id
  subnet_id              = module.network.app_subnet_id
  eni_subnet_ids         = module.network.eni_subnet_ids
  container_network_type = var.cce_container_network_type
  cluster_flavor         = var.cce_cluster_flavor
  cluster_version        = var.cce_cluster_version
  availability_zones     = local.azs
  node_flavor            = var.cce_node_flavor
  node_count_per_az      = var.cce_node_count_per_az
  node_password          = random_password.node.result
  root_volume_size       = var.cce_node_root_volume_size
  data_volume_size       = var.cce_node_data_volume_size
  kms_key_id             = var.encryption_enabled ? huaweicloud_kms_key.this[0].id : null
  enterprise_project_id  = local.eps_id
  tags                   = local.common_tags
}

module "elb" {
  source = "../../modules/elb"

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.app_subnet_id
  availability_zones    = slice(local.azs, 0, 2)
  l7_flavor_id          = var.elb_l7_flavor_id
  eip_bandwidth_size    = var.elb_eip_bandwidth_size
  eip_charge_mode       = var.elb_eip_charge_mode
  certificate_id        = var.certificate_id
  enable_https          = var.enable_https
  charging_mode         = var.charging_mode
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  name_prefix           = local.name_prefix
  enable_lts            = var.enable_lts_logs
  log_retention_days    = var.lts_log_ttl_days
  enable_smn            = var.alarm_email != ""
  alarm_email           = var.alarm_email
  alarms                = local.alarms
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "vpn" {
  source = "../../modules/vpn"
  count  = var.vpn_enabled ? 1 : 0

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  connect_subnet_id     = module.network.app_subnet_id
  local_subnets         = [var.vpc_cidr]
  customer_gateway_ip   = var.customer_gateway_ip
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "vpcep" {
  source = "../../modules/vpcep"
  count  = var.vpce_enabled ? 1 : 0

  name_prefix = local.name_prefix
  service_id  = var.modelarts_vpce_service_id
  vpc_id      = module.network.vpc_id
  subnet_id   = module.network.vpce_subnet_id
  tags        = local.common_tags
}

resource "huaweicloud_elb_log" "this" {
  count = var.enable_lts_logs ? 1 : 0

  loadbalancer_id = module.elb.loadbalancer_id
  log_group_id    = module.observability.log_group_id
  log_topic_id    = module.observability.log_stream_id
}

# -----------------------------------------------------------------------------
# Alarms (opt-in)
# -----------------------------------------------------------------------------

locals {
  alarms = var.enable_alarms ? [
    {
      name                = "${local.name_prefix}-elb-unhealthy-backends"
      namespace           = "SYS.ELB"
      metric_name         = "m9_abnormal_servers"
      dimension_name      = "lbaas_instance_id"
      dimension_value     = module.elb.loadbalancer_id
      comparison_operator = ">"
      value               = 0
      count               = 3
      period              = 300
      filter              = "average"
      level               = 2
      description         = "The LiteLLM gateway load balancer reports unhealthy backend servers."
    },
  ] : []
}

# -----------------------------------------------------------------------------
# Secret Manager (CSMS) - single source of truth for the application secrets
# -----------------------------------------------------------------------------

resource "huaweicloud_csms_secret" "master_key" {
  name        = "${local.name_prefix}-litellm-master-key"
  description = "LiteLLM proxy master key (Admin UI + admin API)"
  secret_text = local.master_key
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "salt_key" {
  name        = "${local.name_prefix}-litellm-salt-key"
  description = "LiteLLM salt key (encrypts provider credentials at rest). Never rotate after models exist."
  secret_text = local.salt_key
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "database" {
  name        = "${local.name_prefix}-litellm-db-password"
  description = "Password of the LiteLLM PostgreSQL administrator"
  secret_text = random_password.database.result
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "redis" {
  name        = "${local.name_prefix}-litellm-redis-password"
  description = "Password of the LiteLLM Redis instance"
  secret_text = random_password.redis.result
  tags        = local.common_tags
}
