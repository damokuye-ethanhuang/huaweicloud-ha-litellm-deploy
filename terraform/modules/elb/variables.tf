variable "name_prefix" {
  description = "Deprecated: kept for compatibility. Names come from `names`, see the naming module."
  type        = string
  default     = ""
}

variable "names" {
  description = "Name map from terraform/modules/naming. Selectors: elb, eip, cert"
  type        = map(string)
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the load balancer VIP."
  type        = string
}

variable "availability_zones" {
  description = "Two availability zones for the load balancer."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "A highly available load balancer needs at least two availability zones."
  }
}

variable "l7_flavor_id" {
  description = "Explicit L7 flavor ID. Leave empty to use the elastic L7 flavor (billed per LCU), which is the recommended default."
  type        = string
  default     = ""
}

variable "internal" {
  description = "true (default): no EIP, the load balancer is only reachable from the VPC and connected networks. false attaches an EIP (public exposure - not allowed in the internal reference design)."
  type        = bool
  default     = true
}

variable "eip_bandwidth_size" {
  description = "Public bandwidth in Mbit/s. Ignored when internal = true."
  type        = number
  default     = 300
}

variable "eip_charge_mode" {
  description = "EIP billing mode: traffic or bandwidth. Ignored when internal = true."
  type        = string
  default     = "traffic"
}

variable "certificate_id" {
  description = "Existing ELB/SCM certificate ID. Used when no PEM pair is supplied."
  type        = string
  default     = ""
}

variable "enable_https" {
  description = "Require a certificate for TLS termination. When false the module can be used for a plain HTTP lab deployment."
  type        = bool
  default     = true
}

variable "certificate_pem" {
  description = "PEM encoded server certificate. When set together with private_key_pem, the module creates an ELB certificate."
  type        = string
  default     = ""
  sensitive   = true
}

variable "private_key_pem" {
  description = "PEM encoded private key matching certificate_pem."
  type        = string
  default     = ""
  sensitive   = true
}

variable "deletion_protection" {
  description = "Block accidental deletion of the load balancer."
  type        = bool
  default     = true
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
