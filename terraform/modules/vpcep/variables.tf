variable "name_prefix" {
  description = "Prefix used in the endpoint description."
  type        = string
}

variable "service_id" {
  description = "VPC endpoint service ID. For ModelArts private access use the service ID shown in the ModelArts intranet-connection console."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Subnet that hosts the endpoint ENI."
  type        = string
}

variable "enable_dns" {
  description = "Enable private DNS for the endpoint."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to the endpoint."
  type        = map(string)
  default     = {}
}
