locals {
  name_prefix = "${var.project_name}-${var.environment}"

  tags = merge(
    {
      "project"     = var.project_name
      "environment" = var.environment
      "managed-by"  = "terraform"
      "component"   = "litellm-gateway"
      "tier"        = "single-node-lab"
    },
    var.tags,
  )
}

data "huaweicloud_availability_zones" "this" {}

data "huaweicloud_images_image" "ubuntu" {
  count = var.image_id == "" ? 1 : 0

  name        = var.image_name
  visibility  = "public"
  most_recent = true
}

resource "random_password" "database" {
  length  = 24
  special = false
}

resource "random_password" "redis" {
  length  = 24
  special = false
}

resource "random_password" "master_key" {
  length  = 48
  special = false
}

resource "random_password" "salt_key" {
  length  = 48
  special = false
}

locals {
  availability_zone = var.availability_zone != "" ? var.availability_zone : data.huaweicloud_availability_zones.this.names[0]
  image_id          = var.image_id != "" ? var.image_id : data.huaweicloud_images_image.ubuntu[0].id
  image             = "${var.litellm_image_repository}:${var.litellm_version}"

  master_key = "sk-${random_password.master_key.result}"
  salt_key   = "sk-${random_password.salt_key.result}"

  env_file = <<-EOT
LITELLM_IMAGE=${local.image}
PG_PASSWORD=${random_password.database.result}
DATABASE_URL=postgresql://litellm:${random_password.database.result}@litellm-pg:5432/litellm?schema=public
LITELLM_MASTER_KEY=${local.master_key}
LITELLM_SALT_KEY=${local.salt_key}
REDIS_HOST=litellm-redis
REDIS_PORT=6379
REDIS_PASSWORD=${random_password.redis.result}
REDIS_SSL=false
STORE_MODEL_IN_DB=True
DISABLE_SCHEMA_UPDATE=false
GLM_API_KEY=${var.glm_api_key}
DEEPSEEK_API_KEY=${var.deepseek_api_key}
EOT

  # The single-VM tier renders its own config: the static settings plus the two
  # preset models, as ONE YAML document (LiteLLM reads only the first document,
  # verified against 1.106.3).
  config = <<-YAML
model_list:
  - model_name: glm-5.3
    litellm_params:
      model: openai/glm-5.3
      api_key: os.environ/GLM_API_KEY
      api_base: ${var.model_base_url}
      timeout: 1500
      stream_timeout: 1500
      max_parallel_requests: 400
    model_info:
      mode: chat
  - model_name: deepseek-v4.1-flash
    litellm_params:
      model: openai/deepseek-v4.1-flash
      api_key: os.environ/DEEPSEEK_API_KEY
      api_base: ${var.model_base_url}
      timeout: 1500
      stream_timeout: 1500
      max_parallel_requests: 400
    model_info:
      mode: chat

router_settings:
  routing_strategy: simple-shuffle
  num_retries: 2
  timeout: 1500
  stream_timeout: 1500
  allowed_fails: 2
  cooldown_time: 60
  fallbacks:
    "glm-5.3":
      - "deepseek-v4.1-flash"

litellm_settings:
  drop_params: true

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true
  proxy_batch_write_at: 60
  database_connection_pool_limit: 10
  global_max_parallel_requests: 400
  trusted_proxy_ranges:
    - 10.0.0.0/8
YAML

  start_script = file("${path.module}/templates/start.sh")

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tpl", {
    env_b64    = base64encode(local.env_file)
    config_b64 = base64encode(local.config)
    start_b64  = base64encode(local.start_script)
  })
}

resource "huaweicloud_vpc" "this" {
  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  tags = local.tags
}

resource "huaweicloud_vpc_subnet" "this" {
  name              = "${local.name_prefix}-app"
  cidr              = var.subnet_cidr
  gateway_ip        = cidrhost(var.subnet_cidr, 1)
  vpc_id            = huaweicloud_vpc.this.id
  availability_zone = local.availability_zone

  tags = local.tags
}

resource "huaweicloud_networking_secgroup" "this" {
  name                 = "${local.name_prefix}-sg"
  description          = "LiteLLM single-node lab"
  delete_default_rules = true

  tags = local.tags
}

resource "huaweicloud_networking_secgroup_rule" "gateway" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = huaweicloud_networking_secgroup.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 4000
  port_range_max    = 4000
  remote_ip_prefix  = each.value
  description       = "LiteLLM API from ${each.value}"
}

resource "huaweicloud_networking_secgroup_rule" "ssh" {
  for_each = toset(var.ssh_ingress_cidrs)

  security_group_id = huaweicloud_networking_secgroup.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  description       = "SSH from ${each.value}"
}

resource "huaweicloud_networking_secgroup_rule" "egress" {
  security_group_id = huaweicloud_networking_secgroup.this.id
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
  description       = "Image pulls and LLM provider calls"
}

resource "huaweicloud_vpc_eip" "this" {
  publicip {
    type = "5_bgp"
  }

  bandwidth {
    name        = "${local.name_prefix}-eip"
    size        = var.eip_bandwidth_size
    share_type  = "PER"
    charge_mode = "traffic"
  }

  tags = local.tags
}

resource "huaweicloud_compute_instance" "this" {
  name               = "${local.name_prefix}-gw"
  image_id           = local.image_id
  flavor_id          = var.flavor_id
  availability_zone  = local.availability_zone
  security_group_ids = [huaweicloud_networking_secgroup.this.id]
  key_pair           = var.key_pair == "" ? null : var.key_pair
  user_data          = local.user_data

  system_disk_type = "SSD"
  system_disk_size = var.system_disk_size

  network {
    uuid = huaweicloud_vpc_subnet.this.id
  }

  tags = local.tags
}

resource "huaweicloud_compute_eip_associate" "this" {
  public_ip   = huaweicloud_vpc_eip.this.address
  instance_id = huaweicloud_compute_instance.this.id
}
