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

variable "ops_subnet_cidr" {
  description = "Operations subnet: the in-VPC bastion and any future jump host. May reach every service in the VPC. One /24."
  type        = string

  validation {
    condition     = can(cidrhost(var.ops_subnet_cidr, 0)) && tonumber(split("/", var.ops_subnet_cidr)[1]) == 24
    error_message = "ops_subnet_cidr must be a valid IPv4 /24."
  }
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

variable "pod_cidr" {
  description = "Container network CIDR (overlay_l2 tunnel or vpc-router)."
  type        = string
  default     = "172.16.0.0/16"
}

variable "pod_cidr_ingress_enabled" {
  description = <<-EOT
    Open 5432/6379 to pod_cidr as well as to the app subnet.

    True only when pods hold VPC-routable addresses (container_network_type
    vpc-router or eni). With overlay_l2 the container IPs live behind VXLAN and
    the node source-NATs pod traffic to its own address, so the app-subnet rules
    are the ones that actually match.
  EOT
  type        = bool
  default     = false
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
