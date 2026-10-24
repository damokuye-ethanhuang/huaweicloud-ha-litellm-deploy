module "naming" {
  source = "../../modules/naming"

  project_name = var.project_name
}

locals {
  names = module.naming.all

  # The international site does not support enterprise projects.
  eps_id = var.site_type == "international" ? "0" : var.enterprise_project_id

  common_tags = merge(
    {
      "project"     = var.project_name
      "environment" = var.environment
      "managed-by"  = "terraform"
      "component"   = "litellm-gateway"
      "exposure"    = "internal"
    },
    var.tags,
  )

  # Encryption: three branches (kms / dew / disabled) resolved once here so the
  # data modules never need to know which one the operator picked.
  kms_key_id = (
    var.encryption_mode == "kms" ? try(huaweicloud_kms_key.this[0].id, null) :
    var.encryption_mode == "dew" ? var.kms_key_id :
    null
  )
  encryption_enabled = var.encryption_mode != "disabled"
}

data "huaweicloud_availability_zones" "this" {}

locals {
  # Empty az_list means: use the first (up to) three zones of the region. The
  # data layer only needs two, the CCE control plane prefers three.
  az_count = min(3, length(data.huaweicloud_availability_zones.this.names))
  azs      = length(var.az_list) > 0 ? var.az_list : slice(data.huaweicloud_availability_zones.this.names, 0, local.az_count)
}

# -----------------------------------------------------------------------------
# Naming guard: every generated name must be a valid, short-enough identifier.
# -----------------------------------------------------------------------------

check "naming" {
  assert {
    condition     = module.naming.valid
    error_message = "A resource name generated from project_name \"${var.project_name}\" is invalid or too long (longest is ${module.naming.longest} chars)."
  }
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

resource "random_password" "bastion" {
  count = var.bastion_enabled ? 1 : 0

  length  = 20
  special = false
}

resource "random_password" "grafana_admin" {
  count = var.metric_backend == "aom" ? 1 : 0

  length  = 20
  special = false
}

locals {
  master_key = "sk-${random_password.master_key.result}"
  salt_key   = "sk-${random_password.salt_key.result}"
}

# Created only when the operator chose the "kms" branch. The "dew" branch reuses
# a key owned by the security team and the "disabled" branch creates nothing.
resource "huaweicloud_kms_key" "this" {
  count = var.encryption_mode == "kms" ? 1 : 0

  key_alias         = local.names["kms"]
  key_description   = "Encryption key for the LiteLLM gateway data stores and node disks"
  rotation_enabled  = true
  rotation_interval = 90

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------

module "network" {
  source = "../../modules/maas-network"

  names                  = local.names
  vpc_cidr               = var.vpc_cidr
  access_subnet_cidr     = var.access_subnet_cidr
  app_subnet_cidr        = var.app_subnet_cidr
  data_subnet_cidr       = var.data_subnet_cidr
  vpce_subnet_cidr       = var.vpce_subnet_cidr
  create_vpce_subnet     = var.vpce_enabled
  availability_zone      = local.azs[0]
  client_cidrs           = var.allowed_client_cidrs
  admin_cidrs            = var.admin_access_cidrs
  bastion_ssh_cidrs      = var.bastion_enabled ? var.bastion_ssh_cidrs : []
  enable_nat_gateway     = var.enable_nat_gateway
  nat_eip_bandwidth_size = var.nat_eip_bandwidth_size
  enterprise_project_id  = local.eps_id
  tags                   = local.common_tags
}

module "postgres" {
  source = "../../modules/postgres"

  names                 = local.names
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.data_subnet_id
  security_group_id     = module.network.data_security_group_id
  availability_zones    = slice(local.azs, 0, 2)
  flavor                = var.rds_flavor
  engine_version        = var.rds_pg_version
  volume_size           = var.rds_volume_size
  backup_keep_days      = var.rds_backup_keep_days
  password              = random_password.database.result
  kms_key_id            = local.kms_key_id
  charging_mode         = var.charging_mode
  period                = var.period
  period_unit           = var.period_unit
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "redis" {
  source = "../../modules/redis"

  names                 = local.names
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

  names                  = local.names
  vpc_id                 = module.network.vpc_id
  subnet_id              = module.network.app_subnet_id
  container_network_cidr = var.pod_cidr
  container_network_type = var.cce_container_network_type
  cluster_flavor         = var.cce_cluster_flavor
  cluster_version        = var.cce_cluster_version
  availability_zones     = local.azs
  node_flavor            = var.cce_node_flavor
  node_count_per_az      = var.cce_node_count_per_az
  node_password          = random_password.node.result
  root_volume_size       = var.cce_node_root_volume_size
  data_volume_size       = var.cce_node_data_volume_size
  kms_key_id             = local.kms_key_id
  charging_mode          = var.charging_mode
  period                 = var.period
  period_unit            = var.period_unit
  enterprise_project_id  = local.eps_id
  tags                   = local.common_tags
}

module "bastion" {
  source = "../../modules/bastion"
  count  = var.bastion_enabled ? 1 : 0

  names                 = local.names
  vpc_id                = module.network.vpc_id
  subnet_id             = module.network.access_subnet_id
  security_group_id     = module.network.bastion_security_group_id
  availability_zone     = local.azs[0]
  flavor_id             = var.bastion_flavor
  admin_password        = random_password.bastion[0].result
  eip_bandwidth_size    = var.bastion_eip_bandwidth_size
  eip_charge_mode       = var.bastion_eip_charge_mode
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "elb" {
  source = "../../modules/elb"

  names              = local.names
  vpc_id             = module.network.vpc_id
  subnet_id          = module.network.app_subnet_id
  availability_zones = slice(local.azs, 0, 2)
  l7_flavor_id       = var.elb_l7_flavor_id
  # Internal by design: this reference architecture must not expose the gateway
  # to the internet.
  internal              = true
  certificate_id        = var.certificate_id
  enable_https          = var.enable_https
  charging_mode         = var.charging_mode
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "observability" {
  source = "../../modules/observability"

  names                 = local.names
  enable_lts            = var.enable_lts_logs
  log_retention_days    = var.lts_log_ttl_days
  enable_smn            = var.alarm_email != ""
  alarm_email           = var.alarm_email
  alarms                = local.alarms
  stream_names          = { elb = local.names["lts_elb"], app = local.names["lts_app"] }
  enterprise_project_id = local.eps_id
  tags                  = local.common_tags
}

module "vpn" {
  source = "../../modules/vpn"
  count  = var.vpn_enabled ? 1 : 0

  names                 = local.names
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

  names      = local.names
  service_id = var.modelarts_vpce_service_id
  vpc_id     = module.network.vpc_id
  subnet_id  = module.network.vpce_subnet_id
  tags       = local.common_tags
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
      name                = "${local.names["smn"]}-elb-unhealthy"
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
  name        = local.names["secret_master_key"]
  description = "LiteLLM proxy master key (Admin UI + admin API)"
  secret_text = local.master_key
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "salt_key" {
  name        = local.names["secret_salt_key"]
  description = "LiteLLM salt key (encrypts provider credentials at rest). Never rotate after models exist."
  secret_text = local.salt_key
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "database" {
  name        = local.names["secret_db"]
  description = "Password of the LiteLLM PostgreSQL administrator"
  secret_text = random_password.database.result
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "redis" {
  name        = local.names["secret_redis"]
  description = "Password of the LiteLLM Redis instance"
  secret_text = random_password.redis.result
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "bastion" {
  count = var.bastion_enabled ? 1 : 0

  name        = local.names["secret_bastion"]
  description = "Admin password of the operator bastion"
  secret_text = random_password.bastion[0].result
  tags        = local.common_tags
}

resource "huaweicloud_csms_secret" "grafana" {
  count = var.metric_backend == "aom" ? 1 : 0

  name        = local.names["secret_grafana"]
  description = "Admin password for the on-premises Grafana (dashboards are kept there, not in the cloud)"
  secret_text = random_password.grafana_admin[0].result
  tags        = local.common_tags
}

# -----------------------------------------------------------------------------
# AOM: the managed metrics backend that the on-premises Grafana queries.
# -----------------------------------------------------------------------------

resource "huaweicloud_aom_prom_instance" "this" {
  count = var.metric_backend == "aom" ? 1 : 0

  prom_name             = local.names["aom"]
  prom_type             = "CCE"
  enterprise_project_id = local.eps_id

  prom_limits {
    compactor_blocks_retention_period = var.aom_retention
  }
}

# -----------------------------------------------------------------------------
# Input consistency
# -----------------------------------------------------------------------------

check "tls_has_certificate" {
  assert {
    condition     = var.tls_mode == "none" || var.certificate_id != ""
    error_message = "tls_mode = ${var.tls_mode} requires certificate_id (upload the certificate to SCM/ELB first)."
  }
}

check "dew_has_key" {
  assert {
    condition     = var.encryption_mode != "dew" || try(var.kms_key_id != null, false)
    error_message = "encryption_mode = dew requires kms_key_id (the existing DEW/KMS key)."
  }
}

check "vpcep_has_service" {
  assert {
    condition     = !var.vpce_enabled || var.modelarts_vpce_service_id != ""
    error_message = "vpce_enabled = true requires modelarts_vpce_service_id."
  }
}
