# ============================================================
# LiteLLM on Huawei Cloud - highly available (CCE) example
# ============================================================

# --- Site and naming ---------------------------------------------------------

variable "site_type" {
  description = "domestic (China site) or international. The international site does not support enterprise projects, so the value is forced to \"0\" there."
  type        = string
  default     = "domestic"

  validation {
    condition     = contains(["domestic", "international"], var.site_type)
    error_message = "site_type must be domestic or international."
  }
}

variable "region" {
  description = "Huawei Cloud region. Changing region requires re-validating flavor codes and AZ names."
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "Short lowercase project name used as a resource prefix."
  type        = string
  default     = "litellm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name must start with a letter and contain only lowercase letters, digits and hyphens (2-21 chars)."
  }
}

variable "environment" {
  description = "Environment suffix, for example prod or staging."
  type        = string
  default     = "prod"
}

variable "enterprise_project_id" {
  description = "Enterprise project ID. Ignored on the international site."
  type        = string
  default     = "0"
}

# --- Version baseline --------------------------------------------------------

variable "litellm_version" {
  description = "LiteLLM image tag. Pinned on purpose: never deploy :latest or main-stable."
  type        = string
  default     = "1.106.3"
}

variable "litellm_image_repository" {
  description = "Image repository. Mirror it into SWR for China regions (see scripts/mirror-image.sh)."
  type        = string
  default     = "ghcr.io/berriai/litellm"
}

variable "rds_pg_version" {
  description = "PostgreSQL major version for RDS."
  type        = string
  default     = "16"
}

variable "dcs_redis_version" {
  description = "Redis version for DCS."
  type        = string
  default     = "7.0"
}

variable "cce_cluster_version" {
  description = "Kubernetes version. Leave empty to let CCE choose the region default; some regions require a full patch version such as v1.31.1-r0."
  type        = string
  default     = "v1.31"
}

# --- Availability zones ------------------------------------------------------

variable "az_list" {
  description = "Availability zones. Empty means: take the first three zones returned by the API."
  type        = list(string)
  default     = []
}

# --- Network -----------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_subnet_cidr" {
  description = "Subnet for CCE nodes and the ELB VIP."
  type        = string
  default     = "10.0.1.0/24"
}

variable "data_subnet_cidr" {
  description = "Subnet for RDS and DCS."
  type        = string
  default     = "10.0.2.0/24"
}

variable "vpce_subnet_cidr" {
  description = "Subnet for VPC endpoints."
  type        = string
  default     = "10.0.3.0/28"
}

variable "eni_subnet_cidrs" {
  description = "CCE Turbo ENI subnets, one per zone. Used only when cce_container_network_type is eni."
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "elb_ingress_cidrs" {
  description = "CIDRs allowed to call the gateway. Restrict this to your corporate egress ranges in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to reach the data subnet on 22. Empty disables SSH."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so the gateway can reach external LLM APIs."
  type        = bool
  default     = true
}

# --- CCE ---------------------------------------------------------------------

variable "cce_cluster_flavor" {
  description = "CCE cluster flavor. Flavor codes are region specific."
  type        = string
  default     = "cce.s2.small"
}

variable "cce_node_flavor" {
  description = "Worker node flavor. Flavor codes are region specific."
  type        = string
  default     = "c7.xlarge.4"
}

variable "cce_node_count_per_az" {
  description = "Worker nodes per availability zone."
  type        = number
  default     = 1
}

variable "cce_container_network_type" {
  description = "overlay_l2 (simple) or eni (CCE Turbo, pods get VPC IPs)."
  type        = string
  default     = "eni"
}

variable "cce_node_root_volume_size" {
  description = "Worker node system disk size in GB."
  type        = number
  default     = 50
}

variable "cce_node_data_volume_size" {
  description = "Worker node data disk size in GB."
  type        = number
  default     = 100
}

# --- RDS PostgreSQL ----------------------------------------------------------

variable "rds_flavor" {
  description = "RDS flavor code (verified in cn-north-4: rds.pg.n1.xlarge.2.ha). Region specific - re-check before changing region."
  type        = string
  default     = "rds.pg.n1.xlarge.2.ha"
}

variable "rds_volume_size" {
  description = "RDS storage in GB."
  type        = number
  default     = 100
}

variable "rds_backup_keep_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

# --- DCS Redis ---------------------------------------------------------------

variable "dcs_flavor" {
  description = "DCS flavor code (verified in cn-north-4: redis.ha.xu1.large.r2.2). Region specific."
  type        = string
  default     = "redis.ha.xu1.large.r2.2"
}

variable "dcs_capacity" {
  description = "DCS capacity in GB. Must match the flavor."
  type        = number
  default     = 2
}

variable "dcs_ssl_enable" {
  description = "Enable TLS on DCS. LiteLLM then uses rediss:// for the cache."
  type        = bool
  default     = false
}

# --- ELB ---------------------------------------------------------------------

variable "elb_l7_flavor_id" {
  description = "Explicit L7 flavor ID. Empty means elastic L7 (billed per LCU)."
  type        = string
  default     = ""
}

variable "elb_eip_bandwidth_size" {
  description = "Public bandwidth of the gateway EIP in Mbit/s."
  type        = number
  default     = 300
}

variable "elb_eip_charge_mode" {
  description = "traffic or bandwidth."
  type        = string
  default     = "traffic"
}

variable "certificate_id" {
  description = "ELB certificate ID. Leave empty when the gateway should not terminate TLS (not recommended outside a lab)."
  type        = string
  default     = ""
}

variable "enable_https" {
  description = "Terminate TLS at the load balancer. Requires certificate_id."
  type        = bool
  default     = true
}

# --- Billing -----------------------------------------------------------------

variable "charging_mode" {
  description = "postPaid or prePaid."
  type        = string
  default     = "postPaid"

  validation {
    condition     = contains(["postPaid", "prePaid"], var.charging_mode)
    error_message = "charging_mode must be postPaid or prePaid."
  }
}

variable "period" {
  description = "Billing period when charging_mode is prePaid."
  type        = number
  default     = 1
}

variable "period_unit" {
  description = "month or year."
  type        = string
  default     = "month"
}

# --- Encryption --------------------------------------------------------------

variable "encryption_enabled" {
  description = "Create a KMS key and use it for RDS and CCE node disks."
  type        = bool
  default     = true
}

# --- VPN ---------------------------------------------------------------------

variable "vpn_enabled" {
  description = "Create a VPN gateway (tunnel configuration stays manual)."
  type        = bool
  default     = false
}

variable "customer_gateway_ip" {
  description = "Public IP of the on-premises VPN peer."
  type        = string
  default     = "0.0.0.0"
}

# --- ModelArts private access ------------------------------------------------

variable "vpce_enabled" {
  description = "Create a VPC endpoint so the gateway can call ModelArts online inference privately."
  type        = bool
  default     = false
}

variable "modelarts_vpce_service_id" {
  description = "VPC endpoint service ID for ModelArts private access (from the ModelArts console)."
  type        = string
  default     = ""
}

# --- Observability -----------------------------------------------------------

variable "lts_log_ttl_days" {
  description = "LTS retention in days for ELB access logs."
  type        = number
  default     = 30
}

variable "enable_lts_logs" {
  description = "Ship load balancer access logs to LTS."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Email for Cloud Eye alarms. SMN sends a confirmation mail. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "enable_alarms" {
  description = "Create the Cloud Eye alarms defined in locals.alarms. Opt-in: verify metric names in your region first."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
