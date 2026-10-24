variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. \"litellm-prod\"."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "availability_zones" {
  description = "Availability zones used for the subnets. At least two zones are required for a highly available data layer."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "app_subnet_cidr" {
  description = "CIDR of the subnet hosting the CCE nodes (and the ELB VIP)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "app_gateway_ip" {
  description = "Gateway IP of the application subnet."
  type        = string
  default     = "10.0.1.1"
}

variable "data_subnet_cidr" {
  description = "CIDR of the subnet hosting RDS and DCS."
  type        = string
  default     = "10.0.2.0/24"
}

variable "data_gateway_ip" {
  description = "Gateway IP of the data subnet."
  type        = string
  default     = "10.0.2.1"
}

variable "vpce_subnet_cidr" {
  description = "CIDR of the subnet used for VPC endpoints (ModelArts / SWR / OBS private access)."
  type        = string
  default     = "10.0.3.0/28"
}

variable "vpce_gateway_ip" {
  description = "Gateway IP of the VPC endpoint subnet."
  type        = string
  default     = "10.0.3.1"
}

variable "eni_subnet_cidrs" {
  description = "CIDRs of the CCE Turbo ENI subnets, one per availability zone. Ignored when the cluster uses overlay networking."
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  validation {
    condition     = length(var.eni_subnet_cidrs) >= 2
    error_message = "Provide at least two ENI subnets so pods can span availability zones."
  }
}

variable "elb_ingress_cidrs" {
  description = "Source CIDRs allowed to reach the gateway on 443/80. Restrict this to your corporate egress ranges in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_ingress_cidrs" {
  description = "Source CIDRs allowed to SSH into instances. Empty list disables SSH ingress entirely."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so private workloads can reach external LLM APIs."
  type        = bool
  default     = true
}

variable "nat_spec" {
  description = "NAT gateway size: 1 (small, 10k SNAT connections), 2 (medium, 50k), 3 (large, 200k), 4 (xlarge, 1M)."
  type        = string
  default     = "1"

  validation {
    condition     = contains(["1", "2", "3", "4"], var.nat_spec)
    error_message = "nat_spec must be one of 1, 2, 3, 4."
  }
}

variable "nat_eip_bandwidth_size" {
  description = "Bandwidth (Mbit/s) of the NAT gateway EIP."
  type        = number
  default     = 100
}

variable "nat_eip_charge_mode" {
  description = "EIP billing mode for the NAT gateway: traffic or bandwidth."
  type        = string
  default     = "traffic"
}

variable "enterprise_project_id" {
  description = "Enterprise project ID. Use \"0\" for the default project."
  type        = string
  default     = "0"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
