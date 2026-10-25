variable "region" {
  description = "Huawei Cloud region."
  type        = string
}

variable "site_type" {
  description = "domestic or international. The international site has no enterprise projects."
  type        = string
  default     = "domestic"

  validation {
    condition     = contains(["domestic", "international"], var.site_type)
    error_message = "site_type must be domestic or international."
  }
}

variable "project_name" {
  description = "Prefix for every resource name, for example litellmtest01."
  type        = string
}

variable "environment" {
  description = "Environment tag (not part of resource names)."
  type        = string
  default     = "prod"
}

variable "enterprise_project_id" {
  description = "Enterprise project ID. Forced to 0 on the international site."
  type        = string
  default     = "0"
}

# --- Network -----------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR. Must be a /21: the modules carve access/app/data/ops /24s and a /26 VPCE subnet from it in that order."
  type        = string
  default     = "10.0.0.0/21"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 21
    error_message = "vpc_cidr must be a /21, for example 10.0.0.0/21."
  }
}

variable "az_list" {
  description = "Availability zones. Empty means the first three returned by the API."
  type        = list(string)
  default     = []
}

variable "access_subnet_cidr" {
  description = "Ingress subnet: internal ELB VIP."
  type        = string
  default     = "10.0.0.0/24"
}

variable "app_subnet_cidr" {
  description = "Application subnet: CCE worker nodes."
  type        = string
  default     = "10.0.1.0/24"
}

variable "data_subnet_cidr" {
  description = "Data subnet: RDS, DCS and every other stateful component."
  type        = string
  default     = "10.0.2.0/24"
}

variable "ops_subnet_cidr" {
  description = "Operations subnet: the in-VPC bastion and future jump hosts. Reaches every service in the VPC."
  type        = string
  default     = "10.0.3.0/24"
}

variable "vpce_subnet_cidr" {
  description = "Small dedicated subnet for ModelArts VPCEP endpoints."
  type        = string
  default     = "10.0.4.0/26"
}

variable "pod_cidr" {
  description = "CCE overlay container network CIDR. Must not overlap the VPC CIDR."
  type        = string
  default     = "172.16.0.0/16"
}

variable "allowed_client_cidrs" {
  description = "VPC-internal CIDRs allowed to call the gateway API on 443 (business subnets, peered VPCs, VPN pools). Public ranges never work here: the ELB has no EIP."
  type        = list(string)

  validation {
    condition     = length(var.allowed_client_cidrs) > 0
    error_message = "allowed_client_cidrs must not be empty: the gateway is private and needs an allow-list."
  }
}

variable "admin_access_cidrs" {
  description = "VPC-internal CIDRs allowed to reach the Admin UI on 443. Narrower than allowed_client_cidrs; the ops subnet is the usual answer."
  type        = list(string)

  validation {
    condition     = length(var.admin_access_cidrs) > 0
    error_message = "admin_access_cidrs must not be empty; use the ops subnet CIDR."
  }
}

variable "bastion_enabled" {
  description = "Create the in-VPC bastion with a pay-per-use EIP. CCE has no public endpoint in this design, so every kubectl/helm/smoke-test command runs from this machine."
  type        = bool
  default     = true
}

variable "bastion_ssh_cidrs" {
  description = "Public CIDRs allowed to SSH into the bastion - the operator PCs' egress addresses. This is the only place a public range belongs. Empty disables SSH ingress (console/VNC only)."
  type        = list(string)
  default     = []
}

variable "bastion_flavor" {
  description = "Bastion ECS flavor. It runs kubectl/helm only."
  type        = string
  default     = "c7.large.2"
}

variable "bastion_eip_bandwidth_size" {
  description = "Bandwidth (Mbit/s) of the bastion's pay-per-use EIP."
  type        = number
  default     = 10
}

variable "bastion_eip_charge_mode" {
  description = "traffic (pay per GB) or bandwidth."
  type        = string
  default     = "traffic"
}

variable "ssh_ingress_cidrs" {
  description = "CIDRs allowed to reach the data subnet on 22. Empty disables SSH."
  type        = list(string)
  default     = []
}

# --- Egress ------------------------------------------------------------------

variable "model_endpoint_mode" {
  description = "vpcep (private model access only), nat (public model APIs allowed) or none (air-gapped)."
  type        = string
  default     = "vpcep"

  validation {
    condition     = contains(["vpcep", "nat", "none"], var.model_endpoint_mode)
    error_message = "model_endpoint_mode must be vpcep, nat or none."
  }
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway. Derived from model_endpoint_mode; set explicitly only to override."
  type        = bool
  default     = false
}

variable "nat_eip_bandwidth_size" {
  description = "NAT EIP bandwidth in Mbit/s."
  type        = number
  default     = 100
}

variable "modelarts_vpce_service_id" {
  description = "VPCEP service ID for ModelArts private access."
  type        = string
  default     = ""
}

variable "vpce_enabled" {
  description = "Create the ModelArts VPC endpoint."
  type        = bool
  default     = true
}

variable "vpn_enabled" {
  description = "Create a VPN gateway (tunnel stays manual)."
  type        = bool
  default     = false
}

variable "customer_gateway_ip" {
  description = "Public IP of the on-premises VPN peer."
  type        = string
  default     = "0.0.0.0"
}

variable "vpn_peer_cidrs" {
  description = "On-premises CIDRs routed over the VPN (used for documentation and route checks)."
  type        = list(string)
  default     = []
}

# --- TLS ---------------------------------------------------------------------

variable "tls_mode" {
  description = "elb_cert (public CA), internal_ca (internal CA) or none (lab only)."
  type        = string
  default     = "internal_ca"

  validation {
    condition     = contains(["elb_cert", "internal_ca", "none"], var.tls_mode)
    error_message = "tls_mode must be elb_cert, internal_ca or none."
  }
}

variable "enable_https" {
  description = "Terminate TLS at the internal load balancer."
  type        = bool
  default     = true
}

variable "certificate_id" {
  description = "ELB certificate ID (SCM). Required unless tls_mode = none."
  type        = string
  default     = ""
}

# --- Encryption --------------------------------------------------------------

variable "encryption_mode" {
  description = "kms (create a key), dew (reuse an existing key) or disabled."
  type        = string
  default     = "kms"

  validation {
    condition     = contains(["kms", "dew", "disabled"], var.encryption_mode)
    error_message = "encryption_mode must be kms, dew or disabled."
  }
}

variable "encryption_enabled" {
  description = "Encrypt RDS volumes and CCE node disks. Derived from encryption_mode."
  type        = bool
  default     = true
}

variable "create_kms_key" {
  description = "Create a dedicated KMS key. False when reusing a DEW key."
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "Existing KMS/DEW key ID to reuse when encryption_mode = dew."
  type        = string
  default     = null
}

# --- Observability -----------------------------------------------------------

variable "log_backend" {
  description = "lts or none."
  type        = string
  default     = "lts"

  validation {
    condition     = contains(["lts", "none"], var.log_backend)
    error_message = "log_backend must be lts or none."
  }
}

variable "metric_backend" {
  description = "aom or none."
  type        = string
  default     = "aom"

  validation {
    condition     = contains(["aom", "none"], var.metric_backend)
    error_message = "metric_backend must be aom or none."
  }
}

variable "enable_lts_logs" {
  description = "Create the LTS log group/stream and associate it with the ELB."
  type        = bool
  default     = true
}

variable "enable_aom" {
  description = "Create the AOM Prometheus instance used by the on-premises Grafana."
  type        = bool
  default     = true
}

variable "aom_retention" {
  description = "AOM Prometheus retention: 360h, 420h, 1440h or 2160h."
  type        = string
  default     = "360h"

  validation {
    condition     = contains(["360h", "420h", "1440h", "2160h"], var.aom_retention)
    error_message = "aom_retention must be one of 360h, 420h, 1440h, 2160h."
  }
}

variable "lts_log_ttl_days" {
  description = "LTS retention in days."
  type        = number
  default     = 30
}

variable "alarm_email" {
  description = "SMN subscription email for alarms. Empty disables subscriptions."
  type        = string
  default     = ""
}

# --- Sizing and versions -----------------------------------------------------

variable "cce_cluster_flavor" {
  description = "CCE cluster flavor (region specific)."
  type        = string
  default     = "cce.s2.small"
}

variable "cce_cluster_version" {
  description = "Kubernetes version, for example v1.31."
  type        = string
  default     = "v1.31"
}

variable "cce_node_flavor" {
  description = "Worker node flavor (region specific)."
  type        = string
  default     = "c7.xlarge.4"
}

variable "cce_node_count_per_az" {
  description = "Worker nodes per availability zone."
  type        = number
  default     = 1
}

variable "cce_container_network_type" {
  description = "vpc-router (default, VPC route based, no extra subnet), overlay_l2 or eni (CCE Turbo)."
  type        = string
  default     = "vpc-router"
}

variable "cce_node_root_volume_size" {
  description = "Worker node system disk in GB."
  type        = number
  default     = 50
}

variable "cce_node_data_volume_size" {
  description = "Worker node data disk in GB."
  type        = number
  default     = 100
}

variable "rds_pg_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "rds_flavor" {
  description = "RDS flavor (region specific)."
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

variable "dcs_redis_version" {
  description = "Redis version."
  type        = string
  default     = "7.0"
}

variable "dcs_flavor" {
  description = "DCS flavor (region specific)."
  type        = string
  default     = "redis.ha.xu1.large.r2.2"
}

variable "dcs_capacity" {
  description = "DCS capacity in GB."
  type        = number
  default     = 2
}

variable "dcs_ssl_enable" {
  description = "Enable TLS on DCS."
  type        = bool
  default     = false
}

variable "elb_l7_flavor_id" {
  description = "Explicit L7 flavor ID. Empty uses the elastic L7 flavor."
  type        = string
  default     = ""
}

variable "litellm_version" {
  description = "LiteLLM image tag. Never latest."
  type        = string
  default     = "1.106.3"
}

variable "litellm_image_repository" {
  description = "Image repository. Point at SWR for China regions."
  type        = string
  default     = "ghcr.io/berriai/litellm"
}

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
  description = "Billing period in months when prePaid."
  type        = number
  default     = 1
}

variable "period_unit" {
  description = "month or year."
  type        = string
  default     = "month"
}

variable "enable_alarms" {
  description = "Create the Cloud Eye alarms defined in the root module."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
