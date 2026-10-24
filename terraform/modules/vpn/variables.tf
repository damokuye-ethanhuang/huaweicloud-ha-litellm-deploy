variable "name_prefix" {
  description = "Deprecated: kept for compatibility. Names come from `names`, see the naming module."
  type        = string
  default     = ""
}

variable "names" {
  description = "Name map from terraform/modules/naming. Selectors: vpn, eip"
  type        = map(string)
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "connect_subnet_id" {
  description = "Subnet ID used by the VPN gateway to allocate the tunnel addresses."
  type        = string
}

variable "local_subnets" {
  description = "CIDRs reachable through the tunnel (normally the VPC CIDR)."
  type        = list(string)
}

variable "customer_gateway_ip" {
  description = "Public IP of the on-premises VPN peer. Leave 0.0.0.0 to create the gateway only and register the peer later."
  type        = string
  default     = "0.0.0.0"
}

variable "flavor" {
  description = "VPN gateway flavor, for example professional1."
  type        = string
  default     = "professional1"
}

variable "eip_bandwidth_size" {
  description = "Bandwidth in Mbit/s for each of the two active/active EIPs."
  type        = number
  default     = 50
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
