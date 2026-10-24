variable "name_prefix" {
  description = "Deprecated: kept for compatibility. Names come from `names`."
  type        = string
  default     = ""
}

variable "names" {
  description = "Name map from terraform/modules/naming."
  type        = map(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR. Must hold the access, app and data /24s plus the reserved container /24."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "access_subnet_cidr" {
  description = "Ingress subnet: internal ELB VIP, bastion. One /24."
  type        = string
}

variable "app_subnet_cidr" {
  description = "Application subnet: CCE worker nodes. One /24."
  type        = string
}

variable "data_subnet_cidr" {
  description = "Data subnet: RDS, DCS and every other stateful component. One /24."
  type        = string
}

variable "vpce_subnet_cidr" {
  description = "Small dedicated subnet for ModelArts VPCEP endpoints (/27 is enough). Created only when create_vpce_subnet is true."
  type        = string
  default     = "10.0.3.0/27"
}

variable "create_vpce_subnet" {
  description = "Create the VPCE subnet. Test environments without model private access can skip it."
  type        = bool
  default     = true
}

variable "availability_zone" {
  description = "AZ for the access and container subnets (the app subnet spans the node pools)."
  type        = string
}

variable "client_cidrs" {
  description = "Private CIDRs allowed to call the gateway on 443 via the internal ELB."
  type        = list(string)
}

variable "admin_cidrs" {
  description = "Private CIDRs allowed to reach the Admin UI. Narrower than client_cidrs."
  type        = list(string)
  default     = []
}

variable "bastion_ssh_cidrs" {
  description = "Public CIDRs allowed to SSH into the bastion. The only inbound path from outside the VPC."
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so the app subnet can reach external model APIs."
  type        = bool
  default     = false
}

variable "nat_spec" {
  description = "NAT gateway size: 1 small (10k connections), 2 medium, 3 large, 4 xlarge."
  type        = string
  default     = "1"
}

variable "nat_eip_bandwidth_size" {
  description = "Bandwidth (Mbit/s) of the NAT EIP."
  type        = number
  default     = 100
}

variable "nat_eip_charge_mode" {
  description = "traffic or bandwidth."
  type        = string
  default     = "traffic"
}

variable "enterprise_project_id" {
  description = "Enterprise project ID."
  type        = string
  default     = "0"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
